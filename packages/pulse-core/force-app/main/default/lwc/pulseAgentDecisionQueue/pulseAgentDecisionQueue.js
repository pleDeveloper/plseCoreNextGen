import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getPendingDecisions from '@salesforce/apex/PulseAgentController.getPendingDecisions';
import approveDecision from '@salesforce/apex/PulseAgentController.approveDecision';
import rejectDecision from '@salesforce/apex/PulseAgentController.rejectDecision';
import answerQuestion from '@salesforce/apex/PulseAgentController.answerQuestion';

const ASK_CLAUDE_HINTS = [
    { value: 'softer', label: 'Draft softer', hint: 'Please rewrite this draft with a softer, more conversational tone.' },
    { value: 'more_detail', label: 'Include more detail', hint: 'Please expand this with more concrete detail and context.' },
    { value: 'escalate', label: 'Escalate to me', hint: 'Hold off — I want to handle this one personally.' },
];

export default class PulseAgentDecisionQueue extends LightningElement {
    @api instanceId;

    @track decisions = [];
    @track loading = true;
    @track error = null;
    @track activeIndex = 0;
    @track refineOpenId = null;
    @track rejectOpenId = null;
    @track askOpenId = null;
    @track draft = {};     // decisionId -> draft { email:{...} | record:{...} | raw }
    @track rejectReason = '';
    @track answerValue = '';
    @track inFlightId = null;
    @track slideState = 'in';  // 'in' | 'out' — used for animation

    _pollHandle;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._load();
        this._pollHandle = setInterval(() => {
            if (this.instanceId) this._load(true);
        }, 3000);
    }

    disconnectedCallback() {
        if (this._pollHandle) clearInterval(this._pollHandle);
    }

    async _load(quiet) {
        if (!this.instanceId) { this.loading = false; return; }
        if (!quiet) this.loading = true;
        try {
            const list = await getPendingDecisions({ instanceId: this.instanceId });
            this.decisions = (list || []).map((d) => this._decorate(d));
            this.error = null;
            if (this.activeIndex >= this.decisions.length) this.activeIndex = 0;
        } catch (e) {
            this.error = e.body?.message || 'Failed to load decisions';
        } finally {
            this.loading = false;
        }
    }

    _decorate(d) {
        const preview = this._buildPreview(d);
        return {
            ...d,
            preview,
            isPropose: d.decisionType === 'Propose_Action',
            isAsk: d.decisionType === 'Ask_User',
            isAdvance: d.decisionType === 'Advance_Phase',
            typeLabel: this._typeLabel(d.decisionType),
            typeVariant: this._typeVariant(d.decisionType),
        };
    }

    _typeLabel(t) {
        return {
            Propose_Action: 'Proposal',
            Ask_User: 'Question',
            Advance_Phase: 'Advance',
            Observe: 'Note',
            Error: 'Error',
        }[t] || t;
    }
    _typeVariant(t) {
        return {
            Propose_Action: 'purple',
            Ask_User: 'magenta',
            Advance_Phase: 'success',
            Observe: 'gray',
            Error: 'error',
        }[t] || 'gray';
    }

    _buildPreview(d) {
        const args = (d.previewData && d.previewData.arguments) || d.previewData || {};
        if (d.previewKind === 'email') {
            return {
                kind: 'email',
                isEmail: true,
                to: args.toAddress || args.to || '',
                subject: args.subject || '(no subject)',
                body: args.body || '',
            };
        }
        if (d.previewKind === 'record') {
            const rows = [];
            if (args.field) rows.push({ key: args.field, value: String(args.value || '') });
            if (args.fields && typeof args.fields === 'object') {
                Object.keys(args.fields).forEach((k) => rows.push({ key: k, value: String(args.fields[k]) }));
            }
            return {
                kind: 'record',
                isRecord: true,
                objectType: args.objectType || '',
                recordId: args.recordId || '',
                rows,
                hasRows: rows.length > 0,
            };
        }
        if (d.previewKind === 'question') {
            const q = d.previewData || {};
            return {
                kind: 'question',
                isQuestion: true,
                prompt: q.prompt || '',
                fieldKey: q.fieldKey || '',
                inputType: q.inputType || 'free_text',
            };
        }
        if (d.previewKind === 'advance') {
            return {
                kind: 'advance',
                isAdvance: true,
                signal: (d.previewData && d.previewData.signal) || '',
            };
        }
        return {
            kind: 'raw',
            isRaw: true,
            raw: JSON.stringify(d.previewData || {}, null, 2),
        };
    }

    // ─── Derived ────────────────────────────────────────────────

    get hasDecisions() { return this.decisions.length > 0; }
    get active() { return this.decisions[this.activeIndex] || null; }
    get queueCounter() {
        if (!this.hasDecisions) return '';
        return `Decision ${this.activeIndex + 1} of ${this.decisions.length}`;
    }
    get slideClass() {
        return this.slideState === 'out' ? 'decision-card slide-out' : 'decision-card slide-in';
    }
    get refining() {
        return this.active && this.refineOpenId === this.active.decisionId;
    }
    get rejecting() {
        return this.active && this.rejectOpenId === this.active.decisionId;
    }
    get askingClaude() {
        return this.active && this.askOpenId === this.active.decisionId;
    }
    get activeDraft() {
        if (!this.active) return null;
        return this.draft[this.active.decisionId] || null;
    }
    get askHints() { return ASK_CLAUDE_HINTS; }

    // ─── Actions ────────────────────────────────────────────────

    async handleApprove() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        try {
            let refinedJson = null;
            if (this.refining) {
                refinedJson = this._buildRefinedJson(this.activeDraft);
            }
            const r = await approveDecision({
                payload: { decisionId: id, refinedPayloadJson: refinedJson }
            });
            if (!r.success) {
                this.error = r.error || 'Approve failed';
            } else {
                this._closeAllEditors();
                await this._slideAndReload();
            }
        } catch (e) {
            this.error = e.body?.message || 'Approve failed';
        } finally {
            this.inFlightId = null;
        }
    }

    handleReject() {
        if (!this.active) return;
        this.rejectOpenId = this.active.decisionId;
        this.refineOpenId = null;
        this.askOpenId = null;
        this.rejectReason = '';
    }

    handleRejectReason(event) {
        this.rejectReason = event.target?.value ?? event.detail?.value ?? '';
    }

    async handleRejectSubmit() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        try {
            const r = await rejectDecision({
                payload: { decisionId: id, reason: this.rejectReason }
            });
            if (!r.success) {
                this.error = r.error || 'Reject failed';
            } else {
                this._closeAllEditors();
                await this._slideAndReload();
            }
        } catch (e) {
            this.error = e.body?.message || 'Reject failed';
        } finally {
            this.inFlightId = null;
        }
    }

    handleRefineOpen() {
        if (!this.active) return;
        const d = this.active;
        const preview = d.preview;
        let draft;
        if (preview?.isEmail) {
            draft = { mode: 'email', email: { to: preview.to, subject: preview.subject, body: preview.body } };
        } else if (preview?.isRecord) {
            const fields = preview.rows && preview.rows.length
                ? preview.rows.slice()
                : [{ key: '', value: '' }];
            draft = { mode: 'record', record: { objectType: preview.objectType, recordId: preview.recordId, fields } };
        } else {
            draft = { mode: 'raw', raw: JSON.stringify((d.previewData && d.previewData.arguments) || {}, null, 2) };
        }
        this.draft = { ...this.draft, [d.decisionId]: draft };
        this.refineOpenId = d.decisionId;
        this.rejectOpenId = null;
        this.askOpenId = null;
    }

    handleRefineCancel() {
        this.refineOpenId = null;
    }

    handleRefineEmailTo(event) {
        this._mutateDraft((d, v) => { d.email.to = v; }, event);
    }
    handleRefineEmailSubject(event) {
        this._mutateDraft((d, v) => { d.email.subject = v; }, event);
    }
    handleRefineEmailBody(event) {
        this._mutateDraft((d, v) => { d.email.body = v; }, event);
    }
    handleRefineRaw(event) {
        this._mutateDraft((d, v) => { d.raw = v; }, event);
    }

    _mutateDraft(applyFn, event) {
        if (!this.active) return;
        const id = this.active.decisionId;
        const val = event.target?.value ?? event.detail?.value ?? '';
        const next = JSON.parse(JSON.stringify(this.draft[id] || {}));
        applyFn(next, val);
        this.draft = { ...this.draft, [id]: next };
    }

    _buildRefinedJson(draft) {
        if (!draft) return null;
        if (draft.mode === 'email') {
            return JSON.stringify({
                toAddress: draft.email.to,
                subject: draft.email.subject,
                body: draft.email.body,
            });
        }
        if (draft.mode === 'record') {
            const fields = {};
            (draft.record.fields || []).forEach((r) => {
                if (r.key) fields[r.key] = r.value;
            });
            return JSON.stringify({
                objectType: draft.record.objectType,
                recordId: draft.record.recordId,
                fields,
            });
        }
        if (draft.mode === 'raw') {
            try { JSON.parse(draft.raw || '{}'); }
            catch (e) { throw new Error('Edited JSON is not valid'); }
            return draft.raw;
        }
        return null;
    }

    handleAskOpen() {
        if (!this.active) return;
        this.askOpenId = this.active.decisionId;
        this.refineOpenId = null;
        this.rejectOpenId = null;
    }

    handleAskCancel() {
        this.askOpenId = null;
    }

    async handleAskHint(event) {
        const v = event.currentTarget?.dataset?.value;
        const hint = ASK_CLAUDE_HINTS.find((h) => h.value === v);
        if (!hint || !this.active) return;
        // Send the hint as a rejection with context — the agent will see it
        // and re-propose on the next turn via rolling summary.
        this.inFlightId = this.active.decisionId;
        try {
            await rejectDecision({
                payload: { decisionId: this.active.decisionId, reason: hint.hint }
            });
            this.askOpenId = null;
            await this._slideAndReload();
        } catch (e) {
            this.error = e.body?.message || 'Hint failed';
        } finally {
            this.inFlightId = null;
        }
    }

    handleAnswerChange(event) {
        this.answerValue = event.target?.value ?? event.detail?.value ?? '';
    }

    async handleAnswerSubmit() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        try {
            const r = await answerQuestion({
                payload: { decisionId: id, responseJson: JSON.stringify({ value: this.answerValue }) }
            });
            if (!r.success) {
                this.error = r.error || 'Answer failed';
            } else {
                this.answerValue = '';
                await this._slideAndReload();
            }
        } catch (e) {
            this.error = e.body?.message || 'Answer failed';
        } finally {
            this.inFlightId = null;
        }
    }

    _closeAllEditors() {
        this.refineOpenId = null;
        this.rejectOpenId = null;
        this.askOpenId = null;
        this.rejectReason = '';
        this.answerValue = '';
    }

    async _slideAndReload() {
        this.slideState = 'out';
        await new Promise((r) => setTimeout(r, 200));
        this.slideState = 'in';
        await this._load(true);
    }

    handleDismissError() { this.error = null; }
}

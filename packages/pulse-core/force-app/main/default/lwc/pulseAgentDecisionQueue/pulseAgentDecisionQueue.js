import { LightningElement, api, track } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getPendingDecisions from '@salesforce/apex/PulseAgentController.getPendingDecisions';
import getAgentState from '@salesforce/apex/PulseAgentController.getAgentState';
import approveDecision from '@salesforce/apex/PulseAgentController.approveDecision';
import rejectDecision from '@salesforce/apex/PulseAgentController.rejectDecision';
import answerQuestion from '@salesforce/apex/PulseAgentController.answerQuestion';

/**
 * pulseAgentDecisionQueue — generic HITL decision queue.
 *
 * Implements upstream-generic patterns from
 * docs/proposed-upstream-reactivity-and-ux-patterns.md:
 *   §1   Platform Event push subscription (filtered by 15-char Instance_Id__c)
 *   §2.1 render-signature diff
 *   §2.5 optimistic local mutation
 *   §4.1 chat-style "thinking" placeholder
 *   §4.2 friendly point-and-click refine editor (email | record | tool | raw)
 *   §4.3 public lifecycle hooks: @api startThinking / stopUpdates
 *
 * No workflow- or persona-specific branding lives here. The "thinking" copy
 * uses {personaName} sourced from getAgentState; the tool refine editor is
 * generic over {fields:{…}} envelopes.
 */
export default class PulseAgentDecisionQueue extends LightningElement {
    @api instanceId;

    @track decisions = [];
    @track loading = true;
    @track error = null;
    @track activeIndex = 0;
    @track refineOpenId = null;
    @track rejectOpenId = null;
    @track draft = {};     // decisionId -> draft { email | record | tool | raw }
    @track rejectReason = '';
    @track answerValue = '';
    @track inFlightId = null;
    @track slideState = 'in';  // 'in' | 'out' — used for animation

    // §4.1 thinking placeholder — purely client-side state.
    @track thinking = false;
    _thinkingTimer = null;

    // §1 push subscription state.
    _empSubscription = null;
    _empChannel = '/event/Pulse_Workflow_Update__e';

    // §2.1 / §2.5 — render-signature snapshot, reset by optimistic mutations.
    _lastSnapshot = null;
    // §4.3 lifecycle — set by stopUpdates(); checked at top of every load /
    // subscribe handler so in-flight events become no-ops after shutdown.
    _stopped = false;

    // §4.1 persona for "{personaName} is thinking" — sourced from
    // getAgentState. Defaults to a neutral label until the state loads.
    @track personaName = 'Agent';

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadPersona();
        this._load(true);
        this._subscribePush();
        onError(() => {});
    }

    disconnectedCallback() {
        this._unsubscribePush();
        if (this._thinkingTimer) {
            clearTimeout(this._thinkingTimer);
            this._thinkingTimer = null;
        }
    }

    // Parent components can call this after their own user actions to force
    // a fresh fetch (push delivery normally handles this on its own).
    @api
    async reload() {
        await this._load(true);
    }

    // §4.3 — sibling components (custom approval surface, chat surface, …)
    // call this so the queue's "{personaName} is thinking" affordance fires
    // immediately on their action instead of only when the queue itself is
    // clicked. The queue auto-clears on the next decision arrival.
    @api
    startThinking() {
        this._setThinking(true);
    }

    // §4.3 — cooperative shutdown. Parent stepper calls this when it detects
    // terminal state; we drop subscriptions, clear timers, and short-circuit
    // every subsequent load / subscribe.
    @api
    stopUpdates() {
        this._stopped = true;
        this._unsubscribePush();
        if (this._thinkingTimer) {
            clearTimeout(this._thinkingTimer);
            this._thinkingTimer = null;
        }
        this.thinking = false;
    }

    // ─── Persona ────────────────────────────────────────────────

    async _loadPersona() {
        if (!this.instanceId) return;
        try {
            const s = await getAgentState({ instanceId: this.instanceId });
            if (s && s.persona) this.personaName = s.persona;
        } catch (e) { /* keep default */ }
    }

    get personaInitial() {
        const n = (this.personaName || '').trim();
        return n ? n.charAt(0).toUpperCase() : 'A';
    }

    get thinkingMessage() {
        return `${this.personaName} is thinking`;
    }

    // ─── Push subscription (§1) ─────────────────────────────────

    _subscribePush() {
        if (this._empSubscription) return;
        if (this._stopped) return;
        subscribe(this._empChannel, -1, (msg) => {
            // Hard stop — bail before any work.
            if (this._stopped) return;
            const eventId = msg && msg.data && msg.data.payload
                && msg.data.payload.Instance_Id__c;
            if (!eventId || !this.instanceId) return;
            // Compare 15-char prefixes — payload is 18-char, prop may be 15.
            if (String(eventId).substring(0, 15) !== String(this.instanceId).substring(0, 15)) return;
            this._load(true);
        }).then((s) => { this._empSubscription = s; })
          .catch(() => { /* fall back to user-action refresh */ });
    }

    _unsubscribePush() {
        if (!this._empSubscription) return;
        try { unsubscribe(this._empSubscription, () => {}); } catch (e) { /* ignore */ }
        this._empSubscription = null;
    }

    // ─── Thinking placeholder (§4.1) ────────────────────────────

    _setThinking(on) {
        if (on) {
            this.thinking = true;
            if (this._thinkingTimer) clearTimeout(this._thinkingTimer);
            // 60s safety timeout in case no decision arrives.
            this._thinkingTimer = setTimeout(() => { this.thinking = false; }, 60000);
        } else {
            this.thinking = false;
            if (this._thinkingTimer) {
                clearTimeout(this._thinkingTimer);
                this._thinkingTimer = null;
            }
        }
    }

    // ─── Load + signature diff (§2.1) ───────────────────────────

    async _load(quiet) {
        if (!this.instanceId) { this.loading = false; return; }
        if (this._stopped) return;
        if (!quiet) this.loading = true;
        try {
            const list = await getPendingDecisions({ instanceId: this.instanceId });
            this.error = null;
            // §2.1 render-signature diff — only the fields the template
            // binds to, joined into a tiny string.
            const sig = (list || [])
                .map((d) => `${d.decisionId}|${d.status}|${d.score == null ? '' : d.score}`)
                .join(',');
            if (quiet && sig === this._lastSnapshot) return;
            this._lastSnapshot = sig;
            this.decisions = (list || []).map((d) => this._decorate(d));
            if (this.activeIndex >= this.decisions.length) this.activeIndex = 0;
            // §4.1 — new decision arrived, clear the optimistic placeholder.
            if (this.decisions.length > 0) this._setThinking(false);
        } catch (e) {
            // Quiet failures stay silent — keep last good state.
            if (!quiet) this.error = e.body?.message || 'Failed to load decisions';
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
        // Generic tool-call preview (§4.2): any propose_action with toolKey +
        // arguments gets a friendly key/value layout instead of a JSON dump.
        const pd = d.previewData || {};
        if (pd.toolKey && pd.arguments && typeof pd.arguments === 'object') {
            return {
                kind: 'tool',
                isTool: true,
                toolLabel: this._humanizeKey(pd.toolKey),
                rows: this._buildToolRows(pd.arguments),
            };
        }
        return {
            kind: 'raw',
            isRaw: true,
            raw: JSON.stringify(pd, null, 2),
        };
    }

    // Generic preview rows for a tool call. Hides internal/technical keys
    // and unwraps {fields:{…}} envelopes the agent sometimes uses when
    // emulating update_record style payloads. No persona-specific or
    // domain-specific formatting.
    _buildToolRows(args) {
        const HIDE_KEYS = new Set(['top_k', 'recordId', 'record_id', 'objectType', 'object_type']);
        let source = args;
        if (args && typeof args === 'object'
            && args.fields && typeof args.fields === 'object'
            && !Array.isArray(args.fields)) {
            source = args.fields;
        }
        const out = [];
        for (const [k, v] of Object.entries(source)) {
            if (HIDE_KEYS.has(k)) continue;
            if (v == null || v === '') continue;
            let display;
            if (Array.isArray(v)) {
                display = v.join(', ');
            } else if (typeof v === 'object') {
                display = JSON.stringify(v);
            } else {
                display = String(v);
            }
            out.push({ key: this._humanizeKey(k), value: display });
        }
        return out;
    }

    _humanizeKey(k) {
        return String(k).split(/[_-]/).map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
    }

    // ─── Derived ────────────────────────────────────────────────

    get hasDecisions() { return this.decisions.length > 0; }
    get active() { return this.decisions[this.activeIndex] || null; }
    get showThinking() { return this.thinking && !this.hasDecisions; }
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
    get activeDraft() {
        if (!this.active) return null;
        return this.draft[this.active.decisionId] || null;
    }

    // ─── Actions ────────────────────────────────────────────────

    async handleApprove() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        // Capture the draft and refining-state BEFORE the optimistic
        // removal — once we filter `decisions`, `this.active` no longer
        // refers to this row and `this.refining` flips to false.
        let refinedJson = null;
        if (this.refining) {
            refinedJson = this._buildRefinedJson(this.activeDraft);
        }
        // §2.5 optimistic local mutation: drop the active decision from
        // local state immediately. Same-reference preservation isn't needed
        // here since we're removing, not patching — but reset the snapshot
        // so the next push delivery still triggers a fresh load.
        this.decisions = this.decisions.filter((d) => d.decisionId !== id);
        if (this.activeIndex >= this.decisions.length) this.activeIndex = Math.max(0, this.decisions.length - 1);
        this._lastSnapshot = null;
        // §4.1 — show thinking immediately while the agent computes.
        this._setThinking(true);
        try {
            const r = await approveDecision({
                payload: { decisionId: id, refinedPayloadJson: refinedJson }
            });
            if (!r.success) {
                // Rollback — refetch real state.
                await this._load(true);
            } else {
                this._closeAllEditors();
                await this._load(true);
            }
        } catch (e) {
            await this._load(true);
        } finally {
            this.inFlightId = null;
        }
    }

    handleReject() {
        if (!this.active) return;
        this.rejectOpenId = this.active.decisionId;
        this.refineOpenId = null;
        this.rejectReason = '';
    }

    handleRejectReason(event) {
        this.rejectReason = event.target?.value ?? event.detail?.value ?? '';
    }

    async handleRejectSubmit() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        this.decisions = this.decisions.filter((d) => d.decisionId !== id);
        if (this.activeIndex >= this.decisions.length) this.activeIndex = Math.max(0, this.decisions.length - 1);
        this._lastSnapshot = null;
        this._setThinking(true);
        try {
            const r = await rejectDecision({
                payload: { decisionId: id, reason: this.rejectReason }
            });
            if (!r.success) {
                await this._load(true);
            } else {
                this._closeAllEditors();
                await this._load(true);
            }
        } catch (e) {
            await this._load(true);
        } finally {
            this.inFlightId = null;
        }
    }

    // ─── Refine (§4.2) ──────────────────────────────────────────

    handleRefineOpen() {
        if (!this.active) return;
        const d = this.active;
        const preview = d.preview;
        const args = (d.previewData && d.previewData.arguments) || {};
        let draft;
        if (preview?.isEmail) {
            draft = { mode: 'email', email: { to: preview.to, subject: preview.subject, body: preview.body } };
        } else if (preview?.isRecord) {
            const fields = preview.rows && preview.rows.length
                ? preview.rows.slice()
                : [{ key: '', value: '' }];
            draft = { mode: 'record', record: { objectType: preview.objectType, recordId: preview.recordId, fields } };
        } else if (preview?.isTool) {
            // §4.2 — friendly per-field editor for any tool call. Generic
            // over {fields:{…}} envelopes; type inferred from key + value.
            draft = this._buildToolDraft(args);
        } else {
            draft = { mode: 'raw', raw: JSON.stringify(args, null, 2) };
        }
        this.draft = { ...this.draft, [d.decisionId]: draft };
        this.refineOpenId = d.decisionId;
        this.rejectOpenId = null;
    }

    _buildToolDraft(args) {
        // Detect agent-wrapped shape ({fields:{…}}) and surface the inner
        // fields as the editable rows; preserve the wrapper on serialize.
        let wrapped = false;
        let source = args && typeof args === 'object' ? args : {};
        if (source.fields && typeof source.fields === 'object' && !Array.isArray(source.fields)) {
            source = source.fields;
            wrapped = true;
        }
        const fields = [];
        for (const [k, v] of Object.entries(source)) {
            if (k === 'top_k') continue;
            const type = this._inferFieldType(k, v);
            fields.push({
                key: k,
                label: this._humanizeKey(k),
                value: v == null ? '' : (Array.isArray(v) ? v.join(', ') : String(v)),
                type,
                isText:     type === 'text',
                isNumber:   type === 'number',
                isDate:     type === 'date',
                isLongText: type === 'longtext',
            });
        }
        return { mode: 'tool', tool: { wrapped, fields } };
    }

    _inferFieldType(key, value) {
        const k = String(key).toLowerCase();
        if (typeof value === 'number') return 'number';
        if (/amount|gift|budget|cost|price/.test(k)) return 'number';
        if (/deadline|due_?date|expires?$|^date$|^.*_date$/.test(k)) return 'date';
        if (/notes|description|reasoning|body|message|long/.test(k)) return 'longtext';
        if (typeof value === 'string' && value.length > 100) return 'longtext';
        return 'text';
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

    handleRefineToolField(event) {
        const idx = Number(event.target?.dataset?.index ?? event.currentTarget?.dataset?.index);
        let val;
        if (event.target?.type === 'number') {
            val = event.target.value === '' ? '' : Number(event.target.value);
        } else if (event.detail && Object.prototype.hasOwnProperty.call(event.detail, 'value')) {
            val = event.detail.value;
        } else {
            val = event.target?.value ?? '';
        }
        this._mutateDraft((d, v) => {
            if (!d.tool || !d.tool.fields[idx]) return;
            d.tool.fields[idx].value = v;
        }, { detail: { value: val } });
    }

    handleRefineToolAdd() {
        if (!this.active) return;
        const id = this.active.decisionId;
        const next = JSON.parse(JSON.stringify(this.draft[id] || {}));
        if (next.mode !== 'tool') return;
        next.tool.fields.push({
            key: '', label: 'New field', value: '', type: 'text',
            isText: true, isNumber: false, isDate: false, isLongText: false,
        });
        this.draft = { ...this.draft, [id]: next };
    }

    handleRefineToolRemove(event) {
        const idx = Number(event.currentTarget?.dataset?.index);
        if (Number.isNaN(idx)) return;
        if (!this.active) return;
        const id = this.active.decisionId;
        const next = JSON.parse(JSON.stringify(this.draft[id] || {}));
        if (next.mode !== 'tool') return;
        next.tool.fields.splice(idx, 1);
        this.draft = { ...this.draft, [id]: next };
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
        if (draft.mode === 'tool') {
            const out = {};
            (draft.tool.fields || []).forEach((r) => {
                if (!r.key) return;
                let v = r.value;
                if (r.type === 'number' && v !== '' && v != null) {
                    const n = Number(v);
                    v = Number.isNaN(n) ? r.value : n;
                }
                out[r.key] = v;
            });
            // Preserve the agent's original {fields:{…}} envelope so the next
            // turn's context isn't surprised by a different argument layout.
            const payload = draft.tool.wrapped ? { fields: out } : out;
            return JSON.stringify(payload);
        }
        if (draft.mode === 'raw') {
            try { JSON.parse(draft.raw || '{}'); }
            catch (e) { throw new Error('Edited JSON is not valid'); }
            return draft.raw;
        }
        return null;
    }

    handleAnswerChange(event) {
        this.answerValue = event.target?.value ?? event.detail?.value ?? '';
    }

    async handleAnswerSubmit() {
        if (!this.active || this.inFlightId) return;
        const id = this.active.decisionId;
        this.inFlightId = id;
        this.decisions = this.decisions.filter((d) => d.decisionId !== id);
        if (this.activeIndex >= this.decisions.length) this.activeIndex = Math.max(0, this.decisions.length - 1);
        this._lastSnapshot = null;
        this._setThinking(true);
        try {
            const r = await answerQuestion({
                payload: { decisionId: id, responseJson: JSON.stringify({ value: this.answerValue }) }
            });
            if (!r.success) {
                await this._load(true);
            } else {
                this.answerValue = '';
                await this._load(true);
            }
        } catch (e) {
            await this._load(true);
        } finally {
            this.inFlightId = null;
        }
    }

    _closeAllEditors() {
        this.refineOpenId = null;
        this.rejectOpenId = null;
        this.rejectReason = '';
        this.answerValue = '';
    }

    handleDismissError() { this.error = null; }
}

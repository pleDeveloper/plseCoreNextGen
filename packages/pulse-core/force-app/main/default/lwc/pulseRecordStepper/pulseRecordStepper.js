import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';
import advanceInstanceWithFields from '@salesforce/apex/PulseRuntimeController.advanceInstanceWithFields';
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';
import saveFieldValues from '@salesforce/apex/PulseRuntimeController.saveFieldValues';

const MAX_COLLAPSED_STEPS = 5;
const TERMINAL_STATUSES = ['Executed', 'Rejected', 'Failed', 'Cancelled'];

export default class PulseRecordStepper extends LightningElement {
    @api recordId;

    @track instance = null;
    @track error = null;
    @track advanceError = null;
    @track actionError = null;
    @track fieldError = null;
    @track isLoading = true;
    @track showModal = false;
    @track selectedSignal = null;
    @track payloadText = '';
    @track isAdvancing = false;
    @track timelineExpanded = false;
    @track resolvingActionId = null;

    // Refine state — keyed by actionId
    @track refiningActionId = null;          // currently-expanded action, if any
    @track refineDraft = {};                 // { actionId: { mode, email:{to,subject,body}, record:{fields[]}, raw } }

    // Phase field form state — fieldKey -> current edited value (string|bool)
    @track fieldValues = {};
    @track isSavingFields = false;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadInstance();
    }

    async _loadInstance() {
        if (!this.recordId) {
            this.isLoading = false;
            return;
        }
        this.isLoading = true;
        try {
            const data = await getInstanceForRecord({ recordId: this.recordId });
            this.instance = data || null;
            this.error = null;
            this._seedFieldValuesFromInstance();
        } catch (err) {
            this.instance = null;
            this.error = err.body?.message || 'Failed to load workflow instance';
        } finally {
            this.isLoading = false;
        }
    }

    _seedFieldValuesFromInstance() {
        const fields = this.instance?.phaseFields || [];
        const next = {};
        fields.forEach((f) => {
            // Preserve unsaved edits when the user has typed a value already.
            next[f.key] = Object.prototype.hasOwnProperty.call(this.fieldValues, f.key)
                ? this.fieldValues[f.key]
                : (f.currentValue == null ? '' : f.currentValue);
        });
        this.fieldValues = next;
    }

    // ─── Computed ───────────────────────────────────────────────

    get hasInstance() { return this.instance != null; }
    get noInstance() { return this.instance == null; }
    get hasError() { return this.error != null; }
    get hasAdvanceError() { return this.advanceError != null; }
    get hasActionError() { return this.actionError != null; }
    get hasFieldError() { return this.fieldError != null; }
    get hasPendingActions() { return (this.instance?.pendingActionCount || 0) > 0; }
    get pendingActionLabel() {
        const count = this.instance?.pendingActionCount || 0;
        return `${count} pending`;
    }

    // Phase actions rendering
    get phaseActions() {
        const raw = this.instance?.phaseActions || [];
        return raw.map((a) => {
            const preview = this._buildPreview(a);
            const isTerminal = TERMINAL_STATUSES.includes(a.status);
            const isAiTool = a.actionType === 'AI_Tool_Call';
            const isRefining = this.refiningActionId === a.actionId;
            const draft = this.refineDraft[a.actionId] || null;
            return {
                ...a,
                isPending: a.status === 'Pending',
                isReady: a.status === 'Ready',
                isBlocked: a.status === 'Blocked',
                isTerminal,
                statusVariant: this._statusVariant(a.status),
                requiredLabel: a.required ? 'Required' : 'Optional',
                blockedReason: a.blocked && a.dependsOn && a.dependsOn.length > 0
                    ? `Waiting on: ${a.dependsOn.join(', ')}`
                    : null,
                preview,
                resolving: this.resolvingActionId === a.actionId,
                refineEligible: isAiTool && a.status === 'Pending',
                refining: isRefining,
                draftMode: draft ? draft.mode : null,
                isEmailDraft: !!(draft && draft.mode === 'email'),
                isRecordDraft: !!(draft && draft.mode === 'record'),
                isRawDraft: !!(draft && draft.mode === 'raw'),
                draftEmail: draft ? draft.email : null,
                draftRecord: draft ? draft.record : null,
                draftRaw: draft ? draft.raw : '',
            };
        });
    }

    get hasPhaseActions() {
        return this.phaseActions.length > 0;
    }

    // Phase fields — one input per contract-declared field on the current phase
    get phaseFields() {
        const fields = this.instance?.phaseFields || [];
        return fields.map((f) => {
            const val = this.fieldValues[f.key];
            const type = (f.fieldType || 'Text');
            const normType = type.toLowerCase();
            return {
                ...f,
                isText: normType === 'text',
                isLongText: normType === 'longtextarea',
                isNumber: normType === 'number' || normType === 'percent',
                isCurrency: normType === 'currency',
                isDate: normType === 'date',
                isDateTime: normType === 'datetime',
                isPicklist: normType === 'picklist',
                isCheckbox: normType === 'checkbox' || normType === 'boolean',
                value: val == null ? '' : val,
                checkedValue: val === true || val === 'true',
                picklistOptions: (f.picklistValues || []).map((v) => ({ value: v, label: v, selected: String(val) === v })),
                requiredBadge: f.required ? 'Required' : 'Optional',
            };
        });
    }

    get hasPhaseFields() {
        return this.phaseFields.length > 0;
    }

    // Signal buttons only appear when the phase is ready to advance.
    // For manual_decision phases: show once all required actions done.
    // For auto phases: the HitlService auto-advances, so signals shouldn't normally appear.
    get shouldShowSignals() {
        if (!this.instance) return false;
        if (!this.signals.length) return false;
        // No declarative phase actions — legacy state, always show signals.
        if (!this.hasPhaseActions) return true;
        // With actions defined: only show signals when phase is complete.
        return this.instance.phaseComplete === true;
    }

    get signals() {
        return (this.instance?.availableSignals || []).map((s) => ({
            ...s,
            label: this._signalLabel(s.signal),
        }));
    }

    get hasSignals() {
        return this.shouldShowSignals;
    }

    get historySteps() {
        const steps = this.instance?.history || [];
        if (!this.timelineExpanded && steps.length > MAX_COLLAPSED_STEPS) {
            return steps.slice(steps.length - MAX_COLLAPSED_STEPS);
        }
        return steps;
    }

    get hasHistory() { return (this.instance?.history || []).length > 0; }
    get isTimelineCollapsible() {
        return (this.instance?.history || []).length > MAX_COLLAPSED_STEPS;
    }

    get timelineToggleLabel() {
        if (this.timelineExpanded) return 'Show less';
        const total = (this.instance?.history || []).length;
        return `Show all ${total} steps`;
    }

    get payloadPlaceholder() { return 'JSON payload, e.g. key: value'; }

    get modalTitle() {
        return this.selectedSignal
            ? `Advance: ${this._signalLabel(this.selectedSignal)}`
            : 'Advance workflow';
    }

    // ─── Handlers ───────────────────────────────────────────────

    handleSignalClick(event) {
        const signal = event.currentTarget.dataset.signal;
        this.selectedSignal = signal;
        this.payloadText = '';
        this.showModal = true;
    }

    handlePayloadChange(event) { this.payloadText = event.detail.value; }

    handleModalClose() {
        this.showModal = false;
        this.selectedSignal = null;
    }

    async handleAdvanceSubmit() {
        if (!this.selectedSignal || this.isAdvancing) return;
        this.isAdvancing = true;
        this.advanceError = null;
        try {
            const payloadJson = this.payloadText || null;
            const hasFieldEdits = this.hasPhaseFields;
            const result = hasFieldEdits
                ? await advanceInstanceWithFields({
                      instanceId: this.instance.instanceId,
                      signal: this.selectedSignal,
                      payloadJson,
                      idempotencyKey: null,
                      fieldValues: this._collectFieldValuesForSave(),
                  })
                : await advanceInstance({
                      instanceId: this.instance.instanceId,
                      signal: this.selectedSignal,
                      payloadJson,
                      idempotencyKey: null,
                  });
            if (result.success) {
                this.showModal = false;
                this.selectedSignal = null;
                if (result.refreshed) {
                    this.instance = result.refreshed;
                    this._seedFieldValuesFromInstance();
                }
            } else {
                this.advanceError = result.error || 'Advance failed';
            }
        } catch (err) {
            this.advanceError = err.body?.message || 'Unexpected error';
        } finally {
            this.isAdvancing = false;
        }
    }

    handleDismissError() { this.advanceError = null; }
    handleDismissActionError() { this.actionError = null; }
    handleDismissFieldError() { this.fieldError = null; }
    handleToggleTimeline() { this.timelineExpanded = !this.timelineExpanded; }

    async handleApproveAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Approve', null);
    }

    async handleRejectAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Reject', null);
    }

    // ─── Refine (edit AI draft before approving) ─────────────────

    handleRefineOpen(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const action = (this.instance?.phaseActions || []).find((a) => a.actionId === actionId);
        if (!action) return;

        this.refineDraft = {
            ...this.refineDraft,
            [actionId]: this._initDraftFromAction(action),
        };
        this.refiningActionId = actionId;
    }

    handleRefineCancel(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const next = { ...this.refineDraft };
        delete next[actionId];
        this.refineDraft = next;
        if (this.refiningActionId === actionId) {
            this.refiningActionId = null;
        }
    }

    handleRefineEmailTo(event) {
        this._mutateDraft(event, (d, val) => { d.email.to = val; });
    }
    handleRefineEmailSubject(event) {
        this._mutateDraft(event, (d, val) => { d.email.subject = val; });
    }
    handleRefineEmailBody(event) {
        this._mutateDraft(event, (d, val) => { d.email.body = val; });
    }
    handleRefineRecordField(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const idx = Number(event.currentTarget.dataset.index);
        const which = event.currentTarget.dataset.which; // 'key' | 'value'
        const val = event.target?.value ?? event.detail?.value ?? '';
        const draft = this.refineDraft[actionId];
        if (!draft || !draft.record) return;
        const rows = draft.record.fields.slice();
        const row = { ...rows[idx] };
        row[which] = val;
        rows[idx] = row;
        this.refineDraft = {
            ...this.refineDraft,
            [actionId]: { ...draft, record: { ...draft.record, fields: rows } },
        };
    }
    handleRefineRaw(event) {
        this._mutateDraft(event, (d, val) => { d.raw = val; });
    }

    _mutateDraft(event, applyFn) {
        const actionId = event.currentTarget.dataset.actionId;
        const val = event.target?.value ?? event.detail?.value ?? '';
        const draft = this.refineDraft[actionId];
        if (!draft) return;
        const next = JSON.parse(JSON.stringify(draft));
        applyFn(next, val);
        this.refineDraft = { ...this.refineDraft, [actionId]: next };
    }

    async handleRefineApprove(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const draft = this.refineDraft[actionId];
        if (!draft) return;
        let refinedJson;
        try {
            refinedJson = this._buildRefinedJson(draft);
        } catch (e) {
            this.actionError = e.message || 'Refined payload is not valid JSON';
            return;
        }
        await this._resolveAction(actionId, 'Approve', refinedJson);
        // Clear the refine state after resolving
        const next = { ...this.refineDraft };
        delete next[actionId];
        this.refineDraft = next;
        if (this.refiningActionId === actionId) this.refiningActionId = null;
    }

    async _resolveAction(actionId, decision, refinedPayloadJson) {
        if (!actionId || this.resolvingActionId) return;
        this.resolvingActionId = actionId;
        this.actionError = null;
        try {
            const result = await resolveAction({
                actionId,
                decision,
                notes: null,
                refinedPayloadJson: refinedPayloadJson || null,
            });
            if (!result.success) {
                this.actionError = result.message || 'Action failed';
            }
        } catch (err) {
            this.actionError = err.body?.message || err?.message || 'Unexpected error';
        } finally {
            this.resolvingActionId = null;
            await this._loadInstance();
        }
    }

    // ─── Phase fields ───────────────────────────────────────────

    handleFieldChange(event) {
        const key = event.currentTarget?.dataset?.fieldKey
            || event.target?.dataset?.fieldKey;
        if (!key) return;
        // Prefer CustomEvent detail.value (emitted by c-pulse-input and our
        // own native onchange dispatches); fall back to native element value.
        let val;
        if (event.target?.type === 'checkbox') {
            val = event.target.checked;
        } else if (event.detail && Object.prototype.hasOwnProperty.call(event.detail, 'value')) {
            val = event.detail.value;
        } else {
            val = event.target?.value ?? '';
        }
        this.fieldValues = { ...this.fieldValues, [key]: val };
    }

    handleFieldCheckboxChange(event) {
        const key = event.currentTarget?.dataset?.fieldKey;
        if (!key) return;
        const checked = event.target?.checked ?? event.detail?.checked ?? false;
        this.fieldValues = { ...this.fieldValues, [key]: checked };
    }

    async handleSaveFields() {
        if (this.isSavingFields || !this.instance?.instanceId) return;
        this.isSavingFields = true;
        this.fieldError = null;
        try {
            const values = this._collectFieldValuesForSave();
            const refreshed = await saveFieldValues({
                instanceId: this.instance.instanceId,
                values,
            });
            if (refreshed) {
                this.instance = refreshed;
                this._seedFieldValuesFromInstance();
            }
        } catch (err) {
            this.fieldError = err.body?.message || err?.message || 'Failed to save fields';
        } finally {
            this.isSavingFields = false;
        }
    }

    _collectFieldValuesForSave() {
        const out = {};
        const fields = this.instance?.phaseFields || [];
        fields.forEach((f) => {
            if (!Object.prototype.hasOwnProperty.call(this.fieldValues, f.key)) return;
            const raw = this.fieldValues[f.key];
            if (raw === '' || raw == null) return;
            const t = (f.fieldType || 'Text').toLowerCase();
            if (t === 'checkbox' || t === 'boolean') {
                out[f.key] = raw === true || raw === 'true';
            } else if (t === 'number' || t === 'currency' || t === 'percent') {
                const n = Number(raw);
                out[f.key] = Number.isFinite(n) ? n : raw;
            } else {
                out[f.key] = raw;
            }
        });
        return out;
    }

    // ─── Helpers ────────────────────────────────────────────────

    _signalLabel(signal) {
        if (!signal) return '';
        return signal.charAt(0).toUpperCase() + signal.slice(1).replace(/_/g, ' ');
    }

    _statusVariant(status) {
        if (status === 'Executed') return 'success';
        if (status === 'Pending') return 'purple';
        if (status === 'Ready') return 'purple';
        if (status === 'Rejected' || status === 'Failed') return 'error';
        if (status === 'Blocked') return 'gray';
        if (status === 'Cancelled') return 'gray';
        return 'gray';
    }

    _buildPreview(action) {
        if (!action.requestJson) return null;
        let parsed;
        try { parsed = JSON.parse(action.requestJson); }
        catch (e) { return { kind: 'raw', raw: action.requestJson }; }

        if (action.toolKey === 'send_email' && parsed) {
            return {
                kind: 'email',
                isEmail: true,
                to: parsed.toAddress || parsed.to || '',
                subject: parsed.subject || '(no subject)',
                body: parsed.body || '',
            };
        }
        if (action.toolKey === 'update_record' && parsed) {
            const rows = [];
            if (parsed.field) rows.push({ key: parsed.field, value: String(parsed.value || '') });
            if (parsed.fields && typeof parsed.fields === 'object') {
                Object.keys(parsed.fields).forEach((k) => {
                    rows.push({ key: k, value: String(parsed.fields[k]) });
                });
            }
            return {
                kind: 'record',
                isRecord: true,
                objectType: parsed.objectType || '',
                recordId: parsed.recordId || '',
                rows,
                hasRows: rows.length > 0,
            };
        }
        return {
            kind: 'raw',
            raw: JSON.stringify(parsed, null, 2),
        };
    }

    _initDraftFromAction(action) {
        let parsed = null;
        try { parsed = action.requestJson ? JSON.parse(action.requestJson) : {}; }
        catch (e) { parsed = null; }

        if (parsed && action.toolKey === 'send_email') {
            return {
                mode: 'email',
                email: {
                    to: parsed.toAddress || parsed.to || '',
                    subject: parsed.subject || '',
                    body: parsed.body || '',
                },
                extras: Object.keys(parsed).reduce((acc, k) => {
                    if (!['toAddress', 'to', 'subject', 'body'].includes(k)) acc[k] = parsed[k];
                    return acc;
                }, {}),
            };
        }
        if (parsed && action.toolKey === 'update_record') {
            const fields = [];
            if (parsed.field) {
                fields.push({ key: parsed.field, value: String(parsed.value || '') });
            }
            if (parsed.fields && typeof parsed.fields === 'object') {
                Object.keys(parsed.fields).forEach((k) => {
                    fields.push({ key: k, value: String(parsed.fields[k]) });
                });
            }
            if (fields.length === 0) fields.push({ key: '', value: '' });
            return {
                mode: 'record',
                record: {
                    objectType: parsed.objectType || '',
                    recordId: parsed.recordId || '',
                    fields,
                },
            };
        }
        // Fallback: raw JSON textarea for anything else (or unparseable)
        return {
            mode: 'raw',
            raw: action.requestJson
                ? (parsed ? JSON.stringify(parsed, null, 2) : action.requestJson)
                : '{}',
        };
    }

    _buildRefinedJson(draft) {
        if (draft.mode === 'raw') {
            try {
                const parsed = JSON.parse(draft.raw || '{}');
                return JSON.stringify(parsed);
            } catch (e) {
                throw new Error('Edited JSON is not valid: ' + e.message);
            }
        }
        if (draft.mode === 'email') {
            const out = { ...(draft.extras || {}) };
            if (draft.email.to) out.toAddress = draft.email.to;
            if (draft.email.subject != null) out.subject = draft.email.subject;
            if (draft.email.body != null) out.body = draft.email.body;
            return JSON.stringify(out);
        }
        if (draft.mode === 'record') {
            const out = {};
            if (draft.record.objectType) out.objectType = draft.record.objectType;
            if (draft.record.recordId) out.recordId = draft.record.recordId;
            const fields = {};
            (draft.record.fields || []).forEach((row) => {
                if (row.key) fields[row.key] = row.value;
            });
            out.fields = fields;
            return JSON.stringify(out);
        }
        return '{}';
    }
}

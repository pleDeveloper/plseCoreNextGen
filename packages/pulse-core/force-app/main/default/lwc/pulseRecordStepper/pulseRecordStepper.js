import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';

const MAX_COLLAPSED_STEPS = 5;
const TERMINAL_STATUSES = ['Executed', 'Rejected', 'Failed', 'Cancelled'];

export default class PulseRecordStepper extends LightningElement {
    @api recordId;

    @track instance = null;
    @track error = null;
    @track advanceError = null;
    @track actionError = null;
    @track isLoading = true;
    @track showModal = false;
    @track selectedSignal = null;
    @track payloadText = '';
    @track isAdvancing = false;
    @track timelineExpanded = false;
    @track resolvingActionId = null;

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
        } catch (err) {
            this.instance = null;
            this.error = err.body?.message || 'Failed to load workflow instance';
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Computed ───────────────────────────────────────────────

    get hasInstance() { return this.instance != null; }
    get noInstance() { return this.instance == null; }
    get hasError() { return this.error != null; }
    get hasAdvanceError() { return this.advanceError != null; }
    get hasActionError() { return this.actionError != null; }
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
            };
        });
    }

    get hasPhaseActions() {
        return this.phaseActions.length > 0;
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
            const result = await advanceInstance({
                instanceId: this.instance.instanceId,
                signal: this.selectedSignal,
                payloadJson: this.payloadText || null,
                idempotencyKey: null,
            });
            if (result.success) {
                this.showModal = false;
                this.selectedSignal = null;
                if (result.refreshed) {
                    this.instance = result.refreshed;
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
    handleToggleTimeline() { this.timelineExpanded = !this.timelineExpanded; }

    async handleApproveAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Approve');
    }

    async handleRejectAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Reject');
    }

    async _resolveAction(actionId, decision) {
        if (!actionId || this.resolvingActionId) return;
        this.resolvingActionId = actionId;
        this.actionError = null;
        try {
            const result = await resolveAction({ actionId, decision, notes: null });
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
}

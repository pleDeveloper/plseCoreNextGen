import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';

const MAX_COLLAPSED_STEPS = 5;

export default class PulseRecordStepper extends LightningElement {
    @api recordId;

    @track instance = null;
    @track error = null;
    @track advanceError = null;
    @track isLoading = true;
    @track showModal = false;
    @track selectedSignal = null;
    @track payloadText = '';
    @track isAdvancing = false;
    @track timelineExpanded = false;

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

    get hasInstance() {
        return this.instance != null;
    }

    get noInstance() {
        return this.instance == null;
    }

    get hasError() {
        return this.error != null;
    }

    get hasAdvanceError() {
        return this.advanceError != null;
    }

    get hasPendingActions() {
        return this.instance?.pendingActionCount > 0;
    }

    get pendingActionLabel() {
        const count = this.instance?.pendingActionCount || 0;
        return `${count} pending`;
    }

    get signals() {
        return (this.instance?.availableSignals || []).map((s) => ({
            ...s,
            label: this._signalLabel(s.signal),
        }));
    }

    get hasSignals() {
        return this.signals.length > 0;
    }

    get historySteps() {
        const steps = this.instance?.history || [];
        if (!this.timelineExpanded && steps.length > MAX_COLLAPSED_STEPS) {
            return steps.slice(steps.length - MAX_COLLAPSED_STEPS);
        }
        return steps;
    }

    get hasHistory() {
        return (this.instance?.history || []).length > 0;
    }

    get isTimelineCollapsible() {
        return (this.instance?.history || []).length > MAX_COLLAPSED_STEPS;
    }

    get timelineToggleLabel() {
        if (this.timelineExpanded) {
            return 'Show less';
        }
        const total = (this.instance?.history || []).length;
        return `Show all ${total} steps`;
    }

    get payloadPlaceholder() {
        return 'JSON payload, e.g. key: value';
    }

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

    handlePayloadChange(event) {
        this.payloadText = event.detail.value;
    }

    handleModalClose() {
        this.showModal = false;
        this.selectedSignal = null;
    }

    async handleAdvanceSubmit() {
        if (!this.selectedSignal || this.isAdvancing) {
            return;
        }
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

    handleDismissError() {
        this.advanceError = null;
    }

    handleToggleTimeline() {
        this.timelineExpanded = !this.timelineExpanded;
    }

    // ─── Helpers ────────────────────────────────────────────────

    _signalLabel(signal) {
        if (!signal) return '';
        return signal.charAt(0).toUpperCase() + signal.slice(1).replace(/_/g, ' ');
    }
}

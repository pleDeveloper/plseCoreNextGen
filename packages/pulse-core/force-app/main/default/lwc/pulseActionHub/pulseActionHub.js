import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import getPendingActions from '@salesforce/apex/PulseRuntimeController.getPendingActions';
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';

export default class PulseActionHub extends LightningElement {
    @api recordId;
    @api instanceId;

    @track actions = [];
    @track resolvedInstanceId = null;
    @track isLoading = true;
    @track error = null;
    @track resolveError = null;
    @track notesByActionId = {};
    @track resolvingActionId = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        this.isLoading = true;
        try {
            let instId = this.instanceId;
            if (!instId && this.recordId) {
                const inst = await getInstanceForRecord({ recordId: this.recordId });
                instId = inst?.instanceId || null;
                this.resolvedInstanceId = instId;
            }
            if (instId) {
                this.actions = await getPendingActions({ instanceId: instId }) || [];
            } else {
                this.actions = [];
            }
            this.error = null;
        } catch (err) {
            this.actions = [];
            this.error = err.body?.message || 'Failed to load pending actions';
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Computed ───────────────────────────────────────────────

    get effectiveInstanceId() {
        return this.instanceId || this.resolvedInstanceId;
    }

    get hasActions() {
        return this.actions.length > 0;
    }

    get noActions() {
        return this.actions.length === 0;
    }

    get countLabel() {
        return `${this.actions.length}`;
    }

    get hasError() {
        return this.error != null;
    }

    get hasResolveError() {
        return this.resolveError != null;
    }

    get actionCards() {
        return this.actions.map((a) => ({
            ...a,
            formattedRequest: this._formatJson(a.requestJson),
            notes: this.notesByActionId[a.actionId] || '',
            isResolving: this.resolvingActionId === a.actionId,
        }));
    }

    // ─── Handlers ───────────────────────────────────────────────

    handleNotesChange(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this.notesByActionId = {
            ...this.notesByActionId,
            [actionId]: event.detail.value,
        };
    }

    async handleApprove(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolve(actionId, 'Approve');
    }

    async handleReject(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolve(actionId, 'Reject');
    }

    handleDismissResolveError() {
        this.resolveError = null;
    }

    // ─── Private ────────────────────────────────────────────────

    async _resolve(actionId, decision) {
        if (this.resolvingActionId) return;
        this.resolvingActionId = actionId;
        this.resolveError = null;

        try {
            const result = await resolveAction({
                actionId,
                decision,
                notes: this.notesByActionId[actionId] || null,
            });

            if (result.success) {
                // eslint-disable-next-line no-alert
                alert(`${decision === 'Approve' ? 'Approved' : 'Rejected'}: ${result.message}`);
                await this._loadData();
            } else {
                this.resolveError = result.message || `${decision} failed`;
            }
        } catch (err) {
            this.resolveError = err.body?.message || 'Unexpected error';
        } finally {
            this.resolvingActionId = null;
        }
    }

    _formatJson(jsonStr) {
        if (!jsonStr) return '';
        try {
            return JSON.stringify(JSON.parse(jsonStr), null, 2);
        } catch {
            return jsonStr;
        }
    }
}

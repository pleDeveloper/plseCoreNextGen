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
        return this.actions.map((a) => {
            const parsed = this._parseJson(a.requestJson);
            const preview = this._buildPreview(a.toolKey, parsed);
            return {
                ...a,
                preview,
                toolLabel: this._toolLabel(a.toolKey),
                notes: this.notesByActionId[a.actionId] || '',
                isResolving: this.resolvingActionId === a.actionId,
            };
        });
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

    _parseJson(jsonStr) {
        if (!jsonStr) return {};
        try { return JSON.parse(jsonStr); } catch { return {}; }
    }

    _formatJson(jsonStr) {
        if (!jsonStr) return '';
        try {
            return JSON.stringify(JSON.parse(jsonStr), null, 2);
        } catch {
            return jsonStr;
        }
    }

    _toolLabel(toolKey) {
        const map = {
            send_email: 'Send email',
            update_record: 'Update record',
            external_api: 'External API call',
        };
        return map[toolKey] || toolKey;
    }

    /**
     * Returns a structured preview object the template renders via
     * lwc:if on preview.kind. Never throws — unknown tool keys fall
     * through to a generic key/value view.
     */
    _buildPreview(toolKey, req) {
        if (toolKey === 'send_email') {
            return {
                kind: 'email',
                isEmail: true,
                to: req.toAddress || req.to || '(recipient missing)',
                subject: req.subject || '(no subject)',
                body: req.body || req.htmlBody || '',
            };
        }
        if (toolKey === 'update_record') {
            const fields = req.fields || {};
            const rows = Object.keys(fields).map((k) => ({
                key: k,
                field: k,
                value: String(fields[k]),
            }));
            return {
                kind: 'record',
                isRecord: true,
                objectType: req.objectType || '(unknown object)',
                recordId: req.recordId || '(no record id)',
                rows,
                hasRows: rows.length > 0,
            };
        }
        if (toolKey === 'external_api') {
            return {
                kind: 'api',
                isApi: true,
                method: (req.method || 'POST').toUpperCase(),
                endpoint: req.endpoint || '(no endpoint)',
                bodyPreview: req.body ? JSON.stringify(req.body, null, 2) : '',
                hasBody: req.body != null,
            };
        }
        // Fallback: render parsed keys as rows
        const rows = Object.keys(req).map((k) => ({
            key: k,
            field: k,
            value: typeof req[k] === 'object' ? JSON.stringify(req[k]) : String(req[k]),
        }));
        return { kind: 'generic', isGeneric: true, rows, hasRows: rows.length > 0 };
    }
}

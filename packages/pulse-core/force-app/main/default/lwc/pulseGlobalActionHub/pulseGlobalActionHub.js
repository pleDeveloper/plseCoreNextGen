import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getMyPendingActions from '@salesforce/apex/PulseGlobalActionHubController.getMyPendingActions';
import approveAction from '@salesforce/apex/PulseGlobalActionHubController.approveAction';
import rejectAction from '@salesforce/apex/PulseGlobalActionHubController.rejectAction';

const FILTER_OPTIONS = [
    { key: 'both', label: 'All' },
    { key: 'me', label: 'Assigned to me' },
    { key: 'myQueues', label: 'My queues' },
    { key: 'includeUnassigned', label: 'Unassigned' },
];

export default class PulseGlobalActionHub extends LightningElement {
    @api hideAssignedFilter = false;
    @api defaultAssignedFilter = 'both';

    @track rows = [];
    @track isLoading = true;
    @track error = null;
    @track resolveError = null;
    @track expandedRowId = null;
    @track notesByActionId = {};
    @track refinedJsonByActionId = {};
    @track refiningActionId = null;
    @track resolvingActionId = null;
    @track activeFilter = 'both';

    connectedCallback() {
        loadPulseBrandTokens(this);
        this.activeFilter = this.defaultAssignedFilter || 'both';
        this._loadData();
    }

    async _loadData() {
        this.isLoading = true;
        try {
            const filters = this._buildFilters();
            const data = await getMyPendingActions({ filters });
            this.rows = Array.isArray(data) ? data : [];
            this.error = null;
        } catch (err) {
            this.rows = [];
            this.error = (err && err.body && err.body.message) || 'Failed to load pending approvals';
        } finally {
            this.isLoading = false;
        }
    }

    _buildFilters() {
        switch (this.activeFilter) {
            case 'me':
                return { assignedOnlyToMe: true };
            case 'myQueues':
                return { includeUnassigned: false };
            case 'includeUnassigned':
                return { includeUnassigned: true };
            case 'both':
            default:
                return { includeUnassigned: false };
        }
    }

    get filterChips() {
        return FILTER_OPTIONS.map((opt) => ({
            ...opt,
            itemClass: this.activeFilter === opt.key
                ? 'hub-chip hub-chip-active'
                : 'hub-chip',
            isActive: this.activeFilter === opt.key,
        }));
    }

    get hasRows() { return this.rows.length > 0; }
    get noRows()  { return this.rows.length === 0; }
    get countLabel() { return `${this.rows.length}`; }
    get hasError() { return this.error != null; }
    get hasResolveError() { return this.resolveError != null; }

    get displayRows() {
        return this.rows.map((r) => {
            const expanded = this.expandedRowId === r.actionId;
            const parsed = this._parseJson(r.requestJson);
            const refinedDraft = this.refinedJsonByActionId[r.actionId] != null
                ? this.refinedJsonByActionId[r.actionId]
                : this._formatJson(r.requestJson);
            return {
                ...r,
                isExpanded: expanded,
                toggleClass: expanded ? 'hub-row hub-row-open' : 'hub-row',
                ageLabel: this._ageLabel(r.ageInHours),
                preview: this._buildPreview(r.toolKey, parsed),
                notes: this.notesByActionId[r.actionId] || '',
                isRefining: this.refiningActionId === r.actionId,
                refinedDraft,
                isResolving: this.resolvingActionId === r.actionId,
                assignmentBadge: this._assignmentBadge(r),
                toolLabel: this._toolLabel(r.toolKey),
            };
        });
    }

    handleFilterChipClick(event) {
        const key = event.currentTarget.dataset.key;
        if (!key || key === this.activeFilter) return;
        this.activeFilter = key;
        this._loadData();
    }

    handleRowToggle(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this.expandedRowId = this.expandedRowId === actionId ? null : actionId;
    }

    handleNotesChange(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this.notesByActionId = {
            ...this.notesByActionId,
            [actionId]: event.detail.value,
        };
    }

    handleToggleRefine(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this.refiningActionId = this.refiningActionId === actionId ? null : actionId;
    }

    handleRefinedChange(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const value = (event.detail && event.detail.value != null)
            ? event.detail.value
            : (event.target ? event.target.value : '');
        this.refinedJsonByActionId = {
            ...this.refinedJsonByActionId,
            [actionId]: value,
        };
    }

    handleApprove(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this._resolve(actionId, true);
    }

    handleReject(event) {
        const actionId = event.currentTarget.dataset.actionId;
        this._resolve(actionId, false);
    }

    handleDismissResolveError() {
        this.resolveError = null;
    }

    handleRefresh() {
        this._loadData();
    }

    async _resolve(actionId, approved) {
        if (this.resolvingActionId) return;
        this.resolvingActionId = actionId;
        this.resolveError = null;
        try {
            let result;
            if (approved) {
                const refined = this.refiningActionId === actionId
                    ? this.refinedJsonByActionId[actionId] || null
                    : null;
                result = await approveAction({
                    actionId,
                    refinedPayloadJson: refined,
                    notes: this.notesByActionId[actionId] || null,
                });
            } else {
                result = await rejectAction({
                    actionId,
                    notes: this.notesByActionId[actionId] || null,
                });
            }
            if (result && result.success) {
                // eslint-disable-next-line no-alert
                alert(`${approved ? 'Approved' : 'Rejected'}: ${result.message}`);
                this.expandedRowId = null;
                this.refiningActionId = null;
                await this._loadData();
            } else {
                this.resolveError = (result && result.message) ||
                    `${approved ? 'Approve' : 'Reject'} failed`;
            }
        } catch (err) {
            this.resolveError = (err && err.body && err.body.message) || 'Unexpected error';
        } finally {
            this.resolvingActionId = null;
        }
    }

    _ageLabel(hours) {
        if (hours == null) return '';
        if (hours < 1) return '<1h ago';
        if (hours < 24) return `${Math.round(hours)}h ago`;
        const days = Math.round(hours / 24);
        return `${days}d ago`;
    }

    _assignmentBadge(row) {
        if (row.assignmentKind === 'me') return 'Me';
        if (row.assignmentKind === 'group') {
            return row.assignedGroupName ? `Queue: ${row.assignedGroupName}` : 'Queue';
        }
        return 'Unassigned';
    }

    _toolLabel(toolKey) {
        const map = {
            send_email: 'Send email',
            update_record: 'Update record',
            external_api: 'External API call',
        };
        return map[toolKey] || toolKey || 'Action';
    }

    _parseJson(s) {
        if (!s) return {};
        try { return JSON.parse(s); } catch (e) { return {}; }
    }

    _formatJson(s) {
        if (!s) return '';
        try { return JSON.stringify(JSON.parse(s), null, 2); } catch (e) { return s; }
    }

    _buildPreview(toolKey, req) {
        if (toolKey === 'send_email') {
            return {
                kind: 'email', isEmail: true,
                to: req.toAddress || req.to || '(recipient missing)',
                subject: req.subject || '(no subject)',
                body: req.body || req.htmlBody || '',
            };
        }
        if (toolKey === 'update_record') {
            const fields = req.fields || {};
            const rows = Object.keys(fields).map((k) => ({
                key: k, field: k, value: String(fields[k]),
            }));
            return {
                kind: 'record', isRecord: true,
                objectType: req.objectType || '(unknown)',
                recordId: req.recordId || '(no id)',
                rows, hasRows: rows.length > 0,
            };
        }
        const rows = Object.keys(req).map((k) => ({
            key: k, field: k,
            value: typeof req[k] === 'object'
                ? JSON.stringify(req[k])
                : String(req[k]),
        }));
        return { kind: 'generic', isGeneric: true, rows, hasRows: rows.length > 0 };
    }
}

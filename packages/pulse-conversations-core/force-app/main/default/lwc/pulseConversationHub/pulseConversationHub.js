import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getConversationsForRecord from '@salesforce/apex/PulseConversationHubController.getConversationsForRecord';
import getConversationsForInstance from '@salesforce/apex/PulseConversationHubController.getConversationsForInstance';
import acceptExtract from '@salesforce/apex/PulseConversationHubController.acceptExtract';
import rejectExtract from '@salesforce/apex/PulseConversationHubController.rejectExtract';
import requestReextraction from '@salesforce/apex/PulseConversationHubController.requestReextraction';

const MEDIUM_VARIANTS = {
    Email: 'purple',
    Phone_Call: 'magenta',
    Meeting: 'gray',
    Chat: 'purple',
};

export default class PulseConversationHub extends LightningElement {
    @api recordId;
    @api instanceId;
    @api targetObjectApiName = 'Account';

    @track conversations = [];
    @track isLoading = true;
    @track error = null;
    @track expandedConversationId = null;
    @track expandedExtractId = null;
    @track selectedFieldsPerExtract = {};
    @track actionInProgress = false;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        this.isLoading = true;
        this.error = null;
        try {
            if (this.recordId) {
                this.conversations =
                    (await getConversationsForRecord({ recordId: this.recordId })) || [];
            } else if (this.instanceId) {
                this.conversations =
                    (await getConversationsForInstance({ workflowInstanceId: this.instanceId })) || [];
            } else {
                this.conversations = [];
            }
        } catch (err) {
            this.conversations = [];
            this.error = err.body?.message || 'Failed to load conversations';
        } finally {
            this.isLoading = false;
        }
    }

    // ─── Computed ───────────────────────────────────────────────

    get hasConversations() {
        return this.conversations.length > 0;
    }

    get noConversations() {
        return !this.isLoading && this.conversations.length === 0 && !this.error;
    }

    get hasError() {
        return this.error != null;
    }

    get noContext() {
        return !this.recordId && !this.instanceId;
    }

    get conversationCards() {
        return this.conversations.map((c) => {
            const isExpanded = c.conversationId === this.expandedConversationId;
            const pendingCount = (c.extracts || []).filter(
                (e) => e.status === 'Pending'
            ).length;
            return {
                ...c,
                isExpanded,
                cardClass: isExpanded
                    ? 'conv-card conv-card-expanded'
                    : 'conv-card',
                mediumVariant: MEDIUM_VARIANTS[c.medium] || 'gray',
                formattedDate: this._formatDate(c.occurredAt),
                pendingCount,
                hasPendingExtracts: pendingCount > 0,
                pendingLabel: `${pendingCount} pending extract${pendingCount !== 1 ? 's' : ''}`,
                showReextract:
                    c.status === 'Extracted' || c.status === 'Reviewed' || c.status === 'Failed',
                turns: (c.turns || []).map((t) => ({
                    ...t,
                    roleVariant: this._roleVariant(t.role),
                    formattedTimestamp: this._formatDate(t.timestamp),
                    displaySpeaker: t.speaker || t.role,
                })),
                extracts: (c.extracts || []).map((e) => ({
                    ...e,
                    isExtractExpanded: e.extractId === this.expandedExtractId,
                    extractPanelClass:
                        e.extractId === this.expandedExtractId
                            ? 'extract-panel extract-panel-expanded'
                            : 'extract-panel',
                    factRows: this._buildFactRows(e),
                    hasSelectedFields: this._hasSelectedFields(e.extractId),
                    acceptDisabled: !this._hasSelectedFields(e.extractId),
                    isPending: e.status === 'Pending',
                    statusVariant: this._extractStatusVariant(e.status),
                })),
            };
        });
    }

    // ─── Handlers ───────────────────────────────────────────────

    handleToggleConversation(event) {
        const convId = event.currentTarget.dataset.convId;
        this.expandedConversationId =
            this.expandedConversationId === convId ? null : convId;
        this.expandedExtractId = null;
    }

    handleToggleExtract(event) {
        const extId = event.currentTarget.dataset.extractId;
        this.expandedExtractId =
            this.expandedExtractId === extId ? null : extId;
    }

    handleFieldToggle(event) {
        const extractId = event.currentTarget.dataset.extractId;
        const fieldKey = event.currentTarget.dataset.fieldKey;
        const current = this.selectedFieldsPerExtract[extractId] || [];
        const idx = current.indexOf(fieldKey);
        let updated;
        if (idx >= 0) {
            updated = current.filter((k) => k !== fieldKey);
        } else {
            updated = [...current, fieldKey];
        }
        this.selectedFieldsPerExtract = {
            ...this.selectedFieldsPerExtract,
            [extractId]: updated,
        };
    }

    async handleAccept(event) {
        const extractId = event.currentTarget.dataset.extractId;
        const convId = event.currentTarget.dataset.convId;
        const selectedKeys = this.selectedFieldsPerExtract[extractId] || [];
        if (selectedKeys.length === 0) return;
        if (this.actionInProgress) return;

        this.actionInProgress = true;
        try {
            const result = await acceptExtract({
                extractId,
                acceptedFieldKeys: selectedKeys,
                targetObjectApiName: this.targetObjectApiName,
                targetRecordId: this.recordId || convId,
                workflowKey: '',
            });
            if (result.success) {
                const msg =
                    result.fieldsProjected +
                    ' field(s) projected.' +
                    (result.errors.length > 0
                        ? ' Warnings: ' + result.errors.join('; ')
                        : '');
                // eslint-disable-next-line no-alert
                alert(msg);
            } else {
                // eslint-disable-next-line no-alert
                alert('Accept failed: ' + result.errors.join('; '));
            }
            await this._loadData();
        } catch (err) {
            // eslint-disable-next-line no-alert
            alert(err.body?.message || 'Unexpected error during accept');
        } finally {
            this.actionInProgress = false;
        }
    }

    async handleReject(event) {
        const extractId = event.currentTarget.dataset.extractId;
        if (this.actionInProgress) return;

        this.actionInProgress = true;
        try {
            const result = await rejectExtract({
                extractId,
                reason: '',
            });
            if (result.success) {
                // eslint-disable-next-line no-alert
                alert('Extract rejected.');
            } else {
                // eslint-disable-next-line no-alert
                alert('Reject failed: ' + result.errors.join('; '));
            }
            await this._loadData();
        } catch (err) {
            // eslint-disable-next-line no-alert
            alert(err.body?.message || 'Unexpected error during reject');
        } finally {
            this.actionInProgress = false;
        }
    }

    async handleReextract(event) {
        const convId = event.currentTarget.dataset.convId;
        if (this.actionInProgress) return;

        this.actionInProgress = true;
        try {
            await requestReextraction({ conversationId: convId });
            // eslint-disable-next-line no-alert
            alert('Re-extraction queued.');
            await this._loadData();
        } catch (err) {
            // eslint-disable-next-line no-alert
            alert(err.body?.message || 'Unexpected error during re-extraction');
        } finally {
            this.actionInProgress = false;
        }
    }

    handleRefresh() {
        this._loadData();
    }

    // ─── Private ────────────────────────────────────────────────

    _buildFactRows(extract) {
        if (!extract.facts) return [];
        const selected = this.selectedFieldsPerExtract[extract.extractId] || [];
        return Object.keys(extract.facts).map((key) => {
            const conf =
                extract.confidence && extract.confidence[key] != null
                    ? extract.confidence[key]
                    : 0;
            const pct = Math.round(conf * 100);
            let barClass = 'fact-bar fact-bar-error';
            if (conf >= 0.8) barClass = 'fact-bar fact-bar-success';
            else if (conf >= 0.5) barClass = 'fact-bar fact-bar-warning';
            return {
                key,
                value: String(extract.facts[key] ?? ''),
                confidence: conf,
                confidenceLabel: pct + '%',
                barClass,
                barWidth: `width: ${pct}%`,
                isChecked: selected.includes(key),
                checkboxClass: selected.includes(key)
                    ? 'fact-check fact-check-on'
                    : 'fact-check',
            };
        });
    }

    _hasSelectedFields(extractId) {
        const sel = this.selectedFieldsPerExtract[extractId];
        return sel != null && sel.length > 0;
    }

    _roleVariant(role) {
        const map = {
            Customer: 'magenta',
            Agent: 'purple',
            System: 'gray',
            AI: 'purple',
        };
        return map[role] || 'gray';
    }

    _extractStatusVariant(status) {
        const map = {
            Pending: 'warning',
            Accepted: 'success',
            Partial: 'warning',
            Rejected: 'error',
        };
        return map[status] || 'gray';
    }

    _formatDate(dt) {
        if (!dt) return '';
        try {
            return new Date(dt).toLocaleString();
        } catch {
            return String(dt);
        }
    }
}

import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listUnroutedEmails from '@salesforce/apex/PulseEmailRouterController.listUnroutedEmails';
import listRoutingRules from '@salesforce/apex/PulseEmailRouterController.listRoutingRules';
import routeToExistingRecord from '@salesforce/apex/PulseEmailRouterController.routeToExistingRecord';
import createOpportunityFromConversation
    from '@salesforce/apex/PulseEmailRouterController.createOpportunityFromConversation';

export default class PulseEmailRouter extends LightningElement {
    @track unrouted = [];
    @track rules = [];

    @track loadingEmails = true;
    @track loadingRules = true;

    @track emailsError = null;
    @track rulesError = null;

    @track toast = null;         // { kind: 'success' | 'error', message }

    // Per-card UI state (record-id pickers, busy flags) keyed by conversationId
    _cardState = {};

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._refreshEmails();
        this._refreshRules();
    }

    // ── Refresh ───────────────────────────────────────────────

    async _refreshEmails() {
        this.loadingEmails = true;
        try {
            const rows = await listUnroutedEmails();
            this.unrouted = (rows || []).map((r) => {
                const saved = this._cardState[r.conversationId];
                const pickerValue = saved && saved.pickerValue ? saved.pickerValue : '';
                return {
                    ...r,
                    pickerValue,
                    busy: false,
                    error: null,
                };
            });
            this.emailsError = null;
        } catch (err) {
            this.emailsError = (err && err.body && err.body.message)
                || (err && err.message)
                || 'Failed to load emails';
        } finally {
            this.loadingEmails = false;
        }
    }

    async _refreshRules() {
        this.loadingRules = true;
        try {
            const rows = await listRoutingRules();
            this.rules = (rows || []).map((r) => ({
                ...r,
                priorityLabel: r.priority != null ? String(r.priority) : '—',
                statusLabel: r.active ? 'Active' : 'Inactive',
                statusClass: r.active ? 'rule-status rule-status-on' : 'rule-status rule-status-off',
            }));
            this.rulesError = null;
        } catch (err) {
            this.rulesError = err?.body?.message || err?.message || 'Failed to load rules';
        } finally {
            this.loadingRules = false;
        }
    }

    // ── Derived getters ──────────────────────────────────────

    get hasUnrouted() { return this.unrouted.length > 0; }
    get hasRules()    { return this.rules.length > 0; }
    get unroutedCountLabel() {
        const n = this.unrouted.length;
        if (n === 0) return 'No unrouted emails';
        if (n === 1) return '1 unrouted email';
        return `${n} unrouted emails`;
    }

    // ── Card picker ──────────────────────────────────────────

    handlePickerChange(event) {
        const conversationId = event.currentTarget.dataset.conversationId;
        const value = event.detail?.value ?? event.target.value;
        this._cardState[conversationId] = {
            ...(this._cardState[conversationId] || {}),
            pickerValue: value,
        };
        this.unrouted = this.unrouted.map((c) =>
            c.conversationId === conversationId
                ? { ...c, pickerValue: value }
                : c
        );
    }

    async handleRouteToExisting(event) {
        const conversationId = event.currentTarget.dataset.conversationId;
        const card = this.unrouted.find((c) => c.conversationId === conversationId);
        if (!card) return;

        const recordId = (card.pickerValue || '').trim();
        if (!recordId) {
            this._patchCard(conversationId, { error: 'Enter a record Id first' });
            return;
        }

        this._patchCard(conversationId, { busy: true, error: null });
        try {
            const result = await routeToExistingRecord({ conversationId, recordId });
            if (result.success) {
                this._toast('success', `Routed to ${result.objectType} ${result.recordId}`);
                this.unrouted = this.unrouted.filter((c) => c.conversationId !== conversationId);
            } else {
                this._patchCard(conversationId, { busy: false, error: result.error || 'Route failed' });
            }
        } catch (err) {
            this._patchCard(conversationId, {
                busy: false,
                error: err?.body?.message || err?.message || 'Route failed',
            });
        }
    }

    async handleCreateOpportunity(event) {
        const conversationId = event.currentTarget.dataset.conversationId;
        this._patchCard(conversationId, { busy: true, error: null });
        try {
            const result = await createOpportunityFromConversation({ conversationId });
            if (result.success) {
                const verb = result.wasCreated ? 'Created' : 'Attached to';
                this._toast('success',
                    `${verb} ${result.objectType} ${result.recordId} via "${result.ruleKey}"`);
                this.unrouted = this.unrouted.filter((c) => c.conversationId !== conversationId);
            } else {
                this._patchCard(conversationId, { busy: false, error: result.error || 'Create failed' });
            }
        } catch (err) {
            this._patchCard(conversationId, {
                busy: false,
                error: err?.body?.message || err?.message || 'Create failed',
            });
        }
    }

    handleCreateRule(event) {
        const conversationId = event.currentTarget.dataset.conversationId;
        const card = this.unrouted.find((c) => c.conversationId === conversationId);
        this._toast('info',
            `Creating routing rules from this UI isn't supported yet — use Setup → Custom Metadata Types → Conversation Routing Rule.${
                card ? ` (sender: ${card.senderEmail || 'unknown'})` : ''
            }`);
    }

    handleAddRule() {
        this._toast('info',
            'Create rules via Setup → Custom Metadata Types → Conversation Routing Rule. In-app rule authoring arrives with the next admin-studio release.');
    }

    handleEditRule(event) {
        const devName = event.currentTarget.dataset.developerName;
        this._toast('info',
            `Edit rule "${devName}" via Setup → Custom Metadata Types → Conversation Routing Rule. The in-app rule editor is read-only for this release.`);
    }

    handleRefreshEmails() { this._refreshEmails(); }
    handleRefreshRules()  { this._refreshRules(); }

    handleDismissToast() { this.toast = null; }

    // ── Helpers ──────────────────────────────────────────────

    _patchCard(conversationId, patch) {
        this.unrouted = this.unrouted.map((c) =>
            c.conversationId === conversationId ? { ...c, ...patch } : c
        );
    }

    _toast(kind, message) {
        this.toast = {
            kind,
            message,
            class: kind === 'error'
                ? 'router-toast router-toast-error'
                : kind === 'success'
                    ? 'router-toast router-toast-success'
                    : 'router-toast router-toast-info',
        };
    }
}

import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listUnroutedEmails from '@salesforce/apex/PulseEmailRouterController.listUnroutedEmails';
import listRoutingRules from '@salesforce/apex/PulseEmailRouterController.listRoutingRules';
import routeToExistingRecord from '@salesforce/apex/PulseEmailRouterController.routeToExistingRecord';
import createOpportunityFromConversation
    from '@salesforce/apex/PulseEmailRouterController.createOpportunityFromConversation';
import upsertRoutingRule from '@salesforce/apex/PulseEmailRouterController.upsertRoutingRule';
import deleteRoutingRule from '@salesforce/apex/PulseEmailRouterController.deleteRoutingRule';
import getDeployStatus from '@salesforce/apex/PulseEmailRouterController.getDeployStatus';

// Status-poll tuning: short-lived background job, keep the loop tight but
// bounded so we don't spin forever if the org never reports Completed.
const POLL_INTERVAL_MS = 1200;
const POLL_MAX_TRIES = 20;

const EMPTY_RULE = Object.freeze({
    developerName: '',
    ruleKey: '',
    active: true,
    priority: 100,
    sourceAdapter: 'inbound_email',
    matchStrategy: 'EMAIL_SENDER_TO_CONTACT',
    targetObject: 'Opportunity',
    createDefaultsJson: '',
    triggerWorkflowKey: '',
});

export default class PulseEmailRouter extends LightningElement {
    @track unrouted = [];
    @track rules = [];

    @track loadingEmails = true;
    @track loadingRules = true;

    @track emailsError = null;
    @track rulesError = null;

    @track toast = null;         // { kind: 'success' | 'error', message }

    // Editor modal state
    @track editorOpen = false;
    @track editorBusy = false;
    @track editorError = null;
    @track editorMode = 'create';      // 'create' | 'edit'
    @track editorForm = { ...EMPTY_RULE };

    // Delete confirm state
    @track confirmOpen = false;
    @track confirmBusy = false;
    @track confirmTarget = null;       // { developerName, ruleKey }

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

    get editorTitle() {
        return this.editorMode === 'edit' ? 'Edit routing rule' : 'Add routing rule';
    }

    get editorDeveloperNameDisabled() {
        // Developer name is immutable once a rule exists — the CMDT record
        // is identified by it. We also lock it when creating so the user
        // can enter the rule key and we derive the developer name on save.
        return this.editorMode === 'edit';
    }

    get editorRuleKey()            { return this.editorForm.ruleKey; }
    get editorDeveloperName()      { return this.editorForm.developerName; }
    get editorPriority()           { return this.editorForm.priority; }
    get editorSourceAdapter()      { return this.editorForm.sourceAdapter; }
    get editorMatchStrategy()      { return this.editorForm.matchStrategy; }
    get editorTargetObject()       { return this.editorForm.targetObject; }
    get editorCreateDefaultsJson() { return this.editorForm.createDefaultsJson; }
    get editorTriggerWorkflowKey() { return this.editorForm.triggerWorkflowKey; }
    get editorActive()             { return this.editorForm.active === true; }

    get confirmMessage() {
        if (!this.confirmTarget) return '';
        return `Deactivate rule "${this.confirmTarget.developerName}"? ` +
            'The Metadata API cannot hard-delete CMDT records, so Pulse sets ' +
            'Active = false. You can reactivate from Setup.';
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
        // Pre-fill from the sender email when available so the admin gets
        // a sensible starting point (ruleKey derived from sender domain).
        const seed = { ...EMPTY_RULE };
        if (card && card.senderEmail) {
            const domain = card.senderEmail.split('@')[1] || '';
            if (domain) {
                seed.ruleKey = `email_from_${domain.replace(/\./g, '_')}`;
            }
        }
        this._openEditor('create', seed);
    }

    handleAddRule() {
        this._openEditor('create', { ...EMPTY_RULE });
    }

    handleEditRule(event) {
        const devName = event.currentTarget.dataset.developerName;
        const rule = this.rules.find((r) => r.developerName === devName);
        if (!rule) {
            this._toast('error', `Rule ${devName} not found`);
            return;
        }
        this._openEditor('edit', {
            developerName:      rule.developerName,
            ruleKey:            rule.ruleKey || '',
            active:             rule.active === true,
            priority:           rule.priority != null ? rule.priority : 100,
            sourceAdapter:      rule.sourceAdapter || 'inbound_email',
            matchStrategy:      rule.matchStrategy || 'EMAIL_SENDER_TO_CONTACT',
            targetObject:       rule.targetObject || 'Opportunity',
            createDefaultsJson: rule.createDefaultsJson || '',
            triggerWorkflowKey: rule.triggerWorkflowKey || '',
        });
    }

    handleDeleteRule(event) {
        const devName = event.currentTarget.dataset.developerName;
        const rule = this.rules.find((r) => r.developerName === devName);
        if (!rule) return;
        this.confirmTarget = { developerName: rule.developerName, ruleKey: rule.ruleKey };
        this.confirmOpen = true;
    }

    handleConfirmClose() {
        if (this.confirmBusy) return;
        this.confirmOpen = false;
        this.confirmTarget = null;
    }

    async handleConfirmDelete() {
        if (!this.confirmTarget) return;
        this.confirmBusy = true;
        try {
            const result = await deleteRoutingRule({
                developerName: this.confirmTarget.developerName,
            });
            if (!result.success) {
                this._toast('error', result.error || 'Delete failed');
                return;
            }
            await this._waitForDeploy(result.jobId);
            this._toast('success',
                `Deactivated "${this.confirmTarget.developerName}"`);
            this.confirmOpen = false;
            this.confirmTarget = null;
            await this._refreshRules();
        } catch (err) {
            this._toast('error', err?.body?.message || err?.message || 'Delete failed');
        } finally {
            this.confirmBusy = false;
        }
    }

    // ── Editor modal ─────────────────────────────────────────

    _openEditor(mode, seed) {
        this.editorMode = mode;
        this.editorForm = { ...EMPTY_RULE, ...seed };
        this.editorError = null;
        this.editorBusy = false;
        this.editorOpen = true;
    }

    handleEditorClose() {
        if (this.editorBusy) return;
        this.editorOpen = false;
        this.editorError = null;
    }

    handleFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        if (!field) return;
        let value = event.detail?.value ?? event.target?.value;
        if (field === 'active') {
            value = event.target.checked;
        } else if (field === 'priority') {
            const parsed = parseInt(value, 10);
            value = Number.isNaN(parsed) ? null : parsed;
        }
        this.editorForm = { ...this.editorForm, [field]: value };
    }

    async handleSaveRule() {
        const f = this.editorForm;
        if (!f.ruleKey || !f.ruleKey.trim()) {
            this.editorError = 'Rule key is required';
            return;
        }
        if (!f.targetObject || !f.targetObject.trim()) {
            this.editorError = 'Target object is required';
            return;
        }
        if (!f.matchStrategy || !f.matchStrategy.trim()) {
            this.editorError = 'Match strategy is required';
            return;
        }
        if (f.createDefaultsJson && f.createDefaultsJson.trim()) {
            try {
                const parsed = JSON.parse(f.createDefaultsJson);
                if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                    this.editorError = 'Create defaults must be a JSON object';
                    return;
                }
            } catch (e) {
                this.editorError = 'Create defaults is not valid JSON: ' + e.message;
                return;
            }
        }

        this.editorBusy = true;
        this.editorError = null;
        try {
            const payload = {
                ruleKey:            f.ruleKey.trim(),
                active:             f.active === true,
                priority:           f.priority,
                sourceAdapter:      f.sourceAdapter,
                matchStrategy:      f.matchStrategy,
                targetObject:       f.targetObject,
                createDefaultsJson: f.createDefaultsJson || null,
                triggerWorkflowKey: f.triggerWorkflowKey || null,
            };
            if (this.editorMode === 'edit' && f.developerName) {
                payload.developerName = f.developerName;
            }
            const result = await upsertRoutingRule({ payload });
            if (!result.success) {
                this.editorError = result.error || 'Save failed';
                return;
            }
            await this._waitForDeploy(result.jobId);
            this._toast('success',
                `${this.editorMode === 'edit' ? 'Updated' : 'Created'} rule "${result.developerName}"`);
            this.editorOpen = false;
            await this._refreshRules();
        } catch (err) {
            this.editorError = err?.body?.message || err?.message || 'Save failed';
        } finally {
            this.editorBusy = false;
        }
    }

    async _waitForDeploy(jobId) {
        if (!jobId) return;
        for (let i = 0; i < POLL_MAX_TRIES; i++) {
            try {
                const s = await getDeployStatus({ jobId });
                if (s && s.done) return;
            } catch (e) {
                // Metadata deploys aren't always queryable as AsyncApexJob —
                // stop polling and let the refresh confirm the outcome.
                return;
            }
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
        }
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

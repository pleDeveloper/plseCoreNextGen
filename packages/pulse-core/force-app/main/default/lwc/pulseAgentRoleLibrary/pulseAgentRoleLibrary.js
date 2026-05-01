import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listRoles from '@salesforce/apex/PulseAgentRoleController.listRoles';
import upsertRole from '@salesforce/apex/PulseAgentRoleController.upsertRole';
import deleteRole from '@salesforce/apex/PulseAgentRoleController.deleteRole';
import getDeployStatus from '@salesforce/apex/PulseAgentRoleController.getDeployStatus';

const POLL_INTERVAL_MS = 1200;
const POLL_MAX_TRIES = 20;

const AUTONOMY_OPTIONS = [
    { label: 'Propose Only', value: 'Propose_Only' },
    { label: 'Act With Approval', value: 'Act_With_Approval' },
    { label: 'Autonomous (Safe Tools Only)', value: 'Autonomous_Safe' }
];

const EMPTY_ROLE = Object.freeze({
    developerName: '',
    roleKey: '',
    displayName: '',
    description: '',
    providerName: '',
    defaultAutonomy: 'Act_With_Approval',
    systemPrompt: '',
    toolAllowlistJson: '',
    suggestedPhaseTypes: '',
    active: true
});

export default class PulseAgentRoleLibrary extends LightningElement {
    @track roles = [];
    @track loading = true;
    @track loadError = null;
    @track toast = null;

    // Editor modal state
    @track editorOpen = false;
    @track editorBusy = false;
    @track editorError = null;
    @track editorMode = 'create';      // 'create' | 'edit'
    @track editorForm = { ...EMPTY_ROLE };

    // Confirm-deactivate modal
    @track confirmOpen = false;
    @track confirmBusy = false;
    @track confirmTarget = null;       // { developerName, displayName }

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._refresh();
    }

    async _refresh() {
        this.loading = true;
        try {
            const rows = await listRoles();
            this.roles = (rows || []).map((r) => ({
                ...r,
                statusLabel: r.active ? 'Active' : 'Inactive',
                statusClass: r.active
                    ? 'role-status role-status-on'
                    : 'role-status role-status-off',
                providerLabel:    r.providerName || '—',
                autonomyLabel:    r.defaultAutonomy || '—',
                phaseTypesLabel:  r.suggestedPhaseTypes || '—',
                allowlistLabel:   _summarizeAllowlist(r.toolAllowlistJson)
            }));
            this.loadError = null;
        } catch (err) {
            this.loadError = err?.body?.message || err?.message
                || 'Failed to load agent roles';
        } finally {
            this.loading = false;
        }
    }

    // ── Derived getters ──────────────────────────────────────

    get hasRoles()        { return this.roles.length > 0; }
    get hasNoRoles()      { return !this.loading && !this.loadError && !this.hasRoles; }
    get countLabel() {
        const n = this.roles.length;
        if (n === 0) return 'No roles defined';
        if (n === 1) return '1 role';
        return `${n} roles`;
    }

    get editorTitle() {
        return this.editorMode === 'edit' ? 'Edit agent role' : 'Add agent role';
    }
    get editorRoleKeyDisabled() {
        // Role key drives the developer name; locking it on edit avoids
        // leaving an orphan record when the admin renames.
        return this.editorMode === 'edit';
    }

    get editorRoleKey()             { return this.editorForm.roleKey; }
    get editorDisplayName()         { return this.editorForm.displayName; }
    get editorDescription()         { return this.editorForm.description; }
    get editorProviderName()        { return this.editorForm.providerName; }
    get editorSystemPrompt()        { return this.editorForm.systemPrompt; }
    get editorToolAllowlistJson()   { return this.editorForm.toolAllowlistJson; }
    get editorSuggestedPhaseTypes() { return this.editorForm.suggestedPhaseTypes; }
    get editorActive()              { return this.editorForm.active === true; }

    get autonomyOptions() {
        const current = this.editorForm.defaultAutonomy || 'Act_With_Approval';
        return AUTONOMY_OPTIONS.map((o) => ({
            ...o,
            selected: o.value === current
        }));
    }

    get confirmMessage() {
        if (!this.confirmTarget) return '';
        return `Deactivate role "${this.confirmTarget.displayName
            || this.confirmTarget.developerName}"? Existing workflows that ` +
            'reference it will fall back to per-level config until the role ' +
            'is re-activated. CMDT records cannot be hard-deleted via the ' +
            'Metadata API; Pulse sets Active = false.';
    }

    // ── Editor open / close ──────────────────────────────────

    handleAddRole() {
        this._openEditor('create', { ...EMPTY_ROLE });
    }

    handleEditRole(event) {
        const devName = event.currentTarget.dataset.developerName;
        const role = this.roles.find((r) => r.developerName === devName);
        if (!role) {
            this._toast('error', `Role ${devName} not found`);
            return;
        }
        this._openEditor('edit', {
            developerName:       role.developerName,
            roleKey:             role.roleKey || '',
            displayName:         role.displayName || '',
            description:         role.description || '',
            providerName:        role.providerName || '',
            defaultAutonomy:     role.defaultAutonomy || 'Act_With_Approval',
            systemPrompt:        role.systemPrompt || '',
            toolAllowlistJson:   role.toolAllowlistJson || '',
            suggestedPhaseTypes: role.suggestedPhaseTypes || '',
            active:              role.active === true
        });
    }

    handleDeactivateRole(event) {
        const devName = event.currentTarget.dataset.developerName;
        const role = this.roles.find((r) => r.developerName === devName);
        if (!role) return;
        this.confirmTarget = {
            developerName: role.developerName,
            displayName: role.displayName
        };
        this.confirmOpen = true;
    }

    handleConfirmClose() {
        if (this.confirmBusy) return;
        this.confirmOpen = false;
        this.confirmTarget = null;
    }

    async handleConfirmDeactivate() {
        if (!this.confirmTarget) return;
        this.confirmBusy = true;
        try {
            const result = await deleteRole({
                developerName: this.confirmTarget.developerName
            });
            if (!result.success) {
                this._toast('error', result.error || 'Deactivate failed');
                return;
            }
            await this._waitForDeploy(result.jobId);
            this._toast('success',
                `Deactivated "${this.confirmTarget.developerName}"`);
            this.confirmOpen = false;
            this.confirmTarget = null;
            await this._refresh();
        } catch (err) {
            this._toast('error',
                err?.body?.message || err?.message || 'Deactivate failed');
        } finally {
            this.confirmBusy = false;
        }
    }

    _openEditor(mode, seed) {
        this.editorMode = mode;
        this.editorForm = { ...EMPTY_ROLE, ...seed };
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
            value = event.detail?.checked ?? event.target.checked;
        }
        this.editorForm = { ...this.editorForm, [field]: value };
    }

    async handleSaveRole() {
        const f = this.editorForm;
        if (!f.roleKey || !f.roleKey.trim()) {
            this.editorError = 'Role key is required';
            return;
        }
        if (!f.displayName || !f.displayName.trim()) {
            this.editorError = 'Display name is required';
            return;
        }
        if (f.toolAllowlistJson && f.toolAllowlistJson.trim()) {
            try {
                const parsed = JSON.parse(f.toolAllowlistJson);
                if (!Array.isArray(parsed)) {
                    this.editorError = 'Tool allowlist must be a JSON array';
                    return;
                }
            } catch (e) {
                this.editorError = 'Tool allowlist is not valid JSON: ' + e.message;
                return;
            }
        }

        this.editorBusy = true;
        this.editorError = null;
        try {
            const payload = {
                roleKey:             f.roleKey.trim(),
                displayName:         f.displayName.trim(),
                description:         f.description || null,
                providerName:        f.providerName || null,
                defaultAutonomy:     f.defaultAutonomy || null,
                systemPrompt:        f.systemPrompt || null,
                toolAllowlistJson:   f.toolAllowlistJson || null,
                suggestedPhaseTypes: f.suggestedPhaseTypes || null,
                active:              f.active === true
            };
            if (this.editorMode === 'edit' && f.developerName) {
                payload.developerName = f.developerName;
            }
            const result = await upsertRole({ payload });
            if (!result.success) {
                this.editorError = result.error || 'Save failed';
                return;
            }
            await this._waitForDeploy(result.jobId);
            this._toast('success',
                `${this.editorMode === 'edit' ? 'Updated' : 'Created'} role "${result.developerName}"`);
            this.editorOpen = false;
            await this._refresh();
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
                return;
            }
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
        }
    }

    handleRefresh() { this._refresh(); }

    handleAutonomyChange(event) {
        const value = event.detail?.value ?? event.target.value ?? '';
        this.editorForm = { ...this.editorForm, defaultAutonomy: value };
    }

    handleDismissToast() { this.toast = null; }

    _toast(kind, message) {
        this.toast = {
            kind,
            message,
            class: kind === 'error'
                ? 'roles-toast roles-toast-error'
                : kind === 'success'
                    ? 'roles-toast roles-toast-success'
                    : 'roles-toast roles-toast-info'
        };
    }
}

function _summarizeAllowlist(json) {
    if (!json) return 'Any tool';
    try {
        const arr = JSON.parse(json);
        if (!Array.isArray(arr) || arr.length === 0) return 'Any tool';
        return `${arr.length} tool${arr.length === 1 ? '' : 's'}`;
    } catch (e) {
        return 'Invalid JSON';
    }
}

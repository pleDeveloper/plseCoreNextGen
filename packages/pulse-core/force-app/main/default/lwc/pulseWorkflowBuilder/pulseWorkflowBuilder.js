import { LightningElement, track, wire } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import {
    getState,
    subscribe,
    dispatch,
    resetStore
} from 'c/pulseStore';
import saveWorkflow from '@salesforce/apex/PulseWorkflowBuilderController.saveWorkflow';
import publishWorkflow from '@salesforce/apex/PulseWorkflowBuilderController.publishWorkflow';
import listWorkflows from '@salesforce/apex/PulseWorkflowBuilderController.listWorkflows';
import loadWorkflow from '@salesforce/apex/PulseWorkflowBuilderController.loadWorkflow';
import listActiveRoleSummaries from '@salesforce/apex/PulseAgentRoleController.listActiveRoleSummaries';

export default class PulseWorkflowBuilder extends LightningElement {
    @track _storeState;
    @track _existingWorkflows = [];
    @track _listError = null;
    @track _agentRoles = [];        // Active role summaries from listActiveRoleSummaries
    @track _agentRoleError = null;
    @track _showAgentOverrides = false; // disclosure state for "Customize this role"
    _unsubscribe;
    _recordId; // Workflow_Definition__c Id once saved

    // Active role summaries — drives the role picker in the agent panel.
    // We use @wire here because the Apex method is cacheable=true and the
    // role library mutates rarely, so cached reads are the right default.
    @wire(listActiveRoleSummaries)
    _wiredAgentRoles({ data, error }) {
        if (data) {
            this._agentRoles = data;
            this._agentRoleError = null;
        } else if (error) {
            this._agentRoles = [];
            this._agentRoleError = error?.body?.message || error?.message
                || 'Failed to load agent roles';
        }
    }

    // ── Create-workflow form state ────────────────────────────────
    newWorkflowKey = '';
    newWorkflowName = '';
    newSubjectKinds = '';
    showCreateForm = false;

    // ── Tab state ─────────────────────────────────────────────────
    activeTab = 'states';

    // ── Add-state form state ──────────────────────────────────────
    showAddStateForm = false;
    newStateKey = '';
    newStateLabel = '';

    // ── Phase settings drawer state ───────────────────────────────
    showPhaseSettings = false;

    // ── Publish state ─────────────────────────────────────────────
    showDeployDialog = false;
    publishTargetObject = '';

    connectedCallback() {
        loadPulseBrandTokens(this);
        resetStore();
        this._storeState = getState();
        this._unsubscribe = subscribe((state) => {
            this._storeState = state;
        });
        this._refreshWorkflowList();
    }

    async _refreshWorkflowList() {
        try {
            const rows = await listWorkflows();
            this._existingWorkflows = (rows || []).map((r) => ({
                ...r,
                statusVariant: r.status === 'Published' ? 'green'
                    : r.status === 'Draft' ? 'slate'
                    : 'slate',
                subjectKindsDisplay: r.subjectKinds
                    ? r.subjectKinds.replace(/;/g, ', ')
                    : '—'
            }));
            this._listError = null;
        } catch (e) {
            this._listError = e?.body?.message || e?.message || 'Failed to load workflows';
        }
    }

    disconnectedCallback() {
        if (this._unsubscribe) {
            this._unsubscribe();
        }
    }

    // ── Computed properties from store ────────────────────────────

    get workflow() {
        return this._storeState?.workflow || {};
    }

    get ui() {
        return this._storeState?.ui || {};
    }

    get states() {
        return this.workflow.states || [];
    }

    get workflowKey() {
        return this.workflow.workflowKey || '';
    }

    get workflowName() {
        return this.workflow.name || this.workflow.workflowKey || '';
    }

    get isDirty() {
        return this.ui.dirty;
    }

    get selectedStateKey() {
        return this.ui.selectedStateKey;
    }

    get selectedFieldKey() {
        return this.ui.selectedFieldKey;
    }

    get selectedActionKey() {
        return this.ui.selectedActionKey;
    }

    get isCreating() {
        return !this.workflowKey;
    }

    get isEditing() {
        return !!this.workflowKey;
    }

    get existingWorkflows() {
        return this._existingWorkflows;
    }

    get hasExistingWorkflows() {
        return this._existingWorkflows && this._existingWorkflows.length > 0;
    }

    get listError() {
        return this._listError;
    }

    get showLanding() {
        return this.isCreating && !this.showCreateForm;
    }

    get showCreatePanel() {
        return this.isCreating && this.showCreateForm;
    }

    get recordId() {
        return this._recordId;
    }

    get isStatesTab() {
        return this.activeTab === 'states';
    }

    get isTriggersTab() {
        return this.activeTab === 'triggers';
    }

    get tabStatesClass() {
        return this.activeTab === 'states'
            ? 'builder-tab builder-tab-active'
            : 'builder-tab';
    }

    get tabTriggersClass() {
        return this.activeTab === 'triggers'
            ? 'builder-tab builder-tab-active'
            : 'builder-tab';
    }

    handleTabClick(event) {
        const tab = event.currentTarget.dataset.tab;
        if (tab) {
            this.activeTab = tab;
        }
    }

    get createDisabled() {
        return !this.newWorkflowKey.trim();
    }

    get saveDisabled() {
        return !this.isDirty;
    }

    get publishDisabled() {
        return this.states.length === 0;
    }

    get addStateDisabled() {
        return !this.newStateKey.trim();
    }

    get subjectKindsDisplay() {
        return (this.workflow.subjectKinds || []).join(', ');
    }

    get statesList() {
        return this.states.map((s) => ({
            ...s,
            fieldCount: (s.fields || []).length,
            transitionCount: (s.transitions || []).length,
            selected: s.key === this.selectedStateKey
        }));
    }

    get hasFieldSelected() {
        return !!this.selectedStateKey && !!this.selectedFieldKey;
    }

    get hasStateSelectedNoField() {
        return (
            !!this.selectedStateKey &&
            !this.selectedFieldKey &&
            !this.selectedActionKey
        );
    }

    get noSelection() {
        return !this.selectedStateKey;
    }

    get selectedState() {
        const s = this.states.find(
            (st) => st.key === this.selectedStateKey
        );
        if (!s) return null;
        return {
            ...s,
            hasFields: s.fields && s.fields.length > 0,
            hasTransitions: s.transitions && s.transitions.length > 0,
            hasActions: s.actions && s.actions.length > 0,
            fields: (s.fields || []).map((f) => ({
                ...f,
                projected: f.projection && f.projection.enabled
            })),
            actions: (s.actions || []).map((a) => ({
                ...a,
                selected: a.key === this.selectedActionKey,
                statusCount: (a.statuses || []).length
            })),
            transitions: (s.transitions || []).map((t, i) => ({
                ...t,
                idx: i,
                compositeKey: `${t.signal}_${t.to}_${i}`
            }))
        };
    }

    // ── Action inspector (status editor) ──────────────────────────

    get hasActionSelected() {
        return !!this.selectedStateKey && !!this.selectedActionKey;
    }

    get selectedAction() {
        if (!this.selectedStateKey || !this.selectedActionKey) return null;
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        if (!s) return null;
        return (s.actions || []).find((a) => a.key === this.selectedActionKey) || null;
    }

    get selectedActionStatuses() {
        const a = this.selectedAction;
        return (a && a.statuses) || [];
    }

    get selectedActionInitialStatusKey() {
        const a = this.selectedAction;
        return (a && a.initialStatusKey) || '';
    }

    /**
     * Sibling-action options for the action-status rule type inside each
     * status's entryConditions — we exclude the selected action itself to
     * prevent a row referencing its own status machine.
     */
    get siblingActionsForSelected() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        if (!s || !s.actions) return [];
        return s.actions
            .filter((a) => a.key !== this.selectedActionKey)
            .map((a) => ({ key: a.key, label: a.label || a.key }));
    }

    // ── Phase settings (entry/exit/progression/status rules) ──────

    get phaseSettingsTargetObject() {
        return (this.workflow.subjectKinds || [])[0] || '';
    }

    get progressionModeOptions() {
        const mode = this.selectedStateProgressionMode;
        const opts = [
            { label: 'Auto on actions', value: 'auto_on_actions' },
            { label: 'Manual decision', value: 'manual_decision' },
            { label: 'Field change', value: 'field_change' },
            { label: 'Custom logic', value: 'custom_logic' }
        ];
        return opts.map((o) => ({ ...o, selected: o.value === mode }));
    }

    get selectedStateProgression() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.progression) || {};
    }

    get selectedStateProgressionMode() {
        return this.selectedStateProgression.mode || 'auto_on_actions';
    }

    get isProgressionFieldChange() {
        return this.selectedStateProgressionMode === 'field_change';
    }

    get isProgressionCustomLogic() {
        return this.selectedStateProgressionMode === 'custom_logic';
    }

    get progressionFieldName() {
        const rule = this.selectedStateProgression.rule || {};
        return rule.field || '';
    }

    get progressionFieldEquals() {
        const rule = this.selectedStateProgression.rule || {};
        return rule.equals != null ? String(rule.equals) : '';
    }

    get progressionCustomRule() {
        return this.selectedStateProgression.rule || {};
    }

    get selectedStateEntryConditions() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.entryConditions) || {};
    }

    get selectedStateExitConditions() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.exitConditions) || {};
    }

    get selectedStateStatusRules() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.statusRules) || {};
    }

    get statusRulesAutoHoldDays() {
        const v = this.selectedStateStatusRules.autoOnHoldAfterDays;
        return v == null ? '' : String(v);
    }

    get statusRulesAutoEscalate() {
        return this.selectedStateStatusRules.autoEscalateIfBlocked === true;
    }

    get phaseSettingsToggleLabel() {
        return this.showPhaseSettings ? 'Hide phase settings' : 'Phase settings';
    }

    handleTogglePhaseSettings() {
        this.showPhaseSettings = !this.showPhaseSettings;
    }

    handleEntryConditionsChange(event) {
        if (!this.selectedStateKey) return;
        dispatch({
            type: 'UPDATE_STATE_ENTRY_CONDITIONS',
            stateKey: this.selectedStateKey,
            tree: event.detail.tree
        });
    }

    handleExitConditionsChange(event) {
        if (!this.selectedStateKey) return;
        dispatch({
            type: 'UPDATE_STATE_EXIT_CONDITIONS',
            stateKey: this.selectedStateKey,
            tree: event.detail.tree
        });
    }

    handleProgressionModeChange(event) {
        if (!this.selectedStateKey) return;
        const mode = event.detail?.value ?? event.target.value;
        const cur = { ...this.selectedStateProgression, mode };
        // Drop a stale rule when switching to a mode that doesn't use it.
        if (mode !== 'field_change' && mode !== 'custom_logic') {
            delete cur.rule;
        }
        dispatch({
            type: 'UPDATE_STATE_PROGRESSION',
            stateKey: this.selectedStateKey,
            progression: cur
        });
    }

    handleProgressionFieldChange(event) {
        if (!this.selectedStateKey) return;
        const field = event.detail?.value ?? event.target.value;
        const cur = this.selectedStateProgression;
        dispatch({
            type: 'UPDATE_STATE_PROGRESSION',
            stateKey: this.selectedStateKey,
            progression: {
                ...cur,
                mode: 'field_change',
                rule: { ...(cur.rule || {}), field }
            }
        });
    }

    handleProgressionEqualsChange(event) {
        if (!this.selectedStateKey) return;
        const equals = event.detail?.value ?? event.target.value;
        const cur = this.selectedStateProgression;
        dispatch({
            type: 'UPDATE_STATE_PROGRESSION',
            stateKey: this.selectedStateKey,
            progression: {
                ...cur,
                mode: 'field_change',
                rule: { ...(cur.rule || {}), equals }
            }
        });
    }

    handleProgressionCustomLogicChange(event) {
        if (!this.selectedStateKey) return;
        const tree = event.detail?.tree;
        if (!tree) return;
        const cur = this.selectedStateProgression;
        dispatch({
            type: 'UPDATE_STATE_PROGRESSION',
            stateKey: this.selectedStateKey,
            progression: {
                ...cur,
                mode: 'custom_logic',
                rule: tree
            }
        });
    }

    handleAutoHoldDaysChange(event) {
        if (!this.selectedStateKey) return;
        const raw = event.detail?.value ?? event.target.value;
        const trimmed = raw == null ? '' : String(raw).trim();
        const next = { ...this.selectedStateStatusRules };
        if (trimmed === '') {
            delete next.autoOnHoldAfterDays;
        } else {
            const num = Number(trimmed);
            if (!Number.isNaN(num) && num > 0) {
                next.autoOnHoldAfterDays = num;
            }
        }
        dispatch({
            type: 'UPDATE_STATE_STATUS_RULES',
            stateKey: this.selectedStateKey,
            statusRules: next
        });
    }

    handleAutoEscalateToggle(event) {
        if (!this.selectedStateKey) return;
        const checked = event.detail?.checked ?? event.target.checked;
        const next = { ...this.selectedStateStatusRules };
        if (checked) next.autoEscalateIfBlocked = true;
        else delete next.autoEscalateIfBlocked;
        dispatch({
            type: 'UPDATE_STATE_STATUS_RULES',
            stateKey: this.selectedStateKey,
            statusRules: next
        });
    }

    // ── Agent Mode panel (per-phase) ──────────────────────────────
    //
    // Phases pick a reusable role from Agent_Role__mdt via the role library;
    // overrides (provider, autonomy, prompt addendum) layer on top. The new
    // shape on state.agent is:
    //   { enabled, roleKey, providerOverride, autonomyOverride, promptAddendum }
    //
    // Backwards-compat: contracts created before role support set
    // { persona, autonomy, systemPrompt } directly. We surface those as a
    // virtual "Custom (legacy)" entry in the dropdown so the admin can keep
    // them or pick a real role. WorkflowContract.resolveAgent already
    // accepts both shapes at runtime.

    get selectedStateAgent() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.agent) || {};
    }

    /** True when the agent block carries legacy freeform fields and no roleKey. */
    get isLegacyAgentConfig() {
        const a = this.selectedStateAgent;
        if (!a) return false;
        if (a.roleKey) return false;
        return !!(a.persona || a.systemPrompt
            || (a.autonomy && a.autonomy !== ''));
    }

    get agentEnabled() {
        return this.selectedStateAgent.enabled === true;
    }

    /**
     * The role currently selected on this phase. For legacy contracts (no
     * roleKey but persona/prompt set), returns the synthetic '__legacy__'
     * value so the dropdown can highlight the legacy entry.
     */
    get selectedRoleKey() {
        const a = this.selectedStateAgent;
        if (a.roleKey) return a.roleKey;
        if (this.isLegacyAgentConfig) return '__legacy__';
        return '';
    }

    /**
     * Dropdown options. Always starts with a blank "Pick a role" placeholder;
     * appends the legacy entry when the current phase has freeform config.
     */
    get agentRoleOptions() {
        const opts = [{ label: 'Pick a role…', value: '', selected: false }];
        const sel = this.selectedRoleKey;
        for (const r of (this._agentRoles || [])) {
            opts.push({
                label: r.displayName || r.roleKey,
                value: r.roleKey,
                selected: r.roleKey === sel
            });
        }
        if (this.isLegacyAgentConfig) {
            opts.push({
                label: 'Custom (legacy)',
                value: '__legacy__',
                selected: sel === '__legacy__'
            });
        }
        // Ensure the placeholder is selected when nothing else matches.
        if (!opts.some((o) => o.selected)) {
            opts[0].selected = true;
        }
        return opts;
    }

    /** The role record (summary) matching the current selection, or null. */
    get selectedRoleRecord() {
        const key = this.selectedStateAgent.roleKey;
        if (!key) return null;
        return (this._agentRoles || []).find((r) => r.roleKey === key) || null;
    }

    get hasSelectedRole() {
        return !!this.selectedRoleRecord;
    }

    get selectedRoleDisplayName() {
        return this.selectedRoleRecord ? this.selectedRoleRecord.displayName : '';
    }

    get selectedRoleDescription() {
        return this.selectedRoleRecord ? (this.selectedRoleRecord.description || '') : '';
    }

    get selectedRoleProviderHint() {
        const r = this.selectedRoleRecord;
        return r && r.providerName
            ? `Default provider: ${r.providerName}`
            : 'Default provider: (use platform default)';
    }

    get selectedRoleAutonomyHint() {
        const r = this.selectedRoleRecord;
        return r && r.defaultAutonomy
            ? `Default autonomy: ${r.defaultAutonomy.replace(/_/g, ' ')}`
            : 'Default autonomy: Act With Approval';
    }

    /** True when the legacy entry is the active selection. */
    get isLegacySelected() {
        return this.selectedRoleKey === '__legacy__';
    }

    /** Override fields */
    get agentProviderOverride() {
        return this.selectedStateAgent.providerOverride || '';
    }

    get agentPromptAddendum() {
        return this.selectedStateAgent.promptAddendum || '';
    }

    get agentAutonomyOverrideOptions() {
        const current = this.selectedStateAgent.autonomyOverride || '';
        const opts = [
            { label: 'Use role default', value: '' },
            { label: 'Propose Only', value: 'Propose_Only' },
            { label: 'Act With Approval', value: 'Act_With_Approval' },
            { label: 'Autonomous (safe)', value: 'Autonomous_Safe' }
        ];
        return opts.map((o) => ({ ...o, selected: o.value === current }));
    }

    get agentRoleError() {
        return this._agentRoleError;
    }

    get showAgentOverrides() {
        return this._showAgentOverrides;
    }

    get agentOverridesToggleLabel() {
        return this._showAgentOverrides
            ? 'Hide overrides'
            : 'Customize this role';
    }

    handleAgentEnabledToggle(event) {
        if (!this.selectedStateKey) return;
        const checked = event.detail?.checked ?? event.target.checked;
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { enabled: !!checked }
        });
    }

    handleAgentRoleChange(event) {
        if (!this.selectedStateKey) return;
        const roleKey = event.detail?.value ?? event.target.value ?? '';
        // Picking a real role wipes any prior legacy freeform fields so the
        // contract is unambiguous — the role drives defaults from there on.
        // Picking the legacy entry is a no-op (already legacy).
        // Picking the placeholder clears the role.
        if (roleKey === '__legacy__') {
            return;
        }
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: {
                roleKey: roleKey || null,
                persona: null,
                systemPrompt: null,
                autonomy: null
            }
        });
    }

    handleAgentProviderOverrideChange(event) {
        if (!this.selectedStateKey) return;
        const providerOverride = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { providerOverride: providerOverride || null }
        });
    }

    handleAgentAutonomyOverrideChange(event) {
        if (!this.selectedStateKey) return;
        const autonomyOverride = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { autonomyOverride: autonomyOverride || null }
        });
    }

    handleAgentPromptAddendumChange(event) {
        if (!this.selectedStateKey) return;
        const promptAddendum = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { promptAddendum: promptAddendum || null }
        });
    }

    handleAgentOverridesToggle() {
        this._showAgentOverrides = !this._showAgentOverrides;
    }

    get selectedField() {
        if (!this.selectedStateKey || !this.selectedFieldKey) return null;
        const state = this.states.find(
            (s) => s.key === this.selectedStateKey
        );
        if (!state) return null;
        const field = (state.fields || []).find(
            (f) => f.key === this.selectedFieldKey
        );
        if (!field) return null;
        return {
            ...field,
            projectionEnabled: field.projection && field.projection.enabled
        };
    }

    // ── Deploy dialog computed ────────────────────────────────────

    get deployFieldSpecs() {
        const specs = [];
        const targetObj =
            this.publishTargetObject ||
            (this.workflow.subjectKinds || [])[0] ||
            '';
        this.states.forEach((s) => {
            (s.fields || []).forEach((f) => {
                if (f.projection && f.projection.enabled) {
                    specs.push({
                        fieldLabel: f.label,
                        fieldApiName: `Pulse_${f.key}__c`,
                        fieldType: f.type || 'Text',
                        objectApiName: targetObj
                    });
                }
            });
        });
        return specs;
    }

    get deployProjections() {
        const projs = [];
        this.states.forEach((s) => {
            (s.fields || []).forEach((f) => {
                if (f.projection && f.projection.enabled) {
                    projs.push({
                        label: f.label,
                        fieldKey: f.key,
                        compositeKey: `${s.key}__${f.key}`
                    });
                }
            });
        });
        return projs;
    }

    // ── Create workflow handlers ──────────────────────────────────

    handleNewKeyChange(event) {
        this.newWorkflowKey = event.detail.value;
    }

    handleNewNameChange(event) {
        this.newWorkflowName = event.detail.value;
    }

    handleNewKindsChange(event) {
        this.newSubjectKinds = event.detail.value;
    }

    handleCreateWorkflow() {
        const kinds = this.newSubjectKinds
            .split(',')
            .map((k) => k.trim())
            .filter(Boolean);
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: this.newWorkflowKey.trim(),
            name: this.newWorkflowName.trim() || this.newWorkflowKey.trim(),
            subjectKinds: kinds
        });
    }

    handleShowCreateForm() {
        this.showCreateForm = true;
    }

    handleBackToLanding() {
        this.showCreateForm = false;
    }

    async handleOpenExisting(event) {
        const recordId = event.currentTarget.dataset.recordId;
        if (!recordId) return;
        try {
            const payload = await loadWorkflow({ workflowDefinitionId: recordId });
            if (!payload || !payload.definitionJson) {
                this._listError = 'Workflow has no definition JSON';
                return;
            }
            const wf = JSON.parse(payload.definitionJson);
            // Ensure workflow object has name for the UI header
            if (!wf.name && payload.name) wf.name = payload.name;
            this._recordId = payload.recordId;
            dispatch({ type: 'LOAD_WORKFLOW', workflow: wf });
        } catch (e) {
            this._listError = e?.body?.message || e?.message || 'Failed to load workflow';
        }
    }

    // ── Metadata handlers ─────────────────────────────────────────

    handleMetaKeyChange(event) {
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: event.detail.value
        });
    }

    handleMetaKindsChange(event) {
        dispatch({
            type: 'SET_WORKFLOW_META',
            subjectKinds: event.detail.value
                .split(',')
                .map((k) => k.trim())
                .filter(Boolean)
        });
    }

    // ── State handlers ────────────────────────────────────────────

    handleAddState() {
        this.showAddStateForm = true;
        this.newStateKey = '';
        this.newStateLabel = '';
    }

    handleCancelAddState() {
        this.showAddStateForm = false;
    }

    handleNewStateKeyChange(event) {
        this.newStateKey = event.detail.value;
    }

    handleNewStateLabelChange(event) {
        this.newStateLabel = event.detail.value;
    }

    handleConfirmAddState() {
        dispatch({
            type: 'ADD_STATE',
            stateKey: this.newStateKey.trim(),
            label: this.newStateLabel.trim() || this.newStateKey.trim()
        });
        this.showAddStateForm = false;
    }

    handleSelectState(event) {
        dispatch({
            type: 'SELECT_STATE',
            stateKey: event.detail.stateKey
        });
    }

    handleDeleteState(event) {
        dispatch({
            type: 'REMOVE_STATE',
            stateKey: event.detail.stateKey
        });
    }

    handleReorderState(event) {
        const { fromKey, toKey } = event.detail;
        const keys = this.states.map((s) => s.key);
        const fromIdx = keys.indexOf(fromKey);
        const toIdx = keys.indexOf(toKey);
        if (fromIdx < 0 || toIdx < 0) return;
        keys.splice(fromIdx, 1);
        keys.splice(toIdx, 0, fromKey);
        dispatch({ type: 'REORDER_STATES', stateKeys: keys });
    }

    handleStateKeyEdit(event) {
        dispatch({
            type: 'UPDATE_STATE',
            stateKey: this.selectedStateKey,
            updates: { key: event.detail.value }
        });
    }

    handleStateLabelEdit(event) {
        dispatch({
            type: 'UPDATE_STATE',
            stateKey: this.selectedStateKey,
            updates: { label: event.detail.value }
        });
    }

    // ── Field handlers ────────────────────────────────────────────

    handleAddField() {
        const count = this.selectedState?.fields?.length || 0;
        const fieldKey = `field_${count + 1}`;
        dispatch({
            type: 'ADD_FIELD',
            stateKey: this.selectedStateKey,
            fieldKey,
            label: fieldKey
        });
        dispatch({
            type: 'SELECT_FIELD',
            stateKey: this.selectedStateKey,
            fieldKey
        });
    }

    handleSelectField(event) {
        const fieldKey = event.currentTarget.dataset.fieldKey;
        dispatch({
            type: 'SELECT_FIELD',
            stateKey: this.selectedStateKey,
            fieldKey
        });
    }

    handleUpdateField(event) {
        dispatch({
            type: 'UPDATE_FIELD',
            stateKey: event.detail.stateKey,
            fieldKey: event.detail.fieldKey,
            updates: event.detail.updates
        });
    }

    handleToggleProjection(event) {
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: event.detail.stateKey,
            fieldKey: event.detail.fieldKey
        });
    }

    handleDeleteField(event) {
        dispatch({
            type: 'REMOVE_FIELD',
            stateKey: event.detail.stateKey,
            fieldKey: event.detail.fieldKey
        });
    }

    handleCloseInspector() {
        dispatch({
            type: 'SELECT_STATE',
            stateKey: this.selectedStateKey
        });
    }

    // ── Transition handlers ───────────────────────────────────────

    handleAddTransition() {
        const otherStates = this.states.filter(
            (s) => s.key !== this.selectedStateKey
        );
        const target =
            otherStates.length > 0 ? otherStates[0].key : this.selectedStateKey;
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: this.selectedStateKey,
            signal: 'submit',
            toStateKey: target
        });
    }

    handleDeleteTransition(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        dispatch({
            type: 'REMOVE_TRANSITION',
            stateKey: this.selectedStateKey,
            transitionIndex: idx
        });
    }

    // ── Action handlers ───────────────────────────────────────────

    handleSelectAction(event) {
        const actionKey = event.currentTarget.dataset.actionKey;
        if (!actionKey) return;
        dispatch({
            type: 'SELECT_ACTION',
            stateKey: this.selectedStateKey,
            actionKey
        });
    }

    handleCloseActionInspector() {
        // Clear action selection but preserve state selection.
        dispatch({
            type: 'SELECT_STATE',
            stateKey: this.selectedStateKey
        });
    }

    handleActionStatusesChange(event) {
        if (!this.selectedStateKey || !this.selectedActionKey) return;
        const detail = event.detail || {};
        dispatch({
            type: 'UPDATE_ACTION_STATUSES',
            stateKey: this.selectedStateKey,
            actionKey: this.selectedActionKey,
            statuses: detail.statuses || [],
            initialStatusKey: detail.initialStatusKey || ''
        });
    }

    // ── Save handler ──────────────────────────────────────────────

    async handleSave() {
        const jsonBody = JSON.stringify(this.workflow);
        try {
            const result = await saveWorkflow({
                workflowDefinitionId: this._recordId || null,
                jsonBody
            });
            if (result.success) {
                this._recordId = result.recordId;
                // Reload to clear dirty flag
                dispatch({
                    type: 'LOAD_WORKFLOW',
                    workflow: this.workflow
                });
            }
        } catch (error) {
            // Surface error through store for UI feedback
            dispatch({
                type: 'SET_DEPLOYMENT_STATUS',
                status: 'Failed'
            });
        }
    }

    // ── Publish handlers ──────────────────────────────────────────

    handleOpenPublish() {
        this.publishTargetObject =
            (this.workflow.subjectKinds || [])[0] || '';
        this.showDeployDialog = true;
        const dialog = this.template.querySelector('c-pulse-deploy-dialog');
        if (dialog) {
            dialog.reset();
        }
    }

    handleClosePublish() {
        this.showDeployDialog = false;
    }

    async handleConfirmPublish() {
        const dialog = this.template.querySelector('c-pulse-deploy-dialog');
        if (dialog) {
            dialog.setDeploying();
        }

        // Save first if needed
        if (this.isDirty || !this._recordId) {
            await this.handleSave();
        }

        if (!this._recordId) {
            if (dialog) {
                dialog.setResult('Failed', 'Workflow must be saved before publishing.');
            }
            return;
        }

        try {
            const result = await publishWorkflow({
                workflowDefinitionId: this._recordId,
                targetObject: this.publishTargetObject,
                requestedFields: this.deployFieldSpecs.map((f) => ({
                    objectApiName: f.objectApiName,
                    fieldApiName: f.fieldApiName,
                    fieldLabel: f.fieldLabel,
                    fieldType: f.fieldType,
                    fieldLength: f.fieldType === 'Text' ? 255 : null,
                    precision: null,
                    scale: null
                }))
            });

            dispatch({
                type: 'SET_DEPLOYMENT_STATUS',
                deploymentRequestId: result.deploymentRequestId,
                status: result.status
            });

            if (dialog) {
                dialog.setResult(result.status, result.message);
            }
        } catch (error) {
            const msg =
                error?.body?.message || error?.message || 'Unknown error';
            if (dialog) {
                dialog.setResult('Failed', msg);
            }
        }
    }
}

import { LightningElement, track } from 'lwc';
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

export default class PulseWorkflowBuilder extends LightningElement {
    @track _storeState;
    @track _existingWorkflows = [];
    @track _listError = null;
    _unsubscribe;
    _recordId; // Workflow_Definition__c Id once saved

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
    // Mirrors the autonomy levels that PulseAgentOrchestrator actually
    // reads (Propose_Only / Act_With_Approval / Autonomous_Safe). The
    // `agent` block lives under the current state in the contract so it
    // round-trips through save/load.

    get selectedStateAgent() {
        const s = this.states.find((st) => st.key === this.selectedStateKey);
        return (s && s.agent) || {};
    }

    get agentEnabled() {
        return this.selectedStateAgent.enabled === true;
    }

    get agentPersona() {
        return this.selectedStateAgent.persona || '';
    }

    get agentSystemPrompt() {
        return this.selectedStateAgent.systemPrompt || '';
    }

    get agentAutonomyOptions() {
        const current = this.selectedStateAgent.autonomy || 'Act_With_Approval';
        const opts = [
            { label: 'Propose Only', value: 'Propose_Only' },
            { label: 'Act With Approval', value: 'Act_With_Approval' },
            { label: 'Autonomous (safe)', value: 'Autonomous_Safe' }
        ];
        return opts.map((o) => ({ ...o, selected: o.value === current }));
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

    handleAgentPersonaChange(event) {
        if (!this.selectedStateKey) return;
        const persona = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { persona }
        });
    }

    handleAgentAutonomyChange(event) {
        if (!this.selectedStateKey) return;
        const autonomy = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { autonomy }
        });
    }

    handleAgentSystemPromptChange(event) {
        if (!this.selectedStateKey) return;
        const systemPrompt = event.detail?.value ?? event.target.value ?? '';
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: this.selectedStateKey,
            patch: { systemPrompt }
        });
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

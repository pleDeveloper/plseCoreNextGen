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

export default class PulseWorkflowBuilder extends LightningElement {
    @track _storeState;
    _unsubscribe;
    _recordId; // Workflow_Definition__c Id once saved

    // ── Create-workflow form state ────────────────────────────────
    newWorkflowKey = '';
    newWorkflowName = '';
    newSubjectKinds = '';

    // ── Add-state form state ──────────────────────────────────────
    showAddStateForm = false;
    newStateKey = '';
    newStateLabel = '';

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

    get isCreating() {
        return !this.workflowKey;
    }

    get isEditing() {
        return !!this.workflowKey;
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
        return !!this.selectedStateKey && !this.selectedFieldKey;
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
            fields: (s.fields || []).map((f) => ({
                ...f,
                projected: f.projection && f.projection.enabled
            })),
            transitions: (s.transitions || []).map((t, i) => ({
                ...t,
                idx: i,
                compositeKey: `${t.signal}_${t.to}_${i}`
            }))
        };
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

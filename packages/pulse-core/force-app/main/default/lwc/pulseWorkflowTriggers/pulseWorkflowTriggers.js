import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listTriggers from '@salesforce/apex/PulseWorkflowTriggerController.listTriggers';
import upsertTrigger from '@salesforce/apex/PulseWorkflowTriggerController.upsertTrigger';
import deleteTrigger from '@salesforce/apex/PulseWorkflowTriggerController.deleteTrigger';

const EVENT_TYPES = [
    { label: 'Created', value: 'Created' },
    { label: 'Updated', value: 'Updated' },
    { label: 'Created or updated', value: 'Created_or_Updated' }
];

let uiRowSeq = 0;
function nextRowId() {
    uiRowSeq += 1;
    return `r_${uiRowSeq}`;
}

function freshTrigger(workflowDefinitionId) {
    return {
        rowId: nextRowId(),
        recordId: null,
        workflowDefinitionId,
        name: '',
        targetObject: '',
        eventType: 'Created_or_Updated',
        conditionTree: { logic: 'AND', rules: [] },
        initialStateKey: '',
        active: true,
        dirty: true,
        saving: false,
        error: null,
        apexTriggerStatus: null
    };
}

export default class PulseWorkflowTriggers extends LightningElement {
    @api workflowDefinitionId;
    @api availableStates = [];    // [{ key, label, type }]

    @track triggers = [];
    @track loading = true;
    @track listError = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._refresh();
    }

    get eventTypes() { return EVENT_TYPES; }

    get hasTriggers() {
        return this.triggers.length > 0;
    }

    _buildStateOptions(selectedKey) {
        const opts = [{ label: '(workflow default)', value: '', selected: !selectedKey }];
        (this.availableStates || []).forEach((s) => {
            opts.push({
                label: s.label || s.key,
                value: s.key,
                selected: s.key === selectedKey
            });
        });
        return opts;
    }

    async _refresh() {
        if (!this.workflowDefinitionId) {
            this.triggers = [];
            this.loading = false;
            return;
        }
        this.loading = true;
        try {
            const rows = await listTriggers({ workflowDefinitionId: this.workflowDefinitionId });
            this.triggers = (rows || []).map((r) => this._rowToState(r));
            this.listError = null;
        } catch (err) {
            this.listError = err?.body?.message || err?.message || 'Failed to load triggers';
        } finally {
            this.loading = false;
        }
    }

    _rowToState(row) {
        let tree = { logic: 'AND', rules: [] };
        try {
            const parsed = row.conditionJson ? JSON.parse(row.conditionJson) : null;
            if (parsed) {
                if (parsed.field && parsed.op) {
                    tree = {
                        logic: 'AND',
                        rules: [
                            {
                                field: parsed.field,
                                op: parsed.op,
                                value: parsed.value
                            }
                        ]
                    };
                } else {
                    tree = parsed;
                }
            }
        } catch (e) {
            // leave empty tree
        }

        return {
            rowId: nextRowId(),
            recordId: row.recordId,
            workflowDefinitionId: row.workflowDefinitionId,
            name: row.name || '',
            targetObject: row.targetObject || '',
            eventType: row.eventType || 'Created_or_Updated',
            conditionTree: tree,
            initialStateKey: row.initialStateKey || '',
            active: row.active !== false,
            dirty: false,
            saving: false,
            error: null,
            apexTriggerStatus: null
        };
    }

    get decoratedTriggers() {
        return this.triggers.map((t) => {
            const eventTypeOptions = EVENT_TYPES.map((opt) => ({
                ...opt,
                selected: opt.value === t.eventType
            }));
            const stateOptions = this._buildStateOptions(t.initialStateKey);

            return {
                ...t,
                eventTypeOptions,
                stateOptions,
                saveDisabled: !t.dirty || t.saving || !t.targetObject,
                saveLabel: t.saving ? 'Saving…' : (t.recordId ? 'Save changes' : 'Save trigger')
            };
        });
    }

    // ── Handlers ───────────────────────────────────────────────

    handleAddTrigger() {
        const t = freshTrigger(this.workflowDefinitionId);
        this.triggers = [...this.triggers, t];
    }

    handleTargetObjectChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, targetObject: value, dirty: true } : t
        );
    }

    handleEventTypeChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, eventType: value, dirty: true } : t
        );
    }

    handleInitialStateChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, initialStateKey: value, dirty: true } : t
        );
    }

    handleActiveToggle(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const checked = event.detail?.checked ?? event.target.checked;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, active: checked, dirty: true } : t
        );
    }

    handleConditionChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const tree = event.detail?.tree;
        if (!tree) return;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId
                ? { ...t, conditionTree: tree, dirty: true }
                : t
        );
    }

    async handleSave(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const t = this.triggers.find((x) => x.rowId === triggerRowId);
        if (!t) return;

        this._setTriggerState(triggerRowId, { saving: true, error: null });

        try {
            const result = await upsertTrigger({
                payload: {
                    recordId: t.recordId || null,
                    workflowDefinitionId: t.workflowDefinitionId,
                    name: t.name || null,
                    targetObject: t.targetObject,
                    eventType: t.eventType,
                    conditionJson: JSON.stringify(t.conditionTree || {}),
                    initialStateKey: t.initialStateKey || null,
                    active: t.active
                }
            });
            if (result.success) {
                let status;
                if (result.apexTriggerProvisioned) {
                    status = result.apexTriggerAlreadyExisted
                        ? `Using existing Apex trigger ${result.triggerName}`
                        : `Provisioned ${result.triggerName}`;
                } else {
                    status = null;
                }
                this._setTriggerState(triggerRowId, {
                    saving: false,
                    dirty: false,
                    recordId: result.recordId,
                    apexTriggerStatus: status,
                    warning: result.warning || null,
                    error: null
                });
            } else {
                this._setTriggerState(triggerRowId, {
                    saving: false,
                    error: result.error || 'Save failed'
                });
            }
        } catch (err) {
            this._setTriggerState(triggerRowId, {
                saving: false,
                error: err?.body?.message || err?.message || 'Save failed'
            });
        }
    }

    async handleDelete(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const t = this.triggers.find((x) => x.rowId === triggerRowId);
        if (!t) return;

        if (!t.recordId) {
            this.triggers = this.triggers.filter((x) => x.rowId !== triggerRowId);
            return;
        }

        try {
            await deleteTrigger({ triggerId: t.recordId });
            this.triggers = this.triggers.filter((x) => x.rowId !== triggerRowId);
        } catch (err) {
            this._setTriggerState(triggerRowId, {
                error: err?.body?.message || err?.message || 'Delete failed'
            });
        }
    }

    _setTriggerState(triggerRowId, patch) {
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, ...patch } : t
        );
    }
}

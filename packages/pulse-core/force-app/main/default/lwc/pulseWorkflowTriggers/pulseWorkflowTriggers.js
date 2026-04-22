import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listTriggers from '@salesforce/apex/PulseWorkflowTriggerController.listTriggers';
import upsertTrigger from '@salesforce/apex/PulseWorkflowTriggerController.upsertTrigger';
import deleteTrigger from '@salesforce/apex/PulseWorkflowTriggerController.deleteTrigger';
import describeObjectFields from '@salesforce/apex/PulseWorkflowTriggerController.describeObjectFields';

const EVENT_TYPES = [
    { label: 'Created', value: 'Created' },
    { label: 'Updated', value: 'Updated' },
    { label: 'Created or updated', value: 'Created_or_Updated' },
];

const DEFAULT_OPS = [
    { label: 'equals', value: 'EQUALS' },
    { label: 'not equals', value: 'NOT_EQUALS' },
    { label: 'contains', value: 'CONTAINS' },
    { label: 'starts with', value: 'STARTS_WITH' },
    { label: 'ends with', value: 'ENDS_WITH' },
    { label: 'greater than', value: 'GREATER_THAN' },
    { label: 'less than', value: 'LESS_THAN' },
    { label: 'is empty', value: 'IS_NULL' },
    { label: 'is not empty', value: 'IS_NOT_NULL' },
    { label: 'changed', value: 'IS_CHANGED' },
    { label: 'changed to', value: 'CHANGED_TO' },
    { label: 'changed from', value: 'CHANGED_FROM' },
];

let uiRowSeq = 0;
function nextRowId() {
    uiRowSeq += 1;
    return `r_${uiRowSeq}`;
}

function freshRule() {
    return { rowId: nextRowId(), field: '', op: 'EQUALS', value: '' };
}

function freshTrigger(workflowDefinitionId) {
    return {
        rowId: nextRowId(),
        recordId: null,
        workflowDefinitionId,
        name: '',
        targetObject: '',
        eventType: 'Created_or_Updated',
        logic: 'AND',
        rules: [freshRule()],
        initialStateKey: '',
        active: true,
        dirty: true,
        saving: false,
        error: null,
        apexTriggerStatus: null,
    };
}

export default class PulseWorkflowTriggers extends LightningElement {
    @api workflowDefinitionId;
    @api availableStates = [];    // [{ key, label, type }]

    @track triggers = [];
    @track loading = true;
    @track listError = null;

    _fieldCache = new Map();      // sObjectApiName -> [{apiName, label, fieldType, picklistValues}]

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
                selected: s.key === selectedKey,
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
        let logic = 'AND';
        let rules = [];
        try {
            const parsed = row.conditionJson ? JSON.parse(row.conditionJson) : null;
            if (parsed) {
                if (parsed.field && parsed.op) {
                    // single-rule shorthand
                    rules = [{
                        rowId: nextRowId(),
                        field: parsed.field,
                        op: parsed.op,
                        value: parsed.value != null ? String(parsed.value) : '',
                    }];
                } else {
                    logic = (parsed.logic || 'AND').toUpperCase();
                    rules = (parsed.rules || []).map((r) => ({
                        rowId: nextRowId(),
                        field: r.field || '',
                        op: r.op || 'EQUALS',
                        value: r.value != null ? String(r.value) : '',
                    }));
                }
            }
        } catch (e) {
            // leave rules empty; user can reset
        }
        if (rules.length === 0) rules = [freshRule()];

        // Load field options for target object if we don't have them cached.
        if (row.targetObject) {
            this._ensureFieldsLoaded(row.targetObject);
        }

        return {
            rowId: nextRowId(),
            recordId: row.recordId,
            workflowDefinitionId: row.workflowDefinitionId,
            name: row.name || '',
            targetObject: row.targetObject || '',
            eventType: row.eventType || 'Created_or_Updated',
            logic,
            rules,
            initialStateKey: row.initialStateKey || '',
            active: row.active !== false,
            dirty: false,
            saving: false,
            error: null,
            apexTriggerStatus: null,
        };
    }

    async _ensureFieldsLoaded(sObjectApiName) {
        if (!sObjectApiName || this._fieldCache.has(sObjectApiName)) return;
        try {
            const fields = await describeObjectFields({ sObjectApiName });
            this._fieldCache.set(sObjectApiName, fields || []);
            // Force re-render so rule rows pick up options.
            this.triggers = this.triggers.map((t) => ({ ...t }));
        } catch (e) {
            // non-fatal; leave field picker empty
            this._fieldCache.set(sObjectApiName, []);
        }
    }

    get decoratedTriggers() {
        return this.triggers.map((t) => {
            const fields = this._fieldCache.get(t.targetObject) || [];
            const fieldByName = new Map(fields.map((f) => [f.apiName, f]));

            const eventTypeOptions = EVENT_TYPES.map((opt) => ({
                ...opt,
                selected: opt.value === t.eventType,
            }));
            const stateOptions = this._buildStateOptions(t.initialStateKey);

            const decoratedRules = t.rules.map((r) => {
                const meta = fieldByName.get(r.field);
                const isPicklist = meta && meta.fieldType === 'PICKLIST';
                const hideValue = r.op === 'IS_NULL' || r.op === 'IS_NOT_NULL' || r.op === 'IS_CHANGED';
                return {
                    ...r,
                    isPicklist,
                    hideValue,
                    fieldEmpty: !r.field,
                    valueEmpty: !r.value,
                    fieldOptions: fields.map((f) => ({
                        label: `${f.label} (${f.apiName})`,
                        value: f.apiName,
                        selected: f.apiName === r.field,
                    })),
                    opOptions: DEFAULT_OPS.map((opt) => ({
                        ...opt,
                        selected: opt.value === r.op,
                    })),
                    picklistOptions: isPicklist
                        ? (meta.picklistValues || []).map((v) => ({
                            label: v,
                            value: v,
                            selected: v === r.value,
                        }))
                        : [],
                };
            });

            return {
                ...t,
                isAnd: t.logic === 'AND',
                logicLabel: t.logic === 'AND' ? 'ALL of' : 'ANY of',
                eventTypeOptions,
                stateOptions,
                saveDisabled: !t.dirty || t.saving || !t.targetObject,
                saveLabel: t.saving ? 'Saving…' : (t.recordId ? 'Save changes' : 'Save trigger'),
                rules: decoratedRules,
                showLogicSelector: t.rules.length > 1,
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
        this._ensureFieldsLoaded(value);
    }

    handleEventTypeChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, eventType: value, dirty: true } : t
        );
    }

    handleLogicToggle(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId
                ? { ...t, logic: t.logic === 'AND' ? 'OR' : 'AND', dirty: true }
                : t
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

    handleAddRule(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId
                ? { ...t, rules: [...t.rules, freshRule()], dirty: true }
                : t
        );
    }

    handleRemoveRule(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const ruleRowId   = event.currentTarget.dataset.ruleRowId;
        this.triggers = this.triggers.map((t) => {
            if (t.rowId !== triggerRowId) return t;
            const rules = t.rules.filter((r) => r.rowId !== ruleRowId);
            return {
                ...t,
                rules: rules.length > 0 ? rules : [freshRule()],
                dirty: true,
            };
        });
    }

    handleRuleFieldChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const ruleRowId   = event.currentTarget.dataset.ruleRowId;
        const value = event.detail?.value ?? event.target.value;
        this._patchRule(triggerRowId, ruleRowId, { field: value });
    }

    handleRuleOpChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const ruleRowId   = event.currentTarget.dataset.ruleRowId;
        const value = event.detail?.value ?? event.target.value;
        this._patchRule(triggerRowId, ruleRowId, { op: value });
    }

    handleRuleValueChange(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const ruleRowId   = event.currentTarget.dataset.ruleRowId;
        const value = event.detail?.value ?? event.target.value;
        this._patchRule(triggerRowId, ruleRowId, { value });
    }

    _patchRule(triggerRowId, ruleRowId, patch) {
        this.triggers = this.triggers.map((t) => {
            if (t.rowId !== triggerRowId) return t;
            return {
                ...t,
                rules: t.rules.map((r) =>
                    r.rowId === ruleRowId ? { ...r, ...patch } : r
                ),
                dirty: true,
            };
        });
    }

    async handleSave(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const t = this.triggers.find((x) => x.rowId === triggerRowId);
        if (!t) return;

        this._setTriggerState(triggerRowId, { saving: true, error: null });

        const conditionTree = {
            logic: t.logic,
            rules: t.rules
                .filter((r) => r.field || r.op === 'IS_NULL' || r.op === 'IS_NOT_NULL' || r.op === 'IS_CHANGED')
                .map((r) => {
                    const rule = { field: r.field, op: r.op };
                    if (!this._isValueless(r.op)) rule.value = this._coerceValue(r.value);
                    return rule;
                }),
        };

        try {
            const result = await upsertTrigger({
                payload: {
                    recordId: t.recordId || null,
                    workflowDefinitionId: t.workflowDefinitionId,
                    name: t.name || null,
                    targetObject: t.targetObject,
                    eventType: t.eventType,
                    conditionJson: JSON.stringify(conditionTree),
                    initialStateKey: t.initialStateKey || null,
                    active: t.active,
                },
            });
            if (result.success) {
                this._setTriggerState(triggerRowId, {
                    saving: false,
                    dirty: false,
                    recordId: result.recordId,
                    apexTriggerStatus: result.apexTriggerAlreadyExisted
                        ? `Using existing Apex trigger ${result.triggerName}`
                        : `Provisioned ${result.triggerName}`,
                });
            } else {
                this._setTriggerState(triggerRowId, {
                    saving: false,
                    error: result.error || 'Save failed',
                });
            }
        } catch (err) {
            this._setTriggerState(triggerRowId, {
                saving: false,
                error: err?.body?.message || err?.message || 'Save failed',
            });
        }
    }

    async handleDelete(event) {
        const triggerRowId = event.currentTarget.dataset.rowId;
        const t = this.triggers.find((x) => x.rowId === triggerRowId);
        if (!t) return;

        if (!t.recordId) {
            // Unsaved — just drop from list
            this.triggers = this.triggers.filter((x) => x.rowId !== triggerRowId);
            return;
        }

        try {
            await deleteTrigger({ triggerId: t.recordId });
            this.triggers = this.triggers.filter((x) => x.rowId !== triggerRowId);
        } catch (err) {
            this._setTriggerState(triggerRowId, {
                error: err?.body?.message || err?.message || 'Delete failed',
            });
        }
    }

    _setTriggerState(triggerRowId, patch) {
        this.triggers = this.triggers.map((t) =>
            t.rowId === triggerRowId ? { ...t, ...patch } : t
        );
    }

    _isValueless(op) {
        return op === 'IS_NULL' || op === 'IS_NOT_NULL' || op === 'IS_CHANGED';
    }

    _coerceValue(raw) {
        if (raw == null || raw === '') return '';
        // Coerce numeric strings to numbers for numeric operators
        const num = Number(raw);
        if (!Number.isNaN(num) && raw.trim && raw.trim() !== '' && String(num) === raw.trim()) {
            return num;
        }
        return raw;
    }
}

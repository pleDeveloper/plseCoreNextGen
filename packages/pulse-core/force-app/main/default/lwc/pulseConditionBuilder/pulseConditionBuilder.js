import { LightningElement, api, track } from 'lwc';
import describeObjectFields from '@salesforce/apex/PulseWorkflowTriggerController.describeObjectFields';

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
    { label: 'changed from', value: 'CHANGED_FROM' }
];

let rowSeq = 0;
function nextRowId() {
    rowSeq += 1;
    return `cb_${rowSeq}`;
}

function freshRule() {
    return { rowId: nextRowId(), field: '', op: 'EQUALS', value: '' };
}

function isValueless(op) {
    return op === 'IS_NULL' || op === 'IS_NOT_NULL' || op === 'IS_CHANGED';
}

/**
 * pulseConditionBuilder — reusable AND/OR rule tree editor.
 *
 * Props:
 *   @api conditionTree  — current tree, e.g. { logic: 'AND', rules: [...] } or {}
 *   @api targetObject   — SObject API name used to populate the field picker
 *   @api logicLabel     — prefix for the logic toggle (default: "Match")
 *   @api hideChangeOps  — when true, hides IS_CHANGED / CHANGED_TO /
 *                         CHANGED_FROM operators (default false, matching
 *                         the trigger builder's needs). Set true for
 *                         point-in-time evaluations (entry/exit/custom
 *                         progression) where change-aware operators don't
 *                         apply.
 *
 * Events:
 *   change — detail: { tree: { logic, rules } }
 */
export default class PulseConditionBuilder extends LightningElement {
    @api logicLabel = 'Match';
    @api hideChangeOps = false;

    @track _logic = 'AND';
    @track _rules = [freshRule()];

    _targetObject = '';
    _fields = [];
    _hydratedFrom = null;

    @api
    get conditionTree() {
        return this._serialize();
    }
    set conditionTree(value) {
        this._hydrate(value);
    }

    @api
    get targetObject() {
        return this._targetObject;
    }
    set targetObject(value) {
        const next = value || '';
        if (next === this._targetObject) return;
        this._targetObject = next;
        this._loadFields();
    }

    connectedCallback() {
        if (this._targetObject) {
            this._loadFields();
        }
    }

    // ── Hydration ──────────────────────────────────────────────

    _hydrate(tree) {
        // Avoid re-hydrating from our own serialized output (would
        // reset rowIds on every parent re-render).
        const key = tree ? JSON.stringify(tree) : '';
        if (key === this._hydratedFrom) return;
        this._hydratedFrom = key;

        let logic = 'AND';
        let rules = [];
        if (tree && typeof tree === 'object') {
            if (tree.field && tree.op) {
                rules = [
                    {
                        rowId: nextRowId(),
                        field: tree.field,
                        op: tree.op,
                        value: tree.value != null ? String(tree.value) : ''
                    }
                ];
            } else {
                logic = (tree.logic || 'AND').toUpperCase();
                const rawRules = Array.isArray(tree.rules) ? tree.rules : [];
                rules = rawRules
                    .filter((r) => r && r.field)
                    .map((r) => ({
                        rowId: nextRowId(),
                        field: r.field || '',
                        op: r.op || 'EQUALS',
                        value: r.value != null ? String(r.value) : ''
                    }));
            }
        }
        if (rules.length === 0) rules = [freshRule()];
        this._logic = logic;
        this._rules = rules;
    }

    _serialize() {
        return {
            logic: this._logic,
            rules: this._rules
                .filter((r) => r.field || isValueless(r.op))
                .map((r) => {
                    const out = { field: r.field, op: r.op };
                    if (!isValueless(r.op)) out.value = this._coerceValue(r.value);
                    return out;
                })
        };
    }

    async _loadFields() {
        if (!this._targetObject) {
            this._fields = [];
            return;
        }
        try {
            const fields = await describeObjectFields({
                sObjectApiName: this._targetObject
            });
            this._fields = Array.isArray(fields) ? fields : [];
        } catch (e) {
            this._fields = [];
        }
    }

    // ── Computed decorators ────────────────────────────────────

    get _opOptions() {
        if (!this.hideChangeOps) return DEFAULT_OPS;
        return DEFAULT_OPS.filter(
            (o) => o.value !== 'IS_CHANGED' && o.value !== 'CHANGED_TO' && o.value !== 'CHANGED_FROM'
        );
    }

    get isAnd() {
        return this._logic === 'AND';
    }

    get toggleLabel() {
        return this._logic === 'AND' ? 'ALL of' : 'ANY of';
    }

    get showLogicSelector() {
        return this._rules.length > 1;
    }

    get hasMultipleRules() {
        return this._rules.length > 1;
    }

    get decoratedRules() {
        const fieldByName = new Map(
            this._fields.map((f) => [f.apiName, f])
        );
        const opOpts = this._opOptions;
        return this._rules.map((r) => {
            const meta = fieldByName.get(r.field);
            const isPicklist = meta && meta.fieldType === 'PICKLIST';
            const hideValue = isValueless(r.op);
            return {
                ...r,
                isPicklist,
                hideValue,
                fieldEmpty: !r.field,
                valueEmpty: !r.value,
                fieldOptions: this._fields.map((f) => ({
                    label: `${f.label} (${f.apiName})`,
                    value: f.apiName,
                    selected: f.apiName === r.field
                })),
                opOptions: opOpts.map((opt) => ({
                    ...opt,
                    selected: opt.value === r.op
                })),
                picklistOptions: isPicklist
                    ? (meta.picklistValues || []).map((v) => ({
                          label: v,
                          value: v,
                          selected: v === r.value
                      }))
                    : []
            };
        });
    }

    // ── Handlers ───────────────────────────────────────────────

    handleLogicToggle() {
        this._logic = this._logic === 'AND' ? 'OR' : 'AND';
        this._emitChange();
    }

    handleAddRule() {
        this._rules = [...this._rules, freshRule()];
        this._emitChange();
    }

    handleRemoveRule(event) {
        const ruleRowId = event.currentTarget.dataset.ruleRowId;
        const filtered = this._rules.filter((r) => r.rowId !== ruleRowId);
        this._rules = filtered.length ? filtered : [freshRule()];
        this._emitChange();
    }

    handleRuleFieldChange(event) {
        this._patchRule(event, {
            field: event.detail?.value ?? event.target.value
        });
    }

    handleRuleOpChange(event) {
        this._patchRule(event, {
            op: event.detail?.value ?? event.target.value
        });
    }

    handleRuleValueChange(event) {
        this._patchRule(event, {
            value: event.detail?.value ?? event.target.value
        });
    }

    _patchRule(event, patch) {
        const ruleRowId = event.currentTarget.dataset.ruleRowId;
        this._rules = this._rules.map((r) =>
            r.rowId === ruleRowId ? { ...r, ...patch } : r
        );
        this._emitChange();
    }

    _emitChange() {
        const tree = this._serialize();
        // Record hydration key so we don't re-hydrate from parent's echo.
        this._hydratedFrom = JSON.stringify(tree);
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { tree }
            })
        );
    }

    _coerceValue(raw) {
        if (raw == null || raw === '') return '';
        const trimmed = typeof raw === 'string' ? raw.trim() : raw;
        if (typeof trimmed === 'string' && trimmed !== '') {
            const num = Number(trimmed);
            if (!Number.isNaN(num) && String(num) === trimmed) {
                return num;
            }
        }
        return raw;
    }
}

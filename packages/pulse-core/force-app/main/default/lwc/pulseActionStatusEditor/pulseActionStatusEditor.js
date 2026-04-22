import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listTemplates from '@salesforce/apex/PulseActionStatusTemplateController.listTemplates';

/**
 * pulseActionStatusEditor — configurable status-machine editor for a
 * single Workflow action.
 *
 * Parent owns the state. The component reads `statuses` and
 * `initialStatusKey` via @api and fires a `change` event on every
 * edit carrying the full merged list + (optionally) a new
 * `initialStatusKey`. The parent dispatches the matching pulseStore
 * action (see UPDATE_ACTION_STATUSES / UPDATE_ACTION_INITIAL_STATUS).
 *
 * Props:
 *   @api statuses           Array<StatusDef> — current list
 *   @api initialStatusKey   current initial status key
 *   @api targetObject       SObject API name (passed to the inline
 *                            condition builder's field picker)
 *   @api workflowActions    Array<{key,label}> siblings for the
 *                            action-status rule type
 *
 * Events:
 *   change — detail: { statuses, initialStatusKey }
 */

const CATEGORY_OPTIONS = [
    { label: 'Open',                 value: 'open' },
    { label: 'Blocked',              value: 'blocked' },
    { label: 'Terminal — success',   value: 'terminal_success' },
    { label: 'Terminal — failure',   value: 'terminal_failure' }
];

let rowSeq = 0;
function nextRowId() {
    rowSeq += 1;
    return `sr_${rowSeq}`;
}

function toKey(label) {
    if (!label) return '';
    return String(label)
        .trim()
        .replace(/[^A-Za-z0-9]+/g, '_')
        .replace(/^_+|_+$/g, '');
}

function hydrateStatus(sd, idx) {
    return {
        rowId: nextRowId(),
        key: sd.key || '',
        label: sd.label || sd.key || '',
        order: typeof sd.order === 'number' ? sd.order : idx,
        category: sd.category || 'open',
        isInitial: sd.isInitial === true,
        entryConditions: sd.entryConditions || {},
        // UX flag — once the user edits the key manually, stop
        // auto-deriving it from the label.
        keyManuallyEdited: !!sd.key
    };
}

export default class PulseActionStatusEditor extends LightningElement {
    @api targetObject = '';

    @track _rows = [];
    @track _templates = [];
    @track _showPicker = false;
    @track _pickerLoading = false;
    @track _pickerError = null;
    @track _importConfirmTemplateKey = null;

    _hydratedFromStatuses = null;
    _initialStatusKey = '';
    _workflowActions = [];

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    // ── Public API ────────────────────────────────────────────────

    @api
    get statuses() {
        return this._serialize();
    }
    set statuses(value) {
        this._hydrate(value);
    }

    @api
    get initialStatusKey() {
        // Return whichever row is marked isInitial, fallback to stored key.
        const initialRow = this._rows.find((r) => r.isInitial);
        if (initialRow) return initialRow.key;
        return this._initialStatusKey || '';
    }
    set initialStatusKey(value) {
        this._initialStatusKey = value || '';
        // Reconcile: flag the matching row as isInitial if one exists.
        if (value && this._rows.length) {
            const hit = this._rows.find((r) => r.key === value);
            if (hit && !hit.isInitial) {
                this._rows = this._rows.map((r) => ({
                    ...r,
                    isInitial: r.key === value
                }));
            }
        }
    }

    @api
    get workflowActions() {
        return this._workflowActions;
    }
    set workflowActions(value) {
        this._workflowActions = Array.isArray(value) ? value : [];
    }

    // ── Hydration / serialization ─────────────────────────────────

    _hydrate(value) {
        const key = value ? JSON.stringify(value) : '';
        if (key === this._hydratedFromStatuses) return;
        this._hydratedFromStatuses = key;

        const list = Array.isArray(value) ? value : [];
        const rows = list.map((sd, idx) => hydrateStatus(sd || {}, idx));
        // Ensure exactly one initial when any are marked.
        let foundInitial = false;
        for (const r of rows) {
            if (r.isInitial && !foundInitial) foundInitial = true;
            else r.isInitial = false;
        }
        // If none were flagged but we have an initialStatusKey, honor it.
        if (!foundInitial && this._initialStatusKey) {
            const target = rows.find((r) => r.key === this._initialStatusKey);
            if (target) target.isInitial = true;
        }
        this._rows = rows;
    }

    _serialize() {
        return this._rows.map((r, idx) => {
            const out = {
                key: r.key,
                label: r.label,
                order: idx,
                category: r.category,
                isInitial: !!r.isInitial
            };
            if (r.entryConditions && Object.keys(r.entryConditions).length) {
                out.entryConditions = r.entryConditions;
            }
            return out;
        });
    }

    _emitChange() {
        // Record hydration key so we don't re-hydrate from our own echo.
        const serialized = this._serialize();
        this._hydratedFromStatuses = JSON.stringify(serialized);
        const initialRow = this._rows.find((r) => r.isInitial);
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: {
                    statuses: serialized,
                    initialStatusKey: initialRow ? initialRow.key : ''
                }
            })
        );
    }

    // ── Computed ──────────────────────────────────────────────────

    get hasRows() {
        return this._rows && this._rows.length > 0;
    }

    get decoratedRows() {
        const only = this._rows.length <= 1;
        return this._rows.map((r, idx) => ({
            ...r,
            position: idx + 1,
            canMoveUp: idx > 0,
            canMoveDown: idx < this._rows.length - 1,
            moveUpDisabled: idx === 0,
            moveDownDisabled: idx >= this._rows.length - 1,
            canRemove: !only,
            categoryOptions: CATEGORY_OPTIONS.map((o) => ({
                ...o,
                selected: o.value === r.category
            }))
        }));
    }

    get showPicker() {
        return this._showPicker;
    }

    get templateOptions() {
        return this._templates;
    }

    get pickerError() {
        return this._pickerError;
    }

    get pickerLoading() {
        return this._pickerLoading;
    }

    get hasTemplates() {
        return this._templates && this._templates.length > 0;
    }

    get showImportConfirm() {
        return !!this._importConfirmTemplateKey;
    }

    get confirmTemplateName() {
        if (!this._importConfirmTemplateKey) return '';
        const hit = this._templates.find(
            (t) => t.templateKey === this._importConfirmTemplateKey
        );
        return hit ? hit.displayName : this._importConfirmTemplateKey;
    }

    // ── Handlers ──────────────────────────────────────────────────

    handleAddStatus() {
        const next = hydrateStatus(
            {
                key: '',
                label: '',
                category: 'open',
                isInitial: this._rows.length === 0
            },
            this._rows.length
        );
        next.keyManuallyEdited = false;
        this._rows = [...this._rows, next];
        this._emitChange();
    }

    handleRemoveRow(event) {
        if (this._rows.length <= 1) return;
        const rowId = event.currentTarget.dataset.rowId;
        const wasInitial =
            (this._rows.find((r) => r.rowId === rowId) || {}).isInitial === true;
        let next = this._rows.filter((r) => r.rowId !== rowId);
        if (wasInitial && next.length) {
            next = next.map((r, idx) => ({ ...r, isInitial: idx === 0 }));
        }
        this._rows = next;
        this._emitChange();
    }

    handleMoveUp(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const idx = this._rows.findIndex((r) => r.rowId === rowId);
        if (idx <= 0) return;
        const next = [...this._rows];
        [next[idx - 1], next[idx]] = [next[idx], next[idx - 1]];
        this._rows = next;
        this._emitChange();
    }

    handleMoveDown(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const idx = this._rows.findIndex((r) => r.rowId === rowId);
        if (idx < 0 || idx >= this._rows.length - 1) return;
        const next = [...this._rows];
        [next[idx], next[idx + 1]] = [next[idx + 1], next[idx]];
        this._rows = next;
        this._emitChange();
    }

    handleLabelChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value ?? '';
        this._rows = this._rows.map((r) => {
            if (r.rowId !== rowId) return r;
            const patch = { ...r, label: value };
            if (!r.keyManuallyEdited) {
                patch.key = toKey(value);
            }
            return patch;
        });
        this._emitChange();
    }

    handleKeyChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value ?? '';
        this._rows = this._rows.map((r) =>
            r.rowId === rowId
                ? { ...r, key: value, keyManuallyEdited: true }
                : r
        );
        this._emitChange();
    }

    handleCategoryChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const value = event.detail?.value ?? event.target.value;
        this._rows = this._rows.map((r) =>
            r.rowId === rowId ? { ...r, category: value } : r
        );
        this._emitChange();
    }

    handleSelectInitial(event) {
        const rowId = event.currentTarget.dataset.rowId;
        this._rows = this._rows.map((r) => ({
            ...r,
            isInitial: r.rowId === rowId
        }));
        this._emitChange();
    }

    handleEntryConditionsChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const tree = event.detail?.tree || {};
        this._rows = this._rows.map((r) =>
            r.rowId === rowId ? { ...r, entryConditions: tree } : r
        );
        this._emitChange();
    }

    // ── Template picker ───────────────────────────────────────────

    async handleOpenPicker() {
        this._showPicker = true;
        this._pickerError = null;
        this._pickerLoading = true;
        try {
            const rows = await listTemplates();
            this._templates = (rows || []).map((t) => ({
                templateKey: t.templateKey,
                displayName: t.displayName || t.templateKey,
                description: t.description || '',
                statusesJson: t.statusesJson || '[]'
            }));
        } catch (e) {
            this._pickerError =
                e?.body?.message || e?.message || 'Failed to load templates';
        } finally {
            this._pickerLoading = false;
        }
    }

    handleClosePicker() {
        this._showPicker = false;
        this._importConfirmTemplateKey = null;
    }

    handlePickTemplate(event) {
        const templateKey = event.currentTarget.dataset.templateKey;
        if (!templateKey) return;
        if (this._rows.length > 0) {
            // Ask for confirmation — existing statuses will be replaced.
            this._importConfirmTemplateKey = templateKey;
            return;
        }
        this._applyTemplate(templateKey);
    }

    handleConfirmImport() {
        if (!this._importConfirmTemplateKey) return;
        this._applyTemplate(this._importConfirmTemplateKey);
    }

    handleCancelImport() {
        this._importConfirmTemplateKey = null;
    }

    _applyTemplate(templateKey) {
        const tpl = this._templates.find((t) => t.templateKey === templateKey);
        if (!tpl) return;
        let parsed = [];
        try {
            parsed = JSON.parse(tpl.statusesJson || '[]');
        } catch (e) {
            this._pickerError = 'Template has invalid statuses JSON';
            return;
        }
        if (!Array.isArray(parsed) || parsed.length === 0) {
            this._pickerError = 'Template has no statuses';
            return;
        }
        // Force a full re-hydrate by clearing the cached key first.
        this._hydratedFromStatuses = null;
        const rows = parsed.map((sd, idx) => hydrateStatus(sd || {}, idx));
        // If none of the imported rows is marked initial, flag the first.
        if (!rows.some((r) => r.isInitial)) {
            if (rows.length) rows[0].isInitial = true;
        }
        this._rows = rows;
        this._showPicker = false;
        this._importConfirmTemplateKey = null;
        this._emitChange();
    }
}

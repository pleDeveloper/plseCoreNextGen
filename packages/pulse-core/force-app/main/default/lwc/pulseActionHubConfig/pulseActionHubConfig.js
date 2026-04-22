import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import listColumnConfigs from '@salesforce/apex/PulseGlobalActionHubController.listColumnConfigs';
import upsertColumnConfig from '@salesforce/apex/PulseGlobalActionHubController.upsertColumnConfig';

const EMPTY_EDITOR = () => ({
    configKey: '',
    targetObject: '',
    masterLabel: '',
    active: true,
    columns: [{ field: '', label: '' }],
});

export default class PulseActionHubConfig extends LightningElement {
    @track configs = [];
    @track isLoading = true;
    @track error = null;
    @track deployMessage = null;
    @track deploying = false;
    @track editor = EMPTY_EDITOR();
    @track editingKey = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._load();
    }

    async _load() {
        this.isLoading = true;
        try {
            const data = await listColumnConfigs();
            this.configs = (data || []).map((c) => ({
                ...c,
                columns: this._parseColumns(c.columnsJson),
            }));
            this.error = null;
        } catch (err) {
            this.error = (err && err.body && err.body.message) || 'Failed to load configs';
        } finally {
            this.isLoading = false;
        }
    }

    _parseColumns(json) {
        if (!json) return [];
        try {
            const parsed = JSON.parse(json);
            return Array.isArray(parsed) ? parsed : [];
        } catch (e) {
            return [];
        }
    }

    get hasConfigs() { return this.configs.length > 0; }
    get noConfigs()  { return this.configs.length === 0; }
    get hasError()   { return this.error != null; }
    get hasDeployMessage() { return this.deployMessage != null; }

    get listRows() {
        return this.configs.map((c) => ({
            ...c,
            subtitle: `${c.targetObject || '*'} · ${c.columns.length} columns`,
            activeBadgeVariant: c.active ? 'purple' : 'slate',
            activeBadgeLabel: c.active ? 'Active' : 'Inactive',
        }));
    }

    get editorColumnRows() {
        return this.editor.columns.map((c, idx) => ({
            ...c,
            key: `col-${idx}`,
            index: idx,
            canRemove: this.editor.columns.length > 1,
        }));
    }

    get saveDisabled() {
        return this.deploying
            || !this.editor.configKey
            || !this.editor.targetObject;
    }

    get saveButtonLabel() {
        return this.deploying ? 'Deploying…' : 'Save column config';
    }

    get editorTitle() {
        return this.editingKey ? `Edit ${this.editingKey}` : 'New column config';
    }

    handleNewConfig() {
        this.editingKey = null;
        this.editor = EMPTY_EDITOR();
        this.deployMessage = null;
    }

    handleEdit(event) {
        const key = event.currentTarget.dataset.key;
        const cfg = this.configs.find((c) => c.configKey === key);
        if (!cfg) return;
        this.editingKey = key;
        this.editor = {
            configKey: cfg.configKey,
            targetObject: cfg.targetObject || '',
            masterLabel: cfg.masterLabel || '',
            active: !!cfg.active,
            columns: cfg.columns && cfg.columns.length > 0
                ? cfg.columns.map((c) => ({ field: c.field || '', label: c.label || '' }))
                : [{ field: '', label: '' }],
        };
        this.deployMessage = null;
    }

    handleConfigKeyChange(event) {
        this.editor = { ...this.editor, configKey: event.detail.value };
    }

    handleTargetObjectChange(event) {
        this.editor = { ...this.editor, targetObject: event.detail.value };
    }

    handleMasterLabelChange(event) {
        this.editor = { ...this.editor, masterLabel: event.detail.value };
    }

    handleActiveChange(event) {
        this.editor = { ...this.editor, active: event.detail.checked };
    }

    handleColumnFieldChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const value = event.detail.value;
        const cols = this.editor.columns.map((c, i) =>
            i === idx ? { ...c, field: value } : c
        );
        this.editor = { ...this.editor, columns: cols };
    }

    handleColumnLabelChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const value = event.detail.value;
        const cols = this.editor.columns.map((c, i) =>
            i === idx ? { ...c, label: value } : c
        );
        this.editor = { ...this.editor, columns: cols };
    }

    handleAddColumn() {
        this.editor = {
            ...this.editor,
            columns: [...this.editor.columns, { field: '', label: '' }],
        };
    }

    handleRemoveColumn(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        if (this.editor.columns.length <= 1) return;
        this.editor = {
            ...this.editor,
            columns: this.editor.columns.filter((_, i) => i !== idx),
        };
    }

    async handleSave() {
        if (this.saveDisabled) return;
        this.deploying = true;
        this.deployMessage = null;
        try {
            const cleanCols = this.editor.columns
                .filter((c) => c.field && c.field.trim())
                .map((c) => ({
                    field: c.field.trim(),
                    label: (c.label || c.field).trim(),
                }));
            const columnsJson = JSON.stringify(cleanCols);
            const result = await upsertColumnConfig({
                payload: {
                    configKey: this.editor.configKey,
                    targetObject: this.editor.targetObject,
                    masterLabel: this.editor.masterLabel,
                    columnsJson,
                    active: this.editor.active,
                },
            });
            if (result && result.success) {
                this.deployMessage = `Deployment enqueued (job ${result.deploymentJobId}). Refreshing list…`;
                setTimeout(() => this._load(), 1500);
            } else {
                this.deployMessage = (result && result.message) || 'Deploy failed';
            }
        } catch (err) {
            this.deployMessage = (err && err.body && err.body.message) || 'Unexpected error';
        } finally {
            this.deploying = false;
        }
    }
}

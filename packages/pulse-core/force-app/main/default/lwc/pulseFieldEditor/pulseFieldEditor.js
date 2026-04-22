import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const FIELD_TYPES = [
    'Text',
    'Number',
    'Date',
    'DateTime',
    'Checkbox',
    'Currency',
    'Percent',
    'LongTextArea'
];

export default class PulseFieldEditor extends LightningElement {
    @api stateKey;
    @api fieldKey;
    @api label;
    @api fieldType = 'Text';
    @api required = false;
    @api projectionEnabled = false;
    @api extractionHints = [];

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get typeOptions() {
        return FIELD_TYPES.map((t) => ({
            value: t,
            label: t,
            selected: t === this.fieldType
        }));
    }

    get hintsValue() {
        return (this.extractionHints || []).join(', ');
    }

    handleKeyChange(event) {
        this._emitUpdate({ key: event.detail.value });
    }

    handleLabelChange(event) {
        this._emitUpdate({ label: event.detail.value });
    }

    handleTypeChange(event) {
        this._emitUpdate({ type: event.target.value });
    }

    handleRequiredChange(event) {
        this._emitUpdate({ required: event.detail.checked });
    }

    handleProjectionToggle() {
        this.dispatchEvent(
            new CustomEvent('toggleprojection', {
                detail: {
                    stateKey: this.stateKey,
                    fieldKey: this.fieldKey
                },
                bubbles: true,
                composed: true
            })
        );
    }

    handleHintsChange(event) {
        const hints = event.detail.value
            .split(',')
            .map((h) => h.trim())
            .filter(Boolean);
        this._emitUpdate({ extractionHints: hints });
    }

    handleDelete() {
        this.dispatchEvent(
            new CustomEvent('deletefield', {
                detail: {
                    stateKey: this.stateKey,
                    fieldKey: this.fieldKey
                },
                bubbles: true,
                composed: true
            })
        );
    }

    handleClose() {
        this.dispatchEvent(
            new CustomEvent('closeinspector', {
                bubbles: true,
                composed: true
            })
        );
    }

    _emitUpdate(updates) {
        this.dispatchEvent(
            new CustomEvent('updatefield', {
                detail: {
                    stateKey: this.stateKey,
                    fieldKey: this.fieldKey,
                    updates
                },
                bubbles: true,
                composed: true
            })
        );
    }
}

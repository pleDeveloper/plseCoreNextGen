import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseInput extends LightningElement {
    @api label;
    @api value = '';
    @api placeholder = '';
    @api type = 'text';
    @api required = false;
    @api error;
    @api helpText;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get inputClass() {
        return this.error
            ? 'pulse-input pulse-input-error'
            : 'pulse-input';
    }

    get hasError() {
        return !!this.error;
    }

    get hasHelpText() {
        return !!this.helpText;
    }

    get inputId() {
        return 'pulse-input-' + this.label?.replace(/\s+/g, '-').toLowerCase();
    }

    get errorId() {
        return this.inputId + '-error';
    }

    get helpId() {
        return this.inputId + '-help';
    }

    get ariaDescribedBy() {
        const ids = [];
        if (this.error) ids.push(this.errorId);
        if (this.helpText) ids.push(this.helpId);
        return ids.length ? ids.join(' ') : null;
    }

    handleInput(event) {
        const val = event.target.value;
        this.dispatchEvent(
            new CustomEvent('change', { detail: { value: val } })
        );
    }
}

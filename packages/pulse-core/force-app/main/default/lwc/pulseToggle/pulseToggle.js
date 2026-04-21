import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseToggle extends LightningElement {
    @api label;
    @api helpText;
    @api checked = false;
    @api disabled = false;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get trackClass() {
        let cls = 'pulse-toggle-track';
        if (this.checked) cls += ' pulse-toggle-track-on';
        if (this.disabled) cls += ' pulse-toggle-track-disabled';
        return cls;
    }

    get thumbClass() {
        return this.checked
            ? 'pulse-toggle-thumb pulse-toggle-thumb-on'
            : 'pulse-toggle-thumb';
    }

    get hasHelpText() {
        return !!this.helpText;
    }

    get ariaChecked() {
        return String(!!this.checked);
    }

    get toggleId() {
        return 'pulse-toggle-' + (this.label || '').replace(/\s+/g, '-').toLowerCase();
    }

    handleClick() {
        if (this.disabled) return;
        this.dispatchEvent(
            new CustomEvent('change', { detail: { checked: !this.checked } })
        );
    }

    handleKeyDown(event) {
        if (this.disabled) return;
        if (event.key === ' ' || event.key === 'Enter') {
            event.preventDefault();
            this.handleClick();
        }
    }
}

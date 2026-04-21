import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const VARIANT_CLASSES = {
    purple: 'pulse-badge pulse-badge-purple',
    magenta: 'pulse-badge pulse-badge-magenta',
    success: 'pulse-badge pulse-badge-success',
    warning: 'pulse-badge pulse-badge-warning',
    error: 'pulse-badge pulse-badge-error',
    gray: 'pulse-badge pulse-badge-gray',
};

export default class PulseBadge extends LightningElement {
    @api label;
    @api variant = 'gray';

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get badgeClass() {
        return VARIANT_CLASSES[this.variant] || VARIANT_CLASSES.gray;
    }
}

import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const VARIANT_CLASSES = {
    primary: 'pulse-btn pulse-btn-primary',
    secondary: 'pulse-btn pulse-btn-secondary',
    dark: 'pulse-btn pulse-btn-dark',
    ghost: 'pulse-btn pulse-btn-ghost',
};

const SIZE_CLASSES = {
    sm: 'pulse-btn-sm',
    md: '',
    lg: 'pulse-btn-lg',
};

export default class PulseButton extends LightningElement {
    @api label;
    @api variant = 'primary';
    @api size = 'md';
    @api disabled = false;
    @api iconName;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get buttonClass() {
        const base = VARIANT_CLASSES[this.variant] || VARIANT_CLASSES.primary;
        const sz = SIZE_CLASSES[this.size] || '';
        return [base, sz].filter(Boolean).join(' ');
    }

    handleClick(event) {
        if (this.disabled) {
            event.stopPropagation();
            event.preventDefault();
        }
    }
}

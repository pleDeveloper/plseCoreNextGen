import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const SIZE_CLASSES = {
    sm: 'pulse-modal-dialog pulse-modal-sm',
    md: 'pulse-modal-dialog pulse-modal-md',
    lg: 'pulse-modal-dialog pulse-modal-lg',
    xl: 'pulse-modal-dialog pulse-modal-xl',
};

const FOCUSABLE = [
    'a[href]', 'button:not([disabled])', 'input:not([disabled])',
    'textarea:not([disabled])', 'select:not([disabled])', '[tabindex]:not([tabindex="-1"])',
].join(', ');

export default class PulseModal extends LightningElement {
    @api open = false;
    @api size = 'md';
    @api title;
    @api dismissible = false;

    _boundKeyHandler;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._boundKeyHandler = this.handleKeyDown.bind(this);
    }

    renderedCallback() {
        if (this.open) {
            document.addEventListener('keydown', this._boundKeyHandler);
            this._trapFocus();
        } else {
            document.removeEventListener('keydown', this._boundKeyHandler);
        }
    }

    disconnectedCallback() {
        document.removeEventListener('keydown', this._boundKeyHandler);
    }

    get dialogClass() {
        return SIZE_CLASSES[this.size] || SIZE_CLASSES.md;
    }

    get hasTitle() {
        return !!this.title;
    }

    get showCloseOnly() {
        return !this.title && this.dismissible;
    }

    handleBackdropClick() {
        if (this.dismissible) {
            this._close();
        }
    }

    handleDialogClick(event) {
        event.stopPropagation();
    }

    handleCloseClick() {
        this._close();
    }

    handleKeyDown(event) {
        if (event.key === 'Escape' && this.dismissible) {
            event.preventDefault();
            this._close();
            return;
        }
        if (event.key === 'Tab') {
            this._handleTabTrap(event);
        }
    }

    _close() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    _trapFocus() {
        // Focus the first focusable element inside the modal on open
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const dialog = this.template.querySelector('.pulse-modal-dialog');
            if (!dialog) return;
            const first = dialog.querySelector(FOCUSABLE) || dialog.querySelector('.pulse-modal-close');
            if (first) first.focus();
        });
    }

    _handleTabTrap(event) {
        const dialog = this.template.querySelector('.pulse-modal-dialog');
        if (!dialog) return;
        const focusable = dialog.querySelectorAll(FOCUSABLE);
        if (!focusable.length) return;

        const first = focusable[0];
        const last = focusable[focusable.length - 1];
        const active = this.template.activeElement || document.activeElement;

        if (event.shiftKey && active === first) {
            event.preventDefault();
            last.focus();
        } else if (!event.shiftKey && active === last) {
            event.preventDefault();
            first.focus();
        }
    }
}

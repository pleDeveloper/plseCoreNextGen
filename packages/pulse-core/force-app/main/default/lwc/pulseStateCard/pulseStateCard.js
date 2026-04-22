import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const TYPE_BADGE = {
    form:     { label: 'Form',     variant: 'purple' },
    approval: { label: 'Approval', variant: 'magenta' },
    auto:     { label: 'Auto',     variant: 'success' },
    terminal: { label: 'Terminal', variant: 'gray' }
};

export default class PulseStateCard extends LightningElement {
    @api stateKey;
    @api label;
    @api stateType = 'form';
    @api fieldCount = 0;
    @api transitionCount = 0;
    @api selected = false;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get cardClass() {
        return this.selected
            ? 'state-card state-card-selected'
            : 'state-card';
    }

    get typeBadgeLabel() {
        return (TYPE_BADGE[this.stateType] || TYPE_BADGE.form).label;
    }

    get typeBadgeVariant() {
        return (TYPE_BADGE[this.stateType] || TYPE_BADGE.form).variant;
    }

    get fieldCountLabel() {
        const n = this.fieldCount || 0;
        return n === 1 ? '1 field' : `${n} fields`;
    }

    get transitionCountLabel() {
        const n = this.transitionCount || 0;
        return n === 1 ? '1 transition' : `${n} transitions`;
    }

    get showActions() {
        return this.selected;
    }

    handleClick() {
        this.dispatchEvent(
            new CustomEvent('selectstate', {
                detail: { stateKey: this.stateKey },
                bubbles: true,
                composed: true
            })
        );
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleClick();
        }
    }

    handleDelete(event) {
        event.stopPropagation();
        this.dispatchEvent(
            new CustomEvent('deletestate', {
                detail: { stateKey: this.stateKey },
                bubbles: true,
                composed: true
            })
        );
    }

    handleDragStart(event) {
        event.dataTransfer.setData('text/plain', this.stateKey);
        event.dataTransfer.effectAllowed = 'move';
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
    }

    handleDrop(event) {
        event.preventDefault();
        const fromKey = event.dataTransfer.getData('text/plain');
        if (fromKey && fromKey !== this.stateKey) {
            this.dispatchEvent(
                new CustomEvent('reorderstate', {
                    detail: { fromKey, toKey: this.stateKey },
                    bubbles: true,
                    composed: true
                })
            );
        }
    }
}

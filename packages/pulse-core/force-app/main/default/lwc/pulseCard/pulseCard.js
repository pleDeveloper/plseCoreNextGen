import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseCard extends LightningElement {
    @api heading;
    @api iconHtml;
    @api elevated = false;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get cardClass() {
        return this.elevated
            ? 'pulse-card pulse-card-elevated'
            : 'pulse-card';
    }

    get hasHeading() {
        return !!this.heading;
    }

    get hasIcon() {
        return !!this.iconHtml;
    }

    renderedCallback() {
        if (this.iconHtml) {
            const iconEl = this.template.querySelector('.pulse-card-icon');
            if (iconEl && !iconEl.hasChildNodes()) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html
                iconEl.innerHTML = this.iconHtml;
            }
        }
    }
}

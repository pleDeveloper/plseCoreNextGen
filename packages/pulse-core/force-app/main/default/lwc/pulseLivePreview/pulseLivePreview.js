import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseLivePreview extends LightningElement {
    @api states = [];

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get allFields() {
        const fields = [];
        (this.states || []).forEach((s) => {
            (s.fields || []).forEach((f) => {
                fields.push({
                    ...f,
                    stateKey: s.key,
                    stateLabel: s.label,
                    compositeKey: `${s.key}__${f.key}`
                });
            });
        });
        return fields;
    }

    get projectedFields() {
        return this.allFields.filter(
            (f) => f.projection && f.projection.enabled
        );
    }

    get stepFields() {
        return this.allFields.filter(
            (f) => !f.projection || !f.projection.enabled
        );
    }

    get hasProjectedFields() {
        return this.projectedFields.length > 0;
    }

    get noProjectedFields() {
        return !this.hasProjectedFields;
    }

    get hasStepFields() {
        return this.stepFields.length > 0;
    }

    get noStepFields() {
        return !this.hasStepFields;
    }
}

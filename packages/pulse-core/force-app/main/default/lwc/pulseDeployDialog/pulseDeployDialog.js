import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseDeployDialog extends LightningElement {
    @api open = false;
    @api targetObject = '';
    @api fieldsToCreate = [];
    @api projections = [];
    @api deploymentStatus;
    @api deploymentMessage;

    _step = 'review'; // review | deploying | result

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    @api
    reset() {
        this._step = 'review';
    }

    @api
    setDeploying() {
        this._step = 'deploying';
    }

    @api
    setResult(status, message) {
        this.deploymentStatus = status;
        this.deploymentMessage = message;
        this._step = 'result';
    }

    get isReviewStep() {
        return this._step === 'review';
    }

    get isDeployingStep() {
        return this._step === 'deploying';
    }

    get isResultStep() {
        return this._step === 'result';
    }

    get hasFieldsToCreate() {
        return this.fieldsToCreate && this.fieldsToCreate.length > 0;
    }

    get hasProjections() {
        return this.projections && this.projections.length > 0;
    }

    get nothingToDeploy() {
        return !this.hasFieldsToCreate && !this.hasProjections;
    }

    get isSuccess() {
        return (
            this.deploymentStatus === 'Completed' ||
            this.deploymentStatus === 'Queued'
        );
    }

    get isFailure() {
        return (
            this.deploymentStatus === 'Failed' ||
            this.deploymentStatus === 'Cancelled'
        );
    }

    get statusBadgeVariant() {
        const map = {
            Queued: 'purple',
            In_Progress: 'warning',
            Completed: 'success',
            Failed: 'error',
            Cancelled: 'gray'
        };
        return map[this.deploymentStatus] || 'gray';
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handlePublish() {
        this.dispatchEvent(new CustomEvent('publish'));
    }
}

import { LightningElement, wire, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import { refreshApex } from '@salesforce/apex';
import listInstalledBundles from '@salesforce/apex/PulseLibraryInstaller.listInstalledBundles';
import installBundle from '@salesforce/apex/PulseLibraryInstaller.installBundle';
import rollback from '@salesforce/apex/PulseLibraryInstaller.rollback';

const STATUS_VARIANT = {
    Installed: 'success',
    Superseded: 'gray',
    Rolled_Back: 'warning',
};

export default class PulseLibraryBrowser extends LightningElement {
    @track bundles = [];
    @track error;
    @track showInstallModal = false;
    @track showRollbackModal = false;
    @track installBundleJson = '';
    @track installSignature = '';
    @track installError;
    @track rollbackTargetId;
    @track rollbackTargetName = '';
    @track rollbackError;

    _wiredResult;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    @wire(listInstalledBundles)
    wiredBundles(result) {
        this._wiredResult = result;
        if (result.data) {
            this.bundles = result.data.map((b) => ({
                ...b,
                statusVariant: STATUS_VARIANT[b.status] || 'gray',
                canRollBack: b.status === 'Installed' && !!b.previousBundleId,
                formattedDate: b.installedDate
                    ? new Date(b.installedDate).toLocaleDateString()
                    : '',
            }));
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'Failed to load bundles';
            this.bundles = [];
        }
    }

    get hasBundles() {
        return this.bundles.length > 0;
    }

    get bundleCount() {
        return this.bundles.length;
    }

    get showEmpty() {
        return this.bundles.length === 0 && !this.error;
    }

    // ── Install flow ─────────────────────────────────────────────

    handleOpenInstall() {
        this.installBundleJson = '';
        this.installSignature = '';
        this.installError = undefined;
        this.showInstallModal = true;
    }

    handleCloseInstall() {
        this.showInstallModal = false;
    }

    handleBundleJsonChange(event) {
        this.installBundleJson = event.detail.value;
    }

    handleSignatureChange(event) {
        this.installSignature = event.detail.value;
    }

    async handleInstall() {
        this.installError = undefined;
        try {
            const result = await installBundle({
                bundleJson: this.installBundleJson,
                signatureB64: this.installSignature,
            });
            if (result.success) {
                this.showInstallModal = false;
                return refreshApex(this._wiredResult);
            }
            this.installError = result.message
                + (result.validationErrors?.length
                    ? ': ' + result.validationErrors.join(', ')
                    : '');
        } catch (e) {
            this.installError = e.body?.message || 'Install failed';
        }
    }

    // ── Rollback flow ────────────────────────────────────────────

    handleRollbackClick(event) {
        this.rollbackTargetId = event.currentTarget.dataset.id;
        this.rollbackTargetName =
            event.currentTarget.dataset.name || 'this bundle';
        this.rollbackError = undefined;
        this.showRollbackModal = true;
    }

    handleCloseRollback() {
        this.showRollbackModal = false;
    }

    async handleConfirmRollback() {
        this.rollbackError = undefined;
        try {
            const result = await rollback({
                bundleRecordId: this.rollbackTargetId,
            });
            if (result.success) {
                this.showRollbackModal = false;
                return refreshApex(this._wiredResult);
            }
            this.rollbackError = result.message
                + (result.validationErrors?.length
                    ? ': ' + result.validationErrors.join(', ')
                    : '');
        } catch (e) {
            this.rollbackError = e.body?.message || 'Rollback failed';
        }
    }
}

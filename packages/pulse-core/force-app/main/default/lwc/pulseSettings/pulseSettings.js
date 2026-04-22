import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getSettings from '@salesforce/apex/PulseAdminConfigController.getSettings';

const STATUS_VARIANT = {
    Completed: 'success',
    In_Progress: 'warning',
    Queued: 'warning',
    Draft: 'warning',
    Failed: 'error',
    Cancelled: 'error',
};

export default class PulseSettings extends LightningElement {
    @track config = null;
    @track error = null;
    @track isLoading = true;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        try {
            this.config = await getSettings();
            this.error = null;
        } catch (err) {
            this.error = err.body?.message || 'Failed to load settings';
            this.config = null;
        } finally {
            this.isLoading = false;
        }
    }

    get hasError() {
        return this.error != null;
    }

    get hasFeatureFlags() {
        return this.config?.featureFlags?.length > 0;
    }

    get hasPermissionSets() {
        return this.config?.pulsePermissionSets?.length > 0;
    }

    get hasDeployments() {
        return this.config?.recentDeployments?.length > 0;
    }

    get flagRows() {
        return (this.config?.featureFlags || []).map((ff) => ({
            ...ff,
            enabledLabel: ff.enabled ? 'Enabled' : 'Disabled',
            enabledVariant: ff.enabled ? 'purple' : 'gray',
        }));
    }

    get psRows() {
        return (this.config?.pulsePermissionSets || []).map((ps) => ({
            ...ps,
            assignedLabel: ps.assignedToCurrentUser ? 'Assigned to you' : null,
        }));
    }

    get deploymentRows() {
        return (this.config?.recentDeployments || []).map((d) => ({
            ...d,
            statusVariant: STATUS_VARIANT[d.status] || 'gray',
            completedLabel: d.completedDate
                ? new Date(d.completedDate).toLocaleString()
                : '',
            hasError: !!d.errorMessage,
        }));
    }
}

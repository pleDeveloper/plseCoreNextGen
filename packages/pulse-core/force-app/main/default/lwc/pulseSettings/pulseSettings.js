import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getSettings from '@salesforce/apex/PulseAdminConfigController.getSettings';
import runChecks from '@salesforce/apex/PulseSetupCheckController.runChecks';

const STATUS_VARIANT = {
    Completed: 'success',
    In_Progress: 'warning',
    Queued: 'warning',
    Draft: 'warning',
    Failed: 'error',
    Cancelled: 'error',
};

const CHECK_STATUS_VARIANT = {
    ok: 'success',
    warning: 'warning',
    error: 'error',
    info: 'gray',
};

const CHECK_STATUS_LABEL = {
    ok: 'OK',
    warning: 'Warning',
    error: 'Action needed',
    info: 'Info',
};

export default class PulseSettings extends LightningElement {
    @track config = null;
    @track error = null;
    @track isLoading = true;
    @track setupChecks = [];
    @track expandedCheck = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        try {
            const [config, checks] = await Promise.all([
                getSettings(),
                runChecks().catch(() => []),
            ]);
            this.config = config;
            this.setupChecks = checks || [];
            this.error = null;
        } catch (err) {
            this.error = err.body?.message || 'Failed to load settings';
            this.config = null;
        } finally {
            this.isLoading = false;
        }
    }

    get setupCheckRows() {
        return (this.setupChecks || []).map((c) => ({
            ...c,
            statusLabel: CHECK_STATUS_LABEL[c.status] || c.status,
            statusVariant: CHECK_STATUS_VARIANT[c.status] || 'gray',
            isExpanded: this.expandedCheck === c.key,
            canExpand: !!c.fixInstructions,
            hasSetupLink: !!c.setupPath,
            rowClass: 'setup-check-row setup-check-' + (c.status || 'info'),
        }));
    }

    get setupSummary() {
        const counts = { ok: 0, warning: 0, error: 0, info: 0 };
        (this.setupChecks || []).forEach((c) => {
            counts[c.status] = (counts[c.status] || 0) + 1;
        });
        if (counts.error > 0) {
            return `${counts.error} action${counts.error === 1 ? '' : 's'} needed`;
        }
        if (counts.warning > 0) {
            return `${counts.warning} warning${counts.warning === 1 ? '' : 's'}`;
        }
        return 'All systems ready';
    }

    get setupSummaryVariant() {
        const hasError = (this.setupChecks || []).some((c) => c.status === 'error');
        if (hasError) return 'error';
        const hasWarning = (this.setupChecks || []).some((c) => c.status === 'warning');
        if (hasWarning) return 'warning';
        return 'success';
    }

    handleToggleCheck(event) {
        const key = event.currentTarget.dataset.key;
        this.expandedCheck = this.expandedCheck === key ? null : key;
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

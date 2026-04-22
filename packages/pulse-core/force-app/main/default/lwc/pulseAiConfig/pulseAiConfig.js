import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getAiConfig from '@salesforce/apex/PulseAdminConfigController.getAiConfig';

const HITL_VARIANT = {
    Approval_Required: 'warning',
    Review_After: 'purple',
    Autonomous: 'success',
};

export default class PulseAiConfig extends LightningElement {
    @track config = null;
    @track error = null;
    @track isLoading = true;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        try {
            this.config = await getAiConfig();
            this.error = null;
        } catch (err) {
            this.error = err.body?.message || 'Failed to load AI configuration';
            this.config = null;
        } finally {
            this.isLoading = false;
        }
    }

    get hasError() {
        return this.error != null;
    }

    get hasProviders() {
        return this.config?.providers?.length > 0;
    }

    get hasTools() {
        return this.config?.tools?.length > 0;
    }

    get hasProfiles() {
        return this.config?.extractionProfiles?.length > 0;
    }

    get providerRows() {
        return (this.config?.providers || []).map((p) => ({
            ...p,
            priorityLabel: p.priority != null ? `Priority ${p.priority}` : 'No priority',
            activeLabel: p.active ? 'Active' : 'Inactive',
            activeVariant: p.active ? 'success' : 'gray',
        }));
    }

    get toolRows() {
        return (this.config?.tools || []).map((t) => ({
            ...t,
            policyVariant: HITL_VARIANT[t.defaultHitlPolicy] || 'gray',
            policyLabel: t.defaultHitlPolicy || 'None',
            activeLabel: t.active ? 'Active' : 'Inactive',
            activeVariant: t.active ? 'success' : 'gray',
        }));
    }

    get profileRows() {
        return (this.config?.extractionProfiles || []).map((e) => ({
            ...e,
            schemaSizeLabel: `schema size: ${e.schemaSize} chars`,
        }));
    }
}

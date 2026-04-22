import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getIntegrationsHub from '@salesforce/apex/PulseAdminConfigController.getIntegrationsHub';

export default class PulseIntegrationsHub extends LightningElement {
    @track config = null;
    @track error = null;
    @track isLoading = true;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._loadData();
    }

    async _loadData() {
        try {
            this.config = await getIntegrationsHub();
            this.error = null;
        } catch (err) {
            this.error = err.body?.message || 'Failed to load integrations';
            this.config = null;
        } finally {
            this.isLoading = false;
        }
    }

    get hasError() {
        return this.error != null;
    }

    get hasNamedCredentials() {
        return this.config?.namedCredentials?.length > 0;
    }

    get hasChannelAdapters() {
        return this.config?.channelAdapters?.length > 0;
    }

    get hasConversationSources() {
        return this.config?.conversationSources?.length > 0;
    }

    get ncRows() {
        return (this.config?.namedCredentials || []).map((nc) => ({
            ...nc,
            endpointTruncated:
                nc.endpoint && nc.endpoint.length > 40
                    ? nc.endpoint.substring(0, 40) + '\u2026'
                    : nc.endpoint || '',
        }));
    }

    get adapterRows() {
        return (this.config?.channelAdapters || []).map((ca) => ({
            ...ca,
            activeLabel: ca.active ? 'Active' : 'Inactive',
            activeVariant: ca.active ? 'success' : 'gray',
        }));
    }

    get sourceRows() {
        return (this.config?.conversationSources || []).map((cs) => ({
            ...cs,
            activeLabel: cs.active ? 'Active' : 'Inactive',
            activeVariant: cs.active ? 'success' : 'gray',
        }));
    }
}

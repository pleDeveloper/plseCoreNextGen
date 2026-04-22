import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getAgentState from '@salesforce/apex/PulseAgentController.getAgentState';
import setAutonomy from '@salesforce/apex/PulseAgentController.setAutonomy';
import kickAgent from '@salesforce/apex/PulseAgentController.kickAgent';

const AUTONOMY_LABELS = {
    Propose_Only: 'Propose only',
    Act_With_Approval: 'Act with approval',
    Autonomous_Safe: 'Autonomous (safe tools)',
};

const STATUS_LABELS = {
    Idle: 'Idle',
    Working: 'Working…',
    Waiting_For_User: 'Waiting on you',
    Paused: 'Paused',
    Error: 'Error',
};

export default class PulseAgentStatusRail extends LightningElement {
    @api instanceId;

    @track state = null;
    @track error = null;
    @track loading = true;
    @track dropdownOpen = false;
    @track kickInFlight = false;

    _pollHandle;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._load();
        this._pollHandle = setInterval(() => {
            if (this.instanceId) this._load(true);
        }, 5000);
    }

    disconnectedCallback() {
        if (this._pollHandle) clearInterval(this._pollHandle);
    }

    async _load(quiet) {
        if (!this.instanceId) { this.loading = false; return; }
        if (!quiet) this.loading = true;
        try {
            const s = await getAgentState({ instanceId: this.instanceId });
            this.state = s;
            this.error = null;
        } catch (e) {
            this.error = e.body?.message || e.message || 'Agent state load failed';
        } finally {
            this.loading = false;
        }
    }

    get hasAgent() { return !!this.state && this.state.enabled; }
    get personaInitial() {
        const p = this.state?.persona || 'Claude';
        return p.charAt(0).toUpperCase();
    }
    get statusLabel() {
        return STATUS_LABELS[this.state?.status] || this.state?.status || 'Idle';
    }
    get autonomyLabel() {
        return AUTONOMY_LABELS[this.state?.autonomy] || this.state?.autonomy || 'Act with approval';
    }
    get statusVariant() {
        const s = this.state?.status;
        if (s === 'Working') return 'purple';
        if (s === 'Waiting_For_User') return 'magenta';
        if (s === 'Error') return 'error';
        if (s === 'Paused') return 'gray';
        return 'gray';
    }
    get pulseClass() {
        return this.state?.status === 'Working'
            ? 'agent-avatar agent-avatar-working'
            : 'agent-avatar';
    }
    get autonomyOptions() {
        const opts = this.state?.autonomyOptions || [];
        return opts.map((o) => ({
            key: o,
            label: AUTONOMY_LABELS[o] || o,
            selected: o === this.state?.autonomy,
        }));
    }

    toggleDropdown() {
        this.dropdownOpen = !this.dropdownOpen;
    }

    async handleAutonomyChange(event) {
        const val = event.currentTarget?.dataset?.value;
        this.dropdownOpen = false;
        if (!val) return;
        try {
            const s = await setAutonomy({ instanceId: this.instanceId, autonomy: val });
            this.state = s;
        } catch (e) {
            this.error = e.body?.message || 'Failed to change autonomy';
        }
    }

    async handleKick() {
        if (this.kickInFlight) return;
        this.kickInFlight = true;
        try {
            await kickAgent({ instanceId: this.instanceId });
            await this._load(true);
            this.dispatchEvent(new CustomEvent('agentkicked', { bubbles: true, composed: true }));
        } catch (e) {
            this.error = e.body?.message || 'Kick failed';
        } finally {
            this.kickInFlight = false;
        }
    }
}

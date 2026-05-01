import { LightningElement, api, track } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
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

const PUSH_CHANNEL = '/event/Pulse_Workflow_Update__e';

export default class PulseAgentStatusRail extends LightningElement {
    @api instanceId;

    @track state = null;
    @track error = null;
    @track loading = true;
    @track dropdownOpen = false;
    @track kickInFlight = false;

    _empSubscription = null;
    _stopped = false;
    _lastSnapshot = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        // Honor the cross-component terminal kill-switch (proposal §2.3).
        // If a sibling has already detected terminal for this workflow,
        // never even start: no fetch, no subscription.
        let isTerminal = false;
        try {
            if (this.instanceId) {
                isTerminal = sessionStorage.getItem(`pulseTerminal:${this.instanceId}`) === '1';
            }
        } catch (e) { /* storage disabled */ }
        if (isTerminal) {
            this._stopped = true;
            this.loading = false;
            return;
        }
        this._load().then(() => {
            if (this._stopped) return;
            this._subscribePush();
        });
    }

    disconnectedCallback() {
        this._unsubscribePush();
    }

    /**
     * Cooperative shutdown — parent stepper calls this when it detects
     * terminal state. See proposal §4.3.
     */
    @api
    stopUpdates() {
        this._stopped = true;
        this._unsubscribePush();
    }

    _subscribePush() {
        if (this._empSubscription || this._stopped) return;
        subscribe(PUSH_CHANNEL, -1, (msg) => {
            if (this._stopped) return;
            const eventId = msg && msg.data && msg.data.payload
                ? msg.data.payload.Instance_Id__c
                : null;
            if (!eventId || !this.instanceId) return;
            // Compare 15-char prefixes — payload is 18-char, prop may be 15.
            if (String(eventId).substring(0, 15) !== String(this.instanceId).substring(0, 15)) {
                return;
            }
            this._load(true);
        }).then((s) => {
            if (this._stopped) {
                try { unsubscribe(s, () => {}); } catch (e) { /* ignore */ }
                return;
            }
            this._empSubscription = s;
        }).catch(() => {
            // empApi unavailable / channel missing — fall back to user-action refresh.
        });
        try { onError(() => {}); } catch (e) { /* ignore */ }
    }

    _unsubscribePush() {
        if (!this._empSubscription) return;
        try { unsubscribe(this._empSubscription, () => {}); } catch (e) { /* ignore */ }
        this._empSubscription = null;
    }

    async _load(quiet) {
        if (!this.instanceId) { this.loading = false; return; }
        if (this._stopped) return;
        if (!quiet) this.loading = true;
        try {
            const s = await getAgentState({ instanceId: this.instanceId });
            // Never null out previously-good state on a quiet refresh (§2.4).
            if (quiet && !s) return;
            const sig = this._buildRenderSig(s);
            if (quiet && sig === this._lastSnapshot) return;
            this._lastSnapshot = sig;
            this.state = s || this.state;
            this.error = null;
        } catch (e) {
            if (!quiet) {
                this.error = e.body?.message || e.message || 'Agent state load failed';
            }
            // On quiet error: keep previous state.
        } finally {
            this.loading = false;
        }
    }

    /**
     * Render signature includes only fields the template binds to.
     * Excludes timestamps so a quiet refresh that only changes server-side
     * `LastModifiedDate` does not trigger a re-render.
     */
    _buildRenderSig(s) {
        if (!s) return '';
        const opts = (s.autonomyOptions || []).join(',');
        return [
            s.enabled === true ? '1' : '0',
            s.persona || '',
            s.status || '',
            s.autonomy || '',
            opts,
        ].join('||');
    }

    get hasAgent() { return !!this.state && this.state.enabled; }
    get personaName() { return this.state?.persona || 'Claude'; }
    get personaInitial() {
        return this.personaName.charAt(0).toUpperCase();
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
            this.state = s || this.state;
            this._lastSnapshot = this._buildRenderSig(this.state);
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
            // Generic event so a parent can react if it wants — the
            // upstream contract for parent→child coordination is `@api`
            // hooks (see proposal §4.3), not custom event cascades.
            this.dispatchEvent(new CustomEvent('agentkicked', { bubbles: true, composed: true }));
        } catch (e) {
            this.error = e.body?.message || 'Kick failed';
        } finally {
            this.kickInFlight = false;
        }
    }
}

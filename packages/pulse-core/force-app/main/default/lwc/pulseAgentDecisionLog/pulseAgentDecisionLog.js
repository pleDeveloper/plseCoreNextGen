import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getDecisionLog from '@salesforce/apex/PulseAgentController.getDecisionLog';

// Compact icon per decision type. ASCII-safe so the log renders in
// restrictive font stacks (e.g. Salesforce managed-package runtime).
const TYPE_ICON = {
    Propose_Action: '>',
    Ask_User: '?',
    Advance_Phase: '>>',
    Observe: '-',
    Error: '!',
};

const STATUS_ICON = {
    Approved: 'OK',
    Rejected: 'X',
    Refined: 'Edit',
    Auto_Executed: 'Auto',
    Answered: 'A',
    Skipped: '-',
    Expired: 'Exp',
};

export default class PulseAgentDecisionLog extends LightningElement {
    @api instanceId;

    @track rows = [];
    @track loading = true;
    @track error = null;
    @track collapsed = true;
    @track expandedId = null;

    _pollHandle;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._load();
        // Gentle refresh — decisions grow when the queue resolves them.
        this._pollHandle = setInterval(() => {
            if (this.instanceId && !this.collapsed) this._load(true);
        }, 6000);
    }

    disconnectedCallback() {
        if (this._pollHandle) clearInterval(this._pollHandle);
    }

    @api
    async refresh() {
        await this._load(true);
    }

    async _load(quiet) {
        if (!this.instanceId) { this.loading = false; return; }
        if (!quiet) this.loading = true;
        try {
            const list = await getDecisionLog({ instanceId: this.instanceId });
            this.rows = (list || []).map((d) => this._decorate(d));
            this.error = null;
        } catch (e) {
            this.error = e.body?.message || e.message || 'Failed to load decision log';
        } finally {
            this.loading = false;
        }
    }

    _decorate(d) {
        const shortSummary = this._shortSummary(d);
        const userResponse = this._userResponseSummary(d);
        const typeIcon = TYPE_ICON[d.decisionType] || '-';
        const statusIcon = STATUS_ICON[d.status] || d.status;
        const timeLabel = this._formatTime(d.createdDate);
        return {
            decisionId: d.decisionId,
            decisionType: d.decisionType,
            typeLabel: this._typeLabel(d.decisionType),
            status: d.status,
            statusLabel: this._statusLabel(d.status),
            statusVariant: this._statusVariant(d.status),
            typeIcon,
            statusIcon,
            timeLabel,
            shortSummary,
            userResponse,
            hasUserResponse: !!userResponse,
            rationale: d.rationale || '(no rationale)',
            proposalJson: d.proposalJson,
            questionJson: d.questionJson,
            userResponseJson: d.userResponseJson,
            prettyProposal: this._pretty(d.proposalJson),
            prettyQuestion: this._pretty(d.questionJson),
            prettyResponse: this._pretty(d.userResponseJson),
            hasProposal: !!d.proposalJson,
            hasQuestion: !!d.questionJson,
            hasResponseJson: !!d.userResponseJson,
            createdDate: d.createdDate,
            resolvedDate: d.resolvedDate,
            rowClass: this._rowClass(d.status),
        };
    }

    _rowClass(status) {
        const base = 'log-row';
        if (status === 'Rejected' || status === 'Expired') return base + ' log-row-muted';
        if (status === 'Auto_Executed') return base + ' log-row-auto';
        if (status === 'Refined') return base + ' log-row-refined';
        return base;
    }

    _shortSummary(d) {
        const r = (d.rationale || '').replace(/\s+/g, ' ').trim();
        const max = 90;
        if (r.length <= max) return r || '(no rationale)';
        return r.substring(0, max - 1) + '…';
    }

    _userResponseSummary(d) {
        if (!d.userResponseJson) return null;
        try {
            const o = JSON.parse(d.userResponseJson);
            if (o == null) return null;
            if (typeof o === 'string') return o;
            if (o.value != null) return String(o.value);
            if (o.reason) return 'reason: ' + o.reason;
            if (o.action) return o.action;
            return JSON.stringify(o);
        } catch (_e) {
            return d.userResponseJson;
        }
    }

    _pretty(jsonStr) {
        if (!jsonStr) return '';
        try {
            return JSON.stringify(JSON.parse(jsonStr), null, 2);
        } catch (_e) {
            return jsonStr;
        }
    }

    _typeLabel(t) {
        return {
            Propose_Action: 'Proposal',
            Ask_User: 'Question',
            Advance_Phase: 'Advance',
            Observe: 'Note',
            Error: 'Error',
        }[t] || t;
    }

    _statusLabel(s) {
        return {
            Approved: 'Approved',
            Rejected: 'Rejected',
            Refined: 'Refined',
            Auto_Executed: 'Auto',
            Answered: 'Answered',
            Skipped: 'Skipped',
            Expired: 'Expired',
        }[s] || s;
    }

    _statusVariant(s) {
        if (s === 'Approved' || s === 'Auto_Executed' || s === 'Answered' || s === 'Refined') return 'purple';
        if (s === 'Rejected' || s === 'Expired') return 'gray';
        return 'gray';
    }

    _formatTime(iso) {
        if (!iso) return '';
        try {
            const d = new Date(iso);
            const h = String(d.getHours()).padStart(2, '0');
            const m = String(d.getMinutes()).padStart(2, '0');
            const day = d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
            return `${day} ${h}:${m}`;
        } catch (_e) {
            return iso;
        }
    }

    // ─── Getters ────────────────────────────────────────────────

    get hasRows() { return this.rows.length > 0; }
    get isCollapsed() { return this.collapsed; }
    get chevronGlyph() { return this.collapsed ? 'triangle-right' : 'triangle-down'; }
    get chevronChar() { return this.collapsed ? '▸' : '▾'; }
    get countLabel() {
        const n = this.rows.length;
        return n === 0 ? 'No past decisions'
             : (n === 1 ? '1 past decision'
                        : `${n} past decisions`);
    }

    // ─── Handlers ───────────────────────────────────────────────

    handleToggleCollapsed() {
        this.collapsed = !this.collapsed;
        if (!this.collapsed) {
            // Load fresh when opening.
            this._load(true);
        } else {
            this.expandedId = null;
        }
    }

    handleRowClick(event) {
        const id = event.currentTarget?.dataset?.id;
        if (!id) return;
        this.expandedId = (this.expandedId === id) ? null : id;
    }

    handleDismissError() { this.error = null; }

    // Expose decorated rows with expansion flag for the template.
    get decoratedRows() {
        return this.rows.map((r) => ({
            ...r,
            expanded: this.expandedId === r.decisionId,
            bodyClass: this.expandedId === r.decisionId
                ? 'log-row-body log-row-body-open'
                : 'log-row-body',
        }));
    }
}

import { LightningElement, api, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import aggregateDwellStats from '@salesforce/apex/StageDwellPredictor.aggregateDwellStats';

export default class PulseSlaHeatmap extends LightningElement {
    @api workflowKey = null;
    @api lookbackDays = 90;

    @track _workflowKeyFilter = '';
    @track _lookbackDaysFilter = 90;
    @track _stats = [];
    @track _isLoading = true;
    @track _error = null;

    connectedCallback() {
        loadPulseBrandTokens(this);
        this._workflowKeyFilter = this.workflowKey || '';
        this._lookbackDaysFilter = this.lookbackDays || 90;
        this._loadStats();
    }

    // ── Data loading ────────────────────────────────────────────────

    async _loadStats() {
        this._isLoading = true;
        this._error = null;
        try {
            this._stats = await aggregateDwellStats({
                workflowKey: this.effectiveWorkflowKey,
                lookbackDays: this.effectiveLookbackDays,
            }) || [];
        } catch (err) {
            this._stats = [];
            this._error = err.body?.message || 'Failed to load dwell stats';
        } finally {
            this._isLoading = false;
        }
    }

    // ── Computed ────────────────────────────────────────────────────

    get effectiveWorkflowKey() {
        return this._workflowKeyFilter || this.workflowKey || null;
    }

    get effectiveLookbackDays() {
        return this._lookbackDaysFilter || this.lookbackDays || 90;
    }

    get isLoading() {
        return this._isLoading;
    }

    get hasError() {
        return this._error != null;
    }

    get errorMessage() {
        return this._error || '';
    }

    get isEmpty() {
        return !this._isLoading && !this._error && this.rows.length === 0;
    }

    get hasData() {
        return !this._isLoading && !this._error && this.rows.length > 0;
    }

    get rows() {
        if (!this._stats || this._stats.length === 0) return [];
        const stats = [...this._stats];
        // Sort by p90 descending
        stats.sort((a, b) => (b.p90Seconds || 0) - (a.p90Seconds || 0));

        const maxP90 = stats.length > 0 ? stats[0].p90Seconds || 1 : 1;

        return stats.map((s) => ({
            ...s,
            id: `${s.workflowKey}-${s.subjectKind}-${s.stateKey}`,
            colorClass: this._colorBucket(s.p90Seconds, maxP90),
            medianFormatted: this._formatDuration(s.medianSeconds),
            p90Formatted: this._formatDuration(s.p90Seconds),
        }));
    }

    // ── Handlers ────────────────────────────────────────────────────

    handleWorkflowKeyChange(event) {
        this._workflowKeyFilter = event.detail.value;
        this._loadStats();
    }

    handleLookbackChange(event) {
        const val = parseInt(event.detail.value, 10);
        if (!isNaN(val) && val > 0) {
            this._lookbackDaysFilter = val;
            this._loadStats();
        }
    }

    handleRowClick(event) {
        const stateKey = event.currentTarget.dataset.stateKey;
        if (stateKey) {
            this.dispatchEvent(
                new CustomEvent('select', { detail: { stateKey }, bubbles: true, composed: true })
            );
        }
    }

    // ── Private ─────────────────────────────────────────────────────

    _colorBucket(p90, maxP90) {
        if (!maxP90 || maxP90 === 0) return 'heatmap-cell-success';
        const ratio = p90 / maxP90;
        if (ratio <= 0.25) return 'heatmap-cell-success';
        if (ratio <= 0.5) return 'heatmap-cell-info';
        if (ratio <= 0.75) return 'heatmap-cell-warning';
        return 'heatmap-cell-error';
    }

    _formatDuration(seconds) {
        if (seconds == null) return '\u2014';
        if (seconds < 60) return `${seconds}s`;
        if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
        if (seconds < 86400) return `${(seconds / 3600).toFixed(1)}h`;
        return `${(seconds / 86400).toFixed(1)}d`;
    }
}

import { createElement } from 'lwc';
import PulseSlaHeatmap from 'c/pulseSlaHeatmap';
import aggregateDwellStats from '@salesforce/apex/StageDwellPredictor.aggregateDwellStats';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

// Helpers ─────────────────────────────────────────────────────────

function createComponent() {
    const el = createElement('c-pulse-sla-heatmap', { is: PulseSlaHeatmap });
    document.body.appendChild(el);
    return el;
}

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

// Tests ──────────────────────────────────────────────────────────

describe('c-pulse-sla-heatmap', () => {
    it('renders empty state when aggregateDwellStats returns []', async () => {
        aggregateDwellStats.mockResolvedValue([]);
        const el = createComponent();
        await flushPromises();

        const muted = el.shadowRoot.querySelector('.heatmap-muted');
        expect(muted).not.toBeNull();
        expect(muted.textContent).toBe('No completed dwell records yet.');

        const hint = el.shadowRoot.querySelector('.heatmap-hint');
        expect(hint).not.toBeNull();

        const table = el.shadowRoot.querySelector('.heatmap-table');
        expect(table).toBeNull();
    });

    it('renders multiple rows sorted by p90 descending', async () => {
        aggregateDwellStats.mockResolvedValue([
            { workflowKey: 'wf1', subjectKind: 'Account', stateKey: 'intake', sampleCount: 10, medianSeconds: 60, p90Seconds: 120, minSeconds: 10, maxSeconds: 200 },
            { workflowKey: 'wf1', subjectKind: 'Account', stateKey: 'review', sampleCount: 5, medianSeconds: 300, p90Seconds: 600, minSeconds: 100, maxSeconds: 800 },
            { workflowKey: 'wf1', subjectKind: 'Account', stateKey: 'approval', sampleCount: 3, medianSeconds: 200, p90Seconds: 400, minSeconds: 50, maxSeconds: 500 },
        ]);
        const el = createComponent();
        await flushPromises();

        const table = el.shadowRoot.querySelector('.heatmap-table');
        expect(table).not.toBeNull();

        const rows = el.shadowRoot.querySelectorAll('.heatmap-table tbody tr');
        expect(rows.length).toBe(3);

        // First row should be 'review' (highest p90=600)
        const firstStateKey = rows[0].querySelector('.heatmap-state-key');
        expect(firstStateKey.textContent).toBe('review');

        // Second row should be 'approval' (p90=400)
        const secondStateKey = rows[1].querySelector('.heatmap-state-key');
        expect(secondStateKey.textContent).toBe('approval');

        // Third row should be 'intake' (p90=120)
        const thirdStateKey = rows[2].querySelector('.heatmap-state-key');
        expect(thirdStateKey.textContent).toBe('intake');
    });

    it('assigns correct color bucket classes for all 4 tiers', async () => {
        // Max p90 will be 1000
        aggregateDwellStats.mockResolvedValue([
            { workflowKey: 'wf1', subjectKind: 'A', stateKey: 's_error', sampleCount: 1, medianSeconds: 500, p90Seconds: 1000, minSeconds: 100, maxSeconds: 1000 },
            { workflowKey: 'wf1', subjectKind: 'A', stateKey: 's_warning', sampleCount: 1, medianSeconds: 300, p90Seconds: 600, minSeconds: 100, maxSeconds: 700 },
            { workflowKey: 'wf1', subjectKind: 'A', stateKey: 's_info', sampleCount: 1, medianSeconds: 200, p90Seconds: 400, minSeconds: 50, maxSeconds: 500 },
            { workflowKey: 'wf1', subjectKind: 'A', stateKey: 's_success', sampleCount: 1, medianSeconds: 50, p90Seconds: 100, minSeconds: 10, maxSeconds: 150 },
        ]);
        const el = createComponent();
        await flushPromises();

        const rows = el.shadowRoot.querySelectorAll('.heatmap-table tbody tr');
        expect(rows.length).toBe(4);

        // Sorted by p90 desc: s_error(1000), s_warning(600), s_info(400), s_success(100)
        // maxP90 = 1000
        // s_error: 1000/1000 = 1.0 > 0.75 → error
        expect(rows[0].classList.contains('heatmap-cell-error')).toBe(true);
        // s_warning: 600/1000 = 0.6 ≤ 0.75 → warning
        expect(rows[1].classList.contains('heatmap-cell-warning')).toBe(true);
        // s_info: 400/1000 = 0.4 ≤ 0.5 → info
        expect(rows[2].classList.contains('heatmap-cell-info')).toBe(true);
        // s_success: 100/1000 = 0.1 ≤ 0.25 → success
        expect(rows[3].classList.contains('heatmap-cell-success')).toBe(true);
    });

    it('fires select event on row click', async () => {
        aggregateDwellStats.mockResolvedValue([
            { workflowKey: 'wf1', subjectKind: 'Account', stateKey: 'intake', sampleCount: 5, medianSeconds: 60, p90Seconds: 120, minSeconds: 10, maxSeconds: 200 },
        ]);
        const el = createComponent();
        await flushPromises();

        const handler = jest.fn();
        el.addEventListener('select', handler);

        const row = el.shadowRoot.querySelector('.heatmap-table tbody tr');
        row.click();
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.stateKey).toBe('intake');
    });

    it('displays error state when Apex call fails', async () => {
        aggregateDwellStats.mockRejectedValue({ body: { message: 'Test error' } });
        const el = createComponent();
        await flushPromises();

        const errorBadge = el.shadowRoot.querySelector('.heatmap-error c-pulse-badge');
        expect(errorBadge).not.toBeNull();
    });
});

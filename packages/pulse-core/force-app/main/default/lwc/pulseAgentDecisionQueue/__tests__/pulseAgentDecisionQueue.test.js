import { createElement } from 'lwc';
import PulseAgentDecisionQueue from 'c/pulseAgentDecisionQueue';
import getPendingDecisions from '@salesforce/apex/PulseAgentController.getPendingDecisions';
import approveDecision from '@salesforce/apex/PulseAgentController.approveDecision';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

// @sfdx/lwc-jest routes every @salesforce/apex/* import through a single
// shared jest.fn (jest-mocks/apex.js). To get distinct return values per
// method we either mockImplementation and switch on argument shape, or
// re-import each stub for shape-filtering.

const INSTANCE_ID = 'a0Fxx0000000001';

const PROPOSE_EMAIL = {
    decisionId: 'a0Ixx0000000001',
    decisionType: 'Propose_Action',
    status: 'Pending_User',
    rationale: 'Best next step.',
    score: 0.9,
    previewKind: 'email',
    previewData: {
        toolKey: 'send_email',
        arguments: {
            toAddress: 'foo@example.com',
            subject: 'Hi',
            body: 'Hello there',
        },
    },
};

const PROPOSE_TOOL_WRAPPED = {
    decisionId: 'a0Ixx0000000002',
    decisionType: 'Propose_Action',
    status: 'Pending_User',
    rationale: 'Update the record.',
    score: 0.8,
    // previewKind omitted on purpose — the queue's generic tool-call
    // preview detection (previewData.toolKey + arguments) handles this.
    previewData: {
        toolKey: 'update_record',
        arguments: {
            recordId: '001xx',
            objectType: 'Account',
            top_k: 5,
            fields: {
                credit_score: 720,
                notes: 'Looks good',
                review_date: '2026-05-01',
            },
        },
    },
};

const PROPOSE_TOOL_FLAT = {
    decisionId: 'a0Ixx0000000003',
    decisionType: 'Propose_Action',
    status: 'Pending_User',
    rationale: 'Search.',
    score: 0.7,
    previewData: {
        toolKey: 'search_index',
        arguments: {
            query: 'invoice anomalies',
            limit: 10,
        },
    },
};

// @sfdx/lwc-jest routes every @salesforce/apex/* import through a single
// shared jest.fn (jest-mocks/apex.js). We drive responses through one
// mockImplementation and switch on argument shape:
//   - approve/reject/answer all pass {payload} → return {success:true}
//   - getAgentState and getPendingDecisions both pass {instanceId} → return
//     a list-with-persona hybrid. Arrays can carry non-enumerable named
//     properties; getAgentState reads `.persona`, getPendingDecisions reads
//     the array contents.
function seedDecisions(list, persona = 'Pulse') {
    const hybrid = list.slice();
    Object.defineProperty(hybrid, 'persona', {
        value: persona, configurable: true, enumerable: false,
    });
    getPendingDecisions.mockImplementation((arg) => {
        if (!arg) return Promise.resolve(null);
        if ('payload' in arg) return Promise.resolve({ success: true });
        if ('instanceId' in arg) return Promise.resolve(hybrid);
        return Promise.resolve(null);
    });
}

function createComponent(instanceId = INSTANCE_ID) {
    const el = createElement('c-pulse-agent-decision-queue', {
        is: PulseAgentDecisionQueue,
    });
    el.instanceId = instanceId;
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
    jest.useRealTimers();
});

describe('c-pulse-agent-decision-queue', () => {
    // ── §4.1 thinking placeholder ───────────────────────────────

    it('renders the {personaName} thinking placeholder when @api startThinking is called and queue is empty', async () => {
        seedDecisions([], 'Pulse');
        const el = createComponent();
        await flushPromises();
        await flushPromises();

        // No decisions, no thinking yet — nothing should render.
        expect(el.shadowRoot.querySelector('.decision-thinking')).toBeNull();

        el.startThinking();
        await flushPromises();

        const thinking = el.shadowRoot.querySelector('.decision-thinking');
        expect(thinking).not.toBeNull();
        const text = thinking.querySelector('.thinking-text').textContent;
        expect(text).toBe('Pulse is thinking');
        const initial = thinking.querySelector('.thinking-initial').textContent;
        expect(initial).toBe('P');
    });

    it('uses the persona returned by getAgentState rather than any hardcoded brand', async () => {
        seedDecisions([], 'Atlas');
        const el = createComponent();
        await flushPromises();
        await flushPromises();
        el.startThinking();
        await flushPromises();

        const text = el.shadowRoot.querySelector('.thinking-text').textContent;
        expect(text).toBe('Atlas is thinking');
        // Critically: never hardcoded "MatchForce".
        expect(text).not.toContain('MatchForce');
    });

    it('auto-clears the thinking placeholder when a decision arrives', async () => {
        seedDecisions([], 'Pulse');
        const el = createComponent();
        await flushPromises();
        await flushPromises();

        el.startThinking();
        await flushPromises();
        expect(el.shadowRoot.querySelector('.decision-thinking')).not.toBeNull();

        // Now a decision arrives via push-driven reload.
        seedDecisions([PROPOSE_EMAIL], 'Pulse');
        await el.reload();
        await flushPromises();

        // Decision card replaces the thinking placeholder.
        expect(el.shadowRoot.querySelector('.decision-thinking')).toBeNull();
        expect(el.shadowRoot.querySelector('.decision-card')).not.toBeNull();
    });

    it('clears the thinking placeholder after the 60s safety timeout', async () => {
        jest.useFakeTimers();
        seedDecisions([], 'Pulse');
        const el = createComponent();
        // Two real microtask flushes for connectedCallback fetches.
        await Promise.resolve();
        await Promise.resolve();

        el.startThinking();
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.decision-thinking')).not.toBeNull();

        jest.advanceTimersByTime(60000);
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.decision-thinking')).toBeNull();
    });

    // ── §4.3 lifecycle hooks ───────────────────────────────────

    it('@api stopUpdates short-circuits subsequent loads and clears thinking', async () => {
        seedDecisions([], 'Pulse');
        const el = createComponent();
        await flushPromises();
        await flushPromises();

        el.startThinking();
        await flushPromises();
        expect(el.shadowRoot.querySelector('.decision-thinking')).not.toBeNull();

        el.stopUpdates();
        await flushPromises();

        // Thinking is cleared.
        expect(el.shadowRoot.querySelector('.decision-thinking')).toBeNull();

        // Subsequent reload is a no-op — even though we'd seed decisions,
        // the queue must not render them.
        seedDecisions([PROPOSE_EMAIL], 'Pulse');
        await el.reload();
        await flushPromises();
        expect(el.shadowRoot.querySelector('.decision-card')).toBeNull();
    });

    // ── §4.2 friendly tool refine editor ───────────────────────

    it('refining a wrapped tool decision opens typed per-field rows and serializes back to {fields:{…}}', async () => {
        seedDecisions([PROPOSE_TOOL_WRAPPED], 'Pulse');
        const el = createComponent();
        await flushPromises();
        await flushPromises();

        // Sanity: tool preview rendered.
        const preview = el.shadowRoot.querySelector('.decision-preview-record');
        expect(preview).not.toBeNull();

        // Click Refine.
        const refineBtn = Array.from(
            el.shadowRoot.querySelectorAll('.decision-actions-main c-pulse-button')
        ).find((b) => b.label === 'Refine');
        expect(refineBtn).toBeDefined();
        refineBtn.click();
        await flushPromises();

        const list = el.shadowRoot.querySelector('.decision-refine-tool-list');
        expect(list).not.toBeNull();
        const rows = list.querySelectorAll('.decision-refine-tool-row');
        // 3 fields (top_k filtered out).
        expect(rows.length).toBe(3);
        const labels = Array.from(list.querySelectorAll('.decision-refine-tool-label'))
            .map((n) => n.textContent.trim());
        expect(labels).toEqual(['Credit Score', 'Notes', 'Review Date']);

        // Type-specific inputs: number, longtext (textarea), date.
        expect(rows[0].querySelector('input[type="number"]')).not.toBeNull();
        expect(rows[1].querySelector('textarea')).not.toBeNull();
        expect(rows[2].querySelector('input[type="date"]')).not.toBeNull();

        // Edit the credit_score number — fire native onchange.
        const creditInput = rows[0].querySelector('input[type="number"]');
        creditInput.value = '810';
        creditInput.dispatchEvent(new CustomEvent('change'));
        await flushPromises();

        // Approve with edits.
        approveDecision.mockImplementation(() => Promise.resolve({ success: true }));
        const approveEditsBtn = Array.from(
            el.shadowRoot.querySelectorAll('.decision-refine c-pulse-button')
        ).find((b) => b.label === 'Approve with edits');
        expect(approveEditsBtn).toBeDefined();
        approveEditsBtn.click();
        await flushPromises();

        const call = approveDecision.mock.calls
            .map((c) => c[0])
            .find((a) => a && a.payload && a.payload.decisionId === PROPOSE_TOOL_WRAPPED.decisionId);
        expect(call).toBeDefined();
        const refined = JSON.parse(call.payload.refinedPayloadJson);
        // Wrapped envelope preserved.
        expect(refined).toHaveProperty('fields');
        expect(refined.fields.credit_score).toBe(810);
        expect(refined.fields.notes).toBe('Looks good');
        expect(refined.fields.review_date).toBe('2026-05-01');
        // top_k stays out of the payload.
        expect(refined.fields.top_k).toBeUndefined();
        expect(refined).not.toHaveProperty('top_k');
    });

    it('refining a flat tool decision serializes without a {fields:{…}} wrapper', async () => {
        seedDecisions([PROPOSE_TOOL_FLAT], 'Pulse');
        const el = createComponent();
        await flushPromises();
        await flushPromises();

        const refineBtn = Array.from(
            el.shadowRoot.querySelectorAll('.decision-actions-main c-pulse-button')
        ).find((b) => b.label === 'Refine');
        refineBtn.click();
        await flushPromises();

        approveDecision.mockImplementation(() => Promise.resolve({ success: true }));
        const approveEditsBtn = Array.from(
            el.shadowRoot.querySelectorAll('.decision-refine c-pulse-button')
        ).find((b) => b.label === 'Approve with edits');
        approveEditsBtn.click();
        await flushPromises();

        const call = approveDecision.mock.calls
            .map((c) => c[0])
            .find((a) => a && a.payload && a.payload.decisionId === PROPOSE_TOOL_FLAT.decisionId);
        expect(call).toBeDefined();
        const refined = JSON.parse(call.payload.refinedPayloadJson);
        // Flat shape preserved — no `fields` wrapper.
        expect(refined).not.toHaveProperty('fields');
        expect(refined.query).toBe('invoice anomalies');
        expect(refined.limit).toBe(10);
    });
});

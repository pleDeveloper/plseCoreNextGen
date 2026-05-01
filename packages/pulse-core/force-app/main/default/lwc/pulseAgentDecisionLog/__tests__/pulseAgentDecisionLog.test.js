import { createElement } from 'lwc';
import PulseAgentDecisionLog from 'c/pulseAgentDecisionLog';
import getDecisionLog from '@salesforce/apex/PulseAgentController.getDecisionLog';
import { subscribe, unsubscribe } from 'lightning/empApi';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const SAMPLE = [
    {
        decisionId: 'a0Ixx0000000001',
        decisionType: 'Propose_Action',
        phaseKey: 'intake_qualification',
        rationale: 'Drafted follow-up email requesting missing financial docs.',
        status: 'Approved',
        proposalJson: JSON.stringify({ toolKey: 'send_email', arguments: { toAddress: 'a@b.com' } }),
        questionJson: null,
        userResponseJson: null,
        createdDate: '2026-04-22T10:00:00Z',
        resolvedDate: '2026-04-22T10:05:00Z',
    },
    {
        decisionId: 'a0Ixx0000000002',
        decisionType: 'Ask_User',
        phaseKey: 'intake_qualification',
        rationale: 'Needed headcount projection.',
        status: 'Answered',
        proposalJson: null,
        questionJson: JSON.stringify({ fieldKey: 'headcount', prompt: 'Headcount at 12 months?' }),
        userResponseJson: JSON.stringify({ value: '35' }),
        createdDate: '2026-04-22T11:00:00Z',
        resolvedDate: '2026-04-22T11:02:00Z',
    },
];

const flush = () => new Promise((r) => setTimeout(r, 0));

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    try { sessionStorage.clear(); } catch (_e) { /* ignore */ }
    jest.clearAllMocks();
});

describe('c-pulse-agent-decision-log', () => {
    it('renders the toggle with a count label when rows exist', async () => {
        getDecisionLog.mockResolvedValue(SAMPLE);
        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();

        const toggle = el.shadowRoot.querySelector('.log-toggle');
        expect(toggle).not.toBeNull();
        const countLabel = el.shadowRoot.querySelector('.log-count').textContent;
        expect(countLabel).toContain('2');

        // Collapsed by default — no rows rendered yet.
        expect(el.shadowRoot.querySelector('.log-list')).toBeNull();
    });

    it('expands rows when the toggle is clicked and expands detail on row click', async () => {
        getDecisionLog.mockResolvedValue(SAMPLE);
        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();

        el.shadowRoot.querySelector('.log-toggle').click();
        await flush();
        await flush();

        const rows = el.shadowRoot.querySelectorAll('.log-row');
        expect(rows.length).toBe(2);

        // Click the first row to expand detail.
        const head = rows[0].querySelector('.log-row-head');
        head.click();
        await flush();

        const body = rows[0].querySelector('.log-row-body');
        expect(body).not.toBeNull();
        const pres = body.querySelectorAll('pre');
        expect(pres.length).toBeGreaterThan(0);
        expect(body.textContent).toContain('send_email');
    });

    it('shows the empty-state message when there are no past decisions', async () => {
        getDecisionLog.mockResolvedValue([]);
        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();

        el.shadowRoot.querySelector('.log-toggle').click();
        await flush();
        await flush();

        const empty = el.shadowRoot.querySelector('.log-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toMatch(/No past agent decisions/i);
    });

    it('subscribes to the workflow push channel after the initial load', async () => {
        getDecisionLog.mockResolvedValue(SAMPLE);
        subscribe.mockResolvedValueOnce({ id: 'sub-log' });

        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();

        expect(subscribe).toHaveBeenCalledWith(
            '/event/Pulse_Workflow_Update__e',
            -1,
            expect.any(Function)
        );
    });

    it('refreshes on a matching push event when expanded; ignores mismatched instance', async () => {
        getDecisionLog.mockResolvedValue(SAMPLE);
        let pushHandler = null;
        subscribe.mockImplementationOnce((_channel, _replay, cb) => {
            pushHandler = cb;
            return Promise.resolve({ id: 'sub-log' });
        });

        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();
        // Initial load (collapsed) is already 1 call.
        expect(getDecisionLog).toHaveBeenCalledTimes(1);

        // Expand — that triggers another load.
        el.shadowRoot.querySelector('.log-toggle').click();
        await flush();
        await flush();
        const beforePush = getDecisionLog.mock.calls.length;

        // Matching 15-char prefix: refresh.
        pushHandler({ data: { payload: { Instance_Id__c: 'a0Fxx0000000001AAA' } } });
        await flush();
        await flush();
        expect(getDecisionLog.mock.calls.length).toBe(beforePush + 1);

        // Mismatched instance: no refresh.
        pushHandler({ data: { payload: { Instance_Id__c: 'a0Fzz0000000999AAA' } } });
        await flush();
        expect(getDecisionLog.mock.calls.length).toBe(beforePush + 1);
    });

    it('honors the terminal kill-switch (sessionStorage flag) at connectedCallback time', async () => {
        try { sessionStorage.setItem('pulseTerminal:a0Fxx0000000001', '1'); } catch (_e) { /* ignore */ }
        getDecisionLog.mockResolvedValue(SAMPLE);

        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();

        expect(getDecisionLog).not.toHaveBeenCalled();
        expect(subscribe).not.toHaveBeenCalled();
    });

    it('stopUpdates @api hook unsubscribes', async () => {
        getDecisionLog.mockResolvedValue(SAMPLE);
        subscribe.mockResolvedValueOnce({ id: 'sub-log' });

        const el = createElement('c-pulse-agent-decision-log', { is: PulseAgentDecisionLog });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();

        el.stopUpdates();
        await flush();
        expect(unsubscribe).toHaveBeenCalled();
    });
});

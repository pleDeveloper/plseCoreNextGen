import { createElement } from 'lwc';
import PulseAgentDecisionLog from 'c/pulseAgentDecisionLog';
import getDecisionLog from '@salesforce/apex/PulseAgentController.getDecisionLog';

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
});

import { createElement } from 'lwc';
import PulseAgentStatusRail from 'c/pulseAgentStatusRail';
import getAgentState from '@salesforce/apex/PulseAgentController.getAgentState';
import { subscribe, unsubscribe } from 'lightning/empApi';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const STATE = {
    enabled: true,
    persona: 'Aria',
    status: 'Working',
    autonomy: 'Act_With_Approval',
    autonomyOptions: ['Propose_Only', 'Act_With_Approval', 'Autonomous_Safe'],
};

const flush = () => new Promise((r) => setTimeout(r, 0));

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    try { sessionStorage.clear(); } catch (_e) { /* ignore */ }
    jest.clearAllMocks();
});

describe('c-pulse-agent-status-rail', () => {
    it('renders the persona name and subscribes to the workflow push channel', async () => {
        getAgentState.mockResolvedValue(STATE);
        // empApi stub: subscribe returns a resolved subscription handle.
        subscribe.mockResolvedValueOnce({ id: 'sub-1' });

        const el = createElement('c-pulse-agent-status-rail', { is: PulseAgentStatusRail });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();

        const persona = el.shadowRoot.querySelector('.agent-persona');
        expect(persona).not.toBeNull();
        expect(persona.textContent).toContain('Aria');

        // Push subscription must target the upstream-generic workflow channel.
        expect(subscribe).toHaveBeenCalledWith(
            '/event/Pulse_Workflow_Update__e',
            -1,
            expect.any(Function)
        );
    });

    it('refreshes when a Platform Event fires for the matching 15-char instance prefix', async () => {
        getAgentState.mockResolvedValue(STATE);
        let pushHandler = null;
        subscribe.mockImplementationOnce((_channel, _replay, cb) => {
            pushHandler = cb;
            return Promise.resolve({ id: 'sub-1' });
        });

        const el = createElement('c-pulse-agent-status-rail', { is: PulseAgentStatusRail });
        el.instanceId = 'a0Fxx0000000001';   // 15-char form
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();
        expect(getAgentState).toHaveBeenCalledTimes(1);

        // Server publishes the 18-char form on the Platform Event payload.
        getAgentState.mockResolvedValue({ ...STATE, status: 'Idle' });
        pushHandler({ data: { payload: { Instance_Id__c: 'a0Fxx0000000001AAA' } } });
        await flush();
        await flush();
        expect(getAgentState).toHaveBeenCalledTimes(2);

        // Mismatched instance — must NOT trigger a refresh.
        pushHandler({ data: { payload: { Instance_Id__c: 'a0Fyy0000000002AAA' } } });
        await flush();
        expect(getAgentState).toHaveBeenCalledTimes(2);
    });

    it('honors the terminal kill-switch (sessionStorage flag) at connectedCallback time', async () => {
        try { sessionStorage.setItem('pulseTerminal:a0Fxx0000000001', '1'); } catch (_e) { /* ignore */ }
        getAgentState.mockResolvedValue(STATE);

        const el = createElement('c-pulse-agent-status-rail', { is: PulseAgentStatusRail });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();

        // Terminal: never fetched, never subscribed.
        expect(getAgentState).not.toHaveBeenCalled();
        expect(subscribe).not.toHaveBeenCalled();
    });

    it('stopUpdates @api hook unsubscribes and stops further refreshes', async () => {
        getAgentState.mockResolvedValue(STATE);
        let pushHandler = null;
        subscribe.mockImplementationOnce((_channel, _replay, cb) => {
            pushHandler = cb;
            return Promise.resolve({ id: 'sub-1' });
        });

        const el = createElement('c-pulse-agent-status-rail', { is: PulseAgentStatusRail });
        el.instanceId = 'a0Fxx0000000001';
        document.body.appendChild(el);

        await flush();
        await flush();
        await flush();
        expect(getAgentState).toHaveBeenCalledTimes(1);

        el.stopUpdates();
        await flush();

        expect(unsubscribe).toHaveBeenCalled();

        // Late-arriving event after stopUpdates: must be a no-op.
        if (pushHandler) {
            pushHandler({ data: { payload: { Instance_Id__c: 'a0Fxx0000000001AAA' } } });
            await flush();
        }
        expect(getAgentState).toHaveBeenCalledTimes(1);
    });
});

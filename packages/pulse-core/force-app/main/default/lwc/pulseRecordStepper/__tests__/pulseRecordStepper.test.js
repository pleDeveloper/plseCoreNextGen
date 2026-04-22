import { createElement } from 'lwc';
import PulseRecordStepper from 'c/pulseRecordStepper';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseRuntimeController.resolveAction',
    () => ({ default: jest.fn(() => Promise.resolve({ success: true, message: 'ok' })) }),
    { virtual: true }
);

const MOCK_INSTANCE = {
    instanceId: 'a0Fxx0000000001',
    workflowKey: 'test_wf',
    workflowName: 'Test Workflow',
    currentStateKey: 'intake',
    currentStateLabel: 'Intake',
    currentStateType: 'form',
    status: 'Active',
    pendingActionCount: 2,
    availableSignals: [
        { signal: 'submit', targetStateKey: 'review', targetStateLabel: 'Review' },
        { signal: 'cancel', targetStateKey: 'cancelled', targetStateLabel: 'Cancelled' },
    ],
    history: [
        {
            stepResultId: 'a0Gxx0000000001',
            stateKey: 'initial',
            stateLabel: 'Initial',
            signal: 'start',
            outcome: 'Completed',
            actorType: 'Human',
        },
        {
            stepResultId: 'a0Gxx0000000002',
            stateKey: 'triage',
            stateLabel: 'Triage',
            signal: 'assign',
            outcome: 'Completed',
            actorType: 'AI',
        },
        {
            stepResultId: 'a0Gxx0000000003',
            stateKey: 'verify',
            stateLabel: 'Verify',
            signal: 'confirm',
            outcome: 'Completed',
            actorType: 'Human',
        },
    ],
};

function createComponent(recordId = '001xx0000000001') {
    const el = createElement('c-pulse-record-stepper', { is: PulseRecordStepper });
    el.recordId = recordId;
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

describe('c-pulse-record-stepper', () => {
    it('renders empty state when no instance', async () => {
        getInstanceForRecord.mockResolvedValue(null);
        const el = createComponent();
        await flushPromises();

        const empty = el.shadowRoot.querySelector('.stepper-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toBe('No active workflow for this record.');
    });

    it('renders active instance with signals and history', async () => {
        getInstanceForRecord.mockResolvedValue(MOCK_INSTANCE);
        const el = createComponent();
        await flushPromises();

        const name = el.shadowRoot.querySelector('.stepper-workflow-name');
        expect(name).not.toBeNull();
        expect(name.textContent).toBe('Test Workflow');

        const pill = el.shadowRoot.querySelector('.stepper-state-pill');
        expect(pill.textContent).toBe('Intake');

        const buttons = el.shadowRoot.querySelectorAll('c-pulse-button[data-signal]');
        expect(buttons.length).toBe(2);

        const badges = el.shadowRoot.querySelectorAll('c-pulse-badge');
        const pendingBadge = Array.from(badges).find((b) => b.label === '2 pending');
        expect(pendingBadge).toBeDefined();

        const steps = el.shadowRoot.querySelectorAll('.stepper-timeline-item');
        expect(steps.length).toBe(3);
    });

    it('opens modal on signal click and submits advance', async () => {
        getInstanceForRecord.mockResolvedValue(MOCK_INSTANCE);
        const el = createComponent();
        await flushPromises();

        advanceInstance.mockResolvedValueOnce({
            success: true,
            idempotent: false,
            error: null,
            fromStateKey: 'intake',
            toStateKey: 'review',
            refreshed: { ...MOCK_INSTANCE, currentStateKey: 'review', currentStateLabel: 'Review' },
        });

        const signalBtn = el.shadowRoot.querySelector('c-pulse-button[data-signal="submit"]');
        signalBtn.click();
        await flushPromises();

        const modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);

        const advanceBtn = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-modal-actions c-pulse-button')
        ).find((b) => b.label === 'Advance');
        advanceBtn.click();
        await flushPromises();

        expect(advanceInstance).toHaveBeenCalledWith({
            instanceId: 'a0Fxx0000000001',
            signal: 'submit',
            payloadJson: null,
            idempotencyKey: null,
        });
    });

    it('renders error state from advance as dismissible badge', async () => {
        getInstanceForRecord.mockResolvedValue(MOCK_INSTANCE);
        const el = createComponent();
        await flushPromises();

        advanceInstance.mockResolvedValueOnce({
            success: false,
            error: 'Signal not valid for current state',
        });

        el.shadowRoot.querySelector('c-pulse-button[data-signal="submit"]').click();
        await flushPromises();

        Array.from(
            el.shadowRoot.querySelectorAll('.stepper-modal-actions c-pulse-button')
        ).find((b) => b.label === 'Advance').click();
        await flushPromises();

        const errorContainer = el.shadowRoot.querySelector('.stepper-advance-error');
        expect(errorContainer).not.toBeNull();
        expect(errorContainer.querySelector('c-pulse-badge').label).toBe(
            'Signal not valid for current state'
        );
        expect(errorContainer.querySelector('c-pulse-badge').variant).toBe('error');

        errorContainer.querySelector('c-pulse-button').click();
        await flushPromises();
        expect(el.shadowRoot.querySelector('.stepper-advance-error')).toBeNull();
    });
});

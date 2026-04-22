import { createElement } from 'lwc';
import PulseRecordStepper from 'c/pulseRecordStepper';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

// @sfdx/lwc-jest routes every @salesforce/apex/* import to a single shared
// jest.fn (see jest-mocks/apex.js). Re-import each stub so we can filter
// mock.calls by shape when asserting.
// eslint-disable-next-line @lwc/lwc/no-async-await
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';
import saveFieldValues from '@salesforce/apex/PulseRuntimeController.saveFieldValues';
import advanceInstanceWithFields from '@salesforce/apex/PulseRuntimeController.advanceInstanceWithFields';

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

const AI_EMAIL_ACTION = {
    actionId: 'a0Hxx0000000001',
    actionKey: 'send_draft',
    phaseKey: 'intake',
    label: 'Send draft email',
    actionType: 'AI_Tool_Call',
    toolKey: 'send_email',
    hitlPolicy: 'Approval_Required',
    status: 'Pending',
    required: true,
    blocked: false,
    dependsOn: [],
    sequence: 0,
    requestJson: JSON.stringify({
        toAddress: 'counterparty@example.com',
        subject: 'Draft proposal',
        body: 'Original draft body',
    }),
};

const INSTANCE_WITH_AI_ACTION = {
    ...MOCK_INSTANCE,
    phaseActions: [AI_EMAIL_ACTION],
    phaseFields: [],
};

const INSTANCE_WITH_FIELDS = {
    ...MOCK_INSTANCE,
    phaseActions: [],
    phaseFields: [
        {
            key: 'credit_score',
            label: 'Credit Score',
            fieldType: 'Number',
            required: true,
            currentValue: '720',
            picklistValues: null,
            projectedFieldApiName: 'Pulse_credit_score__c',
        },
        {
            key: 'credit_review_comments',
            label: 'Reviewer Comments',
            fieldType: 'LongTextArea',
            required: false,
            currentValue: null,
            picklistValues: null,
            projectedFieldApiName: null,
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

    // ── Refine ──────────────────────────────────────────────────

    it('renders a Refine button on a pending AI_Tool_Call action', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_AI_ACTION);
        const el = createComponent();
        await flushPromises();

        const actionButtons = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-phase-actions c-pulse-button')
        );
        const labels = actionButtons.map((b) => b.label);
        expect(labels).toEqual(expect.arrayContaining(['Approve', 'Reject', 'Refine']));
    });

    it('clicking Refine opens an inline editor pre-filled from requestJson', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_AI_ACTION);
        const el = createComponent();
        await flushPromises();

        const refineBtn = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-phase-actions c-pulse-button')
        ).find((b) => b.label === 'Refine');
        expect(refineBtn).toBeDefined();
        refineBtn.click();
        await flushPromises();

        const editor = el.shadowRoot.querySelector('.stepper-refine-editor');
        expect(editor).not.toBeNull();
        const inputs = editor.querySelectorAll('c-pulse-input');
        // To + Subject
        expect(inputs.length).toBeGreaterThanOrEqual(2);
        const toInput = inputs[0];
        expect(toInput.value).toBe('counterparty@example.com');
        const subjectInput = inputs[1];
        expect(subjectInput.value).toBe('Draft proposal');

        const bodyTextarea = editor.querySelector('textarea.stepper-refine-textarea');
        expect(bodyTextarea).not.toBeNull();
        expect(bodyTextarea.textContent.trim()).toBe('Original draft body');
    });

    it('Approve with edits calls resolveAction with refinedPayloadJson', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_AI_ACTION);
        const el = createComponent();
        await flushPromises();

        // Open refine
        const refineBtn = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-phase-actions c-pulse-button')
        ).find((b) => b.label === 'Refine');
        refineBtn.click();
        await flushPromises();

        // Edit the body
        const bodyTextarea = el.shadowRoot.querySelector('.stepper-refine-editor textarea');
        bodyTextarea.value = 'EDITED BODY';
        bodyTextarea.dispatchEvent(new CustomEvent('change'));
        await flushPromises();

        // Click Approve with edits
        const approveBtn = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-refine-actions c-pulse-button')
        ).find((b) => b.label === 'Approve with edits');
        expect(approveBtn).toBeDefined();
        approveBtn.click();
        await flushPromises();

        // Shared jest.fn — filter to the resolveAction-shaped call.
        const call = resolveAction.mock.calls
            .map((c) => c[0])
            .find((a) => a && a.actionId === AI_EMAIL_ACTION.actionId && a.decision === 'Approve');
        expect(call).toBeDefined();
        expect(call.notes).toBeNull();
        expect(typeof call.refinedPayloadJson).toBe('string');
        const refined = JSON.parse(call.refinedPayloadJson);
        expect(refined.body).toBe('EDITED BODY');
        expect(refined.toAddress).toBe('counterparty@example.com');
        expect(refined.subject).toBe('Draft proposal');
    });

    // ── Phase fields form ───────────────────────────────────────

    it('renders a Fields-for-this-phase form when phaseFields is non-empty', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_FIELDS);
        const el = createComponent();
        await flushPromises();

        const list = el.shadowRoot.querySelector('.stepper-fields-list');
        expect(list).not.toBeNull();
        const items = list.querySelectorAll('.stepper-field-item');
        expect(items.length).toBe(2);

        const labels = Array.from(list.querySelectorAll('.stepper-field-label'))
            .map((l) => l.textContent.trim());
        expect(labels).toEqual(['Credit Score', 'Reviewer Comments']);

        // Credit Score (Number) is a c-pulse-input with type="number"
        const numInput = items[0].querySelector('c-pulse-input');
        expect(numInput).not.toBeNull();
        expect(numInput.value).toBe('720');

        // Long-text field is a textarea
        const textarea = items[1].querySelector('textarea');
        expect(textarea).not.toBeNull();
    });

    it('Save fields calls saveFieldValues with edited values', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_FIELDS);
        const el = createComponent();
        await flushPromises();

        // Type into the credit_score input (c-pulse-input dispatches change with .detail.value)
        const items = el.shadowRoot.querySelectorAll('.stepper-field-item');
        const csInput = items[0].querySelector('c-pulse-input');
        csInput.dispatchEvent(
            new CustomEvent('change', { detail: { value: '810' }, bubbles: false })
        );
        await flushPromises();

        // Type into the comments textarea
        const commentsTextarea = items[1].querySelector('textarea');
        commentsTextarea.value = 'Looks clean';
        commentsTextarea.dispatchEvent(new CustomEvent('change'));
        await flushPromises();

        const saveBtn = Array.from(
            el.shadowRoot.querySelectorAll('.stepper-fields-actions c-pulse-button')
        ).find((b) => b.label === 'Save fields');
        expect(saveBtn).toBeDefined();
        saveBtn.click();
        await flushPromises();

        // @sfdx/lwc-jest routes every @salesforce/apex/* import through a
        // single shared jest.fn, so we filter by the shape of the call.
        const saveCall = saveFieldValues.mock.calls.find(
            (c) => c[0] && c[0].values && c[0].instanceId === INSTANCE_WITH_FIELDS.instanceId
        );
        expect(saveCall).toBeDefined();
        expect(saveCall[0].values.credit_score).toBe(810);
        expect(saveCall[0].values.credit_review_comments).toBe('Looks clean');
    });

    it('Advance flows phaseField values through advanceInstanceWithFields', async () => {
        getInstanceForRecord.mockResolvedValue(INSTANCE_WITH_FIELDS);
        const el = createComponent();
        await flushPromises();

        advanceInstanceWithFields.mockResolvedValueOnce({
            success: true,
            refreshed: null,
        });

        el.shadowRoot.querySelector('c-pulse-button[data-signal="submit"]').click();
        await flushPromises();

        Array.from(
            el.shadowRoot.querySelectorAll('.stepper-modal-actions c-pulse-button')
        ).find((b) => b.label === 'Advance').click();
        await flushPromises();

        // Shared jest.fn — filter to the advanceInstanceWithFields-shaped call.
        const call = advanceInstanceWithFields.mock.calls
            .map((c) => c[0])
            .find((a) => a && a.signal === 'submit' && a.fieldValues);
        expect(call).toBeDefined();
        expect(call.instanceId).toBe(INSTANCE_WITH_FIELDS.instanceId);
        expect(call.fieldValues).toEqual(expect.objectContaining({ credit_score: 720 }));
    });
});

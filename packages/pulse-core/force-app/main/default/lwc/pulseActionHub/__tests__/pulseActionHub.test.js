import { createElement } from 'lwc';
import PulseActionHub from 'c/pulseActionHub';
import getPendingActions from '@salesforce/apex/PulseRuntimeController.getPendingActions';
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const MOCK_ACTIONS = [
    {
        actionId: 'a0Hxx0000000001',
        toolKey: 'send_email',
        hitlPolicy: 'Approval_Required',
        requestJson: '{"toAddress":"test@test.com","subject":"Hello"}',
        requestedDate: '2026-04-20T10:00:00.000Z',
        requestedByName: 'Admin User',
    },
    {
        actionId: 'a0Hxx0000000002',
        toolKey: 'update_record',
        hitlPolicy: 'Approval_Required',
        requestJson: '{"field":"Status","value":"Closed"}',
        requestedDate: '2026-04-20T10:05:00.000Z',
        requestedByName: 'AI Agent',
    },
];

function createComponent(props = {}) {
    const el = createElement('c-pulse-action-hub', { is: PulseActionHub });
    Object.assign(el, { instanceId: 'a0Fxx0000000001', ...props });
    document.body.appendChild(el);
    return el;
}

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

function findButtonByLabel(container, label) {
    const buttons = container.querySelectorAll('c-pulse-button');
    return Array.from(buttons).find((b) => b.label === label);
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('c-pulse-action-hub', () => {
    it('renders empty state when no pending actions', async () => {
        getPendingActions.mockResolvedValue([]);
        const el = createComponent();
        await flushPromises();

        const empty = el.shadowRoot.querySelector('.hub-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toBe('No pending approvals for this workflow.');
    });

    it('renders pending action cards', async () => {
        getPendingActions.mockResolvedValue(MOCK_ACTIONS);
        const el = createComponent();
        await flushPromises();

        const heading = el.shadowRoot.querySelector('.hub-heading');
        expect(heading).not.toBeNull();
        expect(heading.textContent).toBe('Approvals awaiting you');

        const items = el.shadowRoot.querySelectorAll('.hub-action-item');
        expect(items.length).toBe(2);

        const toolKeys = el.shadowRoot.querySelectorAll('.hub-tool-key');
        expect(toolKeys[0].textContent).toBe('send_email');
        expect(toolKeys[1].textContent).toBe('update_record');

        const jsonBlocks = el.shadowRoot.querySelectorAll('.hub-request-json');
        expect(jsonBlocks[0].textContent).toContain('"toAddress"');
    });

    it('calls resolveAction with Approve on approve click', async () => {
        getPendingActions.mockResolvedValue(MOCK_ACTIONS);
        const el = createComponent();
        await flushPromises();

        jest.spyOn(window, 'alert').mockImplementation(() => {});
        resolveAction.mockResolvedValueOnce({
            success: true,
            resultStatus: 'Executed',
            message: 'Action approved and executed',
        });
        getPendingActions.mockResolvedValueOnce([]);

        // Find the first action card's Approve button
        const firstCard = el.shadowRoot.querySelector('.hub-action-item');
        const approveBtn = findButtonByLabel(firstCard, 'Approve');
        expect(approveBtn).not.toBeUndefined();
        approveBtn.click();
        await flushPromises();

        expect(resolveAction).toHaveBeenCalledWith({
            actionId: 'a0Hxx0000000001',
            decision: 'Approve',
            notes: null,
        });
        expect(window.alert).toHaveBeenCalledWith('Approved: Action approved and executed');
    });

    it('calls resolveAction with Reject on reject click', async () => {
        getPendingActions.mockResolvedValue(MOCK_ACTIONS);
        const el = createComponent();
        await flushPromises();

        jest.spyOn(window, 'alert').mockImplementation(() => {});
        resolveAction.mockResolvedValueOnce({
            success: true,
            resultStatus: 'Rejected',
            message: 'Action rejected',
        });
        getPendingActions.mockResolvedValueOnce([]);

        const firstCard = el.shadowRoot.querySelector('.hub-action-item');
        const rejectBtn = findButtonByLabel(firstCard, 'Reject');
        expect(rejectBtn).not.toBeUndefined();
        rejectBtn.click();
        await flushPromises();

        expect(resolveAction).toHaveBeenCalledWith({
            actionId: 'a0Hxx0000000001',
            decision: 'Reject',
            notes: null,
        });
    });

    it('renders error state on resolve failure', async () => {
        getPendingActions.mockResolvedValue(MOCK_ACTIONS);
        const el = createComponent();
        await flushPromises();

        resolveAction.mockResolvedValueOnce({
            success: false,
            resultStatus: 'Failed',
            message: 'Action is not Pending',
        });

        const firstCard = el.shadowRoot.querySelector('.hub-action-item');
        const approveBtn = findButtonByLabel(firstCard, 'Approve');
        approveBtn.click();
        await flushPromises();

        const errorRow = el.shadowRoot.querySelector('.hub-resolve-error');
        expect(errorRow).not.toBeNull();
        expect(errorRow.querySelector('c-pulse-badge').label).toBe('Action is not Pending');
    });
});

import { createElement } from 'lwc';
import PulseGlobalActionHub from 'c/pulseGlobalActionHub';
import getMyPendingActions from '@salesforce/apex/PulseGlobalActionHubController.getMyPendingActions';
import approveAction from '@salesforce/apex/PulseGlobalActionHubController.approveAction';
import rejectAction from '@salesforce/apex/PulseGlobalActionHubController.rejectAction';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const MOCK_ROWS = [
    {
        actionId: 'a01xx0000000001',
        actionLabel: 'Send follow-up email',
        toolKey: 'send_email',
        phaseKey: 'intake_qualification',
        phaseLabel: 'Intake Qualification',
        workflowName: 'Real Estate Leasing v1',
        parentObjectType: 'Opportunity',
        parentRecordId: '006xx0000000001',
        parentDisplayName: 'Downtown Law Firm',
        requestedDate: '2026-04-20T09:00:00.000Z',
        ageInHours: 10.5,
        columns: [
            { field: 'Name', label: 'Name', value: 'Downtown Law Firm' },
            { field: 'Amount', label: 'Amount', value: '357000' },
        ],
        canRefine: true,
        hitlPolicy: 'Approval_Required',
        requestJson: '{"toAddress":"a@b.com","subject":"Hi","body":"Hello"}',
        assignmentKind: 'me',
        assignedGroupName: null,
    },
    {
        actionId: 'a01xx0000000002',
        actionLabel: 'Update record',
        toolKey: 'update_record',
        phaseKey: 'review',
        parentObjectType: 'Opportunity',
        parentRecordId: '006xx0000000002',
        parentDisplayName: 'Brooklyn Design',
        requestedDate: '2026-04-21T09:00:00.000Z',
        ageInHours: 2.1,
        columns: [
            { field: 'Name', label: 'Name', value: 'Brooklyn Design' },
        ],
        canRefine: true,
        requestJson: '{"objectType":"Opportunity","recordId":"006xx","fields":{"StageName":"Won"}}',
        assignmentKind: 'unassigned',
    },
];

function createComponent(props = {}) {
    const el = createElement('c-pulse-global-action-hub', { is: PulseGlobalActionHub });
    Object.assign(el, props);
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

describe('c-pulse-global-action-hub', () => {
    it('renders empty state when no rows', async () => {
        getMyPendingActions.mockResolvedValue([]);
        const el = createComponent();
        await flushPromises();
        const empty = el.shadowRoot.querySelector('.hub-empty-title');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toContain('caught up');
    });

    it('renders the configured columns and action label', async () => {
        getMyPendingActions.mockResolvedValue(MOCK_ROWS);
        const el = createComponent();
        await flushPromises();

        const items = el.shadowRoot.querySelectorAll('.hub-row-item');
        expect(items.length).toBe(2);

        const firstRowCols = items[0].querySelectorAll('.hub-col-value');
        expect(firstRowCols.length).toBe(2);
        expect(firstRowCols[0].textContent).toBe('Downtown Law Firm');
        expect(firstRowCols[1].textContent).toBe('357000');

        const actionLabels = el.shadowRoot.querySelectorAll('.hub-action-label');
        expect(actionLabels[0].textContent).toBe('Send follow-up email');
    });

    it('switches filter and re-fetches actions', async () => {
        getMyPendingActions.mockResolvedValue(MOCK_ROWS);
        const el = createComponent();
        await flushPromises();

        const chips = el.shadowRoot.querySelectorAll('.hub-chip');
        const meChip = Array.from(chips).find((c) => c.textContent.trim() === 'Assigned to me');
        expect(meChip).not.toBeUndefined();
        meChip.click();
        await flushPromises();
        expect(getMyPendingActions).toHaveBeenCalledWith({
            filters: { assignedOnlyToMe: true },
        });
    });

    it('expands row on click and renders preview', async () => {
        getMyPendingActions.mockResolvedValue(MOCK_ROWS);
        const el = createComponent();
        await flushPromises();

        const headerBtn = el.shadowRoot.querySelector('.hub-row-header');
        headerBtn.click();
        await flushPromises();

        const preview = el.shadowRoot.querySelector('.hub-preview-email');
        expect(preview).not.toBeNull();
    });

    it('approves an action after row expanded', async () => {
        getMyPendingActions.mockResolvedValue(MOCK_ROWS);
        jest.spyOn(window, 'alert').mockImplementation(() => {});
        const el = createComponent();
        await flushPromises();

        el.shadowRoot.querySelector('.hub-row-header').click();
        await flushPromises();

        approveAction.mockResolvedValueOnce({
            success: true,
            resultStatus: 'Executed',
            message: 'Action approved and executed',
        });

        const firstItem = el.shadowRoot.querySelector('.hub-row-item');
        const approveBtn = findButtonByLabel(firstItem, 'Approve');
        approveBtn.click();
        await flushPromises();

        expect(approveAction).toHaveBeenCalledWith(
            expect.objectContaining({ actionId: 'a01xx0000000001' })
        );
    });

    it('rejects an action', async () => {
        getMyPendingActions.mockResolvedValue(MOCK_ROWS);
        jest.spyOn(window, 'alert').mockImplementation(() => {});

        const el = createComponent();
        await flushPromises();
        el.shadowRoot.querySelector('.hub-row-header').click();
        await flushPromises();

        rejectAction.mockResolvedValueOnce({
            success: true,
            resultStatus: 'Rejected',
            message: 'Action rejected',
        });

        const firstItem = el.shadowRoot.querySelector('.hub-row-item');
        const rejectBtn = findButtonByLabel(firstItem, 'Reject');
        rejectBtn.click();
        await flushPromises();

        expect(rejectAction).toHaveBeenCalledWith(
            expect.objectContaining({ actionId: 'a01xx0000000001' })
        );
    });
});

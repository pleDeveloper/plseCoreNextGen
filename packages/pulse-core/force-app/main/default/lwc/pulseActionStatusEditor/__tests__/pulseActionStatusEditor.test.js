import { createElement } from 'lwc';
import PulseActionStatusEditor from 'c/pulseActionStatusEditor';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseActionStatusTemplateController.listTemplates',
    () => ({ default: jest.fn(() => Promise.resolve([])) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowTriggerController.describeObjectFields',
    () => ({ default: jest.fn(() => Promise.resolve([])) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-action-status-editor', {
        is: PulseActionStatusEditor
    });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
}

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

const FIVE_STATUSES = [
    { key: 'Drafting', label: 'Drafting', order: 0, category: 'open', isInitial: true },
    { key: 'Pending_Approval', label: 'Pending approval', order: 1, category: 'open' },
    { key: 'Sent', label: 'Sent', order: 2, category: 'open' },
    { key: 'Bounced', label: 'Bounced', order: 3, category: 'terminal_failure' },
    { key: 'Complete', label: 'Complete', order: 4, category: 'terminal_success' }
];

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('c-pulse-action-status-editor', () => {
    it('renders the provided statuses', async () => {
        const el = createComponent({
            statuses: FIVE_STATUSES,
            initialStatusKey: 'Drafting',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        const rows = el.shadowRoot.querySelectorAll('.ase-status-row');
        expect(rows.length).toBe(5);
    });

    it('fires change when a status is added', async () => {
        const el = createComponent({
            statuses: FIVE_STATUSES,
            initialStatusKey: 'Drafting',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        const handler = jest.fn();
        el.addEventListener('change', handler);

        const addBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === '+ Add status');
        expect(addBtn).not.toBeUndefined();
        addBtn.click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const rows = el.shadowRoot.querySelectorAll('.ase-status-row');
        expect(rows.length).toBe(6);
    });

    it('removes a status when the remove button is clicked', async () => {
        const el = createComponent({
            statuses: FIVE_STATUSES,
            initialStatusKey: 'Drafting',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        const handler = jest.fn();
        el.addEventListener('change', handler);

        const removeBtns = el.shadowRoot.querySelectorAll('.ase-remove-btn');
        expect(removeBtns.length).toBe(5);
        removeBtns[1].click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const rows = el.shadowRoot.querySelectorAll('.ase-status-row');
        expect(rows.length).toBe(4);
    });

    it('updates category when the dropdown changes', async () => {
        const el = createComponent({
            statuses: [
                { key: 'A', label: 'A', category: 'open', isInitial: true }
            ],
            initialStatusKey: 'A',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        const handler = jest.fn();
        el.addEventListener('change', handler);

        const select = el.shadowRoot.querySelector('.ase-category-select');
        select.value = 'terminal_success';
        select.dispatchEvent(new Event('change'));
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const detail = handler.mock.calls[0][0].detail;
        expect(detail.statuses[0].category).toBe('terminal_success');
    });

    it('allows setting the initial status via radio', async () => {
        const el = createComponent({
            statuses: FIVE_STATUSES,
            initialStatusKey: 'Drafting',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        const handler = jest.fn();
        el.addEventListener('change', handler);

        const radios = el.shadowRoot.querySelectorAll('input[type="radio"]');
        expect(radios.length).toBe(5);
        // Click the 3rd row (Sent)
        radios[2].dispatchEvent(new Event('change'));
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const detail = handler.mock.calls[0][0].detail;
        expect(detail.initialStatusKey).toBe('Sent');
        expect(detail.statuses[2].isInitial).toBe(true);
        // Only one initial at a time.
        const initialCount = detail.statuses.filter((s) => s.isInitial).length;
        expect(initialCount).toBe(1);
    });

    it('opens the picker, lists templates, and replaces statuses on selection', async () => {
        // The jest-mocks/apex.js catch-all exports a SHARED jest.fn() for
        // every @salesforce/apex/* import. That means describeObjectFields
        // (called by each nested c-pulse-condition-builder during hydrate)
        // is the same mock instance as listTemplates — so priming
        // listTemplates.mockResolvedValueOnce BEFORE mount would be
        // consumed by those describe calls first. We mount without
        // statuses (no nested builders, no describe calls), prime, then
        // click.
        const listTemplates = require('@salesforce/apex/PulseActionStatusTemplateController.listTemplates').default;

        const el = createComponent({
            statuses: [],
            initialStatusKey: '',
            targetObject: 'Opportunity'
        });
        await flushPromises();

        listTemplates.mockResolvedValueOnce([
            {
                templateKey: 'Basic_Approval',
                displayName: 'Basic Approval',
                description: 'Open → Approved / Rejected',
                statusesJson: JSON.stringify([
                    { key: 'Open', label: 'Open', order: 0, category: 'open', isInitial: true },
                    { key: 'Approved', label: 'Approved', order: 1, category: 'terminal_success' },
                    { key: 'Rejected', label: 'Rejected', order: 2, category: 'terminal_failure' }
                ])
            },
            {
                templateKey: 'Email_Send',
                displayName: 'Email Send',
                description: '',
                statusesJson: JSON.stringify([
                    { key: 'Draft', label: 'Draft', category: 'open', isInitial: true }
                ])
            },
            {
                templateKey: 'Task',
                displayName: 'Task',
                description: '',
                statusesJson: JSON.stringify([
                    { key: 'Open', label: 'Open', category: 'open', isInitial: true }
                ])
            },
            {
                templateKey: 'Field_Capture',
                displayName: 'Field Capture',
                description: '',
                statusesJson: JSON.stringify([
                    { key: 'Open', label: 'Open', category: 'open', isInitial: true }
                ])
            }
        ]);

        // Open picker
        const importBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Import template');
        importBtn.click();
        // listTemplates promise + internal re-render
        await flushPromises();
        await flushPromises();

        const items = el.shadowRoot.querySelectorAll('.ase-template-item');
        expect(items.length).toBe(4);

        // Click Basic_Approval. With no existing statuses, the template is
        // applied immediately (no confirm step).
        const handler = jest.fn();
        el.addEventListener('change', handler);
        items[0].click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const detail = handler.mock.calls[handler.mock.calls.length - 1][0].detail;
        expect(detail.statuses.length).toBe(3);
        expect(detail.statuses.map((s) => s.key)).toEqual([
            'Open', 'Approved', 'Rejected'
        ]);
        expect(detail.initialStatusKey).toBe('Open');
    });

    it('shows a confirm step when importing over existing statuses', async () => {
        const listTemplates = require('@salesforce/apex/PulseActionStatusTemplateController.listTemplates').default;

        const el = createComponent({
            statuses: FIVE_STATUSES,
            initialStatusKey: 'Drafting',
            targetObject: 'Opportunity'
        });
        await flushPromises();
        // Flush nested condition-builder describeObjectFields calls that
        // share the jest-mocks/apex.js shared jest.fn so our prime isn't
        // eaten by them.
        await flushPromises();

        listTemplates.mockResolvedValueOnce([
            {
                templateKey: 'Basic_Approval',
                displayName: 'Basic Approval',
                description: '',
                statusesJson: JSON.stringify([
                    { key: 'Open', label: 'Open', category: 'open', isInitial: true },
                    { key: 'Approved', label: 'Approved', category: 'terminal_success' },
                    { key: 'Rejected', label: 'Rejected', category: 'terminal_failure' }
                ])
            }
        ]);

        const importBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Import template');
        importBtn.click();
        await flushPromises();
        await flushPromises();

        const items = el.shadowRoot.querySelectorAll('.ase-template-item');
        expect(items.length).toBe(1);
        items[0].click();
        await flushPromises();

        const confirm = el.shadowRoot.querySelector('.ase-import-confirm');
        expect(confirm).not.toBeNull();

        const handler = jest.fn();
        el.addEventListener('change', handler);
        const replaceBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Replace');
        replaceBtn.click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const detail = handler.mock.calls[handler.mock.calls.length - 1][0].detail;
        expect(detail.statuses.length).toBe(3);
    });
});

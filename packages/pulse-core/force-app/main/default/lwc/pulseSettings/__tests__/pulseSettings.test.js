import { createElement } from 'lwc';
import PulseSettings from 'c/pulseSettings';
import getSettings from '@salesforce/apex/PulseAdminConfigController.getSettings';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseAdminConfigController.getSettings',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const MOCK_CONFIG = {
    featureFlags: [
        {
            developerName: 'Enable_AI',
            featureKey: 'enable_ai',
            enabled: true,
            description: 'Enable AI features',
        },
    ],
    pulsePermissionSets: [
        {
            developerName: 'Pulse_Admin',
            label: 'Pulse Admin',
            assignedToCurrentUser: true,
        },
        {
            developerName: 'Pulse_User',
            label: 'Pulse User',
            assignedToCurrentUser: false,
        },
    ],
    recentDeployments: [
        {
            deploymentRequestId: 'a0Fxx0000000001',
            targetObject: 'Contact',
            status: 'Completed',
            completedDate: '2026-04-20T10:00:00.000Z',
            errorMessage: null,
        },
        {
            deploymentRequestId: 'a0Fxx0000000002',
            targetObject: 'Account',
            status: 'Failed',
            completedDate: '2026-04-19T08:00:00.000Z',
            errorMessage: 'Missing required field',
        },
    ],
};

function createComponent() {
    const el = createElement('c-pulse-settings', { is: PulseSettings });
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

describe('c-pulse-settings', () => {
    it('renders empty state for all sections when no data exists', async () => {
        getSettings.mockResolvedValue({
            featureFlags: [],
            pulsePermissionSets: [],
            recentDeployments: [],
        });
        const el = createComponent();
        await flushPromises();

        const empties = el.shadowRoot.querySelectorAll('.empty-state');
        expect(empties.length).toBe(3);
        expect(empties[0].textContent).toContain('No feature flags');
        expect(empties[1].textContent).toContain('No Pulse permission sets');
        expect(empties[2].textContent).toContain('No deployment history');
    });

    it('renders populated rows for each section', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const names = el.shadowRoot.querySelectorAll('.item-name');
        expect(names.length).toBe(5); // 1 flag + 2 PS + 2 deployments
        expect(names[0].textContent).toBe('enable_ai');
        expect(names[1].textContent).toBe('Pulse Admin');
        expect(names[2].textContent).toBe('Pulse User');
        expect(names[3].textContent).toBe('Contact');
        expect(names[4].textContent).toBe('Account');
    });

    it('renders section headings', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const headings = el.shadowRoot.querySelectorAll('.section-title');
        expect(headings.length).toBe(3);
        expect(headings[0].textContent).toBe('Feature flags');
        expect(headings[1].textContent).toBe('Pulse permission sets');
        expect(headings[2].textContent).toBe('Recent deployments');
    });

    it('renders Setup links with target _blank', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const links = el.shadowRoot.querySelectorAll('.setup-link');
        expect(links.length).toBe(2); // Feature flags + Permission sets (deployments has no link)
        links.forEach((link) => {
            expect(link.target).toBe('_blank');
            expect(link.rel).toContain('noopener');
        });
    });

    it('shows "Assigned to you" badge for assigned permission set', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const badges = el.shadowRoot.querySelectorAll('c-pulse-badge');
        const assignedBadge = Array.from(badges).find(
            (b) => b.label === 'Assigned to you'
        );
        expect(assignedBadge).not.toBeUndefined();
        expect(assignedBadge.variant).toBe('success');
    });

    it('shows "Not assigned" text for unassigned permission set', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const mutedTexts = el.shadowRoot.querySelectorAll('.item-muted-text');
        const notAssigned = Array.from(mutedTexts).find(
            (t) => t.textContent === 'Not assigned'
        );
        expect(notAssigned).not.toBeUndefined();
    });

    it('shows error message for failed deployments', async () => {
        getSettings.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const errors = el.shadowRoot.querySelectorAll('.item-error');
        expect(errors.length).toBe(1);
        expect(errors[0].textContent).toBe('Missing required field');
    });
});

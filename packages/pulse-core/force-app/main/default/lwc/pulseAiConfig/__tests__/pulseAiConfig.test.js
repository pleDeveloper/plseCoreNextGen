import { createElement } from 'lwc';
import PulseAiConfig from 'c/pulseAiConfig';
import getAiConfig from '@salesforce/apex/PulseAdminConfigController.getAiConfig';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseAdminConfigController.getAiConfig',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const MOCK_CONFIG = {
    providers: [
        {
            developerName: 'Anthropic_Claude',
            providerName: 'Anthropic',
            modelId: 'claude-sonnet-4-20250514',
            namedCredential: 'Anthropic_API',
            priority: 1,
            active: true,
        },
    ],
    tools: [
        {
            developerName: 'Send_Email',
            toolKey: 'send_email',
            apexClass: 'EmailToolHandler',
            defaultHitlPolicy: 'Approval_Required',
            active: true,
        },
    ],
    extractionProfiles: [
        {
            developerName: 'Contact_Extract',
            profileKey: 'contact_extract',
            medium: 'email',
            schemaSize: 256,
        },
    ],
};

function createComponent() {
    const el = createElement('c-pulse-ai-config', { is: PulseAiConfig });
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

describe('c-pulse-ai-config', () => {
    it('renders empty state for all sections when no data exists', async () => {
        getAiConfig.mockResolvedValue({
            providers: [],
            tools: [],
            extractionProfiles: [],
        });
        const el = createComponent();
        await flushPromises();

        const empties = el.shadowRoot.querySelectorAll('.empty-state');
        expect(empties.length).toBe(3);
        expect(empties[0].textContent).toContain('No AI providers');
        expect(empties[1].textContent).toContain('No tools registered');
        expect(empties[2].textContent).toContain('No extraction profiles');
    });

    it('renders populated provider, tool, and profile rows', async () => {
        getAiConfig.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const names = el.shadowRoot.querySelectorAll('.item-name');
        expect(names.length).toBe(3);
        expect(names[0].textContent).toBe('Anthropic');
        expect(names[1].textContent).toBe('send_email');
        expect(names[2].textContent).toBe('contact_extract');
    });

    it('renders section headings', async () => {
        getAiConfig.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const headings = el.shadowRoot.querySelectorAll('.section-title');
        expect(headings.length).toBe(3);
        expect(headings[0].textContent).toBe('AI providers');
        expect(headings[1].textContent).toBe('Tool registrations');
        expect(headings[2].textContent).toBe('Extraction profiles');
    });

    it('renders Setup links with target _blank', async () => {
        getAiConfig.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const links = el.shadowRoot.querySelectorAll('.setup-link');
        expect(links.length).toBe(3);
        links.forEach((link) => {
            expect(link.target).toBe('_blank');
            expect(link.rel).toContain('noopener');
        });
    });
});

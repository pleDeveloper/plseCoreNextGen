import { createElement } from 'lwc';
import PulseIntegrationsHub from 'c/pulseIntegrationsHub';
import getIntegrationsHub from '@salesforce/apex/PulseAdminConfigController.getIntegrationsHub';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseAdminConfigController.getIntegrationsHub',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const MOCK_CONFIG = {
    namedCredentials: [
        {
            developerName: 'Anthropic_API',
            label: 'Anthropic API',
            endpoint: 'https://api.anthropic.com/v1/messages',
            principalType: 'NamedUser',
        },
    ],
    channelAdapters: [
        {
            developerName: 'Slack_Adapter',
            channelKey: 'slack',
            adapterClass: 'SlackInboundAdapter',
            active: true,
        },
    ],
    conversationSources: [
        {
            developerName: 'Email_Source',
            sourceKey: 'email',
            adapterClass: 'EmailIngestAdapter',
            active: true,
        },
    ],
};

function createComponent() {
    const el = createElement('c-pulse-integrations-hub', { is: PulseIntegrationsHub });
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

describe('c-pulse-integrations-hub', () => {
    it('renders empty state for all sections when no data exists', async () => {
        getIntegrationsHub.mockResolvedValue({
            namedCredentials: [],
            channelAdapters: [],
            conversationSources: [],
        });
        const el = createComponent();
        await flushPromises();

        const empties = el.shadowRoot.querySelectorAll('.empty-state');
        expect(empties.length).toBe(3);
        expect(empties[0].textContent).toContain('No named credentials');
        expect(empties[1].textContent).toContain('No channel adapters');
        expect(empties[2].textContent).toContain('No conversation sources');
    });

    it('renders populated rows for each section', async () => {
        getIntegrationsHub.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const names = el.shadowRoot.querySelectorAll('.item-name');
        expect(names.length).toBe(3);
        expect(names[0].textContent).toBe('Anthropic API');
        expect(names[1].textContent).toBe('slack');
        expect(names[2].textContent).toBe('email');
    });

    it('renders section headings', async () => {
        getIntegrationsHub.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const headings = el.shadowRoot.querySelectorAll('.section-title');
        expect(headings.length).toBe(3);
        expect(headings[0].textContent).toBe('Named credentials');
        expect(headings[1].textContent).toBe('Channel adapters');
        expect(headings[2].textContent).toBe('Conversation sources');
    });

    it('renders Setup links with target _blank', async () => {
        getIntegrationsHub.mockResolvedValue(MOCK_CONFIG);
        const el = createComponent();
        await flushPromises();

        const links = el.shadowRoot.querySelectorAll('.setup-link');
        expect(links.length).toBe(3);
        links.forEach((link) => {
            expect(link.target).toBe('_blank');
            expect(link.rel).toContain('noopener');
        });
    });

    it('truncates long endpoint URLs', async () => {
        getIntegrationsHub.mockResolvedValue({
            ...MOCK_CONFIG,
            namedCredentials: [
                {
                    developerName: 'Long_URL',
                    label: 'Long URL Service',
                    endpoint: 'https://very-long-api-endpoint.example.com/v1/resource/path',
                    principalType: 'NamedUser',
                },
            ],
        });
        const el = createComponent();
        await flushPromises();

        const muted = el.shadowRoot.querySelector('.item-muted');
        expect(muted.textContent.length).toBeLessThanOrEqual(41); // 40 + ellipsis
    });
});

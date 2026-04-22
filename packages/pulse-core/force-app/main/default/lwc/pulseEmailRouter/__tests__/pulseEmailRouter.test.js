import { createElement } from 'lwc';
import PulseEmailRouter from 'c/pulseEmailRouter';
import listUnroutedEmails from '@salesforce/apex/PulseEmailRouterController.listUnroutedEmails';
import listRoutingRules from '@salesforce/apex/PulseEmailRouterController.listRoutingRules';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseEmailRouterController.listUnroutedEmails',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.listRoutingRules',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.routeToExistingRecord',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.createOpportunityFromConversation',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

function createComponent() {
    const el = createElement('c-pulse-email-router', { is: PulseEmailRouter });
    document.body.appendChild(el);
    return el;
}

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

// Some handlers kick off two sequential awaits; run the flush twice so both settle.
async function settle() {
    await flushPromises();
    await flushPromises();
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('c-pulse-email-router', () => {
    it('renders the heading even before data loads', () => {
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([]);
        const el = createComponent();
        const title = el.shadowRoot.querySelector('.router-title');
        expect(title).not.toBeNull();
        expect(title.textContent).toBe('Email routing');
    });

    it('renders empty state when no unrouted emails and no rules', async () => {
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([]);
        const el = createComponent();
        await settle();

        const empties = el.shadowRoot.querySelectorAll('.router-empty');
        expect(empties.length).toBe(2);
        const countLabel = el.shadowRoot.querySelector('.router-panel-sub');
        expect(countLabel.textContent).toContain('No unrouted emails');
    });

    it('renders unrouted email cards when data returns', async () => {
        // Note: all @salesforce/apex/* imports share the same mock module in
        // sfdx-lwc-jest, so we use mockImplementation once and branch on call
        // order. listUnroutedEmails is awaited first in connectedCallback →
        // _refreshEmails; listRoutingRules follows.
        let call = 0;
        const impl = () => {
            call += 1;
            if (call === 1) {
                return Promise.resolve([
                    {
                        conversationId: 'a06000000000001AAA',
                        subject: 'Looking for space',
                        senderEmail: 'prospect@example.com',
                        participants: 'Prospect; prospect@example.com',
                        snippet: 'Hi, we are hunting for 5000 sq ft.',
                        ingestedAt: '2026-04-01T10:00:00Z',
                    },
                ]);
            }
            return Promise.resolve([]);
        };
        listUnroutedEmails.mockImplementation(impl);
        listRoutingRules.mockImplementation(impl);

        const el = createComponent();
        await settle();

        const cards = el.shadowRoot.querySelectorAll('.router-email-card');
        expect(cards.length).toBe(1);
        expect(cards[0].querySelector('.router-email-from').textContent)
            .toBe('prospect@example.com');
        expect(cards[0].querySelector('.router-email-subject').textContent)
            .toBe('Looking for space');
    });

    it('renders routing rule cards when rules return', async () => {
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([
            {
                developerName: 'Default_Email_To_Opportunity',
                ruleKey: 'default_email_to_opportunity',
                active: true,
                priority: 100,
                sourceAdapter: 'email',
                matchStrategy: 'EMAIL_SENDER_TO_CONTACT',
                targetObject: 'Opportunity',
                createDefaultsJson: '{}',
                triggerWorkflowKey: 'real_estate_leasing_v1',
            },
        ]);

        const el = createComponent();
        await settle();

        const ruleCards = el.shadowRoot.querySelectorAll('.router-rule-card');
        expect(ruleCards.length).toBe(1);
        expect(ruleCards[0].querySelector('.router-rule-title').textContent)
            .toBe('Default_Email_To_Opportunity');
        const status = ruleCards[0].querySelector('.rule-status');
        expect(status.classList.contains('rule-status-on')).toBe(true);
        expect(status.textContent).toBe('Active');
    });
});

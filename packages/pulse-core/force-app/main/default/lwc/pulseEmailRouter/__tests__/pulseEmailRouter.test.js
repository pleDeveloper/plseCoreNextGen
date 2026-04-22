import { createElement } from 'lwc';
import PulseEmailRouter from 'c/pulseEmailRouter';
import listUnroutedEmails from '@salesforce/apex/PulseEmailRouterController.listUnroutedEmails';
import listRoutingRules from '@salesforce/apex/PulseEmailRouterController.listRoutingRules';
import upsertRoutingRule from '@salesforce/apex/PulseEmailRouterController.upsertRoutingRule';
import deleteRoutingRule from '@salesforce/apex/PulseEmailRouterController.deleteRoutingRule';
import getDeployStatus from '@salesforce/apex/PulseEmailRouterController.getDeployStatus';

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
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.upsertRoutingRule',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.deleteRoutingRule',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseEmailRouterController.getDeployStatus',
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

    it('opens the editor modal when Add rule is clicked', async () => {
        // In sfdx-lwc-jest, every @salesforce/apex/* import aliases the
        // same jest.fn() — so we must share an implementation and branch on
        // call order rather than using per-import mockResolvedValue.
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([]);

        const el = createComponent();
        await settle();

        // Modal closed by default.
        let modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal).not.toBeNull();
        expect(modal.open).toBe(false);

        const addBtn = el.shadowRoot.querySelector('[data-testid="add-rule"]');
        expect(addBtn).not.toBeNull();
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);
        expect(modal.title).toBe('Add routing rule');
    });

    it('pre-populates the editor when Edit is clicked on an existing rule', async () => {
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([
            {
                developerName: 'Existing_Rule',
                ruleKey: 'existing_rule',
                active: true,
                priority: 42,
                sourceAdapter: 'inbound_email',
                matchStrategy: 'EMAIL_SENDER_TO_CONTACT',
                targetObject: 'Opportunity',
                createDefaultsJson: '{"StageName":"Qualification"}',
                triggerWorkflowKey: 'my_workflow',
            },
        ]);

        const el = createComponent();
        await settle();

        const editBtn = el.shadowRoot.querySelector('[data-testid="edit-rule"]');
        expect(editBtn).not.toBeNull();
        editBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        const modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);
        expect(modal.title).toBe('Edit routing rule');

        const inputs = el.shadowRoot.querySelectorAll('c-pulse-input');
        const byField = {};
        inputs.forEach((i) => {
            const f = i.dataset.field;
            if (f) byField[f] = i;
        });
        expect(byField.ruleKey.value).toBe('existing_rule');
        expect(byField.priority.value).toBe(42);
        expect(byField.matchStrategy.value).toBe('EMAIL_SENDER_TO_CONTACT');
        expect(byField.targetObject.value).toBe('Opportunity');
        expect(byField.triggerWorkflowKey.value).toBe('my_workflow');
    });

    it('calls upsertRoutingRule when Save is clicked and then refreshes', async () => {
        // All @salesforce/apex/* imports alias the same jest.fn() in
        // sfdx-lwc-jest. Use mockImplementation with call-order branching:
        //   1: listUnroutedEmails  → []
        //   2: listRoutingRules    → []
        //   3: upsertRoutingRule   → { success:true, jobId, developerName }
        //   4: getDeployStatus     → { done:true, status:'Completed' }
        //   5: listRoutingRules    → [] (post-save refresh)
        let call = 0;
        const sharedMock = () => {
            call += 1;
            if (call === 3) {
                return Promise.resolve({
                    success: true,
                    jobId: '707000000000000AAA',
                    developerName: 'New_Rule',
                });
            }
            if (call === 4) {
                return Promise.resolve({ status: 'Completed', done: true });
            }
            return Promise.resolve([]);
        };
        listUnroutedEmails.mockImplementation(sharedMock);
        listRoutingRules.mockImplementation(sharedMock);
        upsertRoutingRule.mockImplementation(sharedMock);
        getDeployStatus.mockImplementation(sharedMock);

        const el = createComponent();
        await settle();

        // Open the editor.
        const addBtn = el.shadowRoot.querySelector('[data-testid="add-rule"]');
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        // Populate required fields via change events on the pulse-input stubs.
        const inputs = el.shadowRoot.querySelectorAll('c-pulse-input');
        const byField = {};
        inputs.forEach((i) => {
            const f = i.dataset.field;
            if (f) byField[f] = i;
        });
        byField.ruleKey.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'new_rule' } })
        );
        byField.matchStrategy.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'EMAIL_SENDER_TO_CONTACT' } })
        );
        byField.targetObject.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'Opportunity' } })
        );
        await settle();

        const saveBtn = el.shadowRoot.querySelector('[data-testid="save-rule"]');
        expect(saveBtn).not.toBeNull();
        saveBtn.dispatchEvent(new CustomEvent('click'));
        await settle();
        await settle();

        // All @salesforce/apex/* imports share a single jest.fn in
        // sfdx-lwc-jest. Find the call whose payload matches the upsert
        // shape rather than asserting call count.
        const upsertCall = upsertRoutingRule.mock.calls.find(
            (c) => c[0] && c[0].payload && c[0].payload.ruleKey
        );
        expect(upsertCall).toBeDefined();
        expect(upsertCall[0].payload.ruleKey).toBe('new_rule');
        expect(upsertCall[0].payload.matchStrategy).toBe('EMAIL_SENDER_TO_CONTACT');
        expect(upsertCall[0].payload.targetObject).toBe('Opportunity');
    });

    it('closes the editor modal when cancel fires', async () => {
        listUnroutedEmails.mockResolvedValue([]);
        listRoutingRules.mockResolvedValue([]);

        const el = createComponent();
        await settle();

        const addBtn = el.shadowRoot.querySelector('[data-testid="add-rule"]');
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        let modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);

        modal.dispatchEvent(new CustomEvent('close'));
        await settle();

        modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(false);
    });

    it('opens the delete confirmation modal and calls deleteRoutingRule', async () => {
        // Shared jest.fn() across @salesforce/apex/* imports — branch on call order:
        //   1: listUnroutedEmails  → []
        //   2: listRoutingRules    → [one rule]
        //   3: deleteRoutingRule   → { success:true, jobId, developerName }
        //   4: getDeployStatus     → { done:true }
        //   5: listRoutingRules    → [] (post-delete refresh)
        const rule = {
            developerName: 'Doomed_Rule',
            ruleKey: 'doomed',
            active: true,
            priority: 10,
            sourceAdapter: 'inbound_email',
            matchStrategy: 'EMAIL_SENDER_TO_CONTACT',
            targetObject: 'Opportunity',
            createDefaultsJson: '{}',
            triggerWorkflowKey: null,
        };
        let call = 0;
        const sharedMock = () => {
            call += 1;
            if (call === 2) return Promise.resolve([rule]);
            if (call === 3) {
                return Promise.resolve({
                    success: true,
                    jobId: '707000000000000AAA',
                    developerName: 'Doomed_Rule',
                });
            }
            if (call === 4) return Promise.resolve({ status: 'Completed', done: true });
            return Promise.resolve([]);
        };
        listUnroutedEmails.mockImplementation(sharedMock);
        listRoutingRules.mockImplementation(sharedMock);
        deleteRoutingRule.mockImplementation(sharedMock);
        getDeployStatus.mockImplementation(sharedMock);

        const el = createComponent();
        await settle();

        const deleteBtn = el.shadowRoot.querySelector('[data-testid="delete-rule"]');
        expect(deleteBtn).not.toBeNull();
        deleteBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        const confirmBtn = el.shadowRoot.querySelector('[data-testid="confirm-delete"]');
        expect(confirmBtn).not.toBeNull();
        confirmBtn.dispatchEvent(new CustomEvent('click'));
        await settle();
        await settle();

        // Shared jest.fn — find the call whose arg matches the delete shape.
        const deleteCall = deleteRoutingRule.mock.calls.find(
            (c) => c[0] && c[0].developerName === 'Doomed_Rule'
        );
        expect(deleteCall).toBeDefined();
    });
});

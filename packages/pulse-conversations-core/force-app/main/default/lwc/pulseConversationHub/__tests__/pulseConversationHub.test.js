import { createElement } from 'lwc';
import PulseConversationHub from 'c/pulseConversationHub';
import getConversationsForRecord from '@salesforce/apex/PulseConversationHubController.getConversationsForRecord';
import acceptExtract from '@salesforce/apex/PulseConversationHubController.acceptExtract';
import rejectExtract from '@salesforce/apex/PulseConversationHubController.rejectExtract';
import requestReextraction from '@salesforce/apex/PulseConversationHubController.requestReextraction';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const MOCK_CONVERSATIONS = [
    {
        conversationId: 'a0Cxx0000000001',
        medium: 'Email',
        subject: 'Patient referral follow-up',
        summary: 'Discussed referral details.',
        participants: 'Dr. Smith; Nurse Jones',
        occurredAt: '2026-04-20T14:00:00.000Z',
        status: 'Extracted',
        turns: [
            {
                turnId: 'a0Dxx0000000001',
                turnIndex: 0,
                role: 'Agent',
                speaker: 'Dr. Smith',
                content: 'Please review the referral.',
                timestamp: '2026-04-20T14:00:00.000Z',
            },
            {
                turnId: 'a0Dxx0000000002',
                turnIndex: 1,
                role: 'Customer',
                speaker: 'Nurse Jones',
                content: 'Referral received.',
                timestamp: '2026-04-20T14:05:00.000Z',
            },
        ],
        extracts: [
            {
                extractId: 'a0Exx0000000001',
                profileKey: 'email_default',
                status: 'Pending',
                facts: {
                    contact_name: 'Alice Smith',
                    company: 'Acme Corp',
                },
                confidence: {
                    contact_name: 0.92,
                    company: 0.45,
                },
                sourceRefsJson: '[]',
                reviewedByUserId: null,
                reviewedDate: null,
            },
        ],
    },
];

function createComponent(props = {}) {
    const el = createElement('c-pulse-conversation-hub', {
        is: PulseConversationHub,
    });
    Object.assign(el, { recordId: '001xx000000test', ...props });
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

describe('c-pulse-conversation-hub', () => {
    it('renders empty state when no conversations', async () => {
        getConversationsForRecord.mockResolvedValue([]);
        const el = createComponent();
        await flushPromises();

        const empty = el.shadowRoot.querySelector('.hub-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toBe('No conversations yet.');
    });

    it('renders no-context message when neither recordId nor instanceId', async () => {
        const el = createComponent({ recordId: null, instanceId: null });
        await flushPromises();

        const empty = el.shadowRoot.querySelector('.hub-empty');
        expect(empty).not.toBeNull();
        expect(empty.textContent).toBe('No workflow instance selected.');
    });

    it('renders conversation cards when data is returned', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        const heading = el.shadowRoot.querySelector('.hub-heading');
        expect(heading).not.toBeNull();
        expect(heading.textContent).toBe('Conversations');

        const cards = el.shadowRoot.querySelectorAll('.conv-card');
        expect(cards.length).toBe(1);

        const subject = el.shadowRoot.querySelector('.conv-subject');
        expect(subject.textContent).toBe('Patient referral follow-up');
    });

    it('expands conversation on header click and shows turns', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        const header = el.shadowRoot.querySelector('.conv-header');
        header.click();
        await flushPromises();

        const turns = el.shadowRoot.querySelectorAll('.turn-row');
        expect(turns.length).toBe(2);

        const speaker = el.shadowRoot.querySelector('.turn-speaker');
        expect(speaker.textContent).toBe('Dr. Smith');

        const content = el.shadowRoot.querySelector('.turn-content');
        expect(content.textContent).toBe('Please review the referral.');
    });

    it('shows extract panel with fact rows on expand', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        // Expand conversation first
        el.shadowRoot.querySelector('.conv-header').click();
        await flushPromises();

        // Expand extract
        const extHeader = el.shadowRoot.querySelector('.extract-header');
        extHeader.click();
        await flushPromises();

        const factRows = el.shadowRoot.querySelectorAll('.fact-row');
        expect(factRows.length).toBe(2);

        const keys = el.shadowRoot.querySelectorAll('.fact-key');
        const keyTexts = Array.from(keys).map((k) => k.textContent);
        expect(keyTexts).toContain('contact_name');
        expect(keyTexts).toContain('company');
    });

    it('selecting facts and clicking Accept calls acceptExtract', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        // Expand conversation + extract
        el.shadowRoot.querySelector('.conv-header').click();
        await flushPromises();
        el.shadowRoot.querySelector('.extract-header').click();
        await flushPromises();

        // Toggle a fact checkbox
        const checkboxes = el.shadowRoot.querySelectorAll('.fact-check');
        expect(checkboxes.length).toBeGreaterThan(0);
        checkboxes[0].click();
        await flushPromises();

        // Click Accept
        jest.spyOn(window, 'alert').mockImplementation(() => {});
        acceptExtract.mockResolvedValue({
            success: true,
            fieldsProjected: 1,
            errors: [],
        });
        getConversationsForRecord.mockResolvedValue([]);

        const acceptBtn = findButtonByLabel(
            el.shadowRoot.querySelector('.extract-actions'),
            'Accept selected'
        );
        expect(acceptBtn).not.toBeUndefined();
        acceptBtn.click();
        await flushPromises();

        expect(acceptExtract).toHaveBeenCalledWith(
            expect.objectContaining({
                extractId: 'a0Exx0000000001',
                acceptedFieldKeys: ['contact_name'],
                targetObjectApiName: 'Account',
            })
        );
        expect(window.alert).toHaveBeenCalledWith(
            expect.stringContaining('1 field(s) projected')
        );
    });

    it('clicking Reject calls rejectExtract', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        el.shadowRoot.querySelector('.conv-header').click();
        await flushPromises();
        el.shadowRoot.querySelector('.extract-header').click();
        await flushPromises();

        jest.spyOn(window, 'alert').mockImplementation(() => {});
        rejectExtract.mockResolvedValue({ success: true, fieldsProjected: 0, errors: [] });
        getConversationsForRecord.mockResolvedValue([]);

        const rejectBtn = findButtonByLabel(
            el.shadowRoot.querySelector('.extract-actions'),
            'Reject'
        );
        expect(rejectBtn).not.toBeUndefined();
        rejectBtn.click();
        await flushPromises();

        expect(rejectExtract).toHaveBeenCalledWith(
            expect.objectContaining({ extractId: 'a0Exx0000000001' })
        );
        expect(window.alert).toHaveBeenCalledWith('Extract rejected.');
    });

    it('Request re-extraction calls requestReextraction', async () => {
        getConversationsForRecord.mockResolvedValue(MOCK_CONVERSATIONS);
        const el = createComponent();
        await flushPromises();

        el.shadowRoot.querySelector('.conv-header').click();
        await flushPromises();

        jest.spyOn(window, 'alert').mockImplementation(() => {});
        requestReextraction.mockResolvedValue('707xx0000000001');
        getConversationsForRecord.mockResolvedValue([]);

        const reextBtn = findButtonByLabel(el.shadowRoot, 'Request re-extraction');
        expect(reextBtn).not.toBeUndefined();
        reextBtn.click();
        await flushPromises();

        expect(requestReextraction).toHaveBeenCalledWith(
            expect.objectContaining({ conversationId: 'a0Cxx0000000001' })
        );
        expect(window.alert).toHaveBeenCalledWith('Re-extraction queued.');
    });
});

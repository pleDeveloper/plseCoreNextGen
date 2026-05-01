import { createElement } from 'lwc';
import PulseAgentRoleLibrary from 'c/pulseAgentRoleLibrary';
import listRoles from '@salesforce/apex/PulseAgentRoleController.listRoles';
import upsertRole from '@salesforce/apex/PulseAgentRoleController.upsertRole';
import deleteRole from '@salesforce/apex/PulseAgentRoleController.deleteRole';
import getDeployStatus from '@salesforce/apex/PulseAgentRoleController.getDeployStatus';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseAgentRoleController.listRoles',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseAgentRoleController.upsertRole',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseAgentRoleController.deleteRole',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/PulseAgentRoleController.getDeployStatus',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

function createComponent() {
    const el = createElement('c-pulse-agent-role-library', { is: PulseAgentRoleLibrary });
    document.body.appendChild(el);
    return el;
}

function flush() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

async function settle() {
    await flush();
    await flush();
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('c-pulse-agent-role-library', () => {
    it('renders the heading even before data loads', () => {
        listRoles.mockResolvedValue([]);
        const el = createComponent();
        const title = el.shadowRoot.querySelector('.roles-title');
        expect(title).not.toBeNull();
        expect(title.textContent).toBe('Agent role library');
    });

    it('renders empty state when no roles', async () => {
        listRoles.mockResolvedValue([]);
        const el = createComponent();
        await settle();
        const empty = el.shadowRoot.querySelector('.roles-empty');
        expect(empty).not.toBeNull();
    });

    it('renders role cards when data returns', async () => {
        listRoles.mockResolvedValue([
            {
                developerName: 'Lease_Qualifier',
                roleKey: 'lease_qualifier',
                displayName: 'Lease Qualifier',
                description: 'Qualifies leasing inquiries',
                providerName: 'Anthropic_Claude',
                defaultAutonomy: 'Act_With_Approval',
                systemPrompt: 'You are a leasing pro.',
                toolAllowlistJson: '["update_field"]',
                suggestedPhaseTypes: 'ai_driven',
                active: true
            }
        ]);
        const el = createComponent();
        await settle();

        const cards = el.shadowRoot.querySelectorAll('.role-card');
        expect(cards.length).toBe(1);
        expect(cards[0].querySelector('.role-card-title').textContent)
            .toBe('Lease Qualifier');
        const status = cards[0].querySelector('.role-status');
        expect(status.classList.contains('role-status-on')).toBe(true);
    });

    it('opens the editor modal when Add role is clicked', async () => {
        listRoles.mockResolvedValue([]);
        const el = createComponent();
        await settle();

        let modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(false);

        const addBtn = el.shadowRoot.querySelector('[data-testid="add-role"]');
        expect(addBtn).not.toBeNull();
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);
        expect(modal.title).toBe('Add agent role');
    });

    it('pre-populates the editor when Edit is clicked on an existing role', async () => {
        listRoles.mockResolvedValue([
            {
                developerName: 'Existing_Role',
                roleKey: 'existing_role',
                displayName: 'Existing Role',
                description: 'desc',
                providerName: 'Anthropic_Claude',
                defaultAutonomy: 'Propose_Only',
                systemPrompt: 'sp',
                toolAllowlistJson: '["a"]',
                suggestedPhaseTypes: 'ai_driven',
                active: true
            }
        ]);
        const el = createComponent();
        await settle();

        const editBtn = el.shadowRoot.querySelector('[data-testid="edit-role"]');
        expect(editBtn).not.toBeNull();
        editBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        const modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);
        expect(modal.title).toBe('Edit agent role');

        const inputs = el.shadowRoot.querySelectorAll('c-pulse-input');
        const byField = {};
        inputs.forEach((i) => {
            const f = i.dataset.field;
            if (f) byField[f] = i;
        });
        expect(byField.roleKey.value).toBe('existing_role');
        expect(byField.displayName.value).toBe('Existing Role');
        expect(byField.providerName.value).toBe('Anthropic_Claude');
    });

    it('calls upsertRole when Save is clicked', async () => {
        // Shared jest.fn semantics: branch on call order.
        //   1: listRoles → []
        //   2: upsertRole → {success, jobId, developerName}
        //   3: getDeployStatus → {done:true}
        //   4: listRoles → [] (post-save refresh)
        let call = 0;
        const sharedMock = () => {
            call += 1;
            if (call === 2) {
                return Promise.resolve({
                    success: true,
                    jobId: '707000000000000AAA',
                    developerName: 'New_Role'
                });
            }
            if (call === 3) return Promise.resolve({ status: 'Completed', done: true });
            return Promise.resolve([]);
        };
        listRoles.mockImplementation(sharedMock);
        upsertRole.mockImplementation(sharedMock);
        getDeployStatus.mockImplementation(sharedMock);

        const el = createComponent();
        await settle();

        const addBtn = el.shadowRoot.querySelector('[data-testid="add-role"]');
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        const inputs = el.shadowRoot.querySelectorAll('c-pulse-input');
        const byField = {};
        inputs.forEach((i) => {
            const f = i.dataset.field;
            if (f) byField[f] = i;
        });
        byField.roleKey.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'new_role' } })
        );
        byField.displayName.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'New Role' } })
        );
        await settle();

        const saveBtn = el.shadowRoot.querySelector('[data-testid="save-role"]');
        expect(saveBtn).not.toBeNull();
        saveBtn.dispatchEvent(new CustomEvent('click'));
        await settle();
        await settle();

        const upsertCall = upsertRole.mock.calls.find(
            (c) => c[0] && c[0].payload && c[0].payload.roleKey
        );
        expect(upsertCall).toBeDefined();
        expect(upsertCall[0].payload.roleKey).toBe('new_role');
        expect(upsertCall[0].payload.displayName).toBe('New Role');
    });

    it('opens the deactivate confirmation and calls deleteRole', async () => {
        const role = {
            developerName: 'Doomed_Role',
            roleKey: 'doomed',
            displayName: 'Doomed',
            description: '',
            providerName: '',
            defaultAutonomy: 'Act_With_Approval',
            systemPrompt: '',
            toolAllowlistJson: '',
            suggestedPhaseTypes: '',
            active: true
        };
        let call = 0;
        const sharedMock = () => {
            call += 1;
            if (call === 1) return Promise.resolve([role]);
            if (call === 2) {
                return Promise.resolve({
                    success: true,
                    jobId: '707000000000000AAA',
                    developerName: 'Doomed_Role'
                });
            }
            if (call === 3) return Promise.resolve({ status: 'Completed', done: true });
            return Promise.resolve([]);
        };
        listRoles.mockImplementation(sharedMock);
        deleteRole.mockImplementation(sharedMock);
        getDeployStatus.mockImplementation(sharedMock);

        const el = createComponent();
        await settle();

        const deactivateBtn = el.shadowRoot.querySelector('[data-testid="deactivate-role"]');
        expect(deactivateBtn).not.toBeNull();
        deactivateBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        // Confirmation modal must appear (one of the two pulse-modals is open).
        const modals = el.shadowRoot.querySelectorAll('c-pulse-modal');
        const confirmModal = Array.from(modals).find(
            (m) => m.title === 'Deactivate agent role' && m.open === true
        );
        expect(confirmModal).toBeDefined();

        const confirmBtn = el.shadowRoot.querySelector('[data-testid="confirm-deactivate"]');
        expect(confirmBtn).not.toBeNull();
        confirmBtn.dispatchEvent(new CustomEvent('click'));
        await settle();
        await settle();

        const deleteCall = deleteRole.mock.calls.find(
            (c) => c[0] && c[0].developerName === 'Doomed_Role'
        );
        expect(deleteCall).toBeDefined();
    });

    it('closes the editor modal when cancel fires', async () => {
        listRoles.mockResolvedValue([]);
        const el = createComponent();
        await settle();

        const addBtn = el.shadowRoot.querySelector('[data-testid="add-role"]');
        addBtn.dispatchEvent(new CustomEvent('click'));
        await settle();

        let modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(true);

        modal.dispatchEvent(new CustomEvent('close'));
        await settle();

        modal = el.shadowRoot.querySelector('c-pulse-modal');
        expect(modal.open).toBe(false);
    });
});

import { createElement } from 'lwc';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import PulseWorkflowBuilder from 'c/pulseWorkflowBuilder';
import { resetStore, dispatch, getState } from 'c/pulseStore';
import listActiveRoleSummaries from '@salesforce/apex/PulseAgentRoleController.listActiveRoleSummaries';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.saveWorkflow',
    () => ({
        default: jest.fn(() =>
            Promise.resolve({ success: true, recordId: '001xx0000000001', errors: [] })
        )
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.publishWorkflow',
    () => ({
        default: jest.fn(() =>
            Promise.resolve({
                deploymentRequestId: 'a0Fxx001',
                status: 'Queued',
                message: 'Enqueued'
            })
        )
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.listWorkflows',
    () => ({
        default: jest.fn(() => Promise.resolve([]))
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowTriggerController.describeObjectFields',
    () => ({ default: jest.fn(() => Promise.resolve([])) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseActionStatusTemplateController.listTemplates',
    () => ({ default: jest.fn(() => Promise.resolve([])) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseAgentRoleController.listActiveRoleSummaries',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.loadWorkflow',
    () => ({
        default: jest.fn(() =>
            Promise.resolve({
                recordId: 'a05xx0000000001',
                name: 'Test Workflow',
                workflowKey: 'test_wf',
                version: 1,
                status: 'Draft',
                definitionJson: JSON.stringify({
                    schema: 'pulse.workflow.v1',
                    workflowKey: 'test_wf',
                    name: 'Test Workflow',
                    version: 1,
                    subjectKinds: ['Account'],
                    states: [
                        { key: 'intake', label: 'Intake', type: 'form', fields: [], transitions: [] }
                    ]
                }),
                subjectKinds: 'Account'
            })
        )
    }),
    { virtual: true }
);

const agentRolesAdapter = registerApexTestWireAdapter(listActiveRoleSummaries);

const SAMPLE_AGENT_ROLES = [
    {
        developerName: 'Lease_Qualifier',
        roleKey: 'lease_qualifier',
        displayName: 'Lease Qualifier',
        description: 'Qualifies inbound leasing inquiries.',
        providerName: 'Anthropic_Claude',
        defaultAutonomy: 'Act_With_Approval'
    },
    {
        developerName: 'Donor_Matcher',
        roleKey: 'donor_matcher',
        displayName: 'Donor Matcher',
        description: 'Matches nonprofit donors to projects.',
        providerName: 'Anthropic_Claude',
        defaultAutonomy: 'Propose_Only'
    }
];

function createComponent() {
    const el = createElement('c-pulse-workflow-builder', {
        is: PulseWorkflowBuilder
    });
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
    resetStore();
});

describe('c-pulse-workflow-builder', () => {
    it('shows landing view with workflow list when no workflow is open', async () => {
        const el = createComponent();
        await flushPromises();
        const heading = el.shadowRoot.querySelector('.builder-landing-heading');
        expect(heading).not.toBeNull();
        expect(heading.textContent).toBe('Your workflows');
    });

    it('shows create form after clicking New workflow', async () => {
        const el = createComponent();
        await flushPromises();

        const newBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'New workflow');
        expect(newBtn).not.toBeUndefined();
        newBtn.click();
        await flushPromises();

        const heading = el.shadowRoot.querySelector('.builder-create-heading');
        expect(heading).not.toBeNull();
        expect(heading.textContent).toBe('Create a new workflow');
    });

    it('lists existing workflows returned by the controller', async () => {
        const listWorkflows = require('@salesforce/apex/PulseWorkflowBuilderController.listWorkflows').default;
        listWorkflows.mockResolvedValueOnce([
            {
                recordId: 'a05xx0000000001',
                name: 'Real Estate Leasing v1',
                workflowKey: 'real_estate_leasing_v1',
                version: 1,
                status: 'Published',
                subjectKinds: 'Opportunity'
            }
        ]);
        const el = createComponent();
        await flushPromises();

        const items = el.shadowRoot.querySelectorAll('.builder-landing-item');
        expect(items.length).toBe(1);
        const name = items[0].querySelector('.builder-landing-item-name');
        expect(name.textContent).toBe('Real Estate Leasing v1');
    });

    it('loads existing workflow into editor when clicked', async () => {
        const listWorkflows = require('@salesforce/apex/PulseWorkflowBuilderController.listWorkflows').default;
        listWorkflows.mockResolvedValueOnce([
            {
                recordId: 'a05xx0000000001',
                name: 'Test Workflow',
                workflowKey: 'test_wf',
                version: 1,
                status: 'Draft',
                subjectKinds: 'Account'
            }
        ]);
        const el = createComponent();
        await flushPromises();

        const item = el.shadowRoot.querySelector('.builder-landing-item');
        expect(item).not.toBeNull();
        item.click();
        await flushPromises();
        await flushPromises();

        const body = el.shadowRoot.querySelector('.builder-body');
        expect(body).not.toBeNull();
    });

    it('transitions to editor after dispatching workflow meta', async () => {
        const el = createComponent();
        // Dispatch AFTER component mounts (it resets in connectedCallback)
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            name: 'Test Workflow',
            subjectKinds: ['Account']
        });
        await flushPromises();

        const body = el.shadowRoot.querySelector('.builder-body');
        expect(body).not.toBeNull();
        const createForm = el.shadowRoot.querySelector('.builder-create-heading');
        expect(createForm).toBeNull();
    });

    it('renders state graph when states exist', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf'
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        await flushPromises();

        const graph = el.shadowRoot.querySelector('c-pulse-state-graph');
        expect(graph).not.toBeNull();
    });

    it('shows live preview when no state is selected', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf'
        });
        // No SELECT_STATE — selection stays null
        await flushPromises();

        const preview = el.shadowRoot.querySelector('c-pulse-live-preview');
        expect(preview).not.toBeNull();
    });

    it('shows state inspector when a state is selected', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf'
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        // ADD_STATE auto-selects, so SELECT_STATE is already set to 'intake'
        await flushPromises();

        const inspector = el.shadowRoot.querySelector(
            '.builder-state-inspector'
        );
        expect(inspector).not.toBeNull();
    });

    it('renders the deploy dialog as closed by default', () => {
        const el = createComponent();
        const dialog = el.shadowRoot.querySelector(
            'c-pulse-deploy-dialog'
        );
        expect(dialog).not.toBeNull();
        expect(dialog.open).toBe(false);
    });

    it('shows Phase settings toggle in state inspector', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        await flushPromises();

        const settingsHeader = Array.from(
            el.shadowRoot.querySelectorAll('.builder-phase-settings .builder-section-title')
        ).find((h) => h.textContent === 'Phase settings');
        expect(settingsHeader).not.toBeUndefined();
    });

    it('expands phase settings drawer to show condition builders and progression dropdown', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        await flushPromises();

        const toggleBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Phase settings');
        expect(toggleBtn).not.toBeUndefined();
        toggleBtn.click();
        await flushPromises();

        const builders = el.shadowRoot.querySelectorAll('c-pulse-condition-builder');
        expect(builders.length).toBeGreaterThanOrEqual(2);

        const progressionSelect = el.shadowRoot.querySelector('.builder-phase-select');
        expect(progressionSelect).not.toBeNull();
    });

    it('persists entry conditions into the workflow state', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        dispatch({
            type: 'UPDATE_STATE_ENTRY_CONDITIONS',
            stateKey: 'intake',
            tree: {
                logic: 'AND',
                rules: [{ field: 'Industry', op: 'EQUALS', value: 'Biotechnology' }]
            }
        });
        await flushPromises();

        const state = getState();
        const intake = state.workflow.states.find((s) => s.key === 'intake');
        expect(intake.entryConditions).toEqual({
            logic: 'AND',
            rules: [{ field: 'Industry', op: 'EQUALS', value: 'Biotechnology' }]
        });
    });

    it('dirty indicator reflects progression mode change', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'intake',
            label: 'Intake'
        });
        dispatch({
            type: 'UPDATE_STATE_PROGRESSION',
            stateKey: 'intake',
            progression: { mode: 'field_change', rule: { field: 'StageName', equals: 'Won' } }
        });
        await flushPromises();

        const state = getState();
        const intake = state.workflow.states.find((s) => s.key === 'intake');
        expect(intake.progression.mode).toBe('field_change');
        expect(state.ui.dirty).toBe(true);
    });

    it('mounts the action status editor when an action is selected', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'phase1',
            label: 'Phase 1'
        });
        // Seed the phase with an action + statuses via LOAD_WORKFLOW so the
        // builder has an action to pick (ADD_STATE doesn't create actions).
        dispatch({
            type: 'LOAD_WORKFLOW',
            workflow: {
                schema: 'pulse.workflow.v1',
                workflowKey: 'test_wf',
                name: 'test',
                version: 1,
                subjectKinds: ['Account'],
                states: [
                    {
                        key: 'phase1',
                        label: 'Phase 1',
                        type: 'ai_driven',
                        fields: [],
                        transitions: [],
                        actions: [
                            {
                                key: 'send_followup_email',
                                label: 'Send follow-up email',
                                type: 'ai_tool',
                                statuses: [
                                    { key: 'Drafting', label: 'Drafting', order: 0, category: 'open', isInitial: true }
                                ],
                                initialStatusKey: 'Drafting'
                            }
                        ]
                    }
                ]
            }
        });
        dispatch({ type: 'SELECT_STATE', stateKey: 'phase1' });
        await flushPromises();

        // Click the action list item to select the action.
        const actionItem = el.shadowRoot.querySelector('.builder-action-item');
        expect(actionItem).not.toBeNull();
        actionItem.click();
        await flushPromises();

        const editor = el.shadowRoot.querySelector('c-pulse-action-status-editor');
        expect(editor).not.toBeNull();
    });

    it('shows dirty indicator when store is dirty', async () => {
        const el = createComponent();
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf'
        });
        await flushPromises();

        const dot = el.shadowRoot.querySelector('.builder-dirty-dot');
        expect(dot).not.toBeNull();
    });

    // ── Agent Mode panel (role picker) ───────────────────────────

    it('renders the role picker dropdown sourced from listActiveRoleSummaries', async () => {
        const el = createComponent();
        agentRolesAdapter.emit(SAMPLE_AGENT_ROLES);
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
        dispatch({ type: 'SELECT_STATE', stateKey: 'intake' });
        await flushPromises();

        const toggle = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Phase settings');
        toggle.click();
        await flushPromises();

        const panel = el.shadowRoot.querySelector('.builder-agent-panel');
        expect(panel).not.toBeNull();
        const heading = panel.querySelector('.builder-phase-group-title');
        expect(heading.textContent).toBe('Agent Mode');

        const picker = panel.querySelector('[data-testid="agent-role-picker"]');
        expect(picker).not.toBeNull();
        const optionValues = Array.from(picker.querySelectorAll('option'))
            .map((o) => o.value);
        // Placeholder + the two sample roles
        expect(optionValues).toEqual([
            '',
            'lease_qualifier',
            'donor_matcher'
        ]);
    });

    it('changing the role dispatches UPDATE_AGENT_CONFIG with the new shape', async () => {
        const el = createComponent();
        agentRolesAdapter.emit(SAMPLE_AGENT_ROLES);
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
        dispatch({ type: 'SELECT_STATE', stateKey: 'intake' });
        await flushPromises();

        const toggle = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Phase settings');
        toggle.click();
        await flushPromises();

        const panel = el.shadowRoot.querySelector('.builder-agent-panel');

        // Enable agent.
        const toggleEnabled = panel.querySelector('c-pulse-toggle');
        toggleEnabled.dispatchEvent(
            new CustomEvent('change', { detail: { checked: true } })
        );
        await flushPromises();

        // Pick a role.
        const picker = panel.querySelector('[data-testid="agent-role-picker"]');
        picker.value = 'lease_qualifier';
        picker.dispatchEvent(new CustomEvent('change'));
        await flushPromises();

        // Open overrides and set them.
        const overridesToggle = panel.querySelector(
            '[data-testid="agent-overrides-toggle"]'
        );
        overridesToggle.dispatchEvent(new CustomEvent('click'));
        await flushPromises();

        const providerInput = panel.querySelector('c-pulse-input');
        providerInput.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'Anthropic_Claude_Plus' } })
        );
        await flushPromises();

        const intake = getState().workflow.states.find((s) => s.key === 'intake');
        expect(intake.agent).toEqual(
            expect.objectContaining({
                enabled: true,
                roleKey: 'lease_qualifier',
                providerOverride: 'Anthropic_Claude_Plus'
            })
        );
        // Picking a role wipes legacy freeform fields explicitly.
        expect(intake.agent.persona).toBeNull();
        expect(intake.agent.systemPrompt).toBeNull();
    });

    it('shows a Custom (legacy) entry when phase has freeform agent fields without roleKey', async () => {
        const el = createComponent();
        agentRolesAdapter.emit(SAMPLE_AGENT_ROLES);
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'test_wf',
            subjectKinds: ['Account']
        });
        dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
        dispatch({ type: 'SELECT_STATE', stateKey: 'intake' });
        // Seed legacy-shape agent block.
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: 'intake',
            patch: {
                enabled: true,
                persona: 'Old Persona',
                systemPrompt: 'Old prompt',
                autonomy: 'Act_With_Approval'
            }
        });
        await flushPromises();

        const toggle = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Phase settings');
        toggle.click();
        await flushPromises();

        const picker = el.shadowRoot.querySelector('[data-testid="agent-role-picker"]');
        expect(picker).not.toBeNull();
        const labels = Array.from(picker.querySelectorAll('option'))
            .map((o) => o.textContent.trim());
        expect(labels).toContain('Custom (legacy)');

        // The legacy entry is the selected one.
        const selected = Array.from(picker.querySelectorAll('option'))
            .find((o) => o.selected);
        expect(selected.value).toBe('__legacy__');
    });
});

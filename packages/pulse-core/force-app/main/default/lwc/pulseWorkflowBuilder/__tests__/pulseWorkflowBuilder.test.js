import { createElement } from 'lwc';
import PulseWorkflowBuilder from 'c/pulseWorkflowBuilder';
import { resetStore, dispatch, getState } from 'c/pulseStore';

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
    it('shows create workflow form when no workflow key is set', () => {
        const el = createComponent();
        const heading = el.shadowRoot.querySelector(
            '.builder-create-heading'
        );
        expect(heading).not.toBeNull();
        expect(heading.textContent).toBe('Create a new workflow');
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
});

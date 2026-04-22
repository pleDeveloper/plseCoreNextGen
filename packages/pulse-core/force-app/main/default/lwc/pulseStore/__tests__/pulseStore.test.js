import {
    getState,
    subscribe,
    dispatch,
    resetStore
} from 'c/pulseStore';

beforeEach(() => {
    resetStore();
});

// ── Helpers ───────────────────────────────────────────────────────

function addTwoStates() {
    dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
    dispatch({
        type: 'ADD_STATE',
        stateKey: 'review',
        label: 'Review',
        stateType: 'approval'
    });
}

// ── Initial state ─────────────────────────────────────────────────

describe('initial state', () => {
    it('returns the blank workflow skeleton', () => {
        const s = getState();
        expect(s.workflow.schema).toBe('pulse.workflow.v1');
        expect(s.workflow.workflowKey).toBe('');
        expect(s.workflow.version).toBe(1);
        expect(s.workflow.states).toEqual([]);
        expect(s.ui.selectedStateKey).toBeNull();
        expect(s.ui.dirty).toBe(false);
    });
});

// ── Listener notification ─────────────────────────────────────────

describe('subscribe / unsubscribe', () => {
    it('notifies listeners on dispatch', () => {
        const listener = jest.fn();
        subscribe(listener);
        dispatch({ type: 'SET_WORKFLOW_META', workflowKey: 'test' });
        expect(listener).toHaveBeenCalledTimes(1);
        expect(listener).toHaveBeenCalledWith(
            expect.objectContaining({
                workflow: expect.objectContaining({ workflowKey: 'test' })
            })
        );
    });

    it('stops notifying after unsubscribe', () => {
        const listener = jest.fn();
        const unsub = subscribe(listener);
        unsub();
        dispatch({ type: 'SET_WORKFLOW_META', workflowKey: 'x' });
        expect(listener).not.toHaveBeenCalled();
    });

    it('supports multiple listeners', () => {
        const a = jest.fn();
        const b = jest.fn();
        subscribe(a);
        subscribe(b);
        dispatch({ type: 'SET_WORKFLOW_META', workflowKey: 'multi' });
        expect(a).toHaveBeenCalledTimes(1);
        expect(b).toHaveBeenCalledTimes(1);
    });
});

// ── SET_WORKFLOW_META ─────────────────────────────────────────────

describe('SET_WORKFLOW_META', () => {
    it('sets workflowKey, name, and subjectKinds', () => {
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'intake_wf',
            name: 'Intake Workflow',
            subjectKinds: ['Account', 'Referral__c']
        });
        const wf = getState().workflow;
        expect(wf.workflowKey).toBe('intake_wf');
        expect(wf.name).toBe('Intake Workflow');
        expect(wf.subjectKinds).toEqual(['Account', 'Referral__c']);
        expect(getState().ui.dirty).toBe(true);
    });

    it('leaves unspecified fields unchanged', () => {
        dispatch({
            type: 'SET_WORKFLOW_META',
            workflowKey: 'first'
        });
        dispatch({
            type: 'SET_WORKFLOW_META',
            name: 'Updated Name'
        });
        expect(getState().workflow.workflowKey).toBe('first');
        expect(getState().workflow.name).toBe('Updated Name');
    });
});

// ── ADD_STATE ─────────────────────────────────────────────────────

describe('ADD_STATE', () => {
    it('appends a state with defaults', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
        const states = getState().workflow.states;
        expect(states).toHaveLength(1);
        expect(states[0]).toEqual({
            key: 'intake',
            label: 'Intake',
            type: 'form',
            fields: [],
            transitions: []
        });
    });

    it('auto-selects the new state', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        expect(getState().ui.selectedStateKey).toBe('intake');
    });

    it('uses stateKey as label when label is omitted', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'my_state' });
        expect(getState().workflow.states[0].label).toBe('my_state');
    });

    it('respects stateType override', () => {
        dispatch({
            type: 'ADD_STATE',
            stateKey: 'review',
            stateType: 'approval'
        });
        expect(getState().workflow.states[0].type).toBe('approval');
    });
});

// ── UPDATE_STATE ──────────────────────────────────────────────────

describe('UPDATE_STATE', () => {
    it('merges updates into the matching state', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
        dispatch({
            type: 'UPDATE_STATE',
            stateKey: 'intake',
            updates: { label: 'Clinical Intake', type: 'approval' }
        });
        const s = getState().workflow.states[0];
        expect(s.label).toBe('Clinical Intake');
        expect(s.type).toBe('approval');
    });

    it('does not affect other states', () => {
        addTwoStates();
        dispatch({
            type: 'UPDATE_STATE',
            stateKey: 'intake',
            updates: { label: 'Updated' }
        });
        expect(getState().workflow.states[1].label).toBe('Review');
    });
});

// ── REMOVE_STATE ──────────────────────────────────────────────────

describe('REMOVE_STATE', () => {
    it('removes the state', () => {
        addTwoStates();
        dispatch({ type: 'REMOVE_STATE', stateKey: 'intake' });
        expect(getState().workflow.states).toHaveLength(1);
        expect(getState().workflow.states[0].key).toBe('review');
    });

    it('cleans up transitions targeting the removed state', () => {
        addTwoStates();
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'intake',
            signal: 'submit',
            toStateKey: 'review'
        });
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'review',
            signal: 'back',
            toStateKey: 'intake'
        });
        dispatch({ type: 'REMOVE_STATE', stateKey: 'intake' });
        expect(getState().workflow.states[0].transitions).toHaveLength(0);
    });

    it('clears selection if the removed state was selected', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        expect(getState().ui.selectedStateKey).toBe('intake');
        dispatch({ type: 'REMOVE_STATE', stateKey: 'intake' });
        expect(getState().ui.selectedStateKey).toBeNull();
    });

    it('preserves selection if a different state was selected', () => {
        addTwoStates();
        dispatch({ type: 'SELECT_STATE', stateKey: 'review' });
        dispatch({ type: 'REMOVE_STATE', stateKey: 'intake' });
        expect(getState().ui.selectedStateKey).toBe('review');
    });
});

// ── REORDER_STATES ────────────────────────────────────────────────

describe('REORDER_STATES', () => {
    it('reorders states by key list', () => {
        addTwoStates();
        dispatch({
            type: 'REORDER_STATES',
            stateKeys: ['review', 'intake']
        });
        const keys = getState().workflow.states.map((s) => s.key);
        expect(keys).toEqual(['review', 'intake']);
    });

    it('appends states not in the key list', () => {
        addTwoStates();
        dispatch({ type: 'ADD_STATE', stateKey: 'complete' });
        dispatch({
            type: 'REORDER_STATES',
            stateKeys: ['complete', 'intake']
        });
        const keys = getState().workflow.states.map((s) => s.key);
        expect(keys).toEqual(['complete', 'intake', 'review']);
    });
});

// ── ADD_TRANSITION ────────────────────────────────────────────────

describe('ADD_TRANSITION', () => {
    it('adds a transition to the source state', () => {
        addTwoStates();
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'intake',
            signal: 'submit',
            toStateKey: 'review'
        });
        const t = getState().workflow.states[0].transitions;
        expect(t).toHaveLength(1);
        expect(t[0]).toEqual({ signal: 'submit', to: 'review' });
    });
});

// ── UPDATE_TRANSITION ─────────────────────────────────────────────

describe('UPDATE_TRANSITION', () => {
    it('merges updates into the transition at the given index', () => {
        addTwoStates();
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'intake',
            signal: 'submit',
            toStateKey: 'review'
        });
        dispatch({
            type: 'UPDATE_TRANSITION',
            stateKey: 'intake',
            transitionIndex: 0,
            updates: { signal: 'approve' }
        });
        expect(
            getState().workflow.states[0].transitions[0].signal
        ).toBe('approve');
        expect(getState().workflow.states[0].transitions[0].to).toBe(
            'review'
        );
    });
});

// ── REMOVE_TRANSITION ─────────────────────────────────────────────

describe('REMOVE_TRANSITION', () => {
    it('removes the transition at the given index', () => {
        addTwoStates();
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'intake',
            signal: 'submit',
            toStateKey: 'review'
        });
        dispatch({
            type: 'ADD_TRANSITION',
            fromStateKey: 'intake',
            signal: 'reject',
            toStateKey: 'review'
        });
        dispatch({
            type: 'REMOVE_TRANSITION',
            stateKey: 'intake',
            transitionIndex: 0
        });
        const t = getState().workflow.states[0].transitions;
        expect(t).toHaveLength(1);
        expect(t[0].signal).toBe('reject');
    });
});

// ── ADD_FIELD ─────────────────────────────────────────────────────

describe('ADD_FIELD', () => {
    it('adds a field with defaults to the target state', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'physician',
            label: 'Referring Physician'
        });
        const f = getState().workflow.states[0].fields;
        expect(f).toHaveLength(1);
        expect(f[0]).toEqual({
            key: 'physician',
            label: 'Referring Physician',
            type: 'Text',
            required: false,
            projection: { enabled: false, scope: 'WorkflowScoped' },
            extractionHints: []
        });
    });

    it('auto-selects the new field', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(getState().ui.selectedFieldKey).toBe('notes');
    });
});

// ── UPDATE_FIELD ──────────────────────────────────────────────────

describe('UPDATE_FIELD', () => {
    it('merges updates into the matching field', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        dispatch({
            type: 'UPDATE_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes',
            updates: { label: 'Clinical Notes', required: true }
        });
        const f = getState().workflow.states[0].fields[0];
        expect(f.label).toBe('Clinical Notes');
        expect(f.required).toBe(true);
    });
});

// ── REMOVE_FIELD ──────────────────────────────────────────────────

describe('REMOVE_FIELD', () => {
    it('removes the field from the state', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'a'
        });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'b'
        });
        dispatch({
            type: 'REMOVE_FIELD',
            stateKey: 'intake',
            fieldKey: 'a'
        });
        expect(getState().workflow.states[0].fields).toHaveLength(1);
        expect(getState().workflow.states[0].fields[0].key).toBe('b');
    });

    it('clears field selection if the removed field was selected', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(getState().ui.selectedFieldKey).toBe('notes');
        dispatch({
            type: 'REMOVE_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(getState().ui.selectedFieldKey).toBeNull();
    });
});

// ── TOGGLE_FIELD_PROJECTION ───────────────────────────────────────

describe('TOGGLE_FIELD_PROJECTION', () => {
    it('flips projection.enabled from false to true', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(
            getState().workflow.states[0].fields[0].projection.enabled
        ).toBe(false);
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(
            getState().workflow.states[0].fields[0].projection.enabled
        ).toBe(true);
    });

    it('flips projection.enabled from true to false', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(
            getState().workflow.states[0].fields[0].projection.enabled
        ).toBe(false);
    });

    it('preserves the scope value', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(
            getState().workflow.states[0].fields[0].projection.scope
        ).toBe('WorkflowScoped');
    });

    it('marks the store as dirty', () => {
        resetStore();
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        // dirty is already true from ADD, so reload to reset
        dispatch({
            type: 'LOAD_WORKFLOW',
            workflow: getState().workflow
        });
        expect(getState().ui.dirty).toBe(false);
        dispatch({
            type: 'TOGGLE_FIELD_PROJECTION',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(getState().ui.dirty).toBe(true);
    });
});

// ── LOAD_WORKFLOW ─────────────────────────────────────────────────

describe('LOAD_WORKFLOW', () => {
    it('replaces the entire workflow and resets UI', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'old' });
        dispatch({ type: 'SELECT_STATE', stateKey: 'old' });

        const newWf = {
            schema: 'pulse.workflow.v1',
            workflowKey: 'loaded',
            version: 3,
            subjectKinds: ['Opportunity'],
            states: [
                {
                    key: 's1',
                    label: 'State One',
                    type: 'form',
                    fields: [],
                    transitions: []
                }
            ]
        };
        dispatch({ type: 'LOAD_WORKFLOW', workflow: newWf });

        expect(getState().workflow.workflowKey).toBe('loaded');
        expect(getState().workflow.states).toHaveLength(1);
        expect(getState().ui.selectedStateKey).toBeNull();
        expect(getState().ui.dirty).toBe(false);
    });
});

// ── PUBLISH_REQUESTED ─────────────────────────────────────────────

describe('PUBLISH_REQUESTED', () => {
    it('sets publishing flag and stores payload', () => {
        dispatch({
            type: 'PUBLISH_REQUESTED',
            workflowDefinitionId: '001xx0000000001',
            targetObject: 'Account'
        });
        expect(getState().ui.publishing).toBe(true);
        expect(getState().publishPayload).toEqual({
            workflowDefinitionId: '001xx0000000001',
            targetObject: 'Account'
        });
    });
});

// ── SET_DEPLOYMENT_STATUS ─────────────────────────────────────────

describe('SET_DEPLOYMENT_STATUS', () => {
    it('tracks in-progress deployment', () => {
        dispatch({
            type: 'SET_DEPLOYMENT_STATUS',
            deploymentRequestId: 'a0Fxx001',
            status: 'Queued'
        });
        expect(getState().ui.deploymentRequestId).toBe('a0Fxx001');
        expect(getState().ui.deploymentStatus).toBe('Queued');
        expect(getState().ui.publishing).toBe(true);
    });

    it('clears publishing on terminal status', () => {
        dispatch({
            type: 'SET_DEPLOYMENT_STATUS',
            status: 'Completed'
        });
        expect(getState().ui.publishing).toBe(false);
    });

    it('clears publishing on Failed', () => {
        dispatch({ type: 'SET_DEPLOYMENT_STATUS', status: 'Failed' });
        expect(getState().ui.publishing).toBe(false);
    });
});

// ── SELECT_STATE ──────────────────────────────────────────────────

describe('SELECT_STATE', () => {
    it('sets selectedStateKey and clears field/transition selection', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'ADD_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        dispatch({ type: 'SELECT_STATE', stateKey: 'intake' });
        expect(getState().ui.selectedStateKey).toBe('intake');
        expect(getState().ui.selectedFieldKey).toBeNull();
        expect(getState().ui.selectedTransitionIndex).toBeNull();
    });
});

// ── SELECT_FIELD ──────────────────────────────────────────────────

describe('SELECT_FIELD', () => {
    it('sets both state and field selection', () => {
        dispatch({
            type: 'SELECT_FIELD',
            stateKey: 'intake',
            fieldKey: 'notes'
        });
        expect(getState().ui.selectedStateKey).toBe('intake');
        expect(getState().ui.selectedFieldKey).toBe('notes');
        expect(getState().ui.selectedTransitionIndex).toBeNull();
    });
});

// ── SELECT_TRANSITION ─────────────────────────────────────────────

describe('SELECT_TRANSITION', () => {
    it('sets state and transition selection, clears field', () => {
        dispatch({
            type: 'SELECT_TRANSITION',
            stateKey: 'intake',
            transitionIndex: 0
        });
        expect(getState().ui.selectedStateKey).toBe('intake');
        expect(getState().ui.selectedFieldKey).toBeNull();
        expect(getState().ui.selectedTransitionIndex).toBe(0);
    });
});

// ── Unknown action ────────────────────────────────────────────────

describe('unknown action', () => {
    it('returns state unchanged', () => {
        const before = getState();
        dispatch({ type: 'NONEXISTENT' });
        expect(getState()).toBe(before);
    });
});

// ── UPDATE_AGENT_CONFIG ───────────────────────────────────────────

describe('UPDATE_AGENT_CONFIG', () => {
    it('creates the agent block on a state when missing', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: 'intake',
            patch: { enabled: true, persona: 'Claude' }
        });
        const s = getState().workflow.states.find((x) => x.key === 'intake');
        expect(s.agent).toEqual({ enabled: true, persona: 'Claude' });
        expect(getState().ui.dirty).toBe(true);
    });

    it('merges the patch onto an existing agent block', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: 'intake',
            patch: { enabled: true, autonomy: 'Propose_Only', persona: 'Claude' }
        });
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: 'intake',
            patch: { systemPrompt: 'Be terse.' }
        });
        const s = getState().workflow.states.find((x) => x.key === 'intake');
        expect(s.agent).toEqual({
            enabled: true,
            autonomy: 'Propose_Only',
            persona: 'Claude',
            systemPrompt: 'Be terse.'
        });
    });

    it('ignores unknown state keys', () => {
        dispatch({ type: 'ADD_STATE', stateKey: 'intake' });
        dispatch({
            type: 'UPDATE_AGENT_CONFIG',
            stateKey: 'missing',
            patch: { enabled: true }
        });
        const s = getState().workflow.states.find((x) => x.key === 'intake');
        expect(s.agent).toBeUndefined();
    });
});

// ── resetStore ────────────────────────────────────────────────────

describe('resetStore', () => {
    it('clears state and listeners', () => {
        const listener = jest.fn();
        subscribe(listener);
        dispatch({ type: 'ADD_STATE', stateKey: 'x' });
        resetStore();
        dispatch({ type: 'ADD_STATE', stateKey: 'y' });
        // listener was cleared, so only called once (from first dispatch)
        expect(listener).toHaveBeenCalledTimes(1);
        expect(getState().workflow.states).toHaveLength(1);
        expect(getState().workflow.states[0].key).toBe('y');
    });
});

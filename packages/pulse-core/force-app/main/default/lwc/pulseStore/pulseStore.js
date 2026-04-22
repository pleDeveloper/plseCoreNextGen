/**
 * pulseStore — lightweight Redux-style state management for the workflow builder.
 * Pure vanilla JS, no external dependencies. v4.1 §6 Chat 15.
 *
 * Usage:
 *   import { getState, subscribe, dispatch } from 'c/pulseStore';
 *   const unsub = subscribe(state => { ... });
 *   dispatch({ type: 'ADD_STATE', stateKey: 'intake', label: 'Intake' });
 */

const listeners = new Set();

const INITIAL_WORKFLOW = {
    schema: 'pulse.workflow.v1',
    workflowKey: '',
    version: 1,
    subjectKinds: [],
    states: []
};

const INITIAL_UI = {
    selectedStateKey: null,
    selectedFieldKey: null,
    selectedTransitionIndex: null,
    dirty: false,
    publishing: false,
    deploymentRequestId: null,
    deploymentStatus: null
};

function deepClone(obj) {
    return JSON.parse(JSON.stringify(obj));
}

let state = {
    workflow: deepClone(INITIAL_WORKFLOW),
    ui: deepClone(INITIAL_UI)
};

// ── Public API ────────────────────────────────────────────────────

export function getState() {
    return state;
}

export function subscribe(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
}

export function dispatch(action) {
    state = reduce(state, action);
    listeners.forEach((fn) => fn(state));
}

/** Reset to blank slate — useful for tests and when navigating away. */
export function resetStore() {
    state = {
        workflow: deepClone(INITIAL_WORKFLOW),
        ui: deepClone(INITIAL_UI)
    };
    listeners.clear();
}

// ── Reducer (pure function) ───────────────────────────────────────

function reduce(cur, action) {
    switch (action.type) {
        case 'SET_WORKFLOW_META':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    workflowKey:
                        action.workflowKey !== undefined
                            ? action.workflowKey
                            : cur.workflow.workflowKey,
                    name:
                        action.name !== undefined
                            ? action.name
                            : cur.workflow.name,
                    subjectKinds:
                        action.subjectKinds !== undefined
                            ? action.subjectKinds
                            : cur.workflow.subjectKinds
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'ADD_STATE':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: [
                        ...cur.workflow.states,
                        {
                            key: action.stateKey,
                            label: action.label || action.stateKey,
                            type: action.stateType || 'form',
                            fields: [],
                            transitions: []
                        }
                    ]
                },
                ui: {
                    ...cur.ui,
                    dirty: true,
                    selectedStateKey: action.stateKey
                }
            };

        case 'UPDATE_STATE':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? { ...s, ...action.updates }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'REMOVE_STATE':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states
                        .filter((s) => s.key !== action.stateKey)
                        .map((s) => ({
                            ...s,
                            transitions: s.transitions.filter(
                                (t) => t.to !== action.stateKey
                            )
                        }))
                },
                ui: {
                    ...cur.ui,
                    dirty: true,
                    selectedStateKey:
                        cur.ui.selectedStateKey === action.stateKey
                            ? null
                            : cur.ui.selectedStateKey,
                    selectedFieldKey:
                        cur.ui.selectedStateKey === action.stateKey
                            ? null
                            : cur.ui.selectedFieldKey
                }
            };

        case 'REORDER_STATES': {
            const lookup = new Map(
                cur.workflow.states.map((s) => [s.key, s])
            );
            const ordered = action.stateKeys
                .map((k) => lookup.get(k))
                .filter(Boolean);
            const seen = new Set(action.stateKeys);
            const rest = cur.workflow.states.filter(
                (s) => !seen.has(s.key)
            );
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: [...ordered, ...rest]
                },
                ui: { ...cur.ui, dirty: true }
            };
        }

        case 'ADD_TRANSITION':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.fromStateKey
                            ? {
                                  ...s,
                                  transitions: [
                                      ...s.transitions,
                                      {
                                          signal: action.signal,
                                          to: action.toStateKey
                                      }
                                  ]
                              }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'UPDATE_TRANSITION':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  transitions: s.transitions.map((t, i) =>
                                      i === action.transitionIndex
                                          ? { ...t, ...action.updates }
                                          : t
                                  )
                              }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'REMOVE_TRANSITION':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  transitions: s.transitions.filter(
                                      (_, i) => i !== action.transitionIndex
                                  )
                              }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'ADD_FIELD':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  fields: [
                                      ...s.fields,
                                      {
                                          key: action.fieldKey,
                                          label:
                                              action.label || action.fieldKey,
                                          type: action.fieldType || 'Text',
                                          required:
                                              action.required || false,
                                          projection: {
                                              enabled: false,
                                              scope: 'WorkflowScoped'
                                          },
                                          extractionHints:
                                              action.extractionHints || []
                                      }
                                  ]
                              }
                            : s
                    )
                },
                ui: {
                    ...cur.ui,
                    dirty: true,
                    selectedFieldKey: action.fieldKey
                }
            };

        case 'UPDATE_FIELD':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  fields: s.fields.map((f) =>
                                      f.key === action.fieldKey
                                          ? { ...f, ...action.updates }
                                          : f
                                  )
                              }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'REMOVE_FIELD':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  fields: s.fields.filter(
                                      (f) => f.key !== action.fieldKey
                                  )
                              }
                            : s
                    )
                },
                ui: {
                    ...cur.ui,
                    dirty: true,
                    selectedFieldKey:
                        cur.ui.selectedFieldKey === action.fieldKey
                            ? null
                            : cur.ui.selectedFieldKey
                }
            };

        case 'TOGGLE_FIELD_PROJECTION':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? {
                                  ...s,
                                  fields: s.fields.map((f) =>
                                      f.key === action.fieldKey
                                          ? {
                                                ...f,
                                                projection: {
                                                    ...f.projection,
                                                    enabled:
                                                        !f.projection.enabled
                                                }
                                            }
                                          : f
                                  )
                              }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'UPDATE_STATE_ENTRY_CONDITIONS':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? { ...s, entryConditions: action.tree || {} }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'UPDATE_STATE_EXIT_CONDITIONS':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? { ...s, exitConditions: action.tree || {} }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'UPDATE_STATE_PROGRESSION':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? { ...s, progression: action.progression || {} }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'UPDATE_STATE_STATUS_RULES':
            return {
                ...cur,
                workflow: {
                    ...cur.workflow,
                    states: cur.workflow.states.map((s) =>
                        s.key === action.stateKey
                            ? { ...s, statusRules: action.statusRules || {} }
                            : s
                    )
                },
                ui: { ...cur.ui, dirty: true }
            };

        case 'LOAD_WORKFLOW':
            return {
                ...cur,
                workflow: action.workflow,
                ui: deepClone(INITIAL_UI)
            };

        case 'PUBLISH_REQUESTED':
            return {
                ...cur,
                ui: {
                    ...cur.ui,
                    publishing: true,
                    deploymentRequestId: null,
                    deploymentStatus: null
                },
                publishPayload: {
                    workflowDefinitionId: action.workflowDefinitionId,
                    targetObject: action.targetObject
                }
            };

        case 'SET_DEPLOYMENT_STATUS':
            return {
                ...cur,
                ui: {
                    ...cur.ui,
                    deploymentRequestId:
                        action.deploymentRequestId ??
                        cur.ui.deploymentRequestId,
                    deploymentStatus: action.status,
                    publishing:
                        action.status !== 'Completed' &&
                        action.status !== 'Failed' &&
                        action.status !== 'Cancelled'
                }
            };

        case 'SELECT_STATE':
            return {
                ...cur,
                ui: {
                    ...cur.ui,
                    selectedStateKey: action.stateKey,
                    selectedFieldKey: null,
                    selectedTransitionIndex: null
                }
            };

        case 'SELECT_FIELD':
            return {
                ...cur,
                ui: {
                    ...cur.ui,
                    selectedStateKey: action.stateKey,
                    selectedFieldKey: action.fieldKey,
                    selectedTransitionIndex: null
                }
            };

        case 'SELECT_TRANSITION':
            return {
                ...cur,
                ui: {
                    ...cur.ui,
                    selectedStateKey: action.stateKey,
                    selectedFieldKey: null,
                    selectedTransitionIndex: action.transitionIndex
                }
            };

        default:
            return cur;
    }
}

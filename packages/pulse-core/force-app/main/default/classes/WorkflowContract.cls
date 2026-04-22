/**
 * Strongly-typed parser and validator for the pulse.workflow.v1 JSON contract.
 * Owns contract shape only — no execution logic.
 */
public with sharing class WorkflowContract {

    public static final String SCHEMA_VERSION = 'pulse.workflow.v1';

    // ─── Contract model ──────────────────────────────────────────

    public class Workflow {
        public String schemaVersion;
        public String workflowKey;
        public Integer version;
        public List<String> subjectKinds;
        public List<State> states;

        private Map<String, State> stateIndex;

        public State getState(String key) {
            if (stateIndex == null) {
                stateIndex = new Map<String, State>();
                if (states != null) {
                    for (State s : states) {
                        if (s.key != null) {
                            stateIndex.put(s.key, s);
                        }
                    }
                }
            }
            return stateIndex.get(key);
        }
    }

    public class State {
        public String key;
        public String label;
        public String stateType;
        public List<FieldDef> fields;
        public List<Transition> transitions;
        public ToolConfig toolConfig;
        public UiConfig uiConfig;

        // ── New in phase/actions model ─────────────────────────────
        // If actions is non-empty, the state is a "phase" with one or
        // more actions inside it. 'advancement' controls what happens
        // when all required actions complete: 'auto' fires the first
        // transition; 'manual_decision' requires the user to pick an
        // outcome. 'manual_decision' is the default when multiple
        // transitions exist and advancement is unset (backward compat).
        public List<ActionDef> actions;
        public String advancement;   // 'auto' | 'manual_decision'

        public Transition getTransition(String signal) {
            if (transitions != null) {
                for (Transition t : transitions) {
                    if (t.signal == signal) {
                        return t;
                    }
                }
            }
            return null;
        }

        public ActionDef getAction(String actionKey) {
            if (actions != null) {
                for (ActionDef a : actions) {
                    if (a.key == actionKey) return a;
                }
            }
            return null;
        }

        /**
         * Effective advancement mode: explicit 'advancement' wins; else
         * 'auto' if 0-1 transitions, 'manual_decision' if multiple.
         */
        public String effectiveAdvancement() {
            if (String.isNotBlank(advancement)) return advancement;
            Integer transCount = transitions == null ? 0 : transitions.size();
            return transCount > 1 ? 'manual_decision' : 'auto';
        }
    }

    public class ActionDef {
        public String key;
        public String label;
        public String actionType;        // 'ai_tool' | 'approval' | 'form' | 'auto' | 'wait'
        public Boolean required;         // default true — blocks phase advancement
        public List<String> dependsOn;   // action keys that must terminate before this instantiates
        public Map<String, Object> config; // type-specific (toolKey, hitlPolicy, etc.)
        public Integer sequence;         // display order
    }

    public class FieldDef {
        public String key;
        public String label;
        public String fieldType;
        public Boolean required;
        public Projection projection;
        public List<String> extractionHints;
    }

    public class Transition {
        public String signal;
        public String target;
    }

    public class Projection {
        public Boolean enabled;
        public String scope;
    }

    public class ToolConfig {
        public String toolKey;
        public String hitlPolicy;
        public Map<String, Object> parameters;
    }

    public class UiConfig {
        public String layout;
        public Boolean readOnly;
    }

    // ─── Parse ───────────────────────────────────────────────────

    public static Workflow parse(String jsonStr) {
        if (String.isBlank(jsonStr)) {
            throw new ContractParseException('Definition JSON is blank');
        }
        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        } catch (Exception e) {
            throw new ContractParseException('Invalid JSON: ' + e.getMessage());
        }
        return mapWorkflow(raw);
    }

    // ─── Validate ────────────────────────────────────────────────

    public static List<String> validate(Workflow wf) {
        List<String> errors = new List<String>();
        if (wf == null) {
            errors.add('Workflow is null');
            return errors;
        }
        if (wf.schemaVersion != SCHEMA_VERSION) {
            errors.add('Unsupported schema: ' + wf.schemaVersion);
        }
        if (String.isBlank(wf.workflowKey)) {
            errors.add('workflowKey is required');
        }
        if (wf.version == null || wf.version < 1) {
            errors.add('version must be a positive integer');
        }
        if (wf.subjectKinds == null || wf.subjectKinds.isEmpty()) {
            errors.add('subjectKinds must contain at least one entry');
        }
        if (wf.states == null || wf.states.isEmpty()) {
            errors.add('states must contain at least one entry');
            return errors;
        }

        Set<String> stateKeys = new Set<String>();
        Set<String> fieldKeys = new Set<String>();
        for (State s : wf.states) {
            if (String.isBlank(s.key)) {
                errors.add('State has blank key');
                continue;
            }
            if (!stateKeys.add(s.key)) {
                errors.add('Duplicate state key: ' + s.key);
            }
            if (String.isBlank(s.label)) {
                errors.add('State "' + s.key + '" has blank label');
            }
            if (s.fields != null) {
                for (FieldDef f : s.fields) {
                    if (String.isBlank(f.key)) {
                        errors.add('Field in state "' + s.key + '" has blank key');
                    } else if (!fieldKeys.add(f.key)) {
                        errors.add('Duplicate field key: ' + f.key);
                    }
                }
            }
        }
        // Validate transition targets after collecting all state keys
        for (State s : wf.states) {
            if (s.transitions == null) {
                continue;
            }
            for (Transition t : s.transitions) {
                if (String.isBlank(t.signal)) {
                    errors.add('Transition in state "' + s.key + '" has blank signal');
                }
                if (String.isBlank(t.target)) {
                    errors.add('Transition in state "' + s.key + '" has blank target');
                } else if (!stateKeys.contains(t.target)) {
                    errors.add('Transition in state "' + s.key + '" references unknown target: ' + t.target);
                }
            }
        }

        // Validate actions within each phase: unique keys + resolvable deps.
        for (State s : wf.states) {
            if (s.actions == null || s.actions.isEmpty()) continue;
            Set<String> actionKeys = new Set<String>();
            for (ActionDef a : s.actions) {
                if (String.isBlank(a.key)) {
                    errors.add('Action in state "' + s.key + '" has blank key');
                    continue;
                }
                if (!actionKeys.add(a.key)) {
                    errors.add('Duplicate action key in state "' + s.key + '": ' + a.key);
                }
                if (String.isBlank(a.actionType)) {
                    errors.add('Action "' + a.key + '" in state "' + s.key + '" has blank type');
                }
            }
            for (ActionDef a : s.actions) {
                if (a.dependsOn == null) continue;
                for (String dep : a.dependsOn) {
                    if (!actionKeys.contains(dep)) {
                        errors.add('Action "' + a.key + '" in state "' + s.key + '" depends on unknown action: ' + dep);
                    }
                    if (dep == a.key) {
                        errors.add('Action "' + a.key + '" in state "' + s.key + '" depends on itself');
                    }
                }
            }
        }
        return errors;
    }

    // ─── Helpers ─────────────────────────────────────────────────

    public static State getCurrentState(Workflow wf, Workflow_Instance__c instance) {
        if (wf == null || instance == null || String.isBlank(instance.Current_State__c)) {
            return null;
        }
        return wf.getState(instance.Current_State__c);
    }

    // ─── Private mapping from untyped JSON ───────────────────────

    private static Workflow mapWorkflow(Map<String, Object> raw) {
        Workflow wf = new Workflow();
        wf.schemaVersion = (String) raw.get('schema');
        wf.workflowKey = (String) raw.get('workflowKey');
        Object vObj = raw.get('version');
        if (vObj instanceof Decimal) {
            wf.version = ((Decimal) vObj).intValue();
        }
        Object kindsObj = raw.get('subjectKinds');
        if (kindsObj instanceof List<Object>) {
            wf.subjectKinds = new List<String>();
            for (Object k : (List<Object>) kindsObj) {
                wf.subjectKinds.add(String.valueOf(k));
            }
        }
        Object statesObj = raw.get('states');
        if (statesObj instanceof List<Object>) {
            wf.states = new List<State>();
            for (Object sObj : (List<Object>) statesObj) {
                wf.states.add(mapState((Map<String, Object>) sObj));
            }
        }
        return wf;
    }

    private static State mapState(Map<String, Object> raw) {
        State s = new State();
        s.key = (String) raw.get('key');
        s.label = (String) raw.get('label');
        s.stateType = (String) raw.get('type');
        Object fieldsObj = raw.get('fields');
        if (fieldsObj instanceof List<Object>) {
            s.fields = new List<FieldDef>();
            for (Object fObj : (List<Object>) fieldsObj) {
                s.fields.add(mapFieldDef((Map<String, Object>) fObj));
            }
        }
        Object transObj = raw.get('transitions');
        if (transObj instanceof List<Object>) {
            s.transitions = new List<Transition>();
            for (Object tObj : (List<Object>) transObj) {
                s.transitions.add(mapTransition((Map<String, Object>) tObj));
            }
        }
        Object toolObj = raw.get('toolConfig');
        if (toolObj instanceof Map<String, Object>) {
            s.toolConfig = mapToolConfig((Map<String, Object>) toolObj);
        }
        Object uiObj = raw.get('uiConfig');
        if (uiObj instanceof Map<String, Object>) {
            s.uiConfig = mapUiConfig((Map<String, Object>) uiObj);
        }
        // Phase/actions additions
        s.advancement = (String) raw.get('advancement');
        Object actionsObj = raw.get('actions');
        if (actionsObj instanceof List<Object>) {
            s.actions = new List<ActionDef>();
            Integer idx = 0;
            for (Object aObj : (List<Object>) actionsObj) {
                if (aObj instanceof Map<String, Object>) {
                    ActionDef ad = mapActionDef((Map<String, Object>) aObj);
                    if (ad.sequence == null) ad.sequence = idx;
                    s.actions.add(ad);
                }
                idx++;
            }
        }
        // Backward compatibility: states with toolConfig but no explicit
        // actions[] stay under the legacy PulseAgentRunner path (the agent
        // creates Workflow_Action__c rows via HitlService.createApproval).
        // We do NOT synthesize actions here — that would cause double
        // instantiation when the agent runs.
        return s;
    }

    private static ActionDef mapActionDef(Map<String, Object> raw) {
        ActionDef a = new ActionDef();
        a.key        = (String) raw.get('key');
        a.label      = (String) raw.get('label');
        a.actionType = (String) raw.get('type');
        a.required   = raw.get('required') != false; // default true when unset
        Object depsObj = raw.get('dependsOn');
        a.dependsOn = new List<String>();
        if (depsObj instanceof List<Object>) {
            for (Object d : (List<Object>) depsObj) {
                a.dependsOn.add(String.valueOf(d));
            }
        }
        Object configObj = raw.get('config');
        if (configObj instanceof Map<String, Object>) {
            a.config = (Map<String, Object>) configObj;
        }
        Object seqObj = raw.get('sequence');
        if (seqObj instanceof Decimal) {
            a.sequence = ((Decimal) seqObj).intValue();
        } else if (seqObj instanceof Integer) {
            a.sequence = (Integer) seqObj;
        }
        return a;
    }

    private static FieldDef mapFieldDef(Map<String, Object> raw) {
        FieldDef f = new FieldDef();
        f.key = (String) raw.get('key');
        f.label = (String) raw.get('label');
        f.fieldType = (String) raw.get('type');
        f.required = raw.get('required') == true;
        Object projObj = raw.get('projection');
        if (projObj instanceof Map<String, Object>) {
            f.projection = mapProjection((Map<String, Object>) projObj);
        }
        Object hintsObj = raw.get('extractionHints');
        if (hintsObj instanceof List<Object>) {
            f.extractionHints = new List<String>();
            for (Object h : (List<Object>) hintsObj) {
                f.extractionHints.add(String.valueOf(h));
            }
        }
        return f;
    }

    private static Transition mapTransition(Map<String, Object> raw) {
        Transition t = new Transition();
        t.signal = (String) raw.get('signal');
        t.target = (String) raw.get('to');
        return t;
    }

    private static Projection mapProjection(Map<String, Object> raw) {
        Projection p = new Projection();
        p.enabled = raw.get('enabled') == true;
        p.scope = (String) raw.get('scope');
        return p;
    }

    private static ToolConfig mapToolConfig(Map<String, Object> raw) {
        ToolConfig tc = new ToolConfig();
        tc.toolKey = (String) raw.get('toolKey');
        tc.hitlPolicy = (String) raw.get('hitlPolicy');
        Object paramsObj = raw.get('parameters');
        if (paramsObj instanceof Map<String, Object>) {
            tc.parameters = (Map<String, Object>) paramsObj;
        }
        return tc;
    }

    private static UiConfig mapUiConfig(Map<String, Object> raw) {
        UiConfig ui = new UiConfig();
        ui.layout = (String) raw.get('layout');
        ui.readOnly = raw.get('readOnly') == true;
        return ui;
    }

    public class ContractParseException extends Exception {}
}

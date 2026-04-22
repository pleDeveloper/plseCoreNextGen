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
        // Agent Mode config at workflow-scope. Shape:
        //   { "enabled": true|false, "persona": "Claude",
        //     "autonomy": "Propose_Only"|"Act_With_Approval"|"Autonomous_Safe",
        //     "systemPrompt": "..." }
        // Precedence: action.agent > state.agent > workflow.agent
        public Map<String, Object> agent;

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

        /**
         * Resolve the effective agent config for a phase. Merges workflow
         * and state agent blocks, with state overriding workflow when both
         * are present. Returns null when agent mode is not enabled on this
         * phase (explicitly disabled or missing).
         */
        public Map<String, Object> agentConfigForPhase(String phaseKey) {
            return resolveAgent(this.agent, getState(phaseKey) == null
                ? null : getState(phaseKey).agent, null);
        }

        /**
         * Resolve the effective agent config for a specific action. Merges
         * workflow, state, and action agent blocks, action winning last.
         */
        public Map<String, Object> agentConfigForAction(String phaseKey, String actionKey) {
            State s = getState(phaseKey);
            if (s == null) {
                return resolveAgent(this.agent, null, null);
            }
            ActionDef a = s.getAction(actionKey);
            return resolveAgent(this.agent, s.agent, a == null ? null : a.agent);
        }

        /**
         * Whether agent mode is enabled anywhere on this workflow — used to
         * decide whether to auto-create an Agent_Thread__c at first use.
         */
        public Boolean agentEnabledAnywhere() {
            Map<String, Object> w = this.agent;
            if (w != null && isAgentEnabledMap(w)) return true;
            if (states == null) return false;
            for (State s : states) {
                if (s.agent != null && isAgentEnabledMap(s.agent)) return true;
                if (s.actions != null) {
                    for (ActionDef a : s.actions) {
                        if (a.agent != null && isAgentEnabledMap(a.agent)) return true;
                    }
                }
            }
            return false;
        }
    }

    /**
     * Returns the merged agent config or null when not enabled. Defaults:
     *   persona="Claude", autonomy="Act_With_Approval".
     */
    public static Map<String, Object> resolveAgent(
        Map<String, Object> wf, Map<String, Object> st, Map<String, Object> act
    ) {
        Map<String, Object> merged = new Map<String, Object>();
        if (wf != null) merged.putAll(wf);
        if (st != null) merged.putAll(st);
        if (act != null) merged.putAll(act);
        if (merged.isEmpty()) return null;
        // If explicit enabled=false at most-specific level wins — but we
        // treat missing 'enabled' as enabled when any scope set it true.
        Boolean enabled = isAgentEnabledMap(merged);
        if (!enabled) return null;
        // Fill defaults
        if (merged.get('persona') == null) merged.put('persona', 'Claude');
        if (merged.get('autonomy') == null) merged.put('autonomy', 'Act_With_Approval');
        return merged;
    }

    private static Boolean isAgentEnabledMap(Map<String, Object> m) {
        if (m == null) return false;
        Object v = m.get('enabled');
        if (v == null) {
            // If any other agent field is present, treat as enabled.
            return m.containsKey('persona') || m.containsKey('systemPrompt')
                || m.containsKey('autonomy');
        }
        return v == true;
    }

    public class State {
        public String key;
        public String label;
        public String stateType;
        public List<FieldDef> fields;
        public List<Transition> transitions;
        public ToolConfig toolConfig;
        public UiConfig uiConfig;
        // Agent Mode config at state scope (see Workflow.agent docs).
        public Map<String, Object> agent;

        // ── New in phase/actions model ─────────────────────────────
        // If actions is non-empty, the state is a "phase" with one or
        // more actions inside it. 'advancement' controls what happens
        // when all required actions complete: 'auto' fires the first
        // transition; 'manual_decision' requires the user to pick an
        // outcome. 'manual_decision' is the default when multiple
        // transitions exist and advancement is unset (backward compat).
        public List<ActionDef> actions;
        public String advancement;   // 'auto' | 'manual_decision'

        // ── Phase settings (entry/exit/progression/statusRules) ────
        // AND/OR condition tree evaluated against the parent record on
        // phase entry. If false, the transition is blocked.
        public Map<String, Object> entryConditions;
        // Same shape; evaluated against the parent record on the
        // current phase before advancing. If false, blocks transition.
        public Map<String, Object> exitConditions;
        // { "mode": "auto_on_actions" | "manual_decision" |
        //           "field_change" | "custom_logic",
        //   "rule": { ... mode-specific ... } }
        public Map<String, Object> progression;
        // { "autoOnHoldAfterDays": Integer,
        //   "autoEscalateIfBlocked": Boolean }
        public Map<String, Object> statusRules;

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
         * Effective advancement mode: progression.mode (when set to an
         * auto-compatible mode) or explicit 'advancement' wins; else
         * 'auto' if 0-1 transitions, 'manual_decision' if multiple.
         *
         * progression.mode mapping:
         *   auto_on_actions -> 'auto'
         *   manual_decision -> 'manual_decision'
         *   field_change    -> 'manual_decision' here (auto-advance is
         *                      handled externally via StageProgressionService;
         *                      the post-action HITL path should not auto-fire)
         *   custom_logic    -> 'auto' (StageProgressionService decides)
         */
        public String effectiveAdvancement() {
            String mode = progressionMode();
            if (String.isNotBlank(mode)) {
                if (mode == 'auto_on_actions' || mode == 'custom_logic') return 'auto';
                if (mode == 'manual_decision' || mode == 'field_change') return 'manual_decision';
            }
            if (String.isNotBlank(advancement)) return advancement;
            Integer transCount = transitions == null ? 0 : transitions.size();
            return transCount > 1 ? 'manual_decision' : 'auto';
        }

        /** Returns progression.mode or null when unset. */
        public String progressionMode() {
            if (progression == null) return null;
            Object m = progression.get('mode');
            return m == null ? null : String.valueOf(m);
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
        // Agent Mode config at action scope (see Workflow.agent docs).
        public Map<String, Object> agent;
        // Optional assignment directive resolved at instantiation:
        //   { "type": "workflow_owner" }                      (default)
        //   { "type": "user", "userId": "005..." }
        //   { "type": "parent_owner" }                        (uses OwnerId of Parent_Record_Id__c)
        //   { "type": "group", "groupId": "00G..." } | { "type": "group", "groupName": "QueueName" }
        public Map<String, Object> assignmentRule;
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
        Object agentObj = raw.get('agent');
        if (agentObj instanceof Map<String, Object>) {
            wf.agent = (Map<String, Object>) agentObj;
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
        Object entryObj = raw.get('entryConditions');
        if (entryObj instanceof Map<String, Object>) {
            s.entryConditions = (Map<String, Object>) entryObj;
        }
        Object exitObj = raw.get('exitConditions');
        if (exitObj instanceof Map<String, Object>) {
            s.exitConditions = (Map<String, Object>) exitObj;
        }
        Object progObj = raw.get('progression');
        if (progObj instanceof Map<String, Object>) {
            s.progression = (Map<String, Object>) progObj;
        }
        Object statusRulesObj = raw.get('statusRules');
        if (statusRulesObj instanceof Map<String, Object>) {
            s.statusRules = (Map<String, Object>) statusRulesObj;
        }
        Object stateAgentObj = raw.get('agent');
        if (stateAgentObj instanceof Map<String, Object>) {
            s.agent = (Map<String, Object>) stateAgentObj;
        }
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
        Object assignObj = raw.get('assignmentRule');
        if (assignObj instanceof Map<String, Object>) {
            a.assignmentRule = (Map<String, Object>) assignObj;
        }
        Object actionAgentObj = raw.get('agent');
        if (actionAgentObj instanceof Map<String, Object>) {
            a.agent = (Map<String, Object>) actionAgentObj;
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

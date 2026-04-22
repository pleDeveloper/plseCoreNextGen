/**
 * PulseAgentOrchestrator
 *
 * Agent Mode turn engine. Each call to `advance(instanceId)` runs one
 * "turn": build context, call Claude with a 4-tool contract
 * (propose_action, ask_user, advance_phase, observe), persist an
 * Agent_Decision__c, and either auto-execute (within the safe list and
 * autonomy policy) or hand off to the user.
 *
 * Resume entry points (approveDecision / rejectDecision / answerQuestion)
 * are driven by the LWCs and immediately re-kick the agent so it keeps
 * driving the workflow forward.
 */
public with sharing class PulseAgentOrchestrator {

    // ─── Agent tool keys (meta-tools exposed to Claude) ──────────
    public static final String TOOL_PROPOSE   = 'propose_action';
    public static final String TOOL_ASK       = 'ask_user';
    public static final String TOOL_ADVANCE   = 'advance_phase';
    public static final String TOOL_OBSERVE   = 'observe';

    // Autonomy levels
    public static final String AUT_PROPOSE_ONLY      = 'Propose_Only';
    public static final String AUT_ACT_WITH_APPROVAL = 'Act_With_Approval';
    public static final String AUT_AUTONOMOUS_SAFE   = 'Autonomous_Safe';

    // Safe list for Autonomous_Safe autonomy — tool keys that may execute
    // without an explicit human approval when the agent proposes them.
    // Notably `send_email` is NOT safe (outbound side effect).
    public static final Set<String> AUTONOMOUS_SAFE_TOOLS = new Set<String>{
        'update_record'
    };

    // Compact rolling summary every N decisions
    public static final Integer COMPACT_EVERY_N_DECISIONS = 5;

    // Prevent re-entrant advance() calls within the same transaction
    // (hook -> orchestrator -> HitlService.resolve -> hook, etc.)
    @TestVisible
    private static Boolean running = false;

    // Test hook: when non-null, `advance` skips the AI call entirely and
    // consumes this response as if it came from the provider. Used by
    // PulseAgentOrchestratorTest to keep tests hermetic.
    @TestVisible
    private static PulseAiModels.Response responseForTest;

    public class RunResult {
        public Boolean success;
        public Integer decisionsCreated;
        public String  status;         // thread status after the turn
        public String  error;
        public List<Id> decisionIds;

        public RunResult() {
            this.success = true;
            this.decisionsCreated = 0;
            this.decisionIds = new List<Id>();
        }
    }

    // ─── Public API ──────────────────────────────────────────────

    public static RunResult advance(Id instanceId) {
        RunResult r = new RunResult();
        if (instanceId == null) {
            r.success = false;
            r.error = 'instanceId is required';
            return r;
        }
        if (running) {
            r.success = true;
            r.status = 'Skipped (reentrant)';
            return r;
        }
        running = true;
        try {
            return runTurn(instanceId, r);
        } finally {
            running = false;
        }
    }

    /**
     * Approve a pending Propose_Action decision. Executes the proposal
     * (using refined payload if provided) and re-kicks the agent loop.
     */
    public static RunResult approveDecision(Id decisionId, String refinedPayloadJson) {
        RunResult r = new RunResult();
        if (decisionId == null) { r.success = false; r.error = 'decisionId required'; return r; }
        Agent_Decision__c d = loadDecision(decisionId);
        if (d == null) { r.success = false; r.error = 'Decision not found'; return r; }
        if (d.Status__c != 'Pending_User') {
            r.success = false; r.error = 'Decision not pending'; return r;
        }
        try {
            Id instanceId = d.Workflow_Instance__c;
            if (d.Decision_Type__c == 'Propose_Action') {
                // If a Workflow_Action__c already exists, resolve through HitlService
                if (d.Related_Action__c != null) {
                    HitlService.resolveApproval(d.Related_Action__c, true,
                        UserInfo.getUserId(), refinedPayloadJson);
                } else {
                    // No related action yet — create a pending row with the
                    // (possibly refined) payload and resolve immediately.
                    Map<String, Object> proposal = parseMap(d.Proposal_JSON__c);
                    String toolKey = (String) proposal.get('toolKey');
                    String payloadJson = String.isNotBlank(refinedPayloadJson)
                        ? refinedPayloadJson
                        : JSON.serialize(proposal.get('arguments'));
                    Workflow_Action__c action = HitlService.createApproval(
                        instanceId, toolKey, payloadJson, 'Approval_Required'
                    );
                    d.Related_Action__c = action.Id;
                    update d;
                    HitlService.resolveApproval(action.Id, true,
                        UserInfo.getUserId(), null);
                }
                markDecisionResolved(d, String.isNotBlank(refinedPayloadJson) ? 'Refined' : 'Approved', null);
            } else if (d.Decision_Type__c == 'Advance_Phase') {
                // Fire the requested transition
                Map<String, Object> proposal = parseMap(d.Proposal_JSON__c);
                String signal = (String) proposal.get('signal');
                fireAdvance(instanceId, signal);
                markDecisionResolved(d, 'Approved', null);
            } else {
                markDecisionResolved(d, 'Approved', null);
            }
            // Re-kick the agent loop
            return advance(instanceId);
        } catch (Exception e) {
            r.success = false;
            r.error = 'Approve failed: ' + e.getMessage();
            return r;
        }
    }

    public static RunResult rejectDecision(Id decisionId, String reason) {
        RunResult r = new RunResult();
        if (decisionId == null) { r.success = false; r.error = 'decisionId required'; return r; }
        Agent_Decision__c d = loadDecision(decisionId);
        if (d == null) { r.success = false; r.error = 'Decision not found'; return r; }
        if (d.Status__c != 'Pending_User') {
            r.success = false; r.error = 'Decision not pending'; return r;
        }
        try {
            if (d.Decision_Type__c == 'Propose_Action' && d.Related_Action__c != null) {
                HitlService.resolveApproval(d.Related_Action__c, false, UserInfo.getUserId());
            }
            Map<String, Object> responseMap = new Map<String, Object>{
                'action' => 'rejected',
                'reason' => reason
            };
            markDecisionResolved(d, 'Rejected', JSON.serialize(responseMap));
            return advance(d.Workflow_Instance__c);
        } catch (Exception e) {
            r.success = false;
            r.error = 'Reject failed: ' + e.getMessage();
            return r;
        }
    }

    public static RunResult answerQuestion(Id decisionId, String responseJson) {
        RunResult r = new RunResult();
        if (decisionId == null) { r.success = false; r.error = 'decisionId required'; return r; }
        Agent_Decision__c d = loadDecision(decisionId);
        if (d == null) { r.success = false; r.error = 'Decision not found'; return r; }
        if (d.Status__c != 'Pending_User' || d.Decision_Type__c != 'Ask_User') {
            r.success = false; r.error = 'Decision is not an open question'; return r;
        }
        try {
            // Merge into Workflow_Instance__c.Context_JSON__c if the question
            // identified a field key. Otherwise just store the raw response.
            Map<String, Object> qMap = parseMap(d.Question_JSON__c);
            Map<String, Object> respMap = parseMap(responseJson);
            String fieldKey = (String) qMap.get('fieldKey');
            if (String.isNotBlank(fieldKey) && respMap != null && respMap.containsKey('value')) {
                mergeIntoContext(d.Workflow_Instance__c, fieldKey, respMap.get('value'));
            }
            markDecisionResolved(d, 'Answered', responseJson);
            return advance(d.Workflow_Instance__c);
        } catch (Exception e) {
            r.success = false;
            r.error = 'Answer failed: ' + e.getMessage();
            return r;
        }
    }

    public static Agent_Thread__c getOrCreateThread(Id instanceId) {
        return getOrCreateThreadInternal(instanceId, loadInstance(instanceId));
    }

    // ─── Turn loop ───────────────────────────────────────────────

    private static RunResult runTurn(Id instanceId, RunResult r) {
        Workflow_Instance__c inst = loadInstance(instanceId);
        if (inst == null) {
            r.success = false;
            r.error = 'Instance not found';
            return r;
        }
        if (inst.Status__c != 'Active') {
            r.success = true;
            r.status = 'Instance not active';
            return r;
        }

        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
        } catch (Exception e) {
            r.success = false;
            r.error = 'Contract parse failed: ' + e.getMessage();
            return r;
        }

        Map<String, Object> agentCfg = wf.agentConfigForPhase(inst.Current_State__c);
        if (agentCfg == null) {
            // Agent mode not enabled for this phase — no-op.
            r.success = true;
            r.status = 'Agent disabled for phase';
            return r;
        }

        // Load the thread WITHOUT DML. Salesforce forbids HTTP callouts after
        // uncommitted DML, so we build/mutate the thread in memory, make the
        // callout, and upsert afterwards. See markError + thread.Id == null
        // branch below for the error-path upsert.
        Agent_Thread__c thread = loadThreadInMemory(instanceId);
        // Snapshot the system prompt the first time we use the thread.
        if (String.isBlank(thread.System_Prompt__c)) {
            thread.System_Prompt__c = (String) agentCfg.get('systemPrompt');
        }
        if (String.isBlank(thread.Persona_Name__c)) {
            String persona = (String) agentCfg.get('persona');
            thread.Persona_Name__c = String.isBlank(persona) ? 'Claude' : persona;
        }
        if (String.isBlank(thread.Autonomy_Level__c)) {
            thread.Autonomy_Level__c = (String) agentCfg.get('autonomy');
            if (String.isBlank(thread.Autonomy_Level__c)) {
                thread.Autonomy_Level__c = AUT_ACT_WITH_APPROVAL;
            }
        }
        thread.Status__c = 'Working';
        thread.Last_Run_Date__c = Datetime.now();

        // Build AI request
        PulseAiModels.Request req = buildAgentRequest(inst, thread, wf, agentCfg);

        // Invoke AI (or consume test response) — callout-before-DML discipline.
        PulseAiModels.Response resp;
        try {
            resp = (responseForTest != null) ? responseForTest : PulseAiFacade.invoke(req);
        } catch (Exception e) {
            return markError(thread, r, 'AI call threw: ' + e.getMessage());
        }
        if (resp == null) {
            return markError(thread, r, 'AI response was null');
        }
        if (resp.isError) {
            return markError(thread, r, 'AI error: ' + resp.errorMessage);
        }

        // Callout succeeded — safe to do DML now. Persist the thread so the
        // Id is available for Agent_Decision__c FKs below.
        upsert thread;

        // Parse the first recognized tool call into a decision.
        Agent_Decision__c decision = parseResponseIntoDecision(resp, thread, inst);
        if (decision == null) {
            // No tool call — record an Observe decision with the response text.
            decision = new Agent_Decision__c(
                Agent_Thread__c = thread.Id,
                Workflow_Instance__c = instanceId,
                Phase_Key__c = inst.Current_State__c,
                Decision_Type__c = 'Observe',
                Rationale__c = String.isBlank(resp.text) ? 'No explicit action.' : resp.text,
                Status__c = 'Skipped'
            );
            insert decision;
            thread.Status__c = 'Idle';
            update thread;
            r.decisionsCreated = 1;
            r.decisionIds.add(decision.Id);
            r.status = thread.Status__c;
            return r;
        }

        // Apply autonomy policy
        applyAutonomy(decision, thread, inst);

        // Persist decision after any autonomy updates
        if (decision.Id == null) {
            insert decision;
        } else {
            update decision;
        }
        r.decisionsCreated = 1;
        r.decisionIds.add(decision.Id);

        // Update thread status
        if (decision.Status__c == 'Pending_User') {
            thread.Status__c = 'Waiting_For_User';
        } else {
            thread.Status__c = 'Idle';
        }
        update thread;
        r.status = thread.Status__c;

        // Every N decisions, compact the rolling summary.
        maybeCompactSummary(thread);

        return r;
    }

    private static void applyAutonomy(
        Agent_Decision__c d, Agent_Thread__c thread, Workflow_Instance__c inst
    ) {
        String autonomy = String.isBlank(thread.Autonomy_Level__c)
            ? AUT_ACT_WITH_APPROVAL : thread.Autonomy_Level__c;

        if (d.Decision_Type__c == 'Propose_Action') {
            Map<String, Object> proposal = parseMap(d.Proposal_JSON__c);
            String toolKey = proposal == null ? null : (String) proposal.get('toolKey');
            String payload = proposal == null ? '{}'
                : JSON.serialize(proposal.get('arguments'));

            if (autonomy == AUT_AUTONOMOUS_SAFE
                && String.isNotBlank(toolKey)
                && AUTONOMOUS_SAFE_TOOLS.contains(toolKey)) {
                // Auto-execute via HitlService: create action row, resolve true.
                Workflow_Action__c a = HitlService.createApproval(
                    inst.Id, toolKey, payload, 'Autonomous'
                );
                d.Related_Action__c = a.Id;
                // Insert decision so it has an Id before we call resolve
                if (d.Id == null) insert d;
                d.Status__c = 'Auto_Executed';
                HitlService.resolveApproval(a.Id, true, UserInfo.getUserId(), null);
                d.Resolved_Date__c = Datetime.now();
            } else if (autonomy == AUT_PROPOSE_ONLY) {
                // No Workflow_Action__c — just keep the proposal visible.
                d.Status__c = 'Pending_User';
            } else {
                // Act_With_Approval — create a pending Workflow_Action__c
                // that the Decision Queue card links to.
                if (String.isNotBlank(toolKey)) {
                    Workflow_Action__c a = HitlService.createApproval(
                        inst.Id, toolKey, payload, 'Approval_Required'
                    );
                    d.Related_Action__c = a.Id;
                }
                d.Status__c = 'Pending_User';
            }
        } else if (d.Decision_Type__c == 'Ask_User') {
            d.Status__c = 'Pending_User';
        } else if (d.Decision_Type__c == 'Advance_Phase') {
            // For autonomy Propose_Only keep pending; otherwise fire immediately.
            if (autonomy == AUT_PROPOSE_ONLY) {
                d.Status__c = 'Pending_User';
            } else {
                Map<String, Object> proposal = parseMap(d.Proposal_JSON__c);
                String signal = proposal == null ? null : (String) proposal.get('signal');
                if (String.isNotBlank(signal)) {
                    fireAdvance(inst.Id, signal);
                    d.Status__c = 'Auto_Executed';
                    d.Resolved_Date__c = Datetime.now();
                } else {
                    d.Status__c = 'Pending_User';
                }
            }
        } else if (d.Decision_Type__c == 'Observe') {
            d.Status__c = 'Skipped';
            d.Resolved_Date__c = Datetime.now();
        } else {
            d.Status__c = 'Pending_User';
        }
    }

    // ─── Request construction ───────────────────────────────────

    private static PulseAiModels.Request buildAgentRequest(
        Workflow_Instance__c inst, Agent_Thread__c thread,
        WorkflowContract.Workflow wf, Map<String, Object> agentCfg
    ) {
        PulseAiModels.Request req = new PulseAiModels.Request();
        req.systemPrompt = buildSystemPrompt(thread, agentCfg, inst);
        req.tools = agentToolDefinitions();
        req.messages = new List<PulseAiModels.Message>();

        Map<String, Object> contextPayload = buildContextPayload(inst, thread, wf);
        req.messages.add(new PulseAiModels.Message(
            'user',
            'Workflow context:\n' + JSON.serializePretty(contextPayload)
                + '\n\nPlease choose ONE of the four agent tools to move the workflow forward.'
        ));
        return req;
    }

    private static String buildSystemPrompt(
        Agent_Thread__c thread, Map<String, Object> agentCfg, Workflow_Instance__c inst
    ) {
        String persona = thread.Persona_Name__c == null ? 'Claude' : thread.Persona_Name__c;
        String userPrompt = String.isNotBlank(thread.System_Prompt__c)
            ? thread.System_Prompt__c
            : (String) agentCfg.get('systemPrompt');
        String rolling = String.isBlank(thread.Rolling_Summary__c) ? '' : thread.Rolling_Summary__c;

        String sp = 'You are "' + persona + '", a workflow-driving AI agent for Pulse Core Next.'
            + '\nYou operate a Salesforce-native workflow by choosing ONE tool per turn:'
            + '\n- propose_action: propose a concrete tool call (e.g. send_email, update_record).'
            + '\n- ask_user: ask the user for a field value or open-ended input.'
            + '\n- advance_phase: request the workflow move to the next phase.'
            + '\n- observe: record a brief observation when no action is appropriate.'
            + '\n\nGuidelines:'
            + '\n- Be decisive but deferential. Always include a 1-3 sentence rationale.'
            + '\n- Prefer ask_user when you need parent-record info you do not have yet.'
            + '\n- Never call the same tool twice with identical args without new input.'
            + '\n- All side-effecting tool calls are gated by human approval unless autonomy allows.'
            + '\n\nWorkflow system prompt:\n' + (String.isBlank(userPrompt) ? '(none provided)' : userPrompt);
        if (String.isNotBlank(rolling)) {
            sp += '\n\nRolling summary of prior decisions (for your future self):\n' + rolling;
        }
        return sp;
    }

    private static Map<String, Object> buildContextPayload(
        Workflow_Instance__c inst, Agent_Thread__c thread, WorkflowContract.Workflow wf
    ) {
        Map<String, Object> m = new Map<String, Object>();
        m.put('workflowKey', inst.Workflow_Definition__r.Workflow_Key__c);
        m.put('currentPhase', inst.Current_State__c);
        m.put('instanceStatus', inst.Status__c);
        m.put('parentObjectType', inst.Parent_Object_Type__c);
        m.put('parentRecordId', inst.Parent_Record_Id__c);

        // Current phase metadata
        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase != null) {
            Map<String, Object> phaseMap = new Map<String, Object>();
            phaseMap.put('label', phase.label);
            List<Map<String, Object>> fieldList = new List<Map<String, Object>>();
            if (phase.fields != null) {
                for (WorkflowContract.FieldDef f : phase.fields) {
                    fieldList.add(new Map<String, Object>{
                        'key' => f.key,
                        'label' => f.label,
                        'type' => f.fieldType,
                        'required' => f.required
                    });
                }
            }
            phaseMap.put('fields', fieldList);
            List<Map<String, Object>> tList = new List<Map<String, Object>>();
            if (phase.transitions != null) {
                for (WorkflowContract.Transition t : phase.transitions) {
                    tList.add(new Map<String, Object>{
                        'signal' => t.signal,
                        'to' => t.target
                    });
                }
            }
            phaseMap.put('transitions', tList);
            m.put('phase', phaseMap);
        }

        // Flattened context
        if (String.isNotBlank(inst.Context_JSON__c)) {
            try {
                m.put('context', JSON.deserializeUntyped(inst.Context_JSON__c));
            } catch (Exception ignore) {
                m.put('context', new Map<String, Object>());
            }
        } else {
            m.put('context', new Map<String, Object>());
        }

        // Pending actions for this phase
        List<Workflow_Action__c> pending = [
            SELECT Id, Tool_Key__c, Status__c, Request_JSON__c, Action_Key__c, Phase_Key__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id
              AND Status__c = 'Pending'
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
        List<Map<String, Object>> pendList = new List<Map<String, Object>>();
        for (Workflow_Action__c a : pending) {
            pendList.add(new Map<String, Object>{
                'id' => a.Id,
                'toolKey' => a.Tool_Key__c,
                'actionKey' => a.Action_Key__c
            });
        }
        m.put('pendingActions', pendList);

        // Last 10 decisions (by createdDate desc, reversed to chrono)
        List<Agent_Decision__c> last = [
            SELECT Id, Decision_Type__c, Rationale__c, Status__c, CreatedDate,
                   Proposal_JSON__c, Question_JSON__c, User_Response_JSON__c
            FROM Agent_Decision__c
            WHERE Agent_Thread__c = :thread.Id
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
        List<Map<String, Object>> decList = new List<Map<String, Object>>();
        for (Integer i = last.size() - 1; i >= 0; i--) {
            Agent_Decision__c d = last[i];
            decList.add(new Map<String, Object>{
                'type' => d.Decision_Type__c,
                'status' => d.Status__c,
                'rationale' => d.Rationale__c,
                'response' => d.User_Response_JSON__c
            });
        }
        m.put('recentDecisions', decList);

        return m;
    }

    private static List<PulseAiModels.ToolDefinition> agentToolDefinitions() {
        List<PulseAiModels.ToolDefinition> defs = new List<PulseAiModels.ToolDefinition>();
        defs.add(new PulseAiModels.ToolDefinition(
            TOOL_PROPOSE,
            'Propose a concrete HITL-gated tool call (e.g. send_email, update_record). '
                + 'Provide toolKey, arguments (object), and a short rationale.',
            new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'toolKey' => new Map<String, Object>{ 'type' => 'string' },
                    'arguments' => new Map<String, Object>{ 'type' => 'object' },
                    'rationale' => new Map<String, Object>{ 'type' => 'string' }
                },
                'required' => new List<String>{ 'toolKey', 'rationale' }
            }
        ));
        defs.add(new PulseAiModels.ToolDefinition(
            TOOL_ASK,
            'Ask the user for input. Use fieldKey when you need a phase field value; '
                + 'use inputType="free_text" for open-ended prompts.',
            new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'fieldKey' => new Map<String, Object>{ 'type' => 'string' },
                    'inputType' => new Map<String, Object>{ 'type' => 'string' },
                    'prompt' => new Map<String, Object>{ 'type' => 'string' },
                    'rationale' => new Map<String, Object>{ 'type' => 'string' }
                },
                'required' => new List<String>{ 'prompt', 'rationale' }
            }
        ));
        defs.add(new PulseAiModels.ToolDefinition(
            TOOL_ADVANCE,
            'Advance the workflow to a new phase by firing a transition signal.',
            new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'signal' => new Map<String, Object>{ 'type' => 'string' },
                    'rationale' => new Map<String, Object>{ 'type' => 'string' }
                },
                'required' => new List<String>{ 'signal', 'rationale' }
            }
        ));
        defs.add(new PulseAiModels.ToolDefinition(
            TOOL_OBSERVE,
            'Record a brief observation when no action is warranted this turn.',
            new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'note' => new Map<String, Object>{ 'type' => 'string' }
                },
                'required' => new List<String>{ 'note' }
            }
        ));
        return defs;
    }

    // ─── Response parsing ───────────────────────────────────────

    private static Agent_Decision__c parseResponseIntoDecision(
        PulseAiModels.Response resp, Agent_Thread__c thread, Workflow_Instance__c inst
    ) {
        if (resp.toolCalls == null || resp.toolCalls.isEmpty()) return null;
        // Use the first recognized agent tool call.
        for (PulseAiModels.ToolCall tc : resp.toolCalls) {
            Agent_Decision__c d = new Agent_Decision__c(
                Agent_Thread__c = thread.Id,
                Workflow_Instance__c = inst.Id,
                Phase_Key__c = inst.Current_State__c
            );
            Map<String, Object> args;
            try {
                args = (Map<String, Object>) JSON.deserializeUntyped(
                    String.isNotBlank(tc.inputJson) ? tc.inputJson : '{}'
                );
            } catch (Exception e) {
                d.Decision_Type__c = 'Error';
                d.Rationale__c = 'Agent produced invalid tool input: ' + e.getMessage();
                d.Proposal_JSON__c = tc.inputJson;
                d.Status__c = 'Skipped';
                return d;
            }
            if (tc.toolKey == TOOL_PROPOSE) {
                d.Decision_Type__c = 'Propose_Action';
                d.Rationale__c = (String) args.get('rationale');
                d.Proposal_JSON__c = JSON.serialize(new Map<String, Object>{
                    'toolKey' => args.get('toolKey'),
                    'arguments' => args.get('arguments') == null
                        ? new Map<String, Object>() : args.get('arguments')
                });
                return d;
            }
            if (tc.toolKey == TOOL_ASK) {
                d.Decision_Type__c = 'Ask_User';
                d.Rationale__c = (String) args.get('rationale');
                Map<String, Object> qMap = new Map<String, Object>{
                    'prompt' => args.get('prompt')
                };
                if (args.containsKey('fieldKey')) qMap.put('fieldKey', args.get('fieldKey'));
                if (args.containsKey('inputType')) qMap.put('inputType', args.get('inputType'));
                d.Question_JSON__c = JSON.serialize(qMap);
                return d;
            }
            if (tc.toolKey == TOOL_ADVANCE) {
                d.Decision_Type__c = 'Advance_Phase';
                d.Rationale__c = (String) args.get('rationale');
                d.Proposal_JSON__c = JSON.serialize(new Map<String, Object>{
                    'signal' => args.get('signal')
                });
                return d;
            }
            if (tc.toolKey == TOOL_OBSERVE) {
                d.Decision_Type__c = 'Observe';
                d.Rationale__c = (String) args.get('note');
                return d;
            }
        }
        return null;
    }

    // ─── Thread + decision helpers ──────────────────────────────

    private static Agent_Thread__c getOrCreateThreadInternal(
        Id instanceId, Workflow_Instance__c inst
    ) {
        Agent_Thread__c t = loadThreadInMemory(instanceId);
        if (t.Id == null) insert t;
        return t;
    }

    /**
     * Returns an Agent_Thread__c for the given instance WITHOUT doing any
     * DML. If none exists yet, the returned row has no Id — callers must
     * `upsert` it before persisting children that FK to it. This split is
     * required so the runTurn loop can make its HTTP callout before any
     * DML (Salesforce rule: callouts cannot run after uncommitted DML).
     */
    private static Agent_Thread__c loadThreadInMemory(Id instanceId) {
        List<Agent_Thread__c> existing = [
            SELECT Id, Workflow_Instance__c, Persona_Name__c, System_Prompt__c,
                   Autonomy_Level__c, Rolling_Summary__c, Last_Run_Date__c,
                   Status__c, Last_Error__c
            FROM Agent_Thread__c
            WHERE Workflow_Instance__c = :instanceId
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];
        return new Agent_Thread__c(
            Workflow_Instance__c = instanceId,
            Persona_Name__c = 'Claude',
            Autonomy_Level__c = AUT_ACT_WITH_APPROVAL,
            Status__c = 'Idle'
        );
    }

    private static Agent_Decision__c loadDecision(Id decisionId) {
        List<Agent_Decision__c> rows = [
            SELECT Id, Agent_Thread__c, Workflow_Instance__c, Phase_Key__c,
                   Decision_Type__c, Rationale__c, Proposal_JSON__c,
                   Question_JSON__c, Status__c, Related_Action__c,
                   User_Response_JSON__c
            FROM Agent_Decision__c
            WHERE Id = :decisionId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Workflow_Instance__c loadInstance(Id instanceId) {
        List<Workflow_Instance__c> rows = [
            SELECT Id, Current_State__c, Context_JSON__c, Status__c,
                   Parent_Record_Id__c, Parent_Object_Type__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Workflow_Key__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static void markDecisionResolved(Agent_Decision__c d, String status, String responseJson) {
        d.Status__c = status;
        d.Resolved_Date__c = Datetime.now();
        if (String.isNotBlank(responseJson)) d.User_Response_JSON__c = responseJson;
        update d;
    }

    private static void mergeIntoContext(Id instanceId, String fieldKey, Object value) {
        Workflow_Instance__c inst = [
            SELECT Id, Context_JSON__c FROM Workflow_Instance__c
            WHERE Id = :instanceId LIMIT 1
        ];
        Map<String, Object> ctx = String.isBlank(inst.Context_JSON__c)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(inst.Context_JSON__c);
        ctx.put(fieldKey, value);
        inst.Context_JSON__c = JSON.serialize(ctx);
        update inst;
    }

    private static void fireAdvance(Id instanceId, String signal) {
        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest();
        req.instanceId = instanceId;
        req.signal = signal;
        req.actorType = 'AI';
        req.actorUserId = UserInfo.getUserId();
        req.payloadJson = '{"source":"agent_advance"}';
        WorkflowRuntime.advance(new List<WorkflowAdvanceRequest>{ req });
    }

    private static Map<String, Object> parseMap(String jsonStr) {
        if (String.isBlank(jsonStr)) return new Map<String, Object>();
        try {
            Object o = JSON.deserializeUntyped(jsonStr);
            return o instanceof Map<String, Object>
                ? (Map<String, Object>) o : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static RunResult markError(Agent_Thread__c thread, RunResult r, String msg) {
        thread.Status__c = 'Error';
        thread.Last_Error__c = msg;
        // Thread may have no Id yet when the very first turn's callout fails
        // — upsert covers both insert and update paths.
        upsert thread;
        Agent_Decision__c d = new Agent_Decision__c(
            Agent_Thread__c = thread.Id,
            Workflow_Instance__c = thread.Workflow_Instance__c,
            Decision_Type__c = 'Error',
            Rationale__c = msg,
            Status__c = 'Skipped'
        );
        insert d;
        r.success = false;
        r.error = msg;
        r.decisionsCreated = 1;
        r.decisionIds.add(d.Id);
        r.status = 'Error';
        return r;
    }

    // ─── Context compaction ─────────────────────────────────────

    private static void maybeCompactSummary(Agent_Thread__c thread) {
        Integer count = [
            SELECT COUNT() FROM Agent_Decision__c
            WHERE Agent_Thread__c = :thread.Id
        ];
        if (count == 0) return;
        if (Math.mod(count, COMPACT_EVERY_N_DECISIONS) != 0) return;
        // Build a concise summary client-side (avoid a second AI roundtrip
        // when we can; real compaction via AI is exposed via compactSummary
        // for callers that want it).
        List<Agent_Decision__c> recent = [
            SELECT Decision_Type__c, Rationale__c, Status__c, CreatedDate
            FROM Agent_Decision__c
            WHERE Agent_Thread__c = :thread.Id
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
        List<String> lines = new List<String>();
        for (Integer i = recent.size() - 1; i >= 0; i--) {
            Agent_Decision__c d = recent[i];
            lines.add('- [' + d.Decision_Type__c + '/' + d.Status__c + '] '
                + (d.Rationale__c == null ? '' : d.Rationale__c));
        }
        String merged = 'Summary of last '
            + String.valueOf(recent.size())
            + ' decisions:\n'
            + String.join(lines, '\n');
        if (merged.length() > 30000) merged = merged.substring(0, 30000);
        thread.Rolling_Summary__c = merged;
        update thread;
    }

    /**
     * Called by HitlService / PhaseActionHook after a related
     * Workflow_Action__c resolves, to re-kick the agent.
     */
    public static void onActionResolved(Id workflowActionId) {
        if (workflowActionId == null) return;
        List<Agent_Decision__c> linked = [
            SELECT Id, Workflow_Instance__c, Status__c
            FROM Agent_Decision__c
            WHERE Related_Action__c = :workflowActionId
            LIMIT 1
        ];
        if (linked.isEmpty()) return;
        advance(linked[0].Workflow_Instance__c);
    }

    @TestVisible
    private static void setResponseForTest(PulseAiModels.Response resp) {
        responseForTest = resp;
    }

    @TestVisible
    private static void clearResponseForTest() {
        responseForTest = null;
    }
}

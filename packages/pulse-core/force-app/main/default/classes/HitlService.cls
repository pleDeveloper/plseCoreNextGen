public with sharing class HitlService {

    public static String evaluatePolicy(String toolKey, Id instanceId) {
        return PulseToolRegistry.getEffectiveHitlPolicy(toolKey);
    }

    public static Workflow_Action__c createApproval(
        Id instanceId,
        String toolKey,
        String requestJson,
        String policy
    ) {
        Workflow_Action__c action = new Workflow_Action__c(
            Workflow_Instance__c = instanceId,
            Tool_Key__c = toolKey,
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = policy,
            Request_JSON__c = requestJson,
            Status__c = 'Pending'
        );
        insert action;
        return action;
    }

    public static List<Workflow_Action__c> createApprovals(List<Workflow_Action__c> actions) {
        if (!actions.isEmpty()) {
            insert actions;
        }
        return actions;
    }

    public static PulseToolModels.Result resolveApproval(Id actionId, Boolean approved, Id resolvedById) {
        Workflow_Action__c action = [
            SELECT Id, Tool_Key__c, Request_JSON__c, Status__c, Workflow_Instance__c,
                   Action_Key__c, Phase_Key__c
            FROM Workflow_Action__c
            WHERE Id = :actionId
            LIMIT 1
        ];

        if (action.Status__c != 'Pending') {
            return PulseToolModels.fail('Action is not Pending: ' + action.Status__c);
        }

        if (!approved) {
            action.Status__c = 'Rejected';
            action.Resolved_By__c = resolvedById;
            action.Resolved_Date__c = Datetime.now();
            update action;

            writeAuditEvent(action.Workflow_Instance__c, 'TOOL_REJECTED', action.Tool_Key__c,
                JSON.serialize(new Map<String, String>{ 'actionId' => actionId }));

            return PulseToolModels.ok('{"status":"rejected"}');
        }

        PulseTool tool = PulseToolRegistry.getTool(action.Tool_Key__c);
        if (tool == null) {
            action.Status__c = 'Failed';
            action.Response_JSON__c = '{"error":"Tool not found"}';
            action.Resolved_By__c = resolvedById;
            action.Resolved_Date__c = Datetime.now();
            update action;
            return PulseToolModels.fail('Tool not found: ' + action.Tool_Key__c);
        }

        Map<String, Object> inputMap = (Map<String, Object>) JSON.deserializeUntyped(
            String.isNotBlank(action.Request_JSON__c) ? action.Request_JSON__c : '{}'
        );
        PulseToolModels.Context ctx = new PulseToolModels.Context(action.Workflow_Instance__c, inputMap);
        ctx.actorUserId = resolvedById;

        PulseToolModels.Result result = tool.execute(ctx);

        action.Status__c = result.success ? 'Executed' : 'Failed';
        action.Response_JSON__c = result.success ? result.outputJson : result.errorMessage;
        action.Resolved_By__c = resolvedById;
        action.Resolved_Date__c = Datetime.now();
        update action;

        String eventType = result.success ? 'TOOL_EXECUTED' : 'TOOL_FAILED';
        writeAuditEvent(action.Workflow_Instance__c, eventType, action.Tool_Key__c,
            JSON.serialize(new Map<String, String>{
                'actionId' => actionId,
                'output' => result.success ? result.outputJson : result.errorMessage
            }));

        // Phase/actions lifecycle: on successful execution, promote any
        // dependents whose deps just became satisfied, and auto-advance
        // the instance out of the phase if all required actions are done
        // and the phase's advancement mode is 'auto'.
        if (result.success && String.isNotBlank(action.Action_Key__c)) {
            try {
                PulseActionInstantiationService.promoteDependents(action.Id);
                autoAdvanceIfComplete(action.Workflow_Instance__c);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'HitlService: post-execute action lifecycle failed: ' + e.getMessage());
            }
        }

        return result;
    }

    /**
     * If the instance's current phase is fully done and its advancement
     * mode is 'auto' with exactly one outgoing transition, fire that
     * transition automatically.
     */
    private static void autoAdvanceIfComplete(Id instanceId) {
        if (instanceId == null) return;
        if (!PulseActionInstantiationService.phaseComplete(instanceId)) return;

        Workflow_Instance__c inst = [
            SELECT Id, Current_State__c, Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c WHERE Id = :instanceId LIMIT 1
        ];
        if (String.isBlank(inst.Current_State__c)) return;

        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
        } catch (Exception e) {
            return;
        }
        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase == null) return;
        if (phase.effectiveAdvancement() != 'auto') return;
        if (phase.transitions == null || phase.transitions.size() != 1) return;

        WorkflowContract.Transition t = phase.transitions[0];
        if (String.isBlank(t.signal) || String.isBlank(t.target)) return;

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest();
        req.instanceId = instanceId;
        req.signal     = t.signal;
        req.actorType  = 'System';
        req.payloadJson = '{"source":"phase_auto_advance"}';
        WorkflowRuntime.advance(new List<WorkflowAdvanceRequest>{ req });
    }

    public static void writeAuditEvent(
        Id instanceId, String eventType, String toolKey, String detailJson
    ) {
        insert new Workflow_Event__c(
            Workflow_Instance__c = instanceId,
            Event_Type__c = eventType,
            Actor_Type__c = 'AI',
            Detail_JSON__c = detailJson
        );
    }
}

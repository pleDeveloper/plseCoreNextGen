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
            SELECT Id, Tool_Key__c, Request_JSON__c, Status__c, Workflow_Instance__c
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

        return result;
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

public with sharing class PulseAgentRunner {

    public static final Integer MAX_TOOL_ITERATIONS = 10;

    public class RunResult {
        public Boolean success;
        public String responseText;
        public List<Workflow_Action__c> pendingApprovals;
        public List<Workflow_Event__c> auditEvents;
        public String errorMessage;

        public RunResult() {
            this.pendingApprovals = new List<Workflow_Action__c>();
            this.auditEvents = new List<Workflow_Event__c>();
            this.success = true;
        }
    }

    public static RunResult run(Id instanceId) {
        RunResult result = new RunResult();

        Workflow_Instance__c instance = [
            SELECT Id, Current_State__c, Context_JSON__c, Status__c,
                   Parent_Record_Id__c, Parent_Object_Type__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Definition_JSON__c,
                   Workflow_Definition__r.Workflow_Key__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId
            LIMIT 1
        ];

        if (instance.Status__c != 'Active') {
            result.success = false;
            result.errorMessage = 'Instance is not active: ' + instance.Status__c;
            return result;
        }

        PulseAiProvider.Request aiReq = PulseAiFacade.buildRequest(instance);
        PulseAiProvider.Response aiResp = PulseAiFacade.invoke(aiReq);

        Workflow_Event__c callEvent = new Workflow_Event__c(
            Workflow_Instance__c = instanceId,
            Event_Type__c = 'AI_CALL',
            Actor_Type__c = 'AI',
            Detail_JSON__c = JSON.serialize(new Map<String, Object>{
                'provider' => 'anthropic',
                'requestId' => aiResp.providerRequestId,
                'inputTokens' => aiResp.usage != null ? aiResp.usage.inputTokens : null,
                'outputTokens' => aiResp.usage != null ? aiResp.usage.outputTokens : null
            })
        );

        if (aiResp.isError) {
            result.success = false;
            result.errorMessage = aiResp.errorMessage;
            callEvent.Event_Type__c = 'AI_ERROR';
            result.auditEvents.add(callEvent);
            insertEvents(result.auditEvents);
            return result;
        }

        result.auditEvents.add(callEvent);
        result.responseText = aiResp.text;

        if (aiResp.toolCalls != null && !aiResp.toolCalls.isEmpty()) {
            processToolCalls(instance, aiResp.toolCalls, result);
        }

        insertEvents(result.auditEvents);

        if (!result.pendingApprovals.isEmpty()) {
            HitlService.createApprovals(result.pendingApprovals);
        }

        return result;
    }

    private static void processToolCalls(
        Workflow_Instance__c instance,
        List<PulseAiProvider.ToolCall> toolCalls,
        RunResult result
    ) {
        for (PulseAiProvider.ToolCall tc : toolCalls) {
            PulseTool tool = PulseToolRegistry.getTool(tc.toolKey);

            if (tool == null) {
                result.auditEvents.add(buildAuditEvent(
                    instance.Id, 'TOOL_NOT_FOUND', tc.toolKey,
                    new Map<String, String>{ 'toolCallId' => tc.id }
                ));
                continue;
            }

            String policy = HitlService.evaluatePolicy(tc.toolKey, instance.Id);

            if (policy == 'Disabled') {
                result.auditEvents.add(buildAuditEvent(
                    instance.Id, 'TOOL_DISABLED', tc.toolKey,
                    new Map<String, String>{ 'toolCallId' => tc.id }
                ));
                continue;
            }

            Map<String, Object> inputMap;
            try {
                inputMap = (Map<String, Object>) JSON.deserializeUntyped(
                    String.isNotBlank(tc.inputJson) ? tc.inputJson : '{}'
                );
            } catch (Exception e) {
                result.auditEvents.add(buildAuditEvent(
                    instance.Id, 'TOOL_INVALID_INPUT', tc.toolKey,
                    new Map<String, String>{
                        'toolCallId' => tc.id,
                        'error' => e.getMessage()
                    }
                ));
                continue;
            }

            if (policy == 'Approval_Required') {
                Workflow_Action__c action = new Workflow_Action__c(
                    Workflow_Instance__c = instance.Id,
                    Tool_Key__c = tc.toolKey,
                    Action_Type__c = 'AI_Tool_Call',
                    HITL_Policy__c = policy,
                    Request_JSON__c = tc.inputJson,
                    Status__c = 'Pending'
                );
                result.pendingApprovals.add(action);

                result.auditEvents.add(buildAuditEvent(
                    instance.Id, 'TOOL_APPROVAL_REQUESTED', tc.toolKey,
                    new Map<String, String>{ 'toolCallId' => tc.id }
                ));
                continue;
            }

            PulseTool.Context ctx = new PulseTool.Context(instance.Id, inputMap);
            ctx.parentRecordId = instance.Parent_Record_Id__c != null
                ? Id.valueOf(instance.Parent_Record_Id__c) : null;
            ctx.parentObjectType = instance.Parent_Object_Type__c;
            ctx.actorUserId = UserInfo.getUserId();

            PulseTool.Result toolResult = tool.execute(ctx);

            String eventType = toolResult.success ? 'TOOL_EXECUTED' : 'TOOL_FAILED';
            result.auditEvents.add(buildAuditEvent(
                instance.Id, eventType, tc.toolKey,
                new Map<String, String>{
                    'toolCallId' => tc.id,
                    'output' => toolResult.success
                        ? toolResult.outputJson : toolResult.errorMessage
                }
            ));

            if (policy == 'Review_After' && toolResult.success) {
                Workflow_Action__c reviewAction = new Workflow_Action__c(
                    Workflow_Instance__c = instance.Id,
                    Tool_Key__c = tc.toolKey,
                    Action_Type__c = 'AI_Tool_Call',
                    HITL_Policy__c = 'Review_After',
                    Request_JSON__c = tc.inputJson,
                    Response_JSON__c = toolResult.outputJson,
                    Status__c = 'Executed'
                );
                result.pendingApprovals.add(reviewAction);
            }
        }
    }

    private static Workflow_Event__c buildAuditEvent(
        Id instanceId, String eventType, String toolKey, Map<String, String> details
    ) {
        details.put('toolKey', toolKey);
        return new Workflow_Event__c(
            Workflow_Instance__c = instanceId,
            Event_Type__c = eventType,
            Actor_Type__c = 'AI',
            Detail_JSON__c = JSON.serialize(details)
        );
    }

    private static void insertEvents(List<Workflow_Event__c> events) {
        if (!events.isEmpty()) {
            insert events;
        }
    }
}

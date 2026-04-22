global with sharing class PulseInboundEmailHandler implements Messaging.InboundEmailHandler {

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email, Messaging.InboundEnvelope env
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

        // 1. Existing [Pulse:<id>] tag in subject — routes to a known instance.
        Id instanceId = PulseEmailRouter.extractInstanceId(email.subject);

        // 2. Legacy contact→open-instance path (pre-router behavior).
        if (instanceId == null) {
            instanceId = PulseEmailRouter.routeByContactEmail(email.fromAddress);
        }

        // 3. Router: evaluate rules to find/create a parent record. If we
        //    end up creating an Opportunity and the rule names a workflow,
        //    start one so the record lights up immediately on the record
        //    page.
        InboundRecordRouter.RouteResult rr = null;
        if (instanceId == null) {
            rr = InboundRecordRouter.route(email.fromAddress, email.subject, null);
            if (rr != null && rr.recordId != null
                    && String.isNotBlank(rr.triggerWorkflowKey)) {
                instanceId = ensureWorkflowInstance(
                    rr.recordId, rr.objectType, rr.triggerWorkflowKey
                );
            }
        }

        PulseConversationModels.ConversationInput input =
            PulseEmailRouter.buildConversationInput(email, instanceId);

        // If the router matched/created a parent record but no workflow
        // instance, still attach the parent so Conversation__c lands on
        // the correct record.
        if (instanceId == null && rr != null && rr.recordId != null) {
            input.parentRecordId = String.valueOf(rr.recordId);
            input.parentObjectType = rr.objectType;
        }

        ConversationIngestionService.ingest(
            new List<PulseConversationModels.ConversationInput>{ input }
        );

        result.success = true;
        return result;
    }

    /**
     * Ensures a Workflow_Instance__c exists for (workflowKey, parentRecordId).
     * Returns the instance id, or null if the workflow definition or its
     * first state can't be resolved.
     */
    private static Id ensureWorkflowInstance(
        Id recordId, String objectType, String workflowKey
    ) {
        if (recordId == null || String.isBlank(workflowKey)) return null;

        // Resolve definition by key (latest published, else any)
        List<Workflow_Definition__c> defs = [
            SELECT Id, Definition_JSON__c, Status__c, Version__c
            FROM Workflow_Definition__c
            WHERE Workflow_Key__c = :workflowKey
            ORDER BY Status__c DESC, Version__c DESC NULLS LAST
            LIMIT 1
        ];
        if (defs.isEmpty()) return null;
        Workflow_Definition__c def = defs[0];

        // If an active instance already exists, reuse it.
        String recordIdStr = String.valueOf(recordId);
        List<Workflow_Instance__c> existing = [
            SELECT Id
            FROM Workflow_Instance__c
            WHERE Workflow_Definition__c = :def.Id
              AND Parent_Record_Id__c = :recordIdStr
              AND Status__c = 'Active'
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0].Id;

        String firstState = firstStateKey(def.Definition_JSON__c);
        if (String.isBlank(firstState)) return null;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Parent_Object_Type__c  = objectType,
            Parent_Record_Id__c    = recordIdStr,
            Current_State__c       = firstState,
            Status__c              = 'Active',
            Started_Date__c        = Datetime.now(),
            Pinned_Version__c      = def.Version__c != null ? def.Version__c.intValue() : 1
        );
        try {
            insert inst;
            return inst.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'PulseInboundEmailHandler: failed to start workflow ' +
                workflowKey + ' on ' + recordId + ': ' + e.getMessage());
            return null;
        }
    }

    private static String firstStateKey(String definitionJson) {
        if (String.isBlank(definitionJson)) return null;
        try {
            Object parsed = JSON.deserializeUntyped(definitionJson);
            if (!(parsed instanceof Map<String, Object>)) return null;
            Map<String, Object> root = (Map<String, Object>) parsed;
            List<Object> states = (List<Object>) root.get('states');
            if (states == null || states.isEmpty()) return null;
            Object first = states[0];
            if (!(first instanceof Map<String, Object>)) return null;
            return (String) ((Map<String, Object>) first).get('key');
        } catch (Exception e) {
            return null;
        }
    }
}

@IsTest
private class ConversationTurnAgentTriggerTest {

    private static final String AI_DRIVEN_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"trigger_test_wf","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
        '{"key":"ai_state","label":"AI State","type":"ai_driven",' +
        '"toolConfig":{"toolKey":"send_email","hitlPolicy":"Approval_Required"},' +
        '"transitions":[{"signal":"done","to":"closed"}]},' +
        '{"key":"closed","label":"Closed","type":"terminal","transitions":[]}' +
        ']}';

    private static final String HUMAN_ONLY_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"trigger_test_human","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
        '{"key":"human_state","label":"Human State","type":"form",' +
        '"transitions":[{"signal":"done","to":"closed"}]},' +
        '{"key":"closed","label":"Closed","type":"terminal","transitions":[]}' +
        ']}';

    @TestSetup
    static void setup() {
        // Suppress extraction so conversation inserts stay isolated
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

        // AI-driven definition + instance
        Workflow_Definition__c aiDef = new Workflow_Definition__c(
            Workflow_Key__c = 'trigger_test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = AI_DRIVEN_CONTRACT,
            Subject_Kinds__c = 'Opportunity'
        );
        insert aiDef;

        Workflow_Instance__c aiInst = new Workflow_Instance__c(
            Workflow_Definition__c = aiDef.Id,
            Current_State__c = 'ai_state',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity'
        );
        insert aiInst;

        // Human-only definition + instance
        Workflow_Definition__c humanDef = new Workflow_Definition__c(
            Workflow_Key__c = 'trigger_test_human',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = HUMAN_ONLY_CONTRACT,
            Subject_Kinds__c = 'Opportunity'
        );
        insert humanDef;

        Workflow_Instance__c humanInst = new Workflow_Instance__c(
            Workflow_Definition__c = humanDef.Id,
            Current_State__c = 'human_state',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity'
        );
        insert humanInst;

        // Conversation linked to AI instance
        Conversation__c aiConv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'AI conv',
            Source_Adapter__c = 'test',
            Status__c = 'Ingested',
            Workflow_Instance__c = aiInst.Id
        );
        insert aiConv;

        // Conversation linked to human instance
        Conversation__c humanConv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Human conv',
            Source_Adapter__c = 'test',
            Status__c = 'Ingested',
            Workflow_Instance__c = humanInst.Id
        );
        insert humanConv;
    }

    @IsTest
    static void turnOnAiInstance_enqueuesQueueable() {
        Conversation__c conv = [
            SELECT Id FROM Conversation__c WHERE Subject__c = 'AI conv' LIMIT 1
        ];

        Test.startTest();
        insert new Conversation_Turn__c(
            Conversation__c = conv.Id,
            Content__c = 'Hello, I need info',
            Role__c = 'Customer',
            Turn_Index__c = 0
        );
        Test.stopTest();

        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'PulseAgentInvokerQueueable'
              AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing', 'Completed')
        ];
        System.assert(jobCount >= 1, 'Should enqueue at least one Queueable for AI-driven instance');
    }

    @IsTest
    static void turnOnHumanInstance_noQueueable() {
        Conversation__c conv = [
            SELECT Id FROM Conversation__c WHERE Subject__c = 'Human conv' LIMIT 1
        ];

        Test.startTest();
        insert new Conversation_Turn__c(
            Conversation__c = conv.Id,
            Content__c = 'Human-only turn',
            Role__c = 'Customer',
            Turn_Index__c = 0
        );
        Test.stopTest();

        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'PulseAgentInvokerQueueable'
              AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing', 'Completed')
        ];
        System.assertEquals(0, jobCount, 'Should NOT enqueue Queueable for human-only instance');
    }

    @IsTest
    static void bulkTurns_deduplicatesToOnePerInstance() {
        // Create 10 AI instances each with a conversation
        List<Workflow_Definition__c> defs = [
            SELECT Id FROM Workflow_Definition__c
            WHERE Workflow_Key__c = 'trigger_test_wf' LIMIT 1
        ];
        Id defId = defs[0].Id;

        List<Workflow_Instance__c> bulkInstances = new List<Workflow_Instance__c>();
        for (Integer i = 0; i < 10; i++) {
            bulkInstances.add(new Workflow_Instance__c(
                Workflow_Definition__c = defId,
                Current_State__c = 'ai_state',
                Status__c = 'Active',
                Parent_Object_Type__c = 'Opportunity'
            ));
        }
        insert bulkInstances;

        List<Conversation__c> bulkConvs = new List<Conversation__c>();
        for (Workflow_Instance__c inst : bulkInstances) {
            bulkConvs.add(new Conversation__c(
                Medium__c = 'Email',
                Subject__c = 'Bulk ' + inst.Id,
                Source_Adapter__c = 'test',
                Status__c = 'Ingested',
                Workflow_Instance__c = inst.Id
            ));
        }
        insert bulkConvs;

        // 50 turns across the 10 instances (5 per instance)
        List<Conversation_Turn__c> turns = new List<Conversation_Turn__c>();
        for (Integer i = 0; i < bulkConvs.size(); i++) {
            for (Integer j = 0; j < 5; j++) {
                turns.add(new Conversation_Turn__c(
                    Conversation__c = bulkConvs[i].Id,
                    Content__c = 'Bulk turn ' + j,
                    Role__c = 'Customer',
                    Turn_Index__c = j
                ));
            }
        }

        Test.startTest();
        insert turns;
        Test.stopTest();

        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'PulseAgentInvokerQueueable'
              AND Status IN ('Queued', 'Holding', 'Preparing', 'Processing', 'Completed')
        ];
        System.assertEquals(10, jobCount,
            'Should enqueue exactly 10 Queueables (one per unique AI-eligible instance)');
    }

    @IsTest
    static void turnOnUnlinkedConversation_noQueueable() {
        // Conversation with no Workflow_Instance__c — trigger should exit early
        Conversation__c unlinked = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Unlinked conv',
            Source_Adapter__c = 'test',
            Status__c = 'Ingested'
        );
        insert unlinked;

        Test.startTest();
        insert new Conversation_Turn__c(
            Conversation__c = unlinked.Id,
            Content__c = 'Unlinked turn',
            Role__c = 'System',
            Turn_Index__c = 0
        );
        Test.stopTest();

        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'PulseAgentInvokerQueueable'
        ];
        System.assertEquals(0, jobCount, 'No Queueable for unlinked conversation');
    }
}

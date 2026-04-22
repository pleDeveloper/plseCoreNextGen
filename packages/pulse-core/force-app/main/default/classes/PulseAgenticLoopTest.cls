@IsTest
private class PulseAgenticLoopTest {

    private static final String CONTRACT_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"agentic_loop_test","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
        '{"key":"intake_qualification","label":"Intake Qualification","type":"ai_driven",' +
        '"toolConfig":{"toolKey":"send_email","hitlPolicy":"Approval_Required",' +
        '"parameters":{"systemPrompt":"Draft a follow-up email asking for missing qualifying info."}},' +
        '"transitions":[{"signal":"qualified","to":"credit_review"},{"signal":"disqualified","to":"declined"}]},' +
        '{"key":"credit_review","label":"Credit Review","type":"approval","transitions":[{"signal":"approve","to":"closed"}]},' +
        '{"key":"declined","label":"Declined","type":"terminal","transitions":[]},' +
        '{"key":"closed","label":"Closed","type":"terminal","transitions":[]}' +
        ']}';

    @TestSetup
    static void setup() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'agentic_loop_test',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = CONTRACT_JSON,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;

        Opportunity opp = new Opportunity(
            Name = 'Agentic Loop Test Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'intake_qualification',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id,
            Context_JSON__c = '{"applicant_name":"Test Corp","requested_sqft":5000}'
        );
        insert inst;

        Conversation__c conv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Lease inquiry',
            Source_Adapter__c = 'inbound_email',
            Status__c = 'Ingested',
            Workflow_Instance__c = inst.Id,
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id
        );
        insert conv;
    }

    @IsTest
    static void fullLoop_turnTriggersAgentCreatesApprovalThenExecutes() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        // Wire mock AI provider that returns a send_email tool call
        PulseAiFacade.setProviderForTest(new MockAiProvider());
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new StubEmailTool());

        Conversation__c conv = [SELECT Id FROM Conversation__c LIMIT 1];
        Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        // Insert a conversation turn — this fires the trigger, which enqueues
        // PulseAgentInvokerQueueable, which calls PulseAgentRunner.run().
        Test.startTest();
        insert new Conversation_Turn__c(
            Conversation__c = conv.Id,
            Content__c = 'We are interested in 5,000 sqft. What info do you need from us?',
            Role__c = 'Customer',
            Speaker__c = 'Test Prospect',
            Turn_Index__c = 0
        );
        Test.stopTest();

        // Assert: Queueable executed
        Integer jobCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'PulseAgentInvokerQueueable'
              AND Status IN ('Completed', 'Queued', 'Holding', 'Preparing', 'Processing')
        ];
        System.assert(jobCount >= 1, 'PulseAgentInvokerQueueable should have been enqueued');

        // Assert: Pending approval created
        List<Workflow_Action__c> actions = [
            SELECT Id, Status__c, Tool_Key__c, Request_JSON__c, HITL_Policy__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id
            ORDER BY CreatedDate DESC
        ];
        System.assert(!actions.isEmpty(), 'Should have at least one Workflow_Action__c');

        Workflow_Action__c pendingAction = actions[0];
        System.assertEquals('Pending', pendingAction.Status__c);
        System.assertEquals('send_email', pendingAction.Tool_Key__c);
        System.assertEquals('Approval_Required', pendingAction.HITL_Policy__c);
        System.assert(pendingAction.Request_JSON__c.contains('toAddress'),
            'Request JSON should contain email parameters');

        // Assert: audit events logged
        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        Set<String> eventTypes = new Set<String>();
        for (Workflow_Event__c e : events) {
            eventTypes.add(e.Event_Type__c);
        }
        System.assert(eventTypes.contains('AI_CALL'), 'Should have AI_CALL event');
        System.assert(eventTypes.contains('TOOL_APPROVAL_REQUESTED'),
            'Should have TOOL_APPROVAL_REQUESTED event');

        // Phase 2: approve the action
        PulseToolModels.Result approvalResult = HitlService.resolveApproval(
            pendingAction.Id, true, UserInfo.getUserId()
        );
        System.assertEquals(true, approvalResult.success, 'Approval should succeed');

        Workflow_Action__c executed = [
            SELECT Status__c, Response_JSON__c FROM Workflow_Action__c
            WHERE Id = :pendingAction.Id
        ];
        System.assertEquals('Executed', executed.Status__c);
        System.assert(executed.Response_JSON__c.contains('sent'),
            'Response should confirm email sent');
    }

    @IsTest
    static void filterAiDrivenInstances_returnsOnlyEligible() {
        Workflow_Instance__c aiInst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        // Create a human-only instance
        Workflow_Definition__c humanDef = new Workflow_Definition__c(
            Workflow_Key__c = 'agentic_loop_human',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c =
                '{"schema":"pulse.workflow.v1","workflowKey":"agentic_loop_human","version":1,' +
                '"subjectKinds":["Opportunity"],"states":[' +
                '{"key":"manual","label":"Manual","type":"form","transitions":[]}]}',
            Subject_Kinds__c = 'Opportunity'
        );
        insert humanDef;

        Workflow_Instance__c humanInst = new Workflow_Instance__c(
            Workflow_Definition__c = humanDef.Id,
            Current_State__c = 'manual',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity'
        );
        insert humanInst;

        Set<Id> candidates = new Set<Id>{ aiInst.Id, humanInst.Id };

        Test.startTest();
        Set<Id> eligible = PulseAgentInvoker.filterAiDrivenInstances(candidates);
        Test.stopTest();

        System.assert(eligible.contains(aiInst.Id), 'AI-driven instance should be eligible');
        System.assert(!eligible.contains(humanInst.Id), 'Human-only instance should NOT be eligible');
    }

    @IsTest
    static void emailRouterExtractInstanceId_parsesTag() {
        Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        Id parsed = PulseEmailRouter.extractInstanceId(
            'Re: Lease question [Pulse:' + inst.Id + '] follow-up'
        );
        System.assertEquals(inst.Id, parsed, 'Should extract instance Id from subject');

        Id noTag = PulseEmailRouter.extractInstanceId('No tag here');
        System.assertEquals(null, noTag, 'Should return null when no tag present');

        Id blank = PulseEmailRouter.extractInstanceId(null);
        System.assertEquals(null, blank, 'Should return null for null subject');
    }

    @IsTest
    static void queueableLogsEventOnCompletion() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAiFacade.setProviderForTest(new MockAiProvider());
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new StubEmailTool());

        Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        Test.startTest();
        System.enqueueJob(new PulseAgentInvokerQueueable(inst.Id));
        Test.stopTest();

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id
              AND Event_Type__c = 'AGENT_COMPLETED'
        ];
        System.assertEquals(1, events.size(),
            'Queueable should log AGENT_COMPLETED event');
    }

    // ─── Mock AI Provider ────────────────────────────────────────────

    private class MockAiProvider implements PulseAiProvider {
        public void configure(String namedCredential, String modelId) {}

        public PulseAiModels.Response chat(PulseAiModels.Request req) {
            PulseAiModels.Response resp = new PulseAiModels.Response();
            resp.providerRequestId = 'mock_agentic_loop_001';
            resp.usage = new PulseAiModels.Usage();
            resp.usage.inputTokens = 50;
            resp.usage.outputTokens = 30;
            resp.text = 'I will draft a follow-up email requesting missing qualification details.';

            PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
            tc.id = 'toolu_loop_001';
            tc.toolKey = 'send_email';
            tc.inputJson = JSON.serialize(new Map<String, String>{
                'toAddress' => 'prospect@testcorp.com',
                'subject' => 'Additional information needed for your lease application',
                'body' => 'Thank you for your interest. To proceed with qualification, '
                    + 'we need: 1) Expected headcount 2) Desired move-in date '
                    + '3) Credit qualification documentation.'
            });
            resp.toolCalls.add(tc);

            return resp;
        }
    }

    // ─── Stub Email Tool ─────────────────────────────────────────────

    private class StubEmailTool implements PulseTool {
        public String getToolKey() { return 'send_email'; }
        public String getDescription() { return 'Send email (test stub)'; }
        public Map<String, Object> getInputSchema() {
            return new Map<String, Object>{ 'type' => 'object' };
        }
        public String getDefaultHitlPolicy() { return 'Approval_Required'; }
        public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
            return PulseToolModels.ok('{"status":"sent","toAddress":"prospect@testcorp.com"}');
        }
    }
}

@IsTest
private class PulseEmailRouterControllerTest {

    @IsTest
    static void listUnroutedEmails_returnsPendingConversations() {
        // Suppress side-effects from extraction
        ConversationIngestionService.suppressExtractionEnqueue = true;

        Conversation__c unrouted = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Subject A',
            Participants__c = 'Alice; alice@example.com',
            Source_Adapter__c = 'inbound_email',
            External_Source__c = 'InboundEmail',
            Ingested_Date__c = Datetime.now(),
            Status__c = 'Ingested'
        );
        insert unrouted;

        insert new Conversation_Turn__c(
            Conversation__c = unrouted.Id,
            Content__c = 'Hello there, inquiring minds want to know.',
            Role__c = 'Customer',
            Speaker__c = 'Alice',
            Turn_Index__c = 0,
            Timestamp__c = Datetime.now()
        );

        // Already-routed conversation — should not appear
        Opportunity opp = new Opportunity(
            Name = 'Attached', StageName = 'Qualification', CloseDate = Date.today().addDays(10)
        );
        insert opp;
        insert new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Routed',
            Participants__c = 'Bob; bob@example.com',
            Source_Adapter__c = 'inbound_email',
            Parent_Record_Id__c = opp.Id,
            Parent_Object_Type__c = 'Opportunity',
            Ingested_Date__c = Datetime.now(),
            Status__c = 'Ingested'
        );

        Test.startTest();
        List<PulseEmailRouterController.UnroutedEmailView> views =
            PulseEmailRouterController.listUnroutedEmails();
        Test.stopTest();

        System.assertEquals(1, views.size());
        System.assertEquals(unrouted.Id, views[0].conversationId);
        System.assertEquals('alice@example.com', views[0].senderEmail);
        System.assert(views[0].snippet.contains('Hello there'));
    }

    @IsTest
    static void listRoutingRules_pullsFromCmdt() {
        Test.startTest();
        List<PulseEmailRouterController.RoutingRuleView> rules =
            PulseEmailRouterController.listRoutingRules();
        Test.stopTest();

        // Default rule ships with the package; in tests we can't guarantee
        // a value but the method must be callable without throwing.
        System.assertNotEquals(null, rules);
    }

    @IsTest
    static void routeToExistingRecord_setsParentOnConversation() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        Conversation__c c = new Conversation__c(
            Medium__c = 'Email', Subject__c = 'Hey',
            Source_Adapter__c = 'inbound_email',
            Participants__c = 'you@x.com',
            Status__c = 'Ingested',
            Ingested_Date__c = Datetime.now()
        );
        insert c;

        Opportunity opp = new Opportunity(
            Name = 'Target', StageName = 'Qualification', CloseDate = Date.today().addDays(10)
        );
        insert opp;

        Test.startTest();
        PulseEmailRouterController.RouteActionResult r =
            PulseEmailRouterController.routeToExistingRecord(c.Id, opp.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        Conversation__c reloaded = [
            SELECT Parent_Record_Id__c, Parent_Object_Type__c FROM Conversation__c WHERE Id = :c.Id
        ];
        System.assertEquals(opp.Id, (Id) reloaded.Parent_Record_Id__c);
        System.assertEquals('Opportunity', reloaded.Parent_Object_Type__c);
    }

    @IsTest
    static void createOpportunityFromConversation_routesViaDefaultRule() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        // Inject a test rule since CMDT can't be inserted
        Conversation_Routing_Rule__mdt rule = new Conversation_Routing_Rule__mdt();
        rule.DeveloperName = 'x';
        rule.Rule_Key__c   = 'x';
        rule.Active__c     = true;
        rule.Priority__c   = 100;
        rule.Match_Strategy__c = 'EMAIL_SENDER_TO_CONTACT';
        rule.Target_Object__c  = 'Opportunity';
        rule.Create_Defaults_JSON__c =
            '{"StageName":"Qualification","CloseDate":"+30d","Name":"Inq {senderEmail}"}';
        rule.Trigger_Workflow_Key__c = null;
        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>{ rule };

        Conversation__c c = new Conversation__c(
            Medium__c = 'Email', Subject__c = 'hi',
            Source_Adapter__c = 'inbound_email',
            Participants__c = 'Stranger; stranger@example.com',
            Status__c = 'Ingested', Ingested_Date__c = Datetime.now()
        );
        insert c;

        Test.startTest();
        PulseEmailRouterController.RouteActionResult r =
            PulseEmailRouterController.createOpportunityFromConversation(c.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Error from router: ' + r.error);
        System.assertEquals(true, r.wasCreated);
        Conversation__c reloaded = [
            SELECT Parent_Record_Id__c, Parent_Object_Type__c FROM Conversation__c WHERE Id = :c.Id
        ];
        System.assertEquals('Opportunity', reloaded.Parent_Object_Type__c);
        System.assertNotEquals(null, reloaded.Parent_Record_Id__c);
    }

    @IsTest
    static void firstEmailOrName_picksEmailToken() {
        System.assertEquals('a@b.com',
            PulseEmailRouterController.firstEmailOrName('Alice; a@b.com; leasing@us.com'));
        System.assertEquals('OnlyName',
            PulseEmailRouterController.firstEmailOrName('OnlyName'));
        System.assertEquals(null,
            PulseEmailRouterController.firstEmailOrName(''));
    }

    @IsTest
    static void routeToExistingRecord_rejectsNullArgs() {
        PulseEmailRouterController.RouteActionResult r1 =
            PulseEmailRouterController.routeToExistingRecord(null, null);
        System.assertEquals(false, r1.success);
    }
}

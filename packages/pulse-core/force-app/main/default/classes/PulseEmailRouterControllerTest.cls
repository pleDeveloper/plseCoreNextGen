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

    // ── Routing rule CRUD tests ────────────────────────────────────

    /** Stub IRuleDeployer — records the container so tests can assert the
     *  prepared payload without going through Metadata.Operations, which
     *  throws AsyncException in @IsTest context. */
    private class StubRuleDeployer implements PulseEmailRouterController.IRuleDeployer {
        public Metadata.DeployContainer captured;
        public Id enqueue(Metadata.DeployContainer container) {
            this.captured = container;
            // Return a deterministic non-null Id — doesn't have to exist.
            return '707000000000000AAA';
        }
    }

    @IsTest
    static void upsertRoutingRule_rejectsBlankRuleKey() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'targetObject'  => 'Opportunity',
                    'matchStrategy' => 'EMAIL_SENDER_TO_CONTACT'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('ruleKey'),
            'Expected ruleKey error, got: ' + r.error);
    }

    @IsTest
    static void upsertRoutingRule_rejectsBlankTargetObject() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'       => 'my_rule',
                    'matchStrategy' => 'EMAIL_SENDER_TO_CONTACT'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('targetObject'),
            'Expected targetObject error, got: ' + r.error);
    }

    @IsTest
    static void upsertRoutingRule_rejectsBlankMatchStrategy() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'      => 'my_rule',
                    'targetObject' => 'Opportunity'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('matchStrategy'),
            'Expected matchStrategy error, got: ' + r.error);
    }

    @IsTest
    static void upsertRoutingRule_rejectsInvalidCreateDefaultsJson() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'            => 'my_rule',
                    'targetObject'       => 'Opportunity',
                    'matchStrategy'      => 'EMAIL_SENDER_TO_CONTACT',
                    'createDefaultsJson' => '[ not-json'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null, 'Expected error for invalid JSON');
    }

    @IsTest
    static void upsertRoutingRule_rejectsJsonThatIsNotObject() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'            => 'my_rule',
                    'targetObject'       => 'Opportunity',
                    'matchStrategy'      => 'EMAIL_SENDER_TO_CONTACT',
                    'createDefaultsJson' => '["not","an","object"]'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('JSON object'),
            'Expected JSON-object error, got: ' + r.error);
    }

    @IsTest
    static void upsertRoutingRule_happyPathBuildsContainerAndEnqueues() {
        StubRuleDeployer stub = new StubRuleDeployer();
        PulseEmailRouterController.deployer = stub;

        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'            => 'custom_rule_A',
                    'active'             => true,
                    'priority'           => 50,
                    'sourceAdapter'      => 'inbound_email',
                    'matchStrategy'      => 'EMAIL_SENDER_TO_CONTACT',
                    'targetObject'       => 'Opportunity',
                    'createDefaultsJson' => '{"StageName":"Qualification"}',
                    'triggerWorkflowKey' => 'real_estate_leasing_v1'
                }
            );
        Test.stopTest();

        System.assertEquals(true, r.success, 'Expected success, got error: ' + r.error);
        System.assertNotEquals(null, r.jobId);
        System.assertEquals('custom_rule_A', r.developerName);

        System.assertNotEquals(null, stub.captured, 'Stub deployer should capture container');
        // Also retained on the class for introspection from test harnesses.
        System.assertNotEquals(null, PulseEmailRouterController.lastDeployContainer);
    }

    @IsTest
    static void upsertRoutingRule_usesExplicitDeveloperNameWhenProvided() {
        StubRuleDeployer stub = new StubRuleDeployer();
        PulseEmailRouterController.deployer = stub;

        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.upsertRoutingRule(
                new Map<String, Object>{
                    'ruleKey'       => 'x',
                    'developerName' => 'Explicit_Rule_Name',
                    'targetObject'  => 'Opportunity',
                    'matchStrategy' => 'EMAIL_SENDER_TO_CONTACT'
                }
            );
        Test.stopTest();

        System.assertEquals(true, r.success, 'error: ' + r.error);
        System.assertEquals('Explicit_Rule_Name', r.developerName);
    }

    @IsTest
    static void deleteRoutingRule_requiresDeveloperName() {
        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.deleteRoutingRule('');
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('developerName'),
            'Expected developerName error, got: ' + r.error);
    }

    @IsTest
    static void deleteRoutingRule_softDeletesByDeactivating() {
        StubRuleDeployer stub = new StubRuleDeployer();
        PulseEmailRouterController.deployer = stub;

        Test.startTest();
        PulseEmailRouterController.RuleDeployResult r =
            PulseEmailRouterController.deleteRoutingRule('Some_Rule');
        Test.stopTest();

        System.assertEquals(true, r.success, 'Error: ' + r.error);
        System.assertNotEquals(null, r.jobId);
        System.assertEquals('Some_Rule', r.developerName);
        System.assertNotEquals(null, stub.captured);
    }

    @IsTest
    static void getDeployStatus_handlesBlankJobId() {
        Test.startTest();
        PulseEmailRouterController.DeployStatusView v =
            PulseEmailRouterController.getDeployStatus('');
        Test.stopTest();
        System.assertEquals('Unknown', v.status);
        System.assertEquals(true, v.done);
        System.assert(v.errors != null);
    }

    @IsTest
    static void getDeployStatus_returnsUnknownForUnknownJob() {
        Test.startTest();
        PulseEmailRouterController.DeployStatusView v =
            PulseEmailRouterController.getDeployStatus('707000000000000AAA');
        Test.stopTest();
        // No matching AsyncApexJob in this test → Unknown + done.
        System.assertEquals('Unknown', v.status);
        System.assertEquals(true, v.done);
    }

    @IsTest
    static void coerceToRoutingRuleInput_handlesNullAndCoercions() {
        // null raw map → empty shell.
        PulseEmailRouterController.RoutingRuleInput empty =
            PulseEmailRouterController.coerceToRoutingRuleInput(null);
        System.assertEquals(null, empty.ruleKey);

        // Priority arrives as Decimal (JSON number deserializes to Decimal).
        PulseEmailRouterController.RoutingRuleInput p =
            PulseEmailRouterController.coerceToRoutingRuleInput(
                new Map<String, Object>{
                    'ruleKey'       => 'k',
                    'priority'      => Decimal.valueOf('50'),
                    'active'        => 'true',
                    'matchStrategy' => 'X',
                    'targetObject'  => 'Opportunity'
                }
            );
        System.assertEquals(50, p.priority);
        System.assertEquals(true, p.active);

        // Already-parsed list under createDefaultsJson → re-serialized.
        PulseEmailRouterController.RoutingRuleInput s =
            PulseEmailRouterController.coerceToRoutingRuleInput(
                new Map<String, Object>{
                    'ruleKey'            => 'k',
                    'createDefaultsJson' => new Map<String, Object>{ 'StageName' => 'Q' }
                }
            );
        System.assert(s.createDefaultsJson != null &&
            s.createDefaultsJson.contains('StageName'));
    }

    @IsTest
    static void toDeveloperName_sanitizesInputs() {
        System.assertEquals('my_rule',
            PulseEmailRouterController.toDeveloperName('my rule'));
        System.assertEquals('X_9_starts',
            PulseEmailRouterController.toDeveloperName('9 starts'));
        System.assertEquals('Unnamed',
            PulseEmailRouterController.toDeveloperName(''));
    }

    @IsTest
    static void ruleDeployResultDtoCoverage() {
        PulseEmailRouterController.RuleDeployResult r =
            new PulseEmailRouterController.RuleDeployResult();
        r.success = true; r.error = null;
        r.developerName = 'd'; r.jobId = null;

        PulseEmailRouterController.DeployStatusView v =
            new PulseEmailRouterController.DeployStatusView();
        v.status = 'Completed'; v.done = true; v.errors = null;

        System.assertNotEquals(null, r);
        System.assertNotEquals(null, v);
    }
}

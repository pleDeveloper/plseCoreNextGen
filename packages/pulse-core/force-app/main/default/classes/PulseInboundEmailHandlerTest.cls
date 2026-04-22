@IsTest
private class PulseInboundEmailHandlerTest {

    private static final String CONTRACT_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"email_handler_test","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
        '{"key":"active_state","label":"Active","type":"form",' +
        '"transitions":[{"signal":"done","to":"closed"}]},' +
        '{"key":"closed","label":"Closed","type":"terminal","transitions":[]}' +
        ']}';

    @TestSetup
    static void setup() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'email_handler_test',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = CONTRACT_JSON,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;

        Opportunity opp = new Opportunity(
            Name = 'Email Handler Test Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'active_state',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id
        );
        insert inst;

        // Contact + OCR for contact-based routing test
        Contact ct = new Contact(
            FirstName = 'Jordan',
            LastName = 'Matthews',
            Email = 'jordan@abproperties.com'
        );
        insert ct;

        insert new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId = ct.Id,
            Role = 'Decision Maker'
        );
    }

    @IsTest
    static void emailWithPulseTag_routesToInstance() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

        Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Re: Lease inquiry [Pulse:' + inst.Id + ']';
        email.fromAddress = 'unknown@example.com';
        email.fromName = 'Unknown Sender';
        email.plainTextBody = 'I have questions about the space.';
        email.toAddresses = new List<String>{ 'leasing@ourcompany.com' };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();

        Test.startTest();
        PulseInboundEmailHandler handler = new PulseInboundEmailHandler();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Conversation__c conv = [
            SELECT Workflow_Instance__c, Medium__c, Source_Adapter__c
            FROM Conversation__c
            WHERE Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(inst.Id, conv.Workflow_Instance__c);
        System.assertEquals('Email', conv.Medium__c);

        List<Conversation_Turn__c> turns = [
            SELECT Content__c, Role__c, Speaker__c
            FROM Conversation_Turn__c
            WHERE Conversation__c = :conv.Id
        ];
        System.assertEquals(1, turns.size());
        System.assertEquals('Customer', turns[0].Role__c);
        System.assertEquals('Unknown Sender', turns[0].Speaker__c);
    }

    @IsTest
    static void emailFromKnownContact_autoRouted() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

        Workflow_Instance__c inst = [SELECT Id FROM Workflow_Instance__c LIMIT 1];

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Question about the lease terms';
        email.fromAddress = 'jordan@abproperties.com';
        email.fromName = 'Jordan Matthews';
        email.plainTextBody = 'What is the security deposit requirement?';
        email.toAddresses = new List<String>{ 'leasing@ourcompany.com' };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();

        Test.startTest();
        PulseInboundEmailHandler handler = new PulseInboundEmailHandler();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Conversation__c conv = [
            SELECT Workflow_Instance__c
            FROM Conversation__c
            WHERE Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(inst.Id, conv.Workflow_Instance__c,
            'Should auto-route via Contact email match');
    }

    @IsTest
    static void emailFromUnknownSender_unattachedWhenNoRules() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;
        // Disable the router so this legacy scenario still maps to
        // "unattached conversation". Production has the default rule
        // enabled; tests opt out to assert the no-match path.
        InboundRecordRouter.testRuleOverride =
            new List<Conversation_Routing_Rule__mdt>();

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'General inquiry';
        email.fromAddress = 'stranger@nowhere.com';
        email.fromName = 'Stranger';
        email.plainTextBody = 'I saw your listing online.';
        email.toAddresses = new List<String>{ 'info@ourcompany.com' };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();

        Test.startTest();
        PulseInboundEmailHandler handler = new PulseInboundEmailHandler();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Conversation__c conv = [
            SELECT Workflow_Instance__c, Parent_Record_Id__c
            FROM Conversation__c
            WHERE Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(null, conv.Workflow_Instance__c,
            'Should create unattached conversation when no rules match');
        System.assertEquals(null, conv.Parent_Record_Id__c);
    }

    @IsTest
    static void routerPath_createsOppAndStartsWorkflow_forUnknownSender() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;
        PulseWorkflowStarter.suppressed = true; // no side-effects from provisioned triggers

        // Inject a routing rule that creates Opportunities + starts our test workflow.
        Conversation_Routing_Rule__mdt rule = new Conversation_Routing_Rule__mdt();
        rule.DeveloperName = 'rp_rule';
        rule.Rule_Key__c   = 'rp_rule';
        rule.Active__c     = true;
        rule.Priority__c   = 100;
        rule.Source_Adapter__c      = 'email';
        rule.Match_Strategy__c      = 'EMAIL_SENDER_TO_CONTACT';
        rule.Target_Object__c       = 'Opportunity';
        rule.Create_Defaults_JSON__c =
            '{"StageName":"Qualification","CloseDate":"+30d","Name":"New inquiry from {senderEmail}"}';
        rule.Trigger_Workflow_Key__c = 'email_handler_test';
        InboundRecordRouter.testRuleOverride =
            new List<Conversation_Routing_Rule__mdt>{ rule };

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject      = 'Looking for industrial space';
        email.fromAddress  = 'brandnew@somewhere.com';
        email.fromName     = 'Brand New';
        email.plainTextBody = 'Hi, I saw your listing and would love to tour.';
        email.toAddresses  = new List<String>{ 'leasing@ourcompany.com' };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();

        Test.startTest();
        PulseInboundEmailHandler handler = new PulseInboundEmailHandler();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        // Participants__c is a LongTextArea (no LIKE in SOQL); use the
        // most recent inbound_email Conversation created by this test.
        // The setup @TestSetup Opp name is 'Email Handler Test Opp';
        // a fresh Opp with 'brandnew@' in the name signals the router ran.
        Conversation__c conv = [
            SELECT Workflow_Instance__c, Parent_Record_Id__c, Parent_Object_Type__c,
                   Participants__c
            FROM Conversation__c
            WHERE External_Source__c = 'InboundEmail'
              AND Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertNotEquals(null, conv.Workflow_Instance__c,
            'Router should have started a workflow instance for the new Opp');
        System.assertEquals('Opportunity', conv.Parent_Object_Type__c);
        System.assertNotEquals(null, conv.Parent_Record_Id__c);

        // The Opp is findable and tied to the workflow instance
        Opportunity created = [
            SELECT Id, Name FROM Opportunity WHERE Id = :conv.Parent_Record_Id__c
        ];
        System.assert(created.Name.contains('brandnew@somewhere.com'),
            'Placeholder should have resolved in the created Opp name');

        Workflow_Instance__c inst = [
            SELECT Id, Current_State__c, Status__c, Parent_Record_Id__c
            FROM Workflow_Instance__c
            WHERE Id = :conv.Workflow_Instance__c
        ];
        System.assertEquals('active_state', inst.Current_State__c);
        System.assertEquals('Active', inst.Status__c);
        System.assertEquals(String.valueOf(created.Id), inst.Parent_Record_Id__c);
    }

    @IsTest
    static void emailNoTagUnknownSender_noErrors() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;
        // Focus this test on HTML-stripping, not routing.
        InboundRecordRouter.testRuleOverride =
            new List<Conversation_Routing_Rule__mdt>();

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'No tag here';
        email.fromAddress = 'random@random.com';
        email.htmlBody = '<p>HTML only body with <b>bold</b> text.</p>';
        email.toAddresses = new List<String>{ 'info@ourcompany.com' };

        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();

        Test.startTest();
        PulseInboundEmailHandler handler = new PulseInboundEmailHandler();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, env);
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Conversation_Turn__c> turns = [
            SELECT Content__c FROM Conversation_Turn__c
            WHERE Conversation__r.Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(1, turns.size());
        System.assert(turns[0].Content__c.contains('bold'),
            'Should strip HTML and preserve text content');
    }
}

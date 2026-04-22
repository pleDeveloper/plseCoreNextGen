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
    static void emailFromUnknownSender_unattached() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

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
            SELECT Workflow_Instance__c
            FROM Conversation__c
            WHERE Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(null, conv.Workflow_Instance__c,
            'Should create unattached conversation for unknown sender');
    }

    @IsTest
    static void emailNoTagUnknownSender_noErrors() {
        ConversationIngestionService.suppressExtractionEnqueue = true;
        PulseAgentInvoker.enqueueSuppressed = true;

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

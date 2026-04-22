@IsTest
private class PulseConversationHubControllerTest {

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Conversation__c insertConversation(String parentRecordId) {
        Conversation__c conv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Test conversation',
            Summary__c = 'A test summary',
            Participants__c = 'Alice; Bob',
            Status__c = 'Extracted',
            Source_Adapter__c = 'email',
            Parent_Object_Type__c = 'Account',
            Parent_Record_Id__c = parentRecordId
        );
        insert conv;

        List<Conversation_Turn__c> turns = new List<Conversation_Turn__c>{
            new Conversation_Turn__c(
                Conversation__c = conv.Id,
                Content__c = 'Hello, I need a referral.',
                Role__c = 'Customer',
                Speaker__c = 'Alice',
                Turn_Index__c = 0,
                Timestamp__c = Datetime.now().addMinutes(-10)
            ),
            new Conversation_Turn__c(
                Conversation__c = conv.Id,
                Content__c = 'Sure, I will process that for you.',
                Role__c = 'Agent',
                Speaker__c = 'Bob',
                Turn_Index__c = 1,
                Timestamp__c = Datetime.now()
            )
        };
        insert turns;

        return conv;
    }

    private static Conversation_Extract__c insertExtract(Id conversationId) {
        Conversation_Extract__c ext = new Conversation_Extract__c(
            Conversation__c = conversationId,
            Extraction_Profile__c = 'email_default',
            Status__c = 'Pending',
            Facts_JSON__c = '{"contact_name":"Alice Smith","company":"Acme Corp","priority":"High"}',
            Confidence_JSON__c = '{"contact_name":0.92,"company":0.85,"priority":0.45}',
            Source_Turn_References__c = '[{"factKey":"contact_name","turnIndexes":[0]}]'
        );
        insert ext;
        return ext;
    }

    private static void setupProjectionOverride() {
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            new Workflow_Projection__mdt(
                Field_Key__c = 'contact_name',
                Target_Object__c = 'Account',
                Target_Field__c = 'Description',
                Field_Type__c = 'Text',
                Workflow_Key__c = 'test_wf',
                Write_Precedence__c = 1,
                Active__c = true
            ),
            new Workflow_Projection__mdt(
                Field_Key__c = 'company',
                Target_Object__c = 'Account',
                Target_Field__c = 'Site',
                Field_Type__c = 'Text',
                Workflow_Key__c = 'test_wf',
                Write_Precedence__c = 1,
                Active__c = true
            )
        };
    }

    // ── getConversationsForRecord ───────────────────────────────────────

    @IsTest
    static void getConversationsForRecord_returnsNestedData() {
        Account acct = new Account(Name = 'Test Account');
        insert acct;

        Conversation__c conv = insertConversation(String.valueOf(acct.Id));
        insertExtract(conv.Id);

        // Insert a second conversation to verify multiple are returned
        Conversation__c conv2 = new Conversation__c(
            Medium__c = 'Meeting',
            Subject__c = 'Second conversation',
            Status__c = 'Ingested',
            Source_Adapter__c = 'recall',
            Parent_Record_Id__c = String.valueOf(acct.Id)
        );
        insert conv2;

        Test.startTest();
        List<PulseConversationHubController.ConversationView> results =
            PulseConversationHubController.getConversationsForRecord(acct.Id);
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should return both conversations');

        // Find the one with extracts (Email conversation)
        PulseConversationHubController.ConversationView emailConv = null;
        for (PulseConversationHubController.ConversationView cv : results) {
            if (cv.medium == 'Email') {
                emailConv = cv;
            }
        }
        System.assertNotEquals(null, emailConv, 'Should find the email conversation');
        System.assertEquals(2, emailConv.turns.size(), 'Should have 2 turns');
        System.assertEquals('Alice', emailConv.turns[0].speaker);
        System.assertEquals(1, emailConv.extracts.size(), 'Should have 1 extract');
        System.assertEquals('Pending', emailConv.extracts[0].status);
        System.assert(emailConv.extracts[0].facts.containsKey('contact_name'));
        System.assertEquals(0.92, emailConv.extracts[0].confidence.get('contact_name'));
    }

    @IsTest
    static void getConversationsForRecord_nullId_returnsEmpty() {
        Test.startTest();
        List<PulseConversationHubController.ConversationView> results =
            PulseConversationHubController.getConversationsForRecord(null);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    // ── getConversationsForInstance ─────────────────────────────────────

    @IsTest
    static void getConversationsForInstance_scopesCorrectly() {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Key__c = 'test_wf',
            Status__c = 'Active'
        );
        insert inst;

        Conversation__c conv = new Conversation__c(
            Medium__c = 'Chat',
            Subject__c = 'Instance chat',
            Status__c = 'Extracted',
            Source_Adapter__c = 'chat',
            Workflow_Instance__c = inst.Id
        );
        insert conv;

        // Unrelated conversation (no instance link)
        Conversation__c unrelated = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Unrelated',
            Status__c = 'Ingested',
            Source_Adapter__c = 'email'
        );
        insert unrelated;

        Test.startTest();
        List<PulseConversationHubController.ConversationView> results =
            PulseConversationHubController.getConversationsForInstance(inst.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should only return instance-scoped conversation');
        System.assertEquals('Chat', results[0].medium);
    }

    // ── acceptExtract — full field list ─────────────────────────────────

    @IsTest
    static void acceptExtract_allFields_projectsAndMarksAccepted() {
        Account acct = new Account(Name = 'Projection Target');
        insert acct;

        Conversation__c conv = insertConversation(String.valueOf(acct.Id));
        Conversation_Extract__c ext = insertExtract(conv.Id);
        setupProjectionOverride();

        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.acceptExtract(
                ext.Id,
                new List<String>{ 'contact_name', 'company' },
                'Account',
                acct.Id,
                'test_wf'
            );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Should succeed');
        System.assertEquals(2, result.fieldsProjected, 'Should project 2 fields');
        System.assertEquals(0, result.errors.size(), 'Should have no errors');

        Conversation_Extract__c updated = [
            SELECT Status__c, Reviewed_By__c, Reviewed_Date__c
            FROM Conversation_Extract__c WHERE Id = :ext.Id
        ];
        System.assertEquals('Accepted', updated.Status__c);
        System.assertEquals(UserInfo.getUserId(), updated.Reviewed_By__c);
        System.assertNotEquals(null, updated.Reviewed_Date__c);
    }

    // ── acceptExtract — subset field list ───────────────────────────────

    @IsTest
    static void acceptExtract_subsetFields_projectsOnlySelected() {
        Account acct = new Account(Name = 'Subset Target');
        insert acct;

        Conversation__c conv = insertConversation(String.valueOf(acct.Id));
        Conversation_Extract__c ext = insertExtract(conv.Id);
        setupProjectionOverride();

        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.acceptExtract(
                ext.Id,
                new List<String>{ 'contact_name' },
                'Account',
                acct.Id,
                'test_wf'
            );
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals(1, result.fieldsProjected, 'Should project only 1 field');

        Conversation_Extract__c updated = [
            SELECT Status__c FROM Conversation_Extract__c WHERE Id = :ext.Id
        ];
        System.assertEquals('Accepted', updated.Status__c);
    }

    // ── acceptExtract — partial failure ─────────────────────────────────

    @IsTest
    static void acceptExtract_partialFailure_marksPartial() {
        Account acct = new Account(Name = 'Partial Target');
        insert acct;

        Conversation__c conv = insertConversation(String.valueOf(acct.Id));
        Conversation_Extract__c ext = insertExtract(conv.Id);

        // Only map contact_name — 'priority' has no mapping, so it will fail
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            new Workflow_Projection__mdt(
                Field_Key__c = 'contact_name',
                Target_Object__c = 'Account',
                Target_Field__c = 'Description',
                Field_Type__c = 'Text',
                Workflow_Key__c = 'test_wf',
                Write_Precedence__c = 1,
                Active__c = true
            )
        };

        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.acceptExtract(
                ext.Id,
                new List<String>{ 'contact_name', 'priority' },
                'Account',
                acct.Id,
                'test_wf'
            );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Partial success is still success');
        System.assertEquals(1, result.fieldsProjected);
        System.assert(result.errors.size() > 0, 'Should have errors for unmapped field');

        Conversation_Extract__c updated = [
            SELECT Status__c FROM Conversation_Extract__c WHERE Id = :ext.Id
        ];
        System.assertEquals('Partial', updated.Status__c);
    }

    // ── acceptExtract — validation errors ───────────────────────────────

    @IsTest
    static void acceptExtract_nullArgs_returnsError() {
        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.acceptExtract(
                null, null, 'Account', null, 'wf'
            );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errors.size() > 0);
    }

    // ── rejectExtract ──────────────────────────────────────────────────

    @IsTest
    static void rejectExtract_updatesStatusAndReviewer() {
        Conversation__c conv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Reject test',
            Status__c = 'Extracted',
            Source_Adapter__c = 'email'
        );
        insert conv;
        Conversation_Extract__c ext = insertExtract(conv.Id);

        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.rejectExtract(ext.Id, 'Not relevant');
        Test.stopTest();

        System.assertEquals(true, result.success);

        Conversation_Extract__c updated = [
            SELECT Status__c, Reviewed_By__c, Reviewed_Date__c
            FROM Conversation_Extract__c WHERE Id = :ext.Id
        ];
        System.assertEquals('Rejected', updated.Status__c);
        System.assertEquals(UserInfo.getUserId(), updated.Reviewed_By__c);
        System.assertNotEquals(null, updated.Reviewed_Date__c);
    }

    @IsTest
    static void rejectExtract_nullId_returnsError() {
        Test.startTest();
        PulseConversationHubController.AcceptResult result =
            PulseConversationHubController.rejectExtract(null, 'reason');
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errors.size() > 0);
    }

    // ── requestReextraction ────────────────────────────────────────────

    @IsTest
    static void requestReextraction_enqueuesJob() {
        Conversation__c conv = new Conversation__c(
            Medium__c = 'Meeting',
            Subject__c = 'Re-extract test',
            Status__c = 'Extracted',
            Source_Adapter__c = 'recall'
        );
        insert conv;

        insert new Conversation_Turn__c(
            Conversation__c = conv.Id,
            Content__c = 'Some content.',
            Role__c = 'Agent',
            Speaker__c = 'Alice',
            Turn_Index__c = 0
        );

        // Set up extractor mocks so the Queueable can run
        PulseConversationExtractor.testProfileOverride =
            new Map<String, Extraction_Profile__mdt>();
        PulseConversationExtractor.extractionProvider = null;

        Test.startTest();
        Id jobId = PulseConversationHubController.requestReextraction(conv.Id);
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Should return an async job Id');

        Integer asyncCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable'
              AND ApexClass.Name = 'PulseConversationExtractor'
        ];
        System.assert(asyncCount > 0, 'Should have enqueued PulseConversationExtractor');
    }

    @IsTest
    static void requestReextraction_noTurns_throws() {
        Conversation__c conv = new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Empty conv',
            Status__c = 'Extracted',
            Source_Adapter__c = 'email'
        );
        insert conv;

        Boolean threw = false;
        Test.startTest();
        try {
            PulseConversationHubController.requestReextraction(conv.Id);
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().contains('no turns'));
        }
        Test.stopTest();

        System.assert(threw, 'Should throw when conversation has no turns');
    }
}

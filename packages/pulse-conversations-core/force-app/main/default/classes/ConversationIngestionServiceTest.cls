@IsTest
private class ConversationIngestionServiceTest {

    @TestSetup
    static void setup() {
        // Suppress extraction enqueue so ingestion tests run in isolation
        ConversationIngestionService.suppressExtractionEnqueue = true;
    }

    // ── Email ingestion ─────────────────────────────────────────────────

    @IsTest
    static void ingestEmail_createsConversationAndTurns() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        PulseConversationModels.ConversationInput input = buildEmailInput();

        Test.startTest();
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(new List<PulseConversationModels.ConversationInput>{ input });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(false, results[0].isDuplicate, 'Should not be duplicate');
        System.assertNotEquals(null, results[0].conversationId, 'Should have conversation Id');

        Conversation__c conv = [
            SELECT Medium__c, Subject__c, Status__c, External_Source_Id__c,
                   Source_Adapter__c, Parent_Object_Type__c, Parent_Record_Id__c
            FROM Conversation__c
            WHERE Id = :results[0].conversationId
        ];
        System.assertEquals('Email', conv.Medium__c);
        System.assertEquals('Re: Patient Referral', conv.Subject__c);
        System.assertEquals('Ingested', conv.Status__c);
        System.assertEquals('email-thread-001', conv.External_Source_Id__c);

        List<Conversation_Turn__c> turns = [
            SELECT Content__c, Role__c, Speaker__c, Turn_Index__c
            FROM Conversation_Turn__c
            WHERE Conversation__c = :results[0].conversationId
            ORDER BY Turn_Index__c
        ];
        System.assertEquals(2, turns.size(), 'Should have two turns');
        System.assertEquals('Dr. Smith', turns[0].Speaker__c);
        System.assertEquals(0, turns[0].Turn_Index__c);
    }

    // ── Meeting transcript ingestion ────────────────────────────────────

    @IsTest
    static void ingestMeeting_createsConversationWithTurns() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        PulseConversationModels.ConversationInput input = buildMeetingInput();

        Test.startTest();
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(new List<PulseConversationModels.ConversationInput>{ input });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isDuplicate);

        Conversation__c conv = [
            SELECT Medium__c, Participants__c FROM Conversation__c
            WHERE Id = :results[0].conversationId
        ];
        System.assertEquals('Meeting', conv.Medium__c);
        System.assert(conv.Participants__c.contains('Alice'));
    }

    // ── Duplicate external source ID ────────────────────────────────────

    @IsTest
    static void ingestDuplicate_returnsDuplicateFlag() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        PulseConversationModels.ConversationInput first = buildEmailInput();

        ConversationIngestionService.ingest(
            new List<PulseConversationModels.ConversationInput>{ first });

        PulseConversationModels.ConversationInput second = buildEmailInput();

        Test.startTest();
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(
                new List<PulseConversationModels.ConversationInput>{ second });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isDuplicate, 'Second ingest should be duplicate');
        System.assertNotEquals(null, results[0].conversationId,
            'Duplicate should still return existing Id');
    }

    // ── Source linkage ──────────────────────────────────────────────────

    @IsTest
    static void ingest_linksParentAndWorkflowInstance() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        PulseConversationModels.ConversationInput input =
            new PulseConversationModels.ConversationInput();
        input.medium = 'Phone_Call';
        input.subject = 'Follow-up call';
        input.sourceAdapter = 'telephony';
        input.parentObjectType = 'Account';
        input.parentRecordId = '001000000000001AAA';

        Test.startTest();
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(
                new List<PulseConversationModels.ConversationInput>{ input });
        Test.stopTest();

        Conversation__c conv = [
            SELECT Parent_Object_Type__c, Parent_Record_Id__c
            FROM Conversation__c
            WHERE Id = :results[0].conversationId
        ];
        System.assertEquals('Account', conv.Parent_Object_Type__c);
        System.assertEquals('001000000000001AAA', conv.Parent_Record_Id__c);
    }

    // ── Bulk ingestion ──────────────────────────────────────────────────

    @IsTest
    static void ingestBulk_handles200Records() {
        ConversationIngestionService.suppressExtractionEnqueue = true;

        List<PulseConversationModels.ConversationInput> inputs =
            new List<PulseConversationModels.ConversationInput>();
        for (Integer i = 0; i < 200; i++) {
            PulseConversationModels.ConversationInput inp =
                new PulseConversationModels.ConversationInput();
            inp.medium = 'Email';
            inp.subject = 'Bulk test ' + i;
            inp.externalSourceId = 'bulk-' + i;
            inp.sourceAdapter = 'email';

            PulseConversationModels.TurnInput turn =
                new PulseConversationModels.TurnInput();
            turn.content = 'Content ' + i;
            turn.role = 'Agent';
            turn.turnIndex = 0;
            inp.turns.add(turn);

            inputs.add(inp);
        }

        Test.startTest();
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(inputs);
        Test.stopTest();

        System.assertEquals(200, results.size(), 'Should return 200 results');

        Integer convCount = [SELECT COUNT() FROM Conversation__c];
        System.assertEquals(200, convCount, 'Should create 200 conversations');

        Integer turnCount = [SELECT COUNT() FROM Conversation_Turn__c];
        System.assertEquals(200, turnCount, 'Should create 200 turns');
    }

    // ── Empty input ─────────────────────────────────────────────────────

    @IsTest
    static void ingestEmpty_returnsEmptyList() {
        List<ConversationIngestionService.IngestionResult> results =
            ConversationIngestionService.ingest(
                new List<PulseConversationModels.ConversationInput>());

        System.assertEquals(0, results.size());

        results = ConversationIngestionService.ingest(null);
        System.assertEquals(0, results.size());
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static PulseConversationModels.ConversationInput buildEmailInput() {
        PulseConversationModels.ConversationInput input =
            new PulseConversationModels.ConversationInput();
        input.medium = 'Email';
        input.subject = 'Re: Patient Referral';
        input.summary = 'Discussion about referral details';
        input.participants = 'Dr. Smith; Nurse Jones';
        input.sourceAdapter = 'email';
        input.externalSource = 'SalesforceEmail';
        input.externalSourceId = 'email-thread-001';
        input.parentObjectType = 'Account';
        input.parentRecordId = '001000000000001AAA';

        PulseConversationModels.TurnInput turn1 =
            new PulseConversationModels.TurnInput();
        turn1.content = 'Please review the attached referral for patient.';
        turn1.role = 'Agent';
        turn1.speaker = 'Dr. Smith';
        turn1.turnIndex = 0;
        turn1.timestamp = Datetime.now().addHours(-1);

        PulseConversationModels.TurnInput turn2 =
            new PulseConversationModels.TurnInput();
        turn2.content = 'Referral received. Will process today.';
        turn2.role = 'Customer';
        turn2.speaker = 'Nurse Jones';
        turn2.turnIndex = 1;
        turn2.timestamp = Datetime.now();

        input.turns.add(turn1);
        input.turns.add(turn2);
        return input;
    }

    private static PulseConversationModels.ConversationInput buildMeetingInput() {
        PulseConversationModels.ConversationInput input =
            new PulseConversationModels.ConversationInput();
        input.medium = 'Meeting';
        input.subject = 'Weekly Standup';
        input.participants = 'Alice; Bob; Carol';
        input.sourceAdapter = 'recall';
        input.externalSource = 'Recall';
        input.externalSourceId = 'bot-123';

        PulseConversationModels.TurnInput turn1 =
            new PulseConversationModels.TurnInput();
        turn1.content = 'Let us start with updates on the referral pipeline.';
        turn1.speaker = 'Alice';
        turn1.turnIndex = 0;
        input.turns.add(turn1);

        PulseConversationModels.TurnInput turn2 =
            new PulseConversationModels.TurnInput();
        turn2.content = 'We processed 15 referrals this week.';
        turn2.speaker = 'Bob';
        turn2.turnIndex = 1;
        input.turns.add(turn2);

        return input;
    }
}

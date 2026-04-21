@IsTest
private class PulseConversationExtractorTest {

    // ── Mock extraction provider ────────────────────────────────────────

    private class MockExtractionProvider
            implements PulseConversationExtractor.ExtractionCallable {
        public String mockResponse;
        public Boolean shouldThrow = false;

        public String extract(String prompt, String schemaJson) {
            if (shouldThrow) {
                throw new PulseConversationExtractor.ExtractorException('Mock AI failure');
            }
            return mockResponse;
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Conversation__c insertConversationWithTurns() {
        Conversation__c conv = new Conversation__c(
            Medium__c = 'Meeting',
            Subject__c = 'Test Meeting',
            Status__c = 'Ingested',
            Source_Adapter__c = 'recall'
        );
        insert conv;

        List<Conversation_Turn__c> turns = new List<Conversation_Turn__c>{
            new Conversation_Turn__c(
                Conversation__c = conv.Id,
                Content__c = 'The referring physician is Dr. Adams.',
                Speaker__c = 'Alice',
                Role__c = 'Agent',
                Turn_Index__c = 0
            ),
            new Conversation_Turn__c(
                Conversation__c = conv.Id,
                Content__c = 'Patient insurance is Blue Cross.',
                Speaker__c = 'Bob',
                Role__c = 'Customer',
                Turn_Index__c = 1
            )
        };
        insert turns;
        return conv;
    }

    private static void setMockProfile() {
        Extraction_Profile__mdt profile = new Extraction_Profile__mdt(
            DeveloperName = 'Meeting_Default',
            Profile_Key__c = 'meeting_default',
            Medium__c = 'Meeting',
            Active__c = true,
            Schema_JSON__c = '{"type":"object","properties":{"referring_physician":{"type":"string"},"insurance":{"type":"string"}}}'
        );
        PulseConversationExtractor.testProfileOverride =
            new Map<String, Extraction_Profile__mdt>{ 'Meeting' => profile };
    }

    private static String buildMockAiResponse() {
        Map<String, Object> response = new Map<String, Object>{
            'facts' => new Map<String, Object>{
                'referring_physician' => 'Dr. Adams',
                'insurance' => 'Blue Cross'
            },
            'confidence' => new Map<String, Object>{
                'referring_physician' => 0.95,
                'insurance' => 0.88
            },
            'sourceReferences' => new List<Object>{
                new Map<String, Object>{ 'factKey' => 'referring_physician', 'turnIndexes' => new List<Object>{ 0 } },
                new Map<String, Object>{ 'factKey' => 'insurance', 'turnIndexes' => new List<Object>{ 1 } }
            }
        };
        return JSON.serialize(response);
    }

    // ── Successful extraction ───────────────────────────────────────────

    @IsTest
    static void execute_createsExtractWithFactsAndConfidence() {
        Conversation__c conv = insertConversationWithTurns();
        setMockProfile();

        MockExtractionProvider mockProvider = new MockExtractionProvider();
        mockProvider.mockResponse = buildMockAiResponse();
        PulseConversationExtractor.extractionProvider = mockProvider;

        Test.startTest();
        System.enqueueJob(new PulseConversationExtractor(new Set<Id>{ conv.Id }));
        Test.stopTest();

        // Verify extract created
        List<Conversation_Extract__c> extracts = [
            SELECT Facts_JSON__c, Confidence_JSON__c, Source_Turn_References__c,
                   Status__c, Extraction_Profile__c, Conversation__c
            FROM Conversation_Extract__c
            WHERE Conversation__c = :conv.Id
        ];
        System.assertEquals(1, extracts.size(), 'Should create one extract');

        Conversation_Extract__c ext = extracts[0];
        System.assertEquals('Pending', ext.Status__c,
            'Extract must be Pending — no direct parent writes');
        System.assertEquals('meeting_default', ext.Extraction_Profile__c);
        System.assert(ext.Facts_JSON__c.contains('Dr. Adams'));
        System.assert(ext.Confidence_JSON__c.contains('0.95'));
        System.assert(ext.Source_Turn_References__c.contains('referring_physician'));

        // Verify conversation status updated
        Conversation__c updated = [SELECT Status__c FROM Conversation__c WHERE Id = :conv.Id];
        System.assertEquals('Extracted', updated.Status__c);
    }

    // ── Missing extraction profile ──────────────────────────────────────

    @IsTest
    static void execute_noProfileForMedium_marksConversationFailed() {
        Conversation__c conv = insertConversationWithTurns();
        // Set override with empty map — no profile for Meeting medium
        PulseConversationExtractor.testProfileOverride =
            new Map<String, Extraction_Profile__mdt>();

        Test.startTest();
        System.enqueueJob(new PulseConversationExtractor(new Set<Id>{ conv.Id }));
        Test.stopTest();

        Conversation__c updated = [SELECT Status__c FROM Conversation__c WHERE Id = :conv.Id];
        System.assertEquals('Failed', updated.Status__c,
            'Should fail when no extraction profile matches');

        Integer extractCount = [
            SELECT COUNT() FROM Conversation_Extract__c
            WHERE Conversation__c = :conv.Id
        ];
        System.assertEquals(0, extractCount, 'Should not create extract');
    }

    // ── AI provider failure ─────────────────────────────────────────────

    @IsTest
    static void execute_providerThrows_marksConversationFailed() {
        Conversation__c conv = insertConversationWithTurns();
        setMockProfile();

        MockExtractionProvider mockProvider = new MockExtractionProvider();
        mockProvider.shouldThrow = true;
        PulseConversationExtractor.extractionProvider = mockProvider;

        Test.startTest();
        System.enqueueJob(new PulseConversationExtractor(new Set<Id>{ conv.Id }));
        Test.stopTest();

        Conversation__c updated = [SELECT Status__c FROM Conversation__c WHERE Id = :conv.Id];
        System.assertEquals('Failed', updated.Status__c);
    }

    // ── Extract status is Pending — no parent writes ────────────────────

    @IsTest
    static void extractStatus_alwaysPending_neverApplied() {
        Conversation__c conv = insertConversationWithTurns();
        setMockProfile();

        MockExtractionProvider mockProvider = new MockExtractionProvider();
        mockProvider.mockResponse = buildMockAiResponse();
        PulseConversationExtractor.extractionProvider = mockProvider;

        Test.startTest();
        System.enqueueJob(new PulseConversationExtractor(new Set<Id>{ conv.Id }));
        Test.stopTest();

        List<Conversation_Extract__c> extracts = [
            SELECT Status__c FROM Conversation_Extract__c
            WHERE Conversation__c = :conv.Id
        ];
        for (Conversation_Extract__c ext : extracts) {
            System.assert(ext.Status__c == 'Pending',
                'Extraction must produce Pending status — '
                + 'human verification required before Apply');
        }
    }

    // ── Transcript builder ──────────────────────────────────────────────

    @IsTest
    static void buildTranscript_formatsCorrectly() {
        List<Conversation_Turn__c> turns = new List<Conversation_Turn__c>{
            new Conversation_Turn__c(
                Speaker__c = 'Alice', Role__c = 'Agent',
                Content__c = 'Hello', Turn_Index__c = 0
            ),
            new Conversation_Turn__c(
                Speaker__c = null, Role__c = 'Customer',
                Content__c = 'Hi there', Turn_Index__c = 1
            )
        };

        String transcript = PulseConversationExtractor.buildTranscript(turns);

        System.assert(transcript.contains('[0] Alice: Hello'),
            'Should use speaker name when available');
        System.assert(transcript.contains('[1] Customer: Hi there'),
            'Should fall back to role when speaker is blank');
    }

    // ── Extraction result parser ────────────────────────────────────────

    @IsTest
    static void parseExtractionResult_handlesCompleteResponse() {
        String raw = buildMockAiResponse();

        PulseConversationExtractor.ExtractionOutput output =
            PulseConversationExtractor.parseExtractionResult(raw);

        System.assert(output.factsJson.contains('Dr. Adams'));
        System.assert(output.confidenceJson.contains('0.95'));
        System.assert(output.sourceRefsJson.contains('referring_physician'));
    }

    @IsTest
    static void parseExtractionResult_handlesMissingKeys() {
        String raw = '{"facts": {"name": "test"}}';

        PulseConversationExtractor.ExtractionOutput output =
            PulseConversationExtractor.parseExtractionResult(raw);

        System.assert(output.factsJson.contains('test'));
        System.assertEquals('{}', output.confidenceJson);
        System.assertEquals('[]', output.sourceRefsJson);
    }
}

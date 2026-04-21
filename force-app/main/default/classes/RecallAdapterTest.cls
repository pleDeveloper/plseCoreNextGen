@IsTest
private class RecallAdapterTest {

    // ── HTTP mock ───────────────────────────────────────────────────────

    private class RecallCreateBotSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"id":"bot-abc-123","status":"joining"}');
            return res;
        }
    }

    private class RecallCreateBotFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(422);
            res.setBody('{"error":"invalid_meeting_url"}');
            return res;
        }
    }

    // ── normalizePayload: transcript_complete ───────────────────────────

    @IsTest
    static void normalizePayload_transcriptComplete_returnsConversationInput() {
        RecallAdapter adapter = new RecallAdapter();

        Map<String, Object> payload = new Map<String, Object>{
            'eventType' => 'transcript_complete',
            'botId' => 'bot-abc-123',
            'meetingUrl' => 'https://zoom.us/j/123',
            'meetingTitle' => 'Weekly Standup',
            'participants' => new List<String>{ 'Alice', 'Bob' },
            'transcript' => new List<Object>{
                new Map<String, Object>{
                    'speaker' => 'Alice',
                    'text' => 'Hello everyone.',
                    'startTime' => 0.0,
                    'segmentIndex' => 0
                },
                new Map<String, Object>{
                    'speaker' => 'Bob',
                    'text' => 'Hey Alice.',
                    'startTime' => 2.5,
                    'segmentIndex' => 1
                }
            }
        };

        List<ConversationIngestionService.ConversationInput> results =
            adapter.normalizePayload(JSON.serialize(payload));

        System.assertEquals(1, results.size(), 'Should produce one conversation');

        ConversationIngestionService.ConversationInput conv = results[0];
        System.assertEquals('Meeting', conv.medium);
        System.assertEquals('Weekly Standup', conv.subject);
        System.assertEquals('bot-abc-123', conv.externalSourceId);
        System.assertEquals('Recall', conv.externalSource);
        System.assertEquals('recall', conv.sourceAdapter);
        System.assert(conv.participants.contains('Alice'));

        System.assertEquals(2, conv.turns.size(), 'Should have two turns');
        System.assertEquals('Alice', conv.turns[0].speaker);
        System.assertEquals('Hello everyone.', conv.turns[0].content);
        System.assertEquals(0, conv.turns[0].turnIndex);
        System.assertEquals(null, conv.turns[0].role,
            'Role should be null for meeting turns — resolved during review');
    }

    // ── normalizePayload: non-transcript event ──────────────────────────

    @IsTest
    static void normalizePayload_nonTranscriptEvent_returnsEmpty() {
        RecallAdapter adapter = new RecallAdapter();

        Map<String, Object> payload = new Map<String, Object>{
            'eventType' => 'bot_joined',
            'botId' => 'bot-abc-123'
        };

        List<ConversationIngestionService.ConversationInput> results =
            adapter.normalizePayload(JSON.serialize(payload));

        System.assertEquals(0, results.size(),
            'Non-transcript events should produce no conversations');
    }

    // ── normalizePayload: missing meeting title ─────────────────────────

    @IsTest
    static void normalizePayload_missingTitle_defaultsToMeetingRecording() {
        RecallAdapter adapter = new RecallAdapter();

        Map<String, Object> payload = new Map<String, Object>{
            'eventType' => 'transcript_complete',
            'botId' => 'bot-xyz',
            'transcript' => new List<Object>{
                new Map<String, Object>{
                    'speaker' => 'Alice',
                    'text' => 'Test.',
                    'segmentIndex' => 0
                }
            }
        };

        List<ConversationIngestionService.ConversationInput> results =
            adapter.normalizePayload(JSON.serialize(payload));

        System.assertEquals('Meeting Recording', results[0].subject);
    }

    // ── createBot: success ──────────────────────────────────────────────

    @IsTest
    static void createBot_success_returnsBotResponse() {
        Test.setMock(HttpCalloutMock.class, new RecallCreateBotSuccessMock());

        RecallAdapter adapter = new RecallAdapter();
        RecallAdapter.RecallBotRequest req = new RecallAdapter.RecallBotRequest();
        req.meetingUrl = 'https://zoom.us/j/123';
        req.botName = 'Pulse Notetaker';

        Test.startTest();
        RecallAdapter.RecallBotResponse resp = adapter.createBot(req);
        Test.stopTest();

        System.assertEquals('bot-abc-123', resp.botId);
        System.assertEquals('joining', resp.status);
    }

    // ── createBot: API error ────────────────────────────────────────────

    @IsTest
    static void createBot_apiError_throwsException() {
        Test.setMock(HttpCalloutMock.class, new RecallCreateBotFailMock());

        RecallAdapter adapter = new RecallAdapter();
        RecallAdapter.RecallBotRequest req = new RecallAdapter.RecallBotRequest();
        req.meetingUrl = 'invalid-url';

        Test.startTest();
        try {
            adapter.createBot(req);
            System.assert(false, 'Should have thrown RecallAdapterException');
        } catch (RecallAdapter.RecallAdapterException e) {
            System.assert(e.getMessage().contains('422'));
        }
        Test.stopTest();
    }

    // ── Adapter key ─────────────────────────────────────────────────────

    @IsTest
    static void getAdapterKey_returnsRecall() {
        RecallAdapter adapter = new RecallAdapter();
        System.assertEquals('recall', adapter.getAdapterKey());
    }
}

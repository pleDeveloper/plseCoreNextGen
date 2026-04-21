/**
 * Recall.ai adapter — creates bots, handles webhooks, and normalises
 * transcript payloads into PulseConversationModels inputs.
 * All HTTP callouts use the Pulse_Recall Named Credential.
 */
public with sharing class RecallAdapter implements PulseConversationAdapter {

    private static final String ADAPTER_KEY = 'recall';
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'callout:Pulse_Recall';

    // ── PulseConversationAdapter ────────────────────────────────────────

    public String getAdapterKey() {
        return ADAPTER_KEY;
    }

    public List<PulseConversationModels.ConversationInput> normalizePayload(
            String rawPayload) {
        List<PulseConversationModels.ConversationInput> results =
            new List<PulseConversationModels.ConversationInput>();

        RecallWebhookEvent evt = (RecallWebhookEvent) JSON.deserialize(
            rawPayload, RecallWebhookEvent.class
        );

        if (evt.eventType != 'transcript_complete' || evt.transcript == null) {
            return results;
        }

        PulseConversationModels.ConversationInput input =
            new PulseConversationModels.ConversationInput();
        input.medium = 'Meeting';
        input.subject = String.isNotBlank(evt.meetingTitle)
            ? evt.meetingTitle : 'Meeting Recording';
        input.participants = evt.participants != null
            ? String.join(evt.participants, '; ') : '';
        input.sourceAdapter = ADAPTER_KEY;
        input.externalSource = 'Recall';
        input.externalSourceId = evt.botId;

        for (Integer i = 0; i < evt.transcript.size(); i++) {
            RecallTranscriptSegment seg = evt.transcript[i];
            PulseConversationModels.TurnInput turn =
                new PulseConversationModels.TurnInput();
            turn.content = seg.text;
            turn.speaker = seg.speaker;
            turn.turnIndex = seg.segmentIndex != null ? seg.segmentIndex : i;
            // Role__c left null — speaker identity resolves during review
            input.turns.add(turn);
        }

        results.add(input);
        return results;
    }

    // ── Bot management ──────────────────────────────────────────────────

    public RecallBotResponse createBot(RecallBotRequest request) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + '/api/v1/bot');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');

        Map<String, Object> body = new Map<String, Object>{
            'meeting_url' => request.meetingUrl,
            'bot_name' => String.isNotBlank(request.botName)
                ? request.botName : 'Pulse Notetaker'
        };
        req.setBody(JSON.serialize(body));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new RecallAdapterException(
                'Recall API error: ' + res.getStatusCode() + ' ' + res.getBody()
            );
        }

        Map<String, Object> parsed =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        RecallBotResponse resp = new RecallBotResponse();
        resp.botId = (String) parsed.get('id');
        resp.status = (String) parsed.get('status');
        return resp;
    }

    // ── DTOs ────────────────────────────────────────────────────────────

    public class RecallBotRequest {
        public String meetingUrl;
        public String botName;
        public String botPersona;
    }

    public class RecallBotResponse {
        public String botId;
        public String status;
    }

    public class RecallWebhookEvent {
        public String eventType;
        public String botId;
        public String meetingUrl;
        public String meetingTitle;
        public List<RecallTranscriptSegment> transcript;
        public List<String> participants;
    }

    public class RecallTranscriptSegment {
        public String speaker;
        public String text;
        public Decimal startTime;
        public Integer segmentIndex;
    }

    public class RecallAdapterException extends Exception {}
}

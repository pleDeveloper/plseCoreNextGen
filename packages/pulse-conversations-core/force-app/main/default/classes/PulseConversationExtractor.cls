/**
 * Queueable that runs extraction profiles against ingested conversations.
 * Creates Conversation_Extract__c with facts, confidence, and source-turn references.
 * Does NOT write parent fields — extracts remain Pending until human verification.
 */
public with sharing class PulseConversationExtractor implements Queueable, Database.AllowsCallouts {

    // ── Injectable extraction provider ──────────────────────────────────

    public interface ExtractionCallable {
        String extract(String prompt, String schemaJson);
    }

    @TestVisible
    private static ExtractionCallable extractionProvider;

    @TestVisible
    private static Map<String, Extraction_Profile__mdt> testProfileOverride;

    // ── State ───────────────────────────────────────────────────────────

    private Set<Id> conversationIds;

    public PulseConversationExtractor(Set<Id> conversationIds) {
        this.conversationIds = conversationIds;
    }

    // ── Queueable entry point ───────────────────────────────────────────

    public void execute(QueueableContext ctx) {
        if (conversationIds == null || conversationIds.isEmpty()) {
            return;
        }

        List<Conversation__c> conversations = [
            SELECT Id, Medium__c, Subject__c, Summary__c, Status__c,
                   Workflow_Instance__c,
                   (SELECT Id, Content__c, Role__c, Speaker__c, Turn_Index__c
                    FROM Conversation_Turns__r
                    ORDER BY Turn_Index__c ASC)
            FROM Conversation__c
            WHERE Id IN :conversationIds
              AND Status__c = 'Ingested'
        ];

        if (conversations.isEmpty()) {
            return;
        }

        Map<String, Extraction_Profile__mdt> profilesByMedium = loadProfilesByMedium();

        List<Conversation__c> toUpdate = new List<Conversation__c>();
        List<Conversation_Extract__c> extractsToInsert = new List<Conversation_Extract__c>();

        for (Conversation__c conv : conversations) {
            Extraction_Profile__mdt profile = profilesByMedium.get(conv.Medium__c);
            if (profile == null) {
                toUpdate.add(new Conversation__c(Id = conv.Id, Status__c = 'Failed'));
                continue;
            }

            String transcript = buildTranscript(conv.Conversation_Turns__r);
            String prompt = buildExtractionPrompt(transcript, profile);

            try {
                ExtractionCallable provider = resolveProvider();
                String rawResult = provider.extract(prompt, profile.Schema_JSON__c);
                ExtractionOutput output = parseExtractionResult(rawResult);

                extractsToInsert.add(new Conversation_Extract__c(
                    Conversation__c        = conv.Id,
                    Extraction_Profile__c  = profile.Profile_Key__c,
                    Facts_JSON__c          = output.factsJson,
                    Confidence_JSON__c     = output.confidenceJson,
                    Source_Turn_References__c = output.sourceRefsJson,
                    Status__c              = 'Pending',
                    Workflow_Instance__c   = conv.Workflow_Instance__c
                ));
                toUpdate.add(new Conversation__c(Id = conv.Id, Status__c = 'Extracted'));
            } catch (Exception e) {
                toUpdate.add(new Conversation__c(Id = conv.Id, Status__c = 'Failed'));
            }
        }

        if (!extractsToInsert.isEmpty()) {
            insert extractsToInsert;
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private ExtractionCallable resolveProvider() {
        if (extractionProvider != null) {
            return extractionProvider;
        }
        throw new ExtractorException(
            'No ExtractionCallable provider configured. '
            + 'Set PulseConversationExtractor.extractionProvider before enqueue.'
        );
    }

    private Map<String, Extraction_Profile__mdt> loadProfilesByMedium() {
        if (testProfileOverride != null) {
            return testProfileOverride;
        }
        Map<String, Extraction_Profile__mdt> byMedium = new Map<String, Extraction_Profile__mdt>();
        for (Extraction_Profile__mdt ep : Extraction_Profile__mdt.getAll().values()) {
            if (ep.Active__c && String.isNotBlank(ep.Medium__c)) {
                byMedium.put(ep.Medium__c, ep);
            }
        }
        return byMedium;
    }

    @TestVisible
    private static String buildTranscript(List<Conversation_Turn__c> turns) {
        List<String> lines = new List<String>();
        for (Conversation_Turn__c t : turns) {
            String speaker = String.isNotBlank(t.Speaker__c) ? t.Speaker__c : t.Role__c;
            String idx = t.Turn_Index__c != null ? String.valueOf(t.Turn_Index__c.intValue()) : '?';
            lines.add('[' + idx + '] ' + speaker + ': ' + t.Content__c);
        }
        return String.join(lines, '\n');
    }

    @TestVisible
    private static String buildExtractionPrompt(
            String transcript, Extraction_Profile__mdt profile) {
        return 'Extract structured facts from the following conversation transcript.\n'
             + 'Use the provided JSON schema to structure your output.\n'
             + 'For each fact, include a confidence score (0.0-1.0) and the turn '
             + 'index(es) that support it.\n'
             + 'Return JSON with keys: facts, confidence, sourceReferences.\n\n'
             + 'Schema:\n' + profile.Schema_JSON__c + '\n\n'
             + 'Transcript:\n' + transcript;
    }

    @TestVisible
    private static ExtractionOutput parseExtractionResult(String rawJson) {
        ExtractionOutput output = new ExtractionOutput();
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(rawJson);

        Object facts = parsed.get('facts');
        output.factsJson = facts != null ? JSON.serialize(facts) : '{}';

        Object conf = parsed.get('confidence');
        output.confidenceJson = conf != null ? JSON.serialize(conf) : '{}';

        Object refs = parsed.get('sourceReferences');
        output.sourceRefsJson = refs != null ? JSON.serialize(refs) : '[]';

        return output;
    }

    // ── Inner types ─────────────────────────────────────────────────────

    @TestVisible
    private class ExtractionOutput {
        public String factsJson;
        public String confidenceJson;
        public String sourceRefsJson;
    }

    public class ExtractorException extends Exception {}
}

/**
 * Bulk-safe service that normalises inbound email, call, and meeting payloads
 * into Conversation__c + Conversation_Turn__c records.
 * Deduplicates on External_Source_Id__c and enqueues extraction.
 */
public with sharing class ConversationIngestionService {

    @TestVisible
    private static Boolean suppressExtractionEnqueue = false;

    // ── Input DTOs ──────────────────────────────────────────────────────

    public class ConversationInput {
        public String medium;           // Email | Phone_Call | Meeting | Chat
        public String subject;
        public String summary;
        public String participants;
        public String sourceAdapter;
        public String externalSource;
        public String externalSourceId;
        public String parentObjectType;
        public String parentRecordId;
        public Id workflowInstanceId;
        public List<TurnInput> turns;

        public ConversationInput() {
            this.turns = new List<TurnInput>();
        }
    }

    public class TurnInput {
        public String content;
        public String role;             // Agent | Customer | System | AI (restricted picklist)
        public String speaker;
        public Datetime timestamp;
        public Decimal turnIndex;
    }

    // ── Result DTO ──────────────────────────────────────────────────────

    public class IngestionResult {
        public Id conversationId;
        public String externalSourceId;
        public Boolean isDuplicate;

        public IngestionResult(Id convId, String extId, Boolean isDup) {
            this.conversationId = convId;
            this.externalSourceId = extId;
            this.isDuplicate = isDup;
        }
    }

    // ── Bulk entry point ────────────────────────────────────────────────

    public static List<IngestionResult> ingest(List<ConversationInput> inputs) {
        if (inputs == null || inputs.isEmpty()) {
            return new List<IngestionResult>();
        }

        // 1. Collect external source IDs for dedup
        Set<String> externalIds = new Set<String>();
        for (ConversationInput inp : inputs) {
            if (String.isNotBlank(inp.externalSourceId)) {
                externalIds.add(inp.externalSourceId);
            }
        }

        // 2. Query existing conversations for dedup (single SOQL)
        Map<String, Id> existingByExtId = new Map<String, Id>();
        if (!externalIds.isEmpty()) {
            for (Conversation__c existing : [
                SELECT Id, External_Source_Id__c
                FROM Conversation__c
                WHERE External_Source_Id__c IN :externalIds
            ]) {
                existingByExtId.put(existing.External_Source_Id__c, existing.Id);
            }
        }

        // 3. Build Conversation__c records for non-duplicates
        List<Conversation__c> toInsert = new List<Conversation__c>();
        List<Integer> insertIndexMap = new List<Integer>();
        List<IngestionResult> results = new List<IngestionResult>();

        for (Integer i = 0; i < inputs.size(); i++) {
            ConversationInput inp = inputs[i];

            if (String.isNotBlank(inp.externalSourceId)
                    && existingByExtId.containsKey(inp.externalSourceId)) {
                results.add(new IngestionResult(
                    existingByExtId.get(inp.externalSourceId),
                    inp.externalSourceId,
                    true
                ));
                continue;
            }

            Conversation__c conv = new Conversation__c(
                Medium__c            = inp.medium,
                Subject__c           = inp.subject,
                Summary__c           = inp.summary,
                Participants__c      = inp.participants,
                Source_Adapter__c    = inp.sourceAdapter,
                External_Source__c   = inp.externalSource,
                External_Source_Id__c = inp.externalSourceId,
                Parent_Object_Type__c = inp.parentObjectType,
                Parent_Record_Id__c  = inp.parentRecordId,
                Workflow_Instance__c = inp.workflowInstanceId,
                Ingested_Date__c     = Datetime.now(),
                Status__c            = 'Ingested'
            );
            toInsert.add(conv);
            insertIndexMap.add(i);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }

        // 4. Build Turn records for inserted conversations
        List<Conversation_Turn__c> turnsToInsert = new List<Conversation_Turn__c>();
        Set<Id> newConversationIds = new Set<Id>();

        for (Integer j = 0; j < toInsert.size(); j++) {
            Conversation__c inserted = toInsert[j];
            ConversationInput inp = inputs[insertIndexMap[j]];
            newConversationIds.add(inserted.Id);
            results.add(new IngestionResult(inserted.Id, inp.externalSourceId, false));

            if (inp.turns != null) {
                for (TurnInput turn : inp.turns) {
                    turnsToInsert.add(new Conversation_Turn__c(
                        Conversation__c = inserted.Id,
                        Content__c      = turn.content,
                        Role__c         = turn.role,
                        Speaker__c      = turn.speaker,
                        Timestamp__c    = turn.timestamp,
                        Turn_Index__c   = turn.turnIndex
                    ));
                }
            }
        }

        if (!turnsToInsert.isEmpty()) {
            insert turnsToInsert;
        }

        // 5. Enqueue extraction for new conversations
        if (!suppressExtractionEnqueue
                && !newConversationIds.isEmpty()
                && !System.isBatch() && !System.isFuture()
                && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new PulseConversationExtractor(newConversationIds));
        }

        return results;
    }
}

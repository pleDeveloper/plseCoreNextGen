/**
 * PulseConversationHubController
 *
 * Apex bridge between the pulseConversationHub LWC and the existing
 * conversation + projection services.  Provides read access to
 * conversations/turns/extracts and write access to accept/reject
 * extracted facts via ProjectionWriteService.
 */
global with sharing class PulseConversationHubController {

    // ── View types ─────────────────────────────────────────────────────

    global class ConversationView {
        @AuraEnabled public Id       conversationId;
        @AuraEnabled public String   medium;
        @AuraEnabled public String   subject;
        @AuraEnabled public String   summary;
        @AuraEnabled public String   participants;
        @AuraEnabled public Datetime occurredAt;
        @AuraEnabled public String   status;
        @AuraEnabled public List<TurnView>    turns;
        @AuraEnabled public List<ExtractView> extracts;
    }

    global class TurnView {
        @AuraEnabled public Id       turnId;
        @AuraEnabled public Integer  turnIndex;
        @AuraEnabled public String   role;
        @AuraEnabled public String   speaker;
        @AuraEnabled public String   content;
        @AuraEnabled public Datetime timestamp;
    }

    global class ExtractView {
        @AuraEnabled public Id       extractId;
        @AuraEnabled public String   profileKey;
        @AuraEnabled public String   status;
        @AuraEnabled public Map<String, Object>  facts;
        @AuraEnabled public Map<String, Decimal>  confidence;
        @AuraEnabled public String   sourceRefsJson;
        @AuraEnabled public Id       reviewedByUserId;
        @AuraEnabled public Datetime reviewedDate;
    }

    global class AcceptResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Integer fieldsProjected;
        @AuraEnabled public List<String> errors;
    }

    // ── Read methods ───────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ConversationView> getConversationsForRecord(Id recordId) {
        if (recordId == null) {
            return new List<ConversationView>();
        }
        List<Conversation__c> convos = [
            SELECT Id, Medium__c, Subject__c, Summary__c, Participants__c,
                   Ingested_Date__c, Status__c,
                   (SELECT Id, Turn_Index__c, Role__c, Speaker__c, Content__c, Timestamp__c
                    FROM Conversation_Turns__r
                    ORDER BY Turn_Index__c ASC),
                   (SELECT Id, Extraction_Profile__c, Status__c, Facts_JSON__c,
                           Confidence_JSON__c, Source_Turn_References__c,
                           Reviewed_By__c, Reviewed_Date__c
                    FROM Conversation_Extracts__r
                    ORDER BY CreatedDate ASC)
            FROM Conversation__c
            WHERE Parent_Record_Id__c = :String.valueOf(recordId)
            ORDER BY Ingested_Date__c DESC
            LIMIT 50
        ];
        return mapConversations(convos);
    }

    @AuraEnabled(cacheable=true)
    public static List<ConversationView> getConversationsForInstance(Id workflowInstanceId) {
        if (workflowInstanceId == null) {
            return new List<ConversationView>();
        }
        List<Conversation__c> convos = [
            SELECT Id, Medium__c, Subject__c, Summary__c, Participants__c,
                   Ingested_Date__c, Status__c,
                   (SELECT Id, Turn_Index__c, Role__c, Speaker__c, Content__c, Timestamp__c
                    FROM Conversation_Turns__r
                    ORDER BY Turn_Index__c ASC),
                   (SELECT Id, Extraction_Profile__c, Status__c, Facts_JSON__c,
                           Confidence_JSON__c, Source_Turn_References__c,
                           Reviewed_By__c, Reviewed_Date__c
                    FROM Conversation_Extracts__r
                    ORDER BY CreatedDate ASC)
            FROM Conversation__c
            WHERE Workflow_Instance__c = :workflowInstanceId
            ORDER BY Ingested_Date__c DESC
            LIMIT 50
        ];
        return mapConversations(convos);
    }

    // ── Write methods ──────────────────────────────────────────────────

    @AuraEnabled
    public static AcceptResult acceptExtract(
        Id extractId,
        List<String> acceptedFieldKeys,
        String targetObjectApiName,
        Id targetRecordId,
        String workflowKey
    ) {
        AcceptResult result = new AcceptResult();
        result.errors = new List<String>();
        result.fieldsProjected = 0;
        result.success = false;

        if (extractId == null || acceptedFieldKeys == null || acceptedFieldKeys.isEmpty()) {
            result.errors.add('Extract ID and at least one field key are required.');
            return result;
        }

        Conversation_Extract__c ext = [
            SELECT Id, Facts_JSON__c, Status__c
            FROM Conversation_Extract__c
            WHERE Id = :extractId
            LIMIT 1
        ];

        Map<String, Object> allFacts = (Map<String, Object>) JSON.deserializeUntyped(
            String.isNotBlank(ext.Facts_JSON__c) ? ext.Facts_JSON__c : '{}'
        );

        // Filter to only the accepted field keys
        Map<String, String> fieldValues = new Map<String, String>();
        for (String key : acceptedFieldKeys) {
            if (allFacts.containsKey(key)) {
                Object val = allFacts.get(key);
                fieldValues.put(key, val == null ? null : String.valueOf(val));
            }
        }

        if (fieldValues.isEmpty()) {
            result.errors.add('None of the accepted field keys matched extracted facts.');
            return result;
        }

        // Build projection request
        ProjectionWriteService.ProjectionRequest req = new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId  = targetRecordId;
        req.parentObjectType = targetObjectApiName;
        req.workflowKey     = workflowKey;
        req.fieldValues     = fieldValues;

        List<ProjectionWriteService.ProjectionResult> projResults =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });

        Integer successCount = 0;
        Integer failCount = 0;
        for (ProjectionWriteService.ProjectionResult pr : projResults) {
            if (pr.success) {
                successCount++;
            } else {
                failCount++;
                result.errors.add(pr.fieldKey + ': ' + pr.message);
            }
        }

        result.fieldsProjected = successCount;

        // Determine extract status
        String newStatus;
        if (failCount == 0) {
            newStatus = 'Accepted';
            result.success = true;
        } else if (successCount > 0) {
            newStatus = 'Partial';
            result.success = true;
        } else {
            newStatus = ext.Status__c; // leave unchanged on total failure
        }

        ext.Status__c       = newStatus;
        ext.Reviewed_By__c  = UserInfo.getUserId();
        ext.Reviewed_Date__c = Datetime.now();
        update ext;

        return result;
    }

    @AuraEnabled
    public static AcceptResult rejectExtract(Id extractId, String reason) {
        AcceptResult result = new AcceptResult();
        result.errors = new List<String>();
        result.fieldsProjected = 0;
        result.success = false;

        if (extractId == null) {
            result.errors.add('Extract ID is required.');
            return result;
        }

        Conversation_Extract__c ext = [
            SELECT Id, Status__c
            FROM Conversation_Extract__c
            WHERE Id = :extractId
            LIMIT 1
        ];

        ext.Status__c        = 'Rejected';
        ext.Reviewed_By__c   = UserInfo.getUserId();
        ext.Reviewed_Date__c = Datetime.now();
        update ext;

        result.success = true;
        return result;
    }

    @AuraEnabled
    public static Id requestReextraction(Id conversationId) {
        if (conversationId == null) {
            throw new AuraHandledException('Conversation ID is required.');
        }

        Integer turnCount = [
            SELECT COUNT() FROM Conversation_Turn__c
            WHERE Conversation__c = :conversationId
        ];
        if (turnCount == 0) {
            throw new AuraHandledException('Conversation has no turns to extract from.');
        }

        Id jobId = System.enqueueJob(
            new PulseConversationExtractor(new Set<Id>{ conversationId })
        );
        return jobId;
    }

    // ── Private mapping helpers ────────────────────────────────────────

    private static List<ConversationView> mapConversations(List<Conversation__c> convos) {
        List<ConversationView> views = new List<ConversationView>();
        for (Conversation__c c : convos) {
            ConversationView cv = new ConversationView();
            cv.conversationId = c.Id;
            cv.medium         = c.Medium__c;
            cv.subject        = c.Subject__c;
            cv.summary        = c.Summary__c;
            cv.participants   = c.Participants__c;
            cv.occurredAt     = c.Ingested_Date__c;
            cv.status         = c.Status__c;

            cv.turns = new List<TurnView>();
            if (c.Conversation_Turns__r != null) {
                for (Conversation_Turn__c t : c.Conversation_Turns__r) {
                    TurnView tv = new TurnView();
                    tv.turnId    = t.Id;
                    tv.turnIndex = t.Turn_Index__c != null ? t.Turn_Index__c.intValue() : 0;
                    tv.role      = t.Role__c;
                    tv.speaker   = t.Speaker__c;
                    tv.content   = t.Content__c;
                    tv.timestamp = t.Timestamp__c;
                    cv.turns.add(tv);
                }
            }

            cv.extracts = new List<ExtractView>();
            if (c.Conversation_Extracts__r != null) {
                for (Conversation_Extract__c e : c.Conversation_Extracts__r) {
                    ExtractView ev = new ExtractView();
                    ev.extractId       = e.Id;
                    ev.profileKey      = e.Extraction_Profile__c;
                    ev.status          = e.Status__c;
                    ev.sourceRefsJson  = e.Source_Turn_References__c;
                    ev.reviewedByUserId = e.Reviewed_By__c;
                    ev.reviewedDate    = e.Reviewed_Date__c;

                    ev.facts = (Map<String, Object>) JSON.deserializeUntyped(
                        String.isNotBlank(e.Facts_JSON__c) ? e.Facts_JSON__c : '{}'
                    );
                    // Parse confidence JSON into Map<String, Decimal>
                    ev.confidence = new Map<String, Decimal>();
                    if (String.isNotBlank(e.Confidence_JSON__c)) {
                        Map<String, Object> rawConf = (Map<String, Object>)
                            JSON.deserializeUntyped(e.Confidence_JSON__c);
                        for (String k : rawConf.keySet()) {
                            Object v = rawConf.get(k);
                            if (v instanceof Decimal) {
                                ev.confidence.put(k, (Decimal) v);
                            } else if (v != null) {
                                ev.confidence.put(k, Decimal.valueOf(String.valueOf(v)));
                            }
                        }
                    }

                    cv.extracts.add(ev);
                }
            }

            views.add(cv);
        }
        return views;
    }
}

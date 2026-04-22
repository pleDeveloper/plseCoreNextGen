/**
 * PulseEmailRouterController
 *
 * AuraEnabled façade for the Admin Studio "Email routing" panel.
 * - listUnroutedEmails() — Conversations with no Parent_Record_Id__c
 * - listRoutingRules()   — Conversation_Routing_Rule__mdt
 * - routeToExistingRecord(conversationId, recordId) — sets Parent_Record_Id__c
 * - createOpportunityFromConversation(conversationId) — runs the default rule
 *
 * Write operations for CMDT (create/edit rules) are deliberately out of
 * scope in a subscriber-safe managed package — admins configure rules
 * via Setup → Custom Metadata Types. The LWC surfaces this with a
 * read-only editor.
 */
global with sharing class PulseEmailRouterController {

    // ── DTOs ──────────────────────────────────────────────────────────

    global class UnroutedEmailView {
        @AuraEnabled public Id       conversationId;
        @AuraEnabled public String   subject;
        @AuraEnabled public String   senderEmail;          // best-guess from participants
        @AuraEnabled public String   participants;
        @AuraEnabled public String   snippet;
        @AuraEnabled public Datetime ingestedAt;
    }

    global class RoutingRuleView {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  ruleKey;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer priority;
        @AuraEnabled public String  sourceAdapter;
        @AuraEnabled public String  matchStrategy;
        @AuraEnabled public String  targetObject;
        @AuraEnabled public String  createDefaultsJson;
        @AuraEnabled public String  triggerWorkflowKey;
    }

    global class RouteActionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  objectType;
        @AuraEnabled public Boolean wasCreated;
        @AuraEnabled public String  ruleKey;
        @AuraEnabled public String  error;
    }

    // ── List unrouted emails ──────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<UnroutedEmailView> listUnroutedEmails() {
        List<UnroutedEmailView> out = new List<UnroutedEmailView>();

        List<Conversation__c> convs = [
            SELECT Id, Subject__c, Participants__c, Ingested_Date__c, CreatedDate,
                   (SELECT Id, Content__c, Speaker__c
                    FROM Conversation_Turns__r
                    ORDER BY Turn_Index__c ASC NULLS LAST, CreatedDate ASC
                    LIMIT 1)
            FROM Conversation__c
            WHERE Source_Adapter__c = 'inbound_email'
              AND Parent_Record_Id__c = null
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];

        for (Conversation__c c : convs) {
            UnroutedEmailView v = new UnroutedEmailView();
            v.conversationId = c.Id;
            v.subject        = c.Subject__c;
            v.participants   = c.Participants__c;
            v.senderEmail    = firstEmailOrName(c.Participants__c);
            v.ingestedAt     = c.Ingested_Date__c != null ? c.Ingested_Date__c : c.CreatedDate;
            v.snippet        = snippetFromTurns(c.Conversation_Turns__r);
            out.add(v);
        }

        return out;
    }

    // ── List routing rules ────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<RoutingRuleView> listRoutingRules() {
        List<RoutingRuleView> out = new List<RoutingRuleView>();
        for (Conversation_Routing_Rule__mdt r : [
            SELECT DeveloperName, Rule_Key__c, Active__c, Priority__c,
                   Source_Adapter__c, Match_Strategy__c, Target_Object__c,
                   Create_Defaults_JSON__c, Trigger_Workflow_Key__c
            FROM Conversation_Routing_Rule__mdt
            ORDER BY Priority__c ASC NULLS LAST, DeveloperName ASC
        ]) {
            RoutingRuleView v = new RoutingRuleView();
            v.developerName      = r.DeveloperName;
            v.ruleKey            = r.Rule_Key__c;
            v.active             = r.Active__c == true;
            v.priority           = r.Priority__c != null ? r.Priority__c.intValue() : null;
            v.sourceAdapter      = r.Source_Adapter__c;
            v.matchStrategy      = r.Match_Strategy__c;
            v.targetObject       = r.Target_Object__c;
            v.createDefaultsJson = r.Create_Defaults_JSON__c;
            v.triggerWorkflowKey = r.Trigger_Workflow_Key__c;
            out.add(v);
        }
        return out;
    }

    // ── Route to existing record ──────────────────────────────────────

    @AuraEnabled
    global static RouteActionResult routeToExistingRecord(
        Id conversationId, Id recordId
    ) {
        RouteActionResult out = new RouteActionResult();
        if (conversationId == null) {
            out.success = false;
            out.error = 'conversationId is required';
            return out;
        }
        if (recordId == null) {
            out.success = false;
            out.error = 'recordId is required';
            return out;
        }
        try {
            Conversation__c c = new Conversation__c(
                Id = conversationId,
                Parent_Record_Id__c   = String.valueOf(recordId),
                Parent_Object_Type__c = recordId.getSobjectType().getDescribe().getName()
            );
            update c;
            out.success = true;
            out.recordId = recordId;
            out.objectType = recordId.getSobjectType().getDescribe().getName();
        } catch (Exception e) {
            out.success = false;
            out.error = e.getMessage();
        }
        return out;
    }

    // ── Create new Opportunity via default rule ───────────────────────

    @AuraEnabled
    global static RouteActionResult createOpportunityFromConversation(Id conversationId) {
        RouteActionResult out = new RouteActionResult();
        if (conversationId == null) {
            out.success = false;
            out.error = 'conversationId is required';
            return out;
        }
        List<Conversation__c> convs = [
            SELECT Id, Subject__c, Participants__c
            FROM Conversation__c
            WHERE Id = :conversationId
            LIMIT 1
        ];
        if (convs.isEmpty()) {
            out.success = false;
            out.error = 'Conversation not found';
            return out;
        }
        Conversation__c c = convs[0];
        String sender = firstEmailOrName(c.Participants__c);
        if (String.isBlank(sender)) {
            out.success = false;
            out.error = 'Could not identify sender email from participants';
            return out;
        }

        InboundRecordRouter.RouteResult rr = InboundRecordRouter.route(
            sender, c.Subject__c, null
        );
        if (rr == null || rr.recordId == null) {
            out.success = false;
            out.error = 'No routing rule matched';
            return out;
        }

        try {
            c.Parent_Record_Id__c   = String.valueOf(rr.recordId);
            c.Parent_Object_Type__c = rr.objectType;
            update c;
        } catch (Exception e) {
            out.success = false;
            out.error = 'Created record ' + rr.recordId +
                ' but failed to attach conversation: ' + e.getMessage();
            return out;
        }

        out.success    = true;
        out.recordId   = rr.recordId;
        out.objectType = rr.objectType;
        out.wasCreated = rr.wasCreated;
        out.ruleKey    = rr.ruleKey;
        return out;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    @TestVisible
    private static String firstEmailOrName(String participants) {
        if (String.isBlank(participants)) return null;
        // Participants__c is a semicolon-joined list; fromName is usually
        // first and fromAddress second. We prefer something that looks
        // like an email.
        for (String raw : participants.split(';')) {
            String s = raw == null ? '' : raw.trim();
            if (s.contains('@')) return s;
        }
        // No @ anywhere — return the first non-empty token as a last resort
        for (String raw : participants.split(';')) {
            String s = raw == null ? '' : raw.trim();
            if (String.isNotBlank(s)) return s;
        }
        return null;
    }

    private static String snippetFromTurns(List<Conversation_Turn__c> turns) {
        if (turns == null || turns.isEmpty()) return '';
        String body = turns[0].Content__c;
        if (String.isBlank(body)) return '';
        String trimmed = body.length() > 220 ? body.substring(0, 220) + '…' : body;
        return trimmed.replaceAll('\\s+', ' ').trim();
    }
}

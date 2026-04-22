/**
 * InboundRecordRouter
 *
 * Declarative router that turns an inbound message (email today, more
 * channels tomorrow) into a routing target: an existing record that
 * owns the thread, or a newly-created record when no match exists.
 *
 * Rules live in Conversation_Routing_Rule__mdt. See
 * Conversation_Routing_Rule.Default_Email_To_Opportunity for the
 * starter rule shipped with Pulse Core.
 *
 * Called by PulseInboundEmailHandler after its subject-tag routing
 * attempt returns null.
 */
public with sharing class InboundRecordRouter {

    // ── Public DTO ────────────────────────────────────────────────────

    public class RouteResult {
        public Id      recordId;
        public String  objectType;
        public String  ruleKey;
        public Boolean wasCreated;
        public String  triggerWorkflowKey;
        public Boolean matchedExistingThread;

        public RouteResult() {
            this.wasCreated = false;
            this.matchedExistingThread = false;
        }
    }

    // ── Test seam ─────────────────────────────────────────────────────
    //
    // CMDT records can't be inserted via DML, so tests inject fake
    // rules through this override list. Production leaves this null
    // and the router queries the CMDT table.

    @TestVisible
    private static List<Conversation_Routing_Rule__mdt> testRuleOverride = null;

    // ── Entry point ───────────────────────────────────────────────────

    public static RouteResult route(String senderEmail, String subject, String threadHint) {
        RouteResult result = new RouteResult();
        if (String.isBlank(senderEmail)) {
            return result;
        }

        // 1. Thread match — same sender has an open conversation that
        //    already points at a parent record. Append there.
        Id threadRecordId = findExistingThreadParent(senderEmail);
        if (threadRecordId != null) {
            result.recordId = threadRecordId;
            result.objectType = sObjectTypeName(threadRecordId);
            result.matchedExistingThread = true;
            return result;
        }

        // 2. Rule evaluation — loaded in priority order.
        List<Conversation_Routing_Rule__mdt> rules = loadActiveRules();
        if (rules.isEmpty()) {
            return result;
        }

        for (Conversation_Routing_Rule__mdt rule : rules) {
            RouteResult ruleResult = evaluateRule(rule, senderEmail, subject);
            if (ruleResult != null && ruleResult.recordId != null) {
                return ruleResult;
            }
        }

        return result;
    }

    // ── Thread match ──────────────────────────────────────────────────

    private static Id findExistingThreadParent(String senderEmail) {
        // Participants__c is a LongTextArea — SOQL can't filter on LIKE.
        // Pull the most recent routed email conversations and match the
        // sender against Participants__c in-memory. The cap on rows keeps
        // this governor-safe for high-traffic orgs.
        List<Conversation__c> candidates = [
            SELECT Id, Parent_Record_Id__c, Parent_Object_Type__c,
                   Participants__c, CreatedDate
            FROM Conversation__c
            WHERE Parent_Record_Id__c != null
              AND Source_Adapter__c = 'inbound_email'
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
        if (candidates.isEmpty()) return null;

        String needle = senderEmail.toLowerCase();
        for (Conversation__c c : candidates) {
            if (String.isBlank(c.Participants__c)) continue;
            if (!c.Participants__c.toLowerCase().contains(needle)) continue;
            if (String.isBlank(c.Parent_Record_Id__c)) continue;
            try {
                return Id.valueOf(c.Parent_Record_Id__c);
            } catch (Exception e) {
                // Not a valid Id — skip this row
            }
        }
        return null;
    }

    // ── Rule loading ──────────────────────────────────────────────────

    private static List<Conversation_Routing_Rule__mdt> loadActiveRules() {
        if (testRuleOverride != null) {
            return testRuleOverride;
        }
        return [
            SELECT DeveloperName, Rule_Key__c, Active__c, Priority__c,
                   Source_Adapter__c, Match_Strategy__c, Target_Object__c,
                   Create_Defaults_JSON__c, Trigger_Workflow_Key__c
            FROM Conversation_Routing_Rule__mdt
            WHERE Active__c = true
            ORDER BY Priority__c ASC NULLS LAST, DeveloperName ASC
        ];
    }

    // ── Rule evaluation ───────────────────────────────────────────────

    private static RouteResult evaluateRule(
        Conversation_Routing_Rule__mdt rule, String senderEmail, String subject
    ) {
        String strategy = rule.Match_Strategy__c;
        if (String.isBlank(strategy)) return null;

        if (strategy == 'EMAIL_SENDER_TO_CONTACT') {
            return matchEmailSenderToContact(rule, senderEmail, subject);
        }
        // Future: EMAIL_SENDER_DOMAIN_TO_ACCOUNT, etc.
        return null;
    }

    private static RouteResult matchEmailSenderToContact(
        Conversation_Routing_Rule__mdt rule, String senderEmail, String subject
    ) {
        RouteResult out = new RouteResult();
        out.ruleKey = rule.Rule_Key__c;
        out.triggerWorkflowKey = rule.Trigger_Workflow_Key__c;
        out.objectType = rule.Target_Object__c;

        List<Contact> contacts = [
            SELECT Id, AccountId
            FROM Contact
            WHERE Email = :senderEmail
            LIMIT 1
        ];

        if (!contacts.isEmpty()) {
            Contact c = contacts[0];
            // Find an open Opportunity for this contact via OpportunityContactRole
            List<OpportunityContactRole> roles = [
                SELECT OpportunityId
                FROM OpportunityContactRole
                WHERE ContactId = :c.Id
                  AND Opportunity.IsClosed = false
                ORDER BY Opportunity.CreatedDate DESC
                LIMIT 1
            ];
            if (!roles.isEmpty()) {
                out.recordId = roles[0].OpportunityId;
                out.wasCreated = false;
                return out;
            }
            // Contact exists, no open Opportunity — create one on this Account.
            Id createdId = createFromDefaults(rule, senderEmail, c.AccountId);
            if (createdId != null) {
                out.recordId = createdId;
                out.wasCreated = true;
            }
            return out;
        }

        // No contact at all — fall back to creating a bare record from defaults.
        Id fallbackId = createFromDefaults(rule, senderEmail, null);
        if (fallbackId != null) {
            out.recordId = fallbackId;
            out.wasCreated = true;
        }
        return out;
    }

    // ── Record creation ───────────────────────────────────────────────

    private static Id createFromDefaults(
        Conversation_Routing_Rule__mdt rule, String senderEmail, Id accountId
    ) {
        if (String.isBlank(rule.Target_Object__c)) return null;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(rule.Target_Object__c);
        if (sot == null) return null;

        SObject rec = sot.newSObject();
        Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();

        Map<String, Object> defaults = parseDefaults(rule.Create_Defaults_JSON__c);
        for (String fieldName : defaults.keySet()) {
            Schema.SObjectField sf = fieldMap.get(fieldName);
            if (sf == null) continue;
            Object value = resolvePlaceholders(defaults.get(fieldName), senderEmail, sf);
            if (value != null) {
                try {
                    rec.put(sf, value);
                } catch (Exception e) {
                    // Type mismatch — skip silently rather than blow up routing
                }
            }
        }

        // Wire AccountId when target is an Opportunity and we have one
        if (accountId != null && fieldMap.containsKey('AccountId')) {
            try {
                rec.put('AccountId', accountId);
            } catch (Exception e) {
                // swallow
            }
        }

        try {
            insert rec;
            return (Id) rec.get('Id');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'InboundRecordRouter: failed to create ' + rule.Target_Object__c +
                ': ' + e.getMessage());
            return null;
        }
    }

    private static Map<String, Object> parseDefaults(String rawJson) {
        Map<String, Object> empty = new Map<String, Object>();
        if (String.isBlank(rawJson)) return empty;
        try {
            Object parsed = System.JSON.deserializeUntyped(rawJson);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
        } catch (Exception e) {
            // invalid JSON — return empty
        }
        return empty;
    }

    private static Object resolvePlaceholders(
        Object raw, String senderEmail, Schema.SObjectField sf
    ) {
        if (raw == null) return null;
        Schema.DescribeFieldResult d = sf.getDescribe();
        Schema.DisplayType type = d.getType();

        if (raw instanceof String) {
            String s = (String) raw;
            // Relative date offset: +30d, -7d, etc.
            if (type == Schema.DisplayType.DATE || type == Schema.DisplayType.DATETIME) {
                Integer offset = parseDateOffset(s);
                if (offset != null) {
                    return type == Schema.DisplayType.DATE
                        ? (Object) Date.today().addDays(offset)
                        : (Object) Datetime.now().addDays(offset);
                }
            }
            // Token substitution in text-like fields
            if (senderEmail != null) {
                s = s.replace('{senderEmail}', senderEmail);
            }
            return s;
        }
        return raw;
    }

    @TestVisible
    private static Integer parseDateOffset(String raw) {
        if (String.isBlank(raw)) return null;
        String trimmed = raw.trim();
        if (!(trimmed.startsWith('+') || trimmed.startsWith('-'))) return null;
        if (!trimmed.endsWithIgnoreCase('d')) return null;
        String numPart = trimmed.substring(0, trimmed.length() - 1);
        try {
            return Integer.valueOf(numPart);
        } catch (Exception e) {
            return null;
        }
    }

    // ── Utility ───────────────────────────────────────────────────────

    private static String sObjectTypeName(Id recordId) {
        if (recordId == null) return null;
        Schema.SObjectType sot = recordId.getSobjectType();
        return sot == null ? null : sot.getDescribe().getName();
    }
}

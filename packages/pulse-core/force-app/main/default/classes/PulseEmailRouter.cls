public with sharing class PulseEmailRouter {

    private static final Pattern PULSE_TAG_PATTERN =
        Pattern.compile('\\[Pulse:(a0[0-9a-zA-Z]{13,15})\\]');

    /**
     * Extracts a Workflow_Instance__c Id from an email subject line
     * matching the pattern [Pulse:<sfId>].
     */
    public static Id extractInstanceId(String subject) {
        if (String.isBlank(subject)) {
            return null;
        }
        Matcher m = PULSE_TAG_PATTERN.matcher(subject);
        if (m.find()) {
            String candidate = m.group(1);
            try {
                Id parsed = Id.valueOf(candidate);
                if (parsed.getSobjectType() == Workflow_Instance__c.SObjectType) {
                    return parsed;
                }
            } catch (Exception e) {
                // Invalid Id format — fall through
            }
        }
        return null;
    }

    /**
     * Attempts to route an inbound email by matching the sender's address
     * to a Contact on an Opportunity that has an active Workflow_Instance__c.
     */
    public static Id routeByContactEmail(String fromAddress) {
        if (String.isBlank(fromAddress)) {
            return null;
        }

        // SOQL semi-joins require the outer WHERE's left operand to be an Id
        // field. Parent_Record_Id__c is Text(18), not Id. Split into two
        // queries: first resolve OpportunityContactRole → OpportunityIds,
        // then filter Workflow_Instance__c by Parent_Record_Id__c IN that
        // set (which is an equality filter, not a semi-join — allowed).
        Set<String> oppIdStrings = new Set<String>();
        for (OpportunityContactRole ocr : [
            SELECT OpportunityId
            FROM OpportunityContactRole
            WHERE Contact.Email = :fromAddress
        ]) {
            oppIdStrings.add(String.valueOf(ocr.OpportunityId));
        }
        if (oppIdStrings.isEmpty()) {
            return null;
        }

        List<Workflow_Instance__c> instances = [
            SELECT Id, CreatedDate
            FROM Workflow_Instance__c
            WHERE Status__c = 'Active'
              AND Parent_Object_Type__c = 'Opportunity'
              AND Parent_Record_Id__c IN :oppIdStrings
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        return instances.isEmpty() ? null : instances[0].Id;
    }

    /**
     * Converts a Messaging.InboundEmail into a ConversationInput ready
     * for ConversationIngestionService.ingest().
     */
    public static PulseConversationModels.ConversationInput buildConversationInput(
        Messaging.InboundEmail email, Id instanceId
    ) {
        PulseConversationModels.ConversationInput input =
            new PulseConversationModels.ConversationInput();

        input.medium = 'Email';
        input.subject = email.subject;
        input.sourceAdapter = 'inbound_email';
        input.externalSource = 'InboundEmail';
        input.externalSourceId = email.messageId;
        input.participants = buildParticipants(email);

        if (instanceId != null) {
            input.workflowInstanceId = instanceId;
            List<Workflow_Instance__c> instances = [
                SELECT Parent_Record_Id__c, Parent_Object_Type__c
                FROM Workflow_Instance__c
                WHERE Id = :instanceId
                LIMIT 1
            ];
            if (!instances.isEmpty()) {
                input.parentRecordId = instances[0].Parent_Record_Id__c;
                input.parentObjectType = instances[0].Parent_Object_Type__c;
            }
        }

        PulseConversationModels.TurnInput turn = new PulseConversationModels.TurnInput();
        turn.role = 'Customer';
        turn.speaker = String.isNotBlank(email.fromName) ? email.fromName : email.fromAddress;
        turn.content = String.isNotBlank(email.plainTextBody)
            ? email.plainTextBody
            : stripHtml(email.htmlBody);
        turn.timestamp = Datetime.now();
        turn.turnIndex = 0;
        input.turns.add(turn);

        return input;
    }

    private static String buildParticipants(Messaging.InboundEmail email) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(email.fromName)) {
            parts.add(email.fromName);
        } else if (String.isNotBlank(email.fromAddress)) {
            parts.add(email.fromAddress);
        }
        if (email.toAddresses != null) {
            for (String addr : email.toAddresses) {
                parts.add(addr);
            }
        }
        return String.join(parts, '; ');
    }

    @TestVisible
    private static String stripHtml(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        return html.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
    }
}

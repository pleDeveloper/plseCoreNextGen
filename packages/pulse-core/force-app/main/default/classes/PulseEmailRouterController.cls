/**
 * PulseEmailRouterController
 *
 * AuraEnabled façade for the Admin Studio "Email routing" panel.
 * - listUnroutedEmails() — Conversations with no Parent_Record_Id__c
 * - listRoutingRules()   — Conversation_Routing_Rule__mdt
 * - routeToExistingRecord(conversationId, recordId) — sets Parent_Record_Id__c
 * - createOpportunityFromConversation(conversationId) — runs the default rule
 * - upsertRoutingRule(payload)   — deploys Conversation_Routing_Rule__mdt via
 *                                  Metadata.Operations.enqueueDeployment.
 *                                  Accepts Map<String,Object> to dodge the
 *                                  Aura typed-inner-class deserialization bug
 *                                  (see PulseWorkflowTriggerController for
 *                                  the full note; same pattern applies here).
 * - deleteRoutingRule(developerName) — soft-delete: sets Active__c=false via
 *                                      enqueueDeployment. The Apex Metadata
 *                                      API cannot remove CMDT records, so we
 *                                      deactivate instead of hard-deleting.
 * - getDeployStatus(jobId)       — polls AsyncApexJob status for the UI.
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

    // ── Routing rule CRUD (Metadata API) ──────────────────────────────
    //
    // upsertRoutingRule / deleteRoutingRule use the same pattern established
    // by PulseActionStatusTemplateController.upsertTemplate and
    // PulseGlobalActionHubController.upsertColumnConfig. Input arrives as
    // Map<String,Object> because Aura's JSON→typed-DTO deserialization is
    // broken for user-defined inner Apex classes on this org (empirically
    // reproduced in docs/diagnostics/aura-upsertTrigger-repro.sh).
    //
    // Source deploy of new CMDT records hits UNKNOWN_EXCEPTION on the dev
    // scratch; Metadata.Operations.enqueueDeployment is the one reliable
    // write path — see scripts/seed-tool-registry.apex for precedent.

    global class RoutingRuleInput {
        public String  ruleKey;
        public Boolean active;
        public Integer priority;
        public String  sourceAdapter;
        public String  matchStrategy;
        public String  targetObject;
        public String  createDefaultsJson;
        public String  triggerWorkflowKey;
        // Optional explicit developer name for editing an existing rule; if
        // absent we derive it from ruleKey. Also honoured on delete.
        public String  developerName;
    }

    global class RuleDeployResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      jobId;
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  error;
    }

    global class DeployStatusView {
        @AuraEnabled public String  status;     // Queued | Processing | Completed | Failed | Aborted | Unknown
        @AuraEnabled public Boolean done;
        @AuraEnabled public String  errors;
    }

    /**
     * Test seam around Metadata.Operations.enqueueDeployment. Production
     * code goes through here. Tests swap in a stub via
     * PulseEmailRouterController.deployer = new StubDeployer().
     */
    public interface IRuleDeployer {
        Id enqueue(Metadata.DeployContainer container);
    }

    public class DefaultRuleDeployer implements IRuleDeployer {
        public Id enqueue(Metadata.DeployContainer container) {
            return Metadata.Operations.enqueueDeployment(container, null);
        }
    }

    @TestVisible
    private static IRuleDeployer deployer = new DefaultRuleDeployer();

    /**
     * Last container we tried to deploy — exposed for tests so they can
     * assert the prepared payload without going through the async pipeline.
     */
    @TestVisible
    private static Metadata.DeployContainer lastDeployContainer;

    @AuraEnabled
    global static RuleDeployResult upsertRoutingRule(Map<String, Object> payload) {
        RuleDeployResult out = new RuleDeployResult();
        try {
            RoutingRuleInput input = coerceToRoutingRuleInput(payload);
            if (input == null || String.isBlank(input.ruleKey)) {
                out.success = false;
                out.error = 'ruleKey is required';
                return out;
            }
            if (String.isBlank(input.targetObject)) {
                out.success = false;
                out.error = 'targetObject is required';
                return out;
            }
            if (String.isBlank(input.matchStrategy)) {
                out.success = false;
                out.error = 'matchStrategy is required';
                return out;
            }
            if (String.isNotBlank(input.createDefaultsJson)) {
                // Shape validation — must parse as JSON object.
                try {
                    Object parsed = JSON.deserializeUntyped(input.createDefaultsJson);
                    if (!(parsed instanceof Map<String, Object>)) {
                        out.success = false;
                        out.error = 'createDefaultsJson must be a JSON object';
                        return out;
                    }
                } catch (Exception je) {
                    out.success = false;
                    out.error = 'createDefaultsJson is invalid JSON: ' + je.getMessage();
                    return out;
                }
            }

            String devName = String.isNotBlank(input.developerName)
                ? toDeveloperName(input.developerName)
                : toDeveloperName(input.ruleKey);

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Conversation_Routing_Rule.' + devName;
            cm.label    = devName.replace('_', ' ');

            cm.values.add(makeRuleValue('Rule_Key__c',        input.ruleKey));
            cm.values.add(makeRuleValue('Active__c',
                input.active != null ? input.active : true));
            if (input.priority != null) {
                cm.values.add(makeRuleValue('Priority__c', input.priority));
            }
            if (String.isNotBlank(input.sourceAdapter)) {
                cm.values.add(makeRuleValue('Source_Adapter__c', input.sourceAdapter));
            }
            cm.values.add(makeRuleValue('Match_Strategy__c',  input.matchStrategy));
            cm.values.add(makeRuleValue('Target_Object__c',   input.targetObject));
            if (input.createDefaultsJson != null) {
                cm.values.add(makeRuleValue('Create_Defaults_JSON__c',
                    input.createDefaultsJson));
            }
            if (String.isNotBlank(input.triggerWorkflowKey)) {
                cm.values.add(makeRuleValue('Trigger_Workflow_Key__c',
                    input.triggerWorkflowKey));
            }

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            lastDeployContainer = container;

            Id jobId = deployer.enqueue(container);
            out.success = true;
            out.jobId = jobId;
            out.developerName = devName;
            return out;
        } catch (Exception e) {
            out.success = false;
            out.error = e.getTypeName() + ': ' + e.getMessage();
            return out;
        }
    }

    /**
     * Soft-delete: the Apex Metadata API does not support removing
     * CMDT records, so we deploy an Active__c=false update. This keeps
     * the audit trail and lets admins re-activate via Setup if needed.
     */
    @AuraEnabled
    global static RuleDeployResult deleteRoutingRule(String developerName) {
        RuleDeployResult out = new RuleDeployResult();
        try {
            if (String.isBlank(developerName)) {
                out.success = false;
                out.error = 'developerName is required';
                return out;
            }
            String devName = toDeveloperName(developerName);

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Conversation_Routing_Rule.' + devName;
            cm.label    = devName.replace('_', ' ');
            cm.values.add(makeRuleValue('Active__c', false));

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            lastDeployContainer = container;

            Id jobId = deployer.enqueue(container);
            out.success = true;
            out.jobId = jobId;
            out.developerName = devName;
            return out;
        } catch (Exception e) {
            out.success = false;
            out.error = e.getTypeName() + ': ' + e.getMessage();
            return out;
        }
    }

    @AuraEnabled
    global static DeployStatusView getDeployStatus(String jobId) {
        DeployStatusView v = new DeployStatusView();
        if (String.isBlank(jobId)) {
            v.status = 'Unknown';
            v.done = true;
            v.errors = 'jobId is required';
            return v;
        }
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, ExtendedStatus, NumberOfErrors
            FROM   AsyncApexJob
            WHERE  Id = :jobId
            LIMIT 1
        ];
        if (jobs.isEmpty()) {
            // Metadata deploy jobs are not always AsyncApexJob rows — the
            // UI still gets a sane answer so it can stop polling.
            v.status = 'Unknown';
            v.done = true;
            return v;
        }
        AsyncApexJob j = jobs[0];
        v.status = j.Status;
        v.done = (j.Status == 'Completed' || j.Status == 'Failed' || j.Status == 'Aborted');
        if (j.NumberOfErrors != null && j.NumberOfErrors > 0) {
            v.errors = j.ExtendedStatus;
        }
        return v;
    }

    @TestVisible
    private static RoutingRuleInput coerceToRoutingRuleInput(Map<String, Object> raw) {
        RoutingRuleInput out = new RoutingRuleInput();
        if (raw == null) return out;

        Object rk = raw.get('ruleKey');
        if (rk instanceof String) out.ruleKey = (String) rk;
        else if (rk != null) out.ruleKey = String.valueOf(rk);

        Object act = raw.get('active');
        if (act instanceof Boolean) out.active = (Boolean) act;
        else if (act != null) out.active = Boolean.valueOf(String.valueOf(act));

        Object pr = raw.get('priority');
        if (pr instanceof Integer) out.priority = (Integer) pr;
        else if (pr instanceof Decimal) out.priority = ((Decimal) pr).intValue();
        else if (pr instanceof Double) out.priority = ((Double) pr).intValue();
        else if (pr instanceof String && String.isNotBlank((String) pr)) {
            try { out.priority = Integer.valueOf((String) pr); } catch (Exception ignored) {}
        }

        Object sa = raw.get('sourceAdapter');
        if (sa instanceof String) out.sourceAdapter = (String) sa;

        Object ms = raw.get('matchStrategy');
        if (ms instanceof String) out.matchStrategy = (String) ms;

        Object toObj = raw.get('targetObject');
        if (toObj instanceof String) out.targetObject = (String) toObj;

        Object cd = raw.get('createDefaultsJson');
        if (cd instanceof String) {
            out.createDefaultsJson = (String) cd;
        } else if (cd != null) {
            out.createDefaultsJson = JSON.serialize(cd);
        }

        Object tw = raw.get('triggerWorkflowKey');
        if (tw instanceof String) out.triggerWorkflowKey = (String) tw;

        Object dn = raw.get('developerName');
        if (dn instanceof String) out.developerName = (String) dn;

        return out;
    }

    private static Metadata.CustomMetadataValue makeRuleValue(String field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = val;
        return v;
    }

    @TestVisible
    private static String toDeveloperName(String raw) {
        if (String.isBlank(raw)) return 'Unnamed';
        String cleaned = raw.replaceAll('[^A-Za-z0-9_]', '_');
        while (cleaned.contains('__')) cleaned = cleaned.replace('__', '_');
        if (cleaned.startsWith('_')) cleaned = cleaned.substring(1);
        if (cleaned.endsWith('_'))   cleaned = cleaned.substring(0, cleaned.length() - 1);
        if (String.isBlank(cleaned)) cleaned = 'Unnamed';
        if (!Pattern.matches('[A-Za-z].*', cleaned)) cleaned = 'X_' + cleaned;
        return cleaned;
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

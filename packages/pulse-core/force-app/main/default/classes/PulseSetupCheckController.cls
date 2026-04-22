/**
 * PulseSetupCheckController
 *
 * Preflight checks for the Pulse Admin Studio Settings panel.
 * Each check returns: key, label, description (what it unlocks), status,
 * details (specific finding), and fixInstructions (how to resolve).
 *
 * Status values:
 *   ok       — green, nothing to do
 *   warning  — yellow, recommended but not strictly required
 *   error    — red, blocks a feature
 *   info     — grey, informational only
 */
global with sharing class PulseSetupCheckController {

    global class CheckResult {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String description;
        @AuraEnabled public String status;         // ok | warning | error | info
        @AuraEnabled public String details;
        @AuraEnabled public String fixInstructions;
        @AuraEnabled public String setupPath;      // /lightning/setup/<x>/home — opens Setup page
    }

    @AuraEnabled(cacheable=false)
    global static List<CheckResult> runChecks() {
        List<CheckResult> out = new List<CheckResult>();
        out.add(checkPermissionSet());
        out.add(checkToolingNamedCredential());
        out.add(checkAnthropicNamedCredential());
        out.add(checkToolRegistry());
        out.add(checkPublishedWorkflows());
        out.add(checkProvisionedApexTriggers());
        out.add(checkEmailDeliverability());
        return out;
    }

    // ── Individual checks ─────────────────────────────────────────────

    private static CheckResult checkPermissionSet() {
        CheckResult r = new CheckResult();
        r.key         = 'permission_set';
        r.label       = 'Pulse Core Admin permission set';
        r.description = 'Grants CRUD on every Pulse runtime + config object.';
        r.setupPath   = '/lightning/setup/PermSets/home';

        Integer assigned = [
            SELECT COUNT() FROM PermissionSetAssignment
            WHERE PermissionSet.Name = 'Pulse_Core_Admin'
              AND AssigneeId = :UserInfo.getUserId()
        ];
        if (assigned > 0) {
            r.status  = 'ok';
            r.details = 'Assigned to you.';
        } else {
            r.status          = 'warning';
            r.details         = 'Not assigned to the current user.';
            r.fixInstructions = 'Setup → Permission Sets → Pulse Core Admin → Manage Assignments → add your user. ' +
                'Most admin screens tolerate missing this set, but some FLS-sensitive views will be empty.';
        }
        return r;
    }

    private static CheckResult checkToolingNamedCredential() {
        CheckResult r = new CheckResult();
        r.key         = 'named_credential_tooling';
        r.label       = 'Named Credential: Pulse_Self_Org_Tooling';
        r.description = 'Lets Pulse auto-provision Apex triggers on target objects when you save a Workflow Trigger, ' +
                        'and auto-create projected fields when you publish a workflow.';
        r.setupPath   = '/lightning/setup/NamedCredential/home';

        Integer count = [
            SELECT COUNT() FROM NamedCredential WHERE DeveloperName = 'Pulse_Self_Org_Tooling'
        ];
        if (count > 0) {
            r.status  = 'ok';
            r.details = 'Configured.';
        } else {
            r.status          = 'error';
            r.details         = 'Missing. Saving a Workflow Trigger still works, but the Apex trigger ' +
                                'on the target object will not be auto-created.';
            r.fixInstructions = 'Setup → Named Credentials → New Legacy. ' +
                                'Name: Pulse_Self_Org_Tooling. URL: your org\'s My Domain (e.g. https://yourdomain.my.salesforce.com). ' +
                                'Identity Type: Named Principal. Authentication Protocol: OAuth 2.0. ' +
                                'Auth Provider: a connected app you trust with Apex access. ' +
                                'Scope: api refresh_token. Start Authentication Flow on Save.';
        }
        return r;
    }

    private static CheckResult checkAnthropicNamedCredential() {
        CheckResult r = new CheckResult();
        r.key         = 'named_credential_anthropic';
        r.label       = 'Named Credential: Pulse_Anthropic';
        r.description = 'Lets Pulse call the Anthropic API for AI-driven workflow steps. ' +
                        'Only required if any of your workflows use ai_driven states.';
        r.setupPath   = '/lightning/setup/NamedCredential/home';

        Integer count = [
            SELECT COUNT() FROM NamedCredential
            WHERE DeveloperName = 'Pulse_Anthropic' OR DeveloperName = 'Anthropic_API'
        ];
        if (count > 0) {
            r.status  = 'ok';
            r.details = 'Configured.';
        } else {
            r.status          = 'warning';
            r.details         = 'Missing. AI-driven workflow steps will fail at runtime.';
            r.fixInstructions = 'Setup → Named Credentials → New Legacy. ' +
                                'Name: Pulse_Anthropic. URL: https://api.anthropic.com. ' +
                                'Identity Type: Named Principal. Authentication Protocol: Password Authentication. ' +
                                'Add a Custom Header: x-api-key = <your Anthropic API key>.';
        }
        return r;
    }

    private static CheckResult checkToolRegistry() {
        CheckResult r = new CheckResult();
        r.key         = 'tool_registry';
        r.label       = 'Tool registry';
        r.description = 'Active tools the AI and HITL approvals can resolve at runtime.';
        r.setupPath   = '/lightning/setup/CustomMetadata/home';

        List<Workflow_Tool_Registration__mdt> active = [
            SELECT DeveloperName, Tool_Key__c, Apex_Class__c
            FROM Workflow_Tool_Registration__mdt
            WHERE Active__c = true
        ];
        if (active.isEmpty()) {
            r.status          = 'error';
            r.details         = 'No active tools. Approve clicks on the Action Hub will fail with "Tool not found".';
            r.fixInstructions = 'Deploy the shipped tool registry: run ' +
                                'sf project deploy start --source-dir packages/pulse-tools-core/force-app/main/default/customMetadata';
        } else {
            List<String> keys = new List<String>();
            for (Workflow_Tool_Registration__mdt reg : active) {
                keys.add(reg.Tool_Key__c);
            }
            r.status  = 'ok';
            r.details = active.size() + ' active: ' + String.join(keys, ', ');
        }
        return r;
    }

    private static CheckResult checkPublishedWorkflows() {
        CheckResult r = new CheckResult();
        r.key         = 'published_workflows';
        r.label       = 'Published workflows';
        r.description = 'At least one workflow needs to be published before the runtime does anything.';
        r.setupPath   = null;

        Integer count = [
            SELECT COUNT() FROM Workflow_Definition__c WHERE Status__c = 'Published'
        ];
        if (count > 0) {
            r.status  = 'ok';
            r.details = count + ' published workflow' + (count == 1 ? '' : 's') + '.';
        } else {
            r.status          = 'warning';
            r.details         = 'No published workflows.';
            r.fixInstructions = 'Admin Studio → Workflow builder → New workflow → define states → Publish workflow.';
        }
        return r;
    }

    private static CheckResult checkProvisionedApexTriggers() {
        CheckResult r = new CheckResult();
        r.key         = 'provisioned_triggers';
        r.label       = 'Provisioned Apex triggers';
        r.description = 'Each target object used by a Workflow Trigger needs a Pulse Apex trigger to route record saves to the starter.';
        r.setupPath   = '/lightning/setup/ApexTriggers/home';

        Set<String> targetObjects = new Set<String>();
        for (Workflow_Trigger__c t : [
            SELECT Target_Object__c FROM Workflow_Trigger__c
            WHERE Active__c = true AND Target_Object__c != null
        ]) {
            targetObjects.add(t.Target_Object__c);
        }

        if (targetObjects.isEmpty()) {
            r.status  = 'info';
            r.details = 'No Workflow Triggers configured yet.';
            return r;
        }

        Set<String> expectedTriggerNames = new Set<String>();
        Map<String, String> nameToObject = new Map<String, String>();
        for (String obj : targetObjects) {
            String name = PulseTriggerProvisioningService.triggerNameFor(obj);
            expectedTriggerNames.add(name);
            nameToObject.put(name, obj);
        }

        Set<String> existingNames = new Set<String>();
        for (ApexTrigger at : [
            SELECT Name FROM ApexTrigger WHERE Name IN :expectedTriggerNames
        ]) {
            existingNames.add(at.Name);
        }

        List<String> missing = new List<String>();
        for (String expected : expectedTriggerNames) {
            if (!existingNames.contains(expected)) {
                missing.add(nameToObject.get(expected) + ' (' + expected + ')');
            }
        }

        if (missing.isEmpty()) {
            r.status  = 'ok';
            r.details = 'All ' + expectedTriggerNames.size() + ' target object' +
                        (expectedTriggerNames.size() == 1 ? '' : 's') + ' wired up.';
        } else {
            r.status          = 'error';
            r.details         = 'Missing triggers for: ' + String.join(missing, '; ') + '. ' +
                                'Workflow Triggers on those objects will not fire until this is fixed.';
            r.fixInstructions = 'Re-save the Workflow Trigger once the Pulse_Self_Org_Tooling Named Credential is configured — ' +
                                'the Apex trigger will be provisioned automatically. ' +
                                'Or create manually: Setup → Apex Triggers → New, on the target object, with body ' +
                                'plse.PulseWorkflowStarter.handle(\'<SObject>\', Trigger.new, Trigger.oldMap, Trigger.isInsert);';
        }
        return r;
    }

    private static CheckResult checkEmailDeliverability() {
        CheckResult r = new CheckResult();
        r.key         = 'email_deliverability';
        r.label       = 'Email deliverability';
        r.description = 'Required for the send_email tool. Scratch orgs default to System email only.';
        r.setupPath   = '/lightning/setup/OrgEmailSettings/home';
        r.status      = 'info';
        r.details     = 'Cannot be verified from Apex. Scratch orgs default to "System email only" ' +
                        'which lets send_email fire internally but prevents real outbound delivery.';
        r.fixInstructions = 'Setup → Deliverability → Access level = All email. ' +
                            'For production orgs this is usually already set.';
        return r;
    }
}

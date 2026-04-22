/**
 * PulseTriggerProvisioningService
 *
 * Provisions a thin per-SObject Apex trigger via the Tooling API so that
 * any record save on that SObject calls PulseWorkflowStarter. The trigger
 * is created once per object (idempotent) the first time an admin adds
 * a Workflow_Trigger__c whose Target_Object__c = <SObject>.
 *
 * The generated trigger body is intentionally thin:
 *
 *   trigger <SObject>_PulseWorkflowTrigger on <SObject> (after insert, after update) {
 *       plse.PulseWorkflowStarter.handle('<SObject>', Trigger.new, Trigger.oldMap, Trigger.isInsert);
 *   }
 *
 * We check Setup's ApexTrigger table first — if a trigger with the canonical
 * name already exists, we do nothing. This is both safer (never overwrite
 * admin-authored triggers) and cheaper (no callout needed on repeat).
 *
 * Named Credential: re-uses Pulse_Self_Org_Tooling — the same credential the
 * schema deployer uses for field creation.
 */
global with sharing class PulseTriggerProvisioningService {

    @TestVisible private static final String NAMED_CREDENTIAL = 'callout:Pulse_Self_Org_Tooling';
    @TestVisible private static final String API_VERSION       = 'v62.0';
    @TestVisible private static final String TRIGGER_SUFFIX    = '_PulseWorkflowTrigger';
    @TestVisible private static final String STARTER_REF       = 'plse.PulseWorkflowStarter';

    // Hook so tests can bypass the callout.
    public static Boolean mockProvisioned = false;

    global class ProvisionResult {
        @AuraEnabled global Boolean success;
        @AuraEnabled global Boolean alreadyExisted;
        @AuraEnabled global String  triggerName;
        @AuraEnabled global String  message;
    }

    /**
     * Ensure an Apex trigger exists on the given SObject that calls the
     * Pulse starter. Safe to call repeatedly.
     */
    global static ProvisionResult ensureTriggerFor(String sObjectApiName) {
        ProvisionResult result = new ProvisionResult();
        result.triggerName = triggerNameFor(sObjectApiName);

        if (String.isBlank(sObjectApiName)) {
            result.success = false;
            result.message = 'sObjectApiName is required';
            return result;
        }

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(sObjectApiName)) {
            result.success = false;
            result.message = 'SObject does not exist: ' + sObjectApiName;
            return result;
        }

        if (triggerExists(result.triggerName)) {
            result.success        = true;
            result.alreadyExisted = true;
            result.message        = 'Trigger already provisioned';
            return result;
        }

        if (Test.isRunningTest() && !mockProvisioned) {
            // Don't actually call out in test context.
            result.success        = true;
            result.alreadyExisted = false;
            result.message        = 'Test mode — callout skipped';
            return result;
        }

        String body = buildTriggerBody(sObjectApiName, result.triggerName);

        Map<String, Object> payload = new Map<String, Object>();
        payload.put('Name',            result.triggerName);
        payload.put('TableEnumOrId',   sObjectApiName);
        payload.put('Body',            body);
        payload.put('ApiVersion',      62.0);
        payload.put('Status',          'Active');

        try {
            HttpResponse res = invokeToolingApi(
                'POST',
                '/services/data/' + API_VERSION + '/tooling/sobjects/ApexTrigger/',
                JSON.serialize(payload)
            );

            Integer code = res.getStatusCode();
            if (code >= 200 && code < 300) {
                result.success        = true;
                result.alreadyExisted = false;
                result.message        = 'Created ' + result.triggerName;
            } else {
                result.success = false;
                result.message = 'Tooling API ' + code + ': ' + res.getBody();
            }
        } catch (System.CalloutException ce) {
            // Common cause: Named Credential 'Pulse_Self_Org_Tooling' isn't
            // configured in this org. We don't want that to block the admin
            // from saving the trigger definition — the Workflow_Trigger__c
            // row itself is still useful data, and the admin can wire up
            // the Apex trigger later (manually or after setting up the NC).
            result.success = false;
            result.message = 'Could not auto-provision the Apex trigger (' + ce.getMessage() +
                '). Set up the Pulse_Self_Org_Tooling Named Credential, ' +
                'or create an Apex trigger named ' + result.triggerName +
                ' on ' + sObjectApiName + ' that calls plse.PulseWorkflowStarter.handle.';
        } catch (Exception e) {
            result.success = false;
            result.message = 'Provisioning failed: ' + e.getMessage();
        }
        return result;
    }

    /** Return the canonical trigger name for a given SObject. */
    global static String triggerNameFor(String sObjectApiName) {
        if (String.isBlank(sObjectApiName)) return null;
        // Strip namespace prefix (rare but safe) and trailing __c if custom.
        String base = sObjectApiName;
        if (base.endsWith('__c')) {
            base = base.removeEnd('__c');
        }
        // Keep base; replace any non-alphanumeric with underscore.
        base = base.replaceAll('[^A-Za-z0-9]', '_');
        return base + TRIGGER_SUFFIX;
    }

    @TestVisible
    private static Boolean triggerExists(String triggerName) {
        List<ApexTrigger> rows = [
            SELECT Id FROM ApexTrigger WHERE Name = :triggerName LIMIT 1
        ];
        return !rows.isEmpty();
    }

    @TestVisible
    private static String buildTriggerBody(String sObjectApiName, String triggerName) {
        return 'trigger ' + triggerName + ' on ' + sObjectApiName
            + ' (after insert, after update) {\n'
            + '    ' + STARTER_REF + '.handle(\''
            + sObjectApiName + '\', Trigger.new, Trigger.oldMap, Trigger.isInsert);\n'
            + '}\n';
    }

    @TestVisible
    private static HttpResponse invokeToolingApi(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);
        if (body != null) {
            req.setBody(body);
        }
        return new Http().send(req);
    }
}

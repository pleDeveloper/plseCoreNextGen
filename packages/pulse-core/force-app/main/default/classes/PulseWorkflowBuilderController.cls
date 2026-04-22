/**
 * PulseWorkflowBuilderController
 *
 * AuraEnabled controller for the Workflow Builder canvas (Wave 3b).
 * Global for potential cross-package extraction.
 *
 * Methods:
 *   loadWorkflow   — returns Workflow_Definition__c record + raw JSON
 *   saveWorkflow   — validates contract + persists JSON
 *   publishWorkflow— delegates to SchemaProvisioningService.provision()
 */
global with sharing class PulseWorkflowBuilderController {

    // ── Inner types (AuraEnabled-serialisable) ─────────────────────────

    global class WorkflowPayload {
        @AuraEnabled public Id    recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String workflowKey;
        @AuraEnabled public Integer version;
        @AuraEnabled public String status;
        @AuraEnabled public String definitionJson;
        @AuraEnabled public String subjectKinds;
    }

    global class SaveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      recordId;
        @AuraEnabled public List<String> errors;
    }

    global class PublishResult {
        @AuraEnabled public Id     deploymentRequestId;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public List<String> validationErrors;
    }

    global class FieldSpec {
        @AuraEnabled public String  objectApiName;
        @AuraEnabled public String  fieldApiName;
        @AuraEnabled public String  fieldLabel;
        @AuraEnabled public String  fieldType;
        @AuraEnabled public Integer fieldLength;
        @AuraEnabled public Integer precision;
        @AuraEnabled public Integer scale;
    }

    // ── Load ───────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static WorkflowPayload loadWorkflow(Id workflowDefinitionId) {
        Workflow_Definition__c wd = [
            SELECT Id, Name, Workflow_Key__c, Version__c, Status__c,
                   Definition_JSON__c, Subject_Kinds__c
            FROM   Workflow_Definition__c
            WHERE  Id = :workflowDefinitionId
            LIMIT  1
        ];
        WorkflowPayload p = new WorkflowPayload();
        p.recordId       = wd.Id;
        p.name           = wd.Name;
        p.workflowKey    = wd.Workflow_Key__c;
        p.version        = wd.Version__c != null ? wd.Version__c.intValue() : 1;
        p.status         = wd.Status__c;
        p.definitionJson = wd.Definition_JSON__c;
        p.subjectKinds   = wd.Subject_Kinds__c;
        return p;
    }

    // ── Save ───────────────────────────────────────────────────────────

    @AuraEnabled
    global static SaveResult saveWorkflow(Id workflowDefinitionId, String jsonBody) {
        SaveResult result = new SaveResult();
        result.errors = new List<String>();

        // Parse + validate the contract
        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(jsonBody);
        } catch (WorkflowContract.ContractParseException e) {
            result.success = false;
            result.errors.add(e.getMessage());
            return result;
        }

        List<String> validationErrors = WorkflowContract.validate(wf);
        if (!validationErrors.isEmpty()) {
            result.success = false;
            result.errors  = validationErrors;
            return result;
        }

        if (workflowDefinitionId != null) {
            // Update existing record
            Workflow_Definition__c wd = new Workflow_Definition__c(
                Id                 = workflowDefinitionId,
                Definition_JSON__c = jsonBody
            );
            update wd;
            result.recordId = workflowDefinitionId;
        } else {
            // Create new record
            Workflow_Definition__c wd = new Workflow_Definition__c(
                Name               = wf.workflowKey,
                Workflow_Key__c    = wf.workflowKey,
                Version__c         = wf.version,
                Status__c          = 'Draft',
                Definition_JSON__c = jsonBody,
                Subject_Kinds__c   = wf.subjectKinds != null
                    ? String.join(wf.subjectKinds, ';')
                    : null
            );
            insert wd;
            result.recordId = wd.Id;
        }

        result.success = true;
        return result;
    }

    // ── Publish ────────────────────────────────────────────────────────

    @AuraEnabled
    global static PublishResult publishWorkflow(
        Id workflowDefinitionId,
        String targetObject,
        List<FieldSpec> requestedFields
    ) {
        PublishResult result = new PublishResult();

        // Look up workflow key from the definition record
        Workflow_Definition__c wd = [
            SELECT Workflow_Key__c
            FROM   Workflow_Definition__c
            WHERE  Id = :workflowDefinitionId
            LIMIT  1
        ];

        // Map controller FieldSpec → gateway FieldSpec
        List<SchemaDeploymentGateway.FieldSpec> gwFields =
            new List<SchemaDeploymentGateway.FieldSpec>();
        for (FieldSpec fs : requestedFields) {
            SchemaDeploymentGateway.FieldSpec gf = new SchemaDeploymentGateway.FieldSpec();
            gf.objectApiName = fs.objectApiName;
            gf.fieldApiName  = fs.fieldApiName;
            gf.fieldLabel    = fs.fieldLabel;
            gf.fieldType     = fs.fieldType;
            gf.length        = fs.fieldLength;
            gf.precision     = fs.precision;
            gf.scale         = fs.scale;
            gwFields.add(gf);
        }

        SchemaProvisioningService.ProvisioningResult provResult =
            SchemaProvisioningService.provision(
                workflowDefinitionId,
                targetObject,
                wd.Workflow_Key__c,
                gwFields
            );

        result.deploymentRequestId = provResult.deploymentRequestId;
        result.status              = provResult.status;
        result.message             = provResult.message;
        result.validationErrors    = provResult.validationErrors;
        return result;
    }
}

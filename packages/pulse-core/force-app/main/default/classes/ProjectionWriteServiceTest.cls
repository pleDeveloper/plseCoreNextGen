@IsTest
private class ProjectionWriteServiceTest {

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Workflow_Projection__mdt makeMapping(
        String workflowKey,
        String fieldKey,
        String targetObject,
        String targetField,
        String fieldType,
        String scope,
        Integer precedence
    ) {
        Workflow_Projection__mdt m = new Workflow_Projection__mdt();
        m.Workflow_Key__c    = workflowKey;
        m.Field_Key__c       = fieldKey;
        m.Target_Object__c   = targetObject;
        m.Target_Field__c    = targetField;
        m.Field_Type__c      = fieldType;
        m.Scope__c           = scope;
        m.Write_Precedence__c = precedence;
        m.Active__c          = true;
        return m;
    }

    private static Account createTestAccount() {
        Account a = new Account(Name = 'Projection Test Account');
        insert a;
        return a;
    }

    // ── Tests ───────────────────────────────────────────────────────────

    @IsTest
    static void testSuccessfulProjectionToAccount() {
        Account a = createTestAccount();

        // Map workflow field 'company_website' → Account.Website
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'company_website', 'Account', 'Website', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId    = a.Id;
        req.parentObjectType  = 'Account';
        req.workflowKey       = 'intake';
        req.fieldValues       = new Map<String, String>{
            'company_website' => 'https://example.com'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected one result');
        System.assertEquals(true, results[0].success, 'Projection should succeed');
        System.assertEquals('Website', results[0].targetField);

        Account updated = [SELECT Website FROM Account WHERE Id = :a.Id];
        System.assertEquals('https://example.com', updated.Website);

        // Audit event written
        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Event_Type__c = 'PROJECTION_WRITE'
        ];
        System.assert(!events.isEmpty(), 'Audit event should be written');
    }

    @IsTest
    static void testBulkProjectionMultipleRecords() {
        List<Account> accts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accts.add(new Account(Name = 'Bulk Test ' + i));
        }
        insert accts;

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'phone', 'Account', 'Phone', 'Text', 'WorkflowScoped', 10)
        };

        List<ProjectionWriteService.ProjectionRequest> requests =
            new List<ProjectionWriteService.ProjectionRequest>();
        for (Account a : accts) {
            ProjectionWriteService.ProjectionRequest req =
                new ProjectionWriteService.ProjectionRequest();
            req.parentRecordId   = a.Id;
            req.parentObjectType = 'Account';
            req.workflowKey      = 'intake';
            req.fieldValues      = new Map<String, String>{
                'phone' => '555-0' + String.valueOf(a.Id).right(3)
            };
            requests.add(req);
        }

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(requests);
        Test.stopTest();

        Integer successCount = 0;
        for (ProjectionWriteService.ProjectionResult pr : results) {
            if (pr.success) {
                successCount++;
            }
        }
        System.assertEquals(200, successCount, 'All 200 projections should succeed');
    }

    @IsTest
    static void testNoMappingForFieldKey() {
        Account a = createTestAccount();

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>();

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'unmapped_field' => 'value'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('No active projection mapping'));
    }

    @IsTest
    static void testInvalidTargetObject() {
        Account a = createTestAccount();

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'field_a', 'Nonexistent_Object__c', 'Field__c', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'field_a' => 'value'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('Target object not found'));
    }

    @IsTest
    static void testInvalidTargetField() {
        Account a = createTestAccount();

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'field_a', 'Account', 'Nonexistent_Field__c', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'field_a' => 'value'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('Target field not found'));
    }

    @IsTest
    static void testTypeIncompatibilityNumberField() {
        Account a = createTestAccount();

        // Map to Account.NumberOfEmployees (Integer field)
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'emp_count', 'Account', 'NumberOfEmployees', 'Number', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'emp_count' => 'not_a_number'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('Type incompatibility'));
    }

    @IsTest
    static void testSharedVsScopedPrecedence() {
        Account a = createTestAccount();

        // Shared mapping at precedence 50, scoped at precedence 10 → scoped wins
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping(null, 'company_website', 'Account', 'Description', 'Text', 'Shared', 50),
            makeMapping('intake', 'company_website', 'Account', 'Website', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'company_website' => 'https://scoped.example.com'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        // Should resolve to the workflow-scoped mapping → Website, not Description
        System.assertEquals('Website', results[0].targetField);
        System.assertEquals(true, results[0].success);

        Account updated = [SELECT Website FROM Account WHERE Id = :a.Id];
        System.assertEquals('https://scoped.example.com', updated.Website);
    }

    @IsTest
    static void testSharedFallbackWhenNoScopedMapping() {
        Account a = createTestAccount();

        // Only a shared mapping — no scoped one for 'other_workflow'
        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping(null, 'company_website', 'Account', 'Website', 'Text', 'Shared', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'other_workflow';
        req.fieldValues      = new Map<String, String>{
            'company_website' => 'https://shared.example.com'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        Account updated = [SELECT Website FROM Account WHERE Id = :a.Id];
        System.assertEquals('https://shared.example.com', updated.Website);
    }

    @IsTest
    static void testNullValueProjectsNull() {
        Account a = createTestAccount();
        a.Website = 'https://old.example.com';
        update a;

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'company_website', 'Account', 'Website', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'company_website' => null
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        System.assertEquals(true, results[0].success);
        Account updated = [SELECT Website FROM Account WHERE Id = :a.Id];
        System.assertEquals(null, updated.Website);
    }

    @IsTest
    static void testEmptyRequestListReturnsEmpty() {
        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>());
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testMultipleFieldsOnSameRecord() {
        Account a = createTestAccount();

        ProjectionWriteService.projectionOverride = new List<Workflow_Projection__mdt>{
            makeMapping('intake', 'company_website', 'Account', 'Website', 'Text', 'WorkflowScoped', 10),
            makeMapping('intake', 'phone', 'Account', 'Phone', 'Text', 'WorkflowScoped', 10)
        };

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId   = a.Id;
        req.parentObjectType = 'Account';
        req.workflowKey      = 'intake';
        req.fieldValues      = new Map<String, String>{
            'company_website' => 'https://multi.example.com',
            'phone'           => '555-1234'
        };

        Test.startTest();
        List<ProjectionWriteService.ProjectionResult> results =
            ProjectionWriteService.project(new List<ProjectionWriteService.ProjectionRequest>{ req });
        Test.stopTest();

        Integer successCount = 0;
        for (ProjectionWriteService.ProjectionResult pr : results) {
            if (pr.success) {
                successCount++;
            }
        }
        System.assertEquals(2, successCount, 'Both fields should succeed');

        Account updated = [SELECT Website, Phone FROM Account WHERE Id = :a.Id];
        System.assertEquals('https://multi.example.com', updated.Website);
        System.assertEquals('555-1234', updated.Phone);
    }
}

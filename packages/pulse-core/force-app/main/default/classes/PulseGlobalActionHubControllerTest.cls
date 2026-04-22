@IsTest
private class PulseGlobalActionHubControllerTest {

    private static final String SIMPLE_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"hub_test","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
          '{"key":"review","label":"Review","type":"approval","transitions":[]}' +
        ']}';

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Hub Test', Workflow_Key__c = 'hub_test', Version__c = 1,
            Status__c = 'Published', Definition_JSON__c = SIMPLE_CONTRACT,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;
    }

    private static Workflow_Definition__c getDef() {
        return [SELECT Id, Workflow_Key__c FROM Workflow_Definition__c LIMIT 1];
    }

    private static Opportunity newOpp(String name) {
        Opportunity o = new Opportunity(
            Name = name, StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert o;
        return o;
    }

    private static Workflow_Instance__c newInstance(Id defId, Id oppId) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId, Current_State__c = 'review',
            Status__c = 'Active', Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = oppId
        );
        insert inst;
        return inst;
    }

    private static Workflow_Action__c newAction(
        Id instanceId, String toolKey, String label, Id assignedUserId, Id assignedGroupId
    ) {
        Workflow_Action__c a = new Workflow_Action__c(
            Workflow_Instance__c = instanceId,
            Action_Key__c = 'a_' + Math.mod(Crypto.getRandomLong(), 100000),
            Phase_Key__c = 'review',
            Label__c = label,
            Action_Type__c = 'AI_Tool_Call',
            Tool_Key__c = toolKey,
            HITL_Policy__c = 'Approval_Required',
            Status__c = 'Pending',
            Required_For_Phase__c = true,
            Sequence__c = 0,
            Request_JSON__c = '{"toAddress":"t@t.com","subject":"hi","body":"hello"}',
            Assigned_User__c = assignedUserId,
            Assigned_To_Group__c = assignedGroupId
        );
        insert a;
        return a;
    }

    // ─── 1. Assigned to me ──────────────────────────────────────────

    @IsTest
    static void getMyPendingActionsReturnsActionsAssignedToMe() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Me');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        Workflow_Action__c mine = newAction(inst.Id, 'send_email', 'Mine', UserInfo.getUserId(), null);

        newAction(inst.Id, 'send_email', 'Other', null, null);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> rows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'assignedOnlyToMe' => true
            });
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertEquals(mine.Id, rows[0].actionId);
        System.assertEquals('me', rows[0].assignmentKind);
        System.assertEquals(true, rows[0].canRefine, 'send_email is refinable');
    }

    // ─── 2. includeUnassigned filter ────────────────────────────────

    @IsTest
    static void includeUnassignedReturnsUnassignedActions() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Unassigned');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        newAction(inst.Id, 'send_email', 'Unass', null, null);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> rows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'includeUnassigned' => true
            });
        Test.stopTest();

        Boolean foundUnassigned = false;
        for (PulseGlobalActionHubController.HubRow r : rows) {
            if (r.assignmentKind == 'unassigned') foundUnassigned = true;
        }
        System.assertEquals(true, foundUnassigned,
            'includeUnassigned should surface unassigned actions');
    }

    // ─── 3. My queues (group membership) ────────────────────────────

    @IsTest
    static void myQueuesReturnsGroupAssignedActions() {
        Group q = new Group(Name = 'Hub Test Queue', Type = 'Queue');
        insert q;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new GroupMember(GroupId = q.Id, UserOrGroupId = UserInfo.getUserId());
        }

        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Queue');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        Workflow_Action__c qAction = newAction(inst.Id, 'send_email', 'Queue task', null, q.Id);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> rows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>());
        Test.stopTest();

        Boolean foundGroup = false;
        for (PulseGlobalActionHubController.HubRow r : rows) {
            if (r.actionId == qAction.Id) {
                foundGroup = true;
                System.assertEquals('group', r.assignmentKind);
            }
        }
        System.assertEquals(true, foundGroup, 'queue-assigned action should be returned');
    }

    // ─── 4. Filter by parentObjectType ──────────────────────────────

    @IsTest
    static void filtersByParentObjectType() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Filter');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        newAction(inst.Id, 'send_email', 'Opp task', UserInfo.getUserId(), null);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> oppRows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'parentObjectType' => 'Opportunity'
            });
        List<PulseGlobalActionHubController.HubRow> accRows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'parentObjectType' => 'Account'
            });
        Test.stopTest();

        System.assertEquals(true, oppRows.size() >= 1,
            'Opportunity filter should include the seeded row');
        System.assertEquals(0, accRows.size(),
            'Account filter should exclude the Opportunity row');
    }

    // ─── 5. Column config: Opportunity_Columns resolves ─────────────

    @IsTest
    static void returnsConfiguredColumnsForOpportunity() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Cols');
        o.Amount = 12345; update o;
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        newAction(inst.Id, 'send_email', 'Col task', UserInfo.getUserId(), null);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> rows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'assignedOnlyToMe' => true
            });
        Test.stopTest();

        System.assertEquals(1, rows.size());
        PulseGlobalActionHubController.HubRow r = rows[0];
        System.assertEquals('Opp Cols', r.parentDisplayName);
        System.assertEquals(true, r.columns != null && !r.columns.isEmpty(),
            'Should produce column cells');
    }

    // ─── 6. FLS stripping path ─────────────────────────────────────

    @IsTest
    static void honoursStripInaccessibleForParentRecords() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp FLS');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        newAction(inst.Id, 'send_email', 'FLS task', UserInfo.getUserId(), null);

        Test.startTest();
        List<PulseGlobalActionHubController.HubRow> rows =
            PulseGlobalActionHubController.getMyPendingActions(new Map<String, Object>{
                'assignedOnlyToMe' => true
            });
        Test.stopTest();

        System.assertEquals(1, rows.size());
        System.assertNotEquals(null, rows[0].parentDisplayName);
    }

    // ─── 7. approveAction round-trip ────────────────────────────────

    @IsTest
    static void approveActionDelegatesToHitlService() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('stub', new StubTool());

        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Approve');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        Workflow_Action__c a = newAction(inst.Id, 'stub', 'Approve task', UserInfo.getUserId(), null);

        Test.startTest();
        PulseGlobalActionHubController.ResolveResult res =
            PulseGlobalActionHubController.approveAction(a.Id, null, 'notes');
        Test.stopTest();

        System.assertEquals(true, res.success, 'Approve should succeed: ' + res.message);
        System.assertEquals('Executed', res.resultStatus);
        Workflow_Action__c reloaded = [
            SELECT Status__c FROM Workflow_Action__c WHERE Id = :a.Id
        ];
        System.assertEquals('Executed', reloaded.Status__c);
    }

    // ─── 8. rejectAction round-trip ─────────────────────────────────

    @IsTest
    static void rejectActionDelegatesToHitlService() {
        Workflow_Definition__c def = getDef();
        Opportunity o = newOpp('Opp Reject');
        Workflow_Instance__c inst = newInstance(def.Id, o.Id);
        Workflow_Action__c a = newAction(inst.Id, 'send_email', 'Reject task',
            UserInfo.getUserId(), null);

        Test.startTest();
        PulseGlobalActionHubController.ResolveResult res =
            PulseGlobalActionHubController.rejectAction(a.Id, 'not now');
        Test.stopTest();

        System.assertEquals(true, res.success);
        System.assertEquals('Rejected', res.resultStatus);
        Workflow_Action__c reloaded = [
            SELECT Status__c FROM Workflow_Action__c WHERE Id = :a.Id
        ];
        System.assertEquals('Rejected', reloaded.Status__c);
    }

    // ─── 9. listColumnConfigs ───────────────────────────────────────

    @IsTest
    static void listColumnConfigsReturnsDeployedRecords() {
        Test.startTest();
        List<PulseGlobalActionHubController.ColumnConfigView> configs =
            PulseGlobalActionHubController.listColumnConfigs();
        Test.stopTest();

        System.assertNotEquals(null, configs);
    }

    // ─── 10. upsertColumnConfig enqueues deploy ─────────────────────

    @IsTest
    static void upsertColumnConfigEnqueuesDeployment() {
        PulseGlobalActionHubController.ColumnConfigInput input =
            new PulseGlobalActionHubController.ColumnConfigInput();
        input.configKey = 'Test_Cfg';
        input.targetObject = 'Account';
        input.columnsJson = '[{"field":"Name","label":"Name"}]';
        input.active = true;
        input.masterLabel = 'Test Cfg';

        Test.startTest();
        PulseGlobalActionHubController.UpsertConfigResult res =
            PulseGlobalActionHubController.upsertColumnConfig(input);
        Test.stopTest();

        System.assertNotEquals(null, res);
    }

    // ─── 11. Invalid actionId handled ───────────────────────────────

    @IsTest
    static void approveActionWithNullIdFails() {
        Test.startTest();
        PulseGlobalActionHubController.ResolveResult res =
            PulseGlobalActionHubController.approveAction(null, null, null);
        Test.stopTest();
        System.assertEquals(false, res.success);
    }

    // ─── Helpers ────────────────────────────────────────────────────

    private class StubTool implements PulseTool {
        public String getToolKey() { return 'stub'; }
        public String getDescription() { return 'Stub'; }
        public Map<String, Object> getInputSchema() {
            return new Map<String, Object>{ 'type' => 'object' };
        }
        public String getDefaultHitlPolicy() { return 'Approval_Required'; }
        public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
            return PulseToolModels.ok('{"status":"ok"}');
        }
    }
}

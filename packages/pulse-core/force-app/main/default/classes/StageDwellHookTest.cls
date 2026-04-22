@IsTest
private class StageDwellHookTest {

    // ─── Single transition creates TO row + closes FROM row ─────────

    @IsTest
    static void singleTransitionCreatesDwellRows() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        // Seed an open FROM dwell row (as if the instance was already in 'intake')
        Stage_Dwell__c seed = new Stage_Dwell__c(
            Workflow_Instance__c = inst.Id,
            Workflow_Key__c = 'test_wf',
            Subject_Kind__c = 'Account',
            State_Key__c = 'intake',
            State_Label__c = 'Intake',
            State_Type__c = 'form',
            Entered_At__c = Datetime.now().addHours(-2)
        );
        insert seed;

        StageDwellHook.rowsCreated = 0;

        Test.startTest();
        WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ new WorkflowAdvanceRequest(inst.Id, 'submit') }
        );
        Test.stopTest();

        // The hook should have created 1 new TO row
        System.assertEquals(1, StageDwellHook.rowsCreated, 'Should create one TO-state dwell row');

        // FROM row should be closed
        Stage_Dwell__c closed = [
            SELECT Exited_At__c, Duration_Seconds__c, Next_State_Key__c, Signal__c, Actor_Type__c
            FROM Stage_Dwell__c WHERE Id = :seed.Id
        ];
        System.assertNotEquals(null, closed.Exited_At__c, 'FROM dwell should have Exited_At set');
        System.assert(closed.Duration_Seconds__c > 0, 'Duration should be positive');
        System.assertEquals('review', closed.Next_State_Key__c);
        System.assertEquals('submit', closed.Signal__c);
        System.assertEquals('Human', closed.Actor_Type__c);

        // TO row should be open
        List<Stage_Dwell__c> toRows = [
            SELECT State_Key__c, Entered_At__c, Exited_At__c, State_Label__c, State_Type__c,
                   Workflow_Key__c, Subject_Kind__c
            FROM Stage_Dwell__c
            WHERE Workflow_Instance__c = :inst.Id AND State_Key__c = 'review'
        ];
        System.assertEquals(1, toRows.size(), 'Should have one TO-state dwell row');
        System.assertNotEquals(null, toRows[0].Entered_At__c);
        System.assertEquals(null, toRows[0].Exited_At__c, 'TO row should still be open');
        System.assertEquals('Review', toRows[0].State_Label__c);
        System.assertEquals('approval', toRows[0].State_Type__c);
        System.assertEquals('test_wf', toRows[0].Workflow_Key__c);
        System.assertEquals('Account', toRows[0].Subject_Kind__c);
    }

    // ─── Batch of 5 instances transitions correctly ─────────────────

    @IsTest
    static void batchTransitionProducesPerInstanceRows() {
        Workflow_Definition__c def = insertDefinition();
        List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
        for (Integer i = 0; i < 5; i++) {
            instances.add(new Workflow_Instance__c(
                Workflow_Definition__c = def.Id,
                Current_State__c = 'intake',
                Status__c = 'Active',
                Pinned_Version__c = 1,
                Started_Date__c = Datetime.now()
            ));
        }
        insert instances;

        // Seed open FROM rows
        List<Stage_Dwell__c> seeds = new List<Stage_Dwell__c>();
        for (Workflow_Instance__c inst : instances) {
            seeds.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                State_Key__c = 'intake',
                State_Label__c = 'Intake',
                State_Type__c = 'form',
                Entered_At__c = Datetime.now().addHours(-1)
            ));
        }
        insert seeds;

        StageDwellHook.rowsCreated = 0;

        List<WorkflowAdvanceRequest> requests = new List<WorkflowAdvanceRequest>();
        for (Workflow_Instance__c inst : instances) {
            requests.add(new WorkflowAdvanceRequest(inst.Id, 'submit'));
        }

        Test.startTest();
        WorkflowRuntime.advance(requests);
        Test.stopTest();

        System.assertEquals(5, StageDwellHook.rowsCreated, 'Should create 5 TO-state dwell rows');

        // All FROM rows should be closed
        List<Stage_Dwell__c> closedRows = [
            SELECT Id FROM Stage_Dwell__c
            WHERE Workflow_Instance__c IN :instances AND State_Key__c = 'intake' AND Exited_At__c != NULL
        ];
        System.assertEquals(5, closedRows.size(), 'All FROM rows should be closed');

        // All TO rows should be open
        List<Stage_Dwell__c> toRows = [
            SELECT Id FROM Stage_Dwell__c
            WHERE Workflow_Instance__c IN :instances AND State_Key__c = 'review' AND Exited_At__c = NULL
        ];
        System.assertEquals(5, toRows.size(), 'All TO rows should be open');
    }

    // ─── Terminal transition creates terminal TO row ─────────────────

    @IsTest
    static void terminalTransitionCreatesTerminalRow() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review');

        Stage_Dwell__c seed = new Stage_Dwell__c(
            Workflow_Instance__c = inst.Id,
            Workflow_Key__c = 'test_wf',
            State_Key__c = 'review',
            State_Label__c = 'Review',
            State_Type__c = 'approval',
            Entered_At__c = Datetime.now().addMinutes(-30)
        );
        insert seed;

        StageDwellHook.rowsCreated = 0;

        Test.startTest();
        WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ new WorkflowAdvanceRequest(inst.Id, 'approve') }
        );
        Test.stopTest();

        System.assertEquals(1, StageDwellHook.rowsCreated);

        // FROM row closed
        Stage_Dwell__c closed = [
            SELECT Exited_At__c, Next_State_Key__c FROM Stage_Dwell__c WHERE Id = :seed.Id
        ];
        System.assertNotEquals(null, closed.Exited_At__c);
        System.assertEquals('complete', closed.Next_State_Key__c);

        // Terminal TO row created with Exited_At = null
        List<Stage_Dwell__c> termRows = [
            SELECT State_Key__c, State_Type__c, Exited_At__c
            FROM Stage_Dwell__c
            WHERE Workflow_Instance__c = :inst.Id AND State_Key__c = 'complete'
        ];
        System.assertEquals(1, termRows.size());
        System.assertEquals('terminal', termRows[0].State_Type__c);
        System.assertEquals(null, termRows[0].Exited_At__c, 'Terminal TO row should have null Exited_At');
    }

    // ─── First-ever transition (no prior FROM row) only creates TO ──

    @IsTest
    static void firstTransitionWithoutPriorDwellOnlyCreatesToRow() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        // No seed dwell row — simulates first transition on legacy data
        StageDwellHook.rowsCreated = 0;

        Test.startTest();
        WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ new WorkflowAdvanceRequest(inst.Id, 'submit') }
        );
        Test.stopTest();

        System.assertEquals(1, StageDwellHook.rowsCreated, 'Should create only the TO row');

        // Only the TO row exists
        List<Stage_Dwell__c> allDwells = [
            SELECT State_Key__c, Exited_At__c FROM Stage_Dwell__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals(1, allDwells.size());
        System.assertEquals('review', allDwells[0].State_Key__c);
        System.assertEquals(null, allDwells[0].Exited_At__c);
    }

    // ─── Test data helpers ──────────────────────────────────────────

    private static Workflow_Definition__c insertDefinition() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Test Workflow',
            Workflow_Key__c = 'test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = buildContractJson()
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c insertInstance(Id defId, String currentState) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = currentState,
            Status__c = 'Active',
            Pinned_Version__c = 1,
            Started_Date__c = Datetime.now()
        );
        insert inst;
        return inst;
    }

    private static String buildContractJson() {
        return '{"schema":"pulse.workflow.v1","workflowKey":"test_wf","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"intake","label":"Intake","type":"form","fields":[],"transitions":[' +
            '{"signal":"submit","to":"review"},' +
            '{"signal":"cancel","to":"cancelled"}' +
            ']},' +
            '{"key":"review","label":"Review","type":"approval","fields":[],"transitions":[' +
            '{"signal":"approve","to":"complete"},' +
            '{"signal":"reject","to":"intake"}' +
            ']},' +
            '{"key":"complete","label":"Complete","type":"terminal","fields":[],"transitions":[]},' +
            '{"key":"cancelled","label":"Cancelled","type":"terminal","fields":[],"transitions":[]}' +
            ']}';
    }
}

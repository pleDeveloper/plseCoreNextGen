@IsTest
private class StageDwellPredictorTest {

    // ─── aggregateDwellStats computes correct median + p90 ──────────

    @IsTest
    static void aggregateStatsComputesPercentiles() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review');

        // Seed 20 completed dwell rows for 'intake' with known durations:
        // durations = 10,20,30,...,200 (ascending)
        List<Stage_Dwell__c> dwells = new List<Stage_Dwell__c>();
        for (Integer i = 1; i <= 20; i++) {
            Datetime entered = Datetime.now().addDays(-10).addMinutes(i);
            Integer dur = i * 10;
            dwells.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'intake',
                State_Label__c = 'Intake',
                State_Type__c = 'form',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(dur),
                Duration_Seconds__c = dur
            ));
        }
        // Seed 10 completed rows for 'review'
        for (Integer i = 1; i <= 10; i++) {
            Datetime entered = Datetime.now().addDays(-5).addMinutes(i);
            Integer dur = i * 100;
            dwells.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'review',
                State_Label__c = 'Review',
                State_Type__c = 'approval',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(dur),
                Duration_Seconds__c = dur
            ));
        }
        insert dwells;

        Test.startTest();
        List<StageDwellPredictor.StageStats> stats =
            StageDwellPredictor.aggregateDwellStats('test_wf', 90);
        Test.stopTest();

        System.assertEquals(2, stats.size(), 'Should have stats for 2 states');

        // Find intake stats
        StageDwellPredictor.StageStats intakeStats = null;
        StageDwellPredictor.StageStats reviewStats = null;
        for (StageDwellPredictor.StageStats ss : stats) {
            if (ss.stateKey == 'intake') intakeStats = ss;
            if (ss.stateKey == 'review') reviewStats = ss;
        }

        System.assertNotEquals(null, intakeStats, 'Should have intake stats');
        System.assertEquals(20, intakeStats.sampleCount);
        System.assertEquals(10, intakeStats.minSeconds);
        System.assertEquals(200, intakeStats.maxSeconds);
        // Sorted durations: 10,20,...,200 (20 items)
        // median = index floor(20*0.5) = index 10 → value 110
        System.assertEquals(110, intakeStats.medianSeconds);
        // p90 = index floor(20*0.9) = index 18 → value 190
        System.assertEquals(190, intakeStats.p90Seconds);

        System.assertNotEquals(null, reviewStats, 'Should have review stats');
        System.assertEquals(10, reviewStats.sampleCount);
    }

    // ─── aggregateDwellStats filters by workflowKey + lookback ──────

    @IsTest
    static void aggregateStatsFiltersCorrectly() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        List<Stage_Dwell__c> dwells = new List<Stage_Dwell__c>();
        // 5 rows within 30-day lookback
        for (Integer i = 1; i <= 5; i++) {
            Datetime entered = Datetime.now().addDays(-10);
            dwells.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'intake',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(100),
                Duration_Seconds__c = 100
            ));
        }
        // 3 rows outside 30-day lookback (60 days ago)
        for (Integer i = 1; i <= 3; i++) {
            Datetime entered = Datetime.now().addDays(-60);
            dwells.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'intake',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(100),
                Duration_Seconds__c = 100
            ));
        }
        // 2 rows for a different workflow key
        for (Integer i = 1; i <= 2; i++) {
            Datetime entered = Datetime.now().addDays(-5);
            dwells.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'other_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'intake',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(200),
                Duration_Seconds__c = 200
            ));
        }
        insert dwells;

        Test.startTest();
        List<StageDwellPredictor.StageStats> stats =
            StageDwellPredictor.aggregateDwellStats('test_wf', 30);
        Test.stopTest();

        System.assertEquals(1, stats.size());
        System.assertEquals(5, stats[0].sampleCount, 'Only 5 rows within 30-day lookback for test_wf');
    }

    // ─── predictExitFor returns correct date arithmetic ─────────────

    @IsTest
    static void predictExitForComputesCorrectly() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review');

        // Seed historical completed dwells for review state
        List<Stage_Dwell__c> history = new List<Stage_Dwell__c>();
        for (Integer i = 1; i <= 10; i++) {
            Datetime entered = Datetime.now().addDays(-20).addMinutes(i);
            Integer dur = i * 60;  // 60, 120, ..., 600 seconds
            history.add(new Stage_Dwell__c(
                Workflow_Instance__c = inst.Id,
                Workflow_Key__c = 'test_wf',
                Subject_Kind__c = 'Account',
                State_Key__c = 'review',
                Entered_At__c = entered,
                Exited_At__c = entered.addSeconds(dur),
                Duration_Seconds__c = dur
            ));
        }
        // Seed an open dwell row for the current instance in 'review'
        Datetime enteredAt = Datetime.now().addMinutes(-5);
        history.add(new Stage_Dwell__c(
            Workflow_Instance__c = inst.Id,
            Workflow_Key__c = 'test_wf',
            Subject_Kind__c = 'Account',
            State_Key__c = 'review',
            Entered_At__c = enteredAt,
            Exited_At__c = null
        ));
        insert history;

        Test.startTest();
        StageDwellPredictor.ExitPrediction pred =
            StageDwellPredictor.predictExitFor(inst.Id);
        Test.stopTest();

        System.assertEquals('review', pred.currentStateKey);
        System.assertEquals(10, pred.sampleCount);
        System.assertNotEquals(null, pred.expectedExitDate, 'Should have an expected exit date');
        System.assertNotEquals(null, pred.p90ExitDate, 'Should have a p90 exit date');
        System.assertNotEquals(null, pred.isOverdue, 'isOverdue should be set');

        // Sorted durations: 60,120,180,240,300,360,420,480,540,600
        // median = index 5 → 360
        // p90 = index 9 → 600
        System.assertEquals(360, pred.medianSecondsForState);
        System.assertEquals(600, pred.p90SecondsForState);
    }

    // ─── predictExitFor returns sampleCount=0 when no history ───────

    @IsTest
    static void predictExitForReturnsZeroWhenNoHistory() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        // Only an open dwell row, no completed history
        insert new Stage_Dwell__c(
            Workflow_Instance__c = inst.Id,
            Workflow_Key__c = 'test_wf',
            Subject_Kind__c = 'Account',
            State_Key__c = 'intake',
            Entered_At__c = Datetime.now()
        );

        Test.startTest();
        StageDwellPredictor.ExitPrediction pred =
            StageDwellPredictor.predictExitFor(inst.Id);
        Test.stopTest();

        System.assertEquals(0, pred.sampleCount);
        System.assertEquals(null, pred.expectedExitDate);
        System.assertEquals(null, pred.p90ExitDate);
    }

    // ─── percentile helper unit test ────────────────────────────────

    @IsTest
    static void percentileHelperReturnsCorrectValues() {
        List<Integer> vals = new List<Integer>{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        System.assertEquals(6, StageDwellPredictor.percentile(vals, 50));
        System.assertEquals(10, StageDwellPredictor.percentile(vals, 90));
        System.assertEquals(0, StageDwellPredictor.percentile(new List<Integer>(), 50));
    }

    // ─── Test data helpers ──────────────────────────────────────────

    private static Workflow_Definition__c insertDefinition() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Test Workflow',
            Workflow_Key__c = 'test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1","workflowKey":"test_wf","version":1,' +
                '"subjectKinds":["Account"],"states":[' +
                '{"key":"intake","label":"Intake","type":"form","fields":[],"transitions":[' +
                '{"signal":"submit","to":"review"}]},' +
                '{"key":"review","label":"Review","type":"approval","fields":[],"transitions":[' +
                '{"signal":"approve","to":"complete"}]},' +
                '{"key":"complete","label":"Complete","type":"terminal","fields":[],"transitions":[]}]}'
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
}

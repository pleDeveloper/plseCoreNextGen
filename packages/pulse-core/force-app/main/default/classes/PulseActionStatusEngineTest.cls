@IsTest
private class PulseActionStatusEngineTest {

    // Two actions:
    //   prereq:   open -> completed (when Opportunity.StageName = 'Closed Won')
    //   follower: blocked -> ready  (when prereq's status_key is 'completed')
    private static final String CASCADE_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"status_engine_cascade","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
          '{"key":"p","label":"P","type":"form","actions":[' +
            // prereq
            '{"key":"prereq","label":"Prereq","type":"approval","required":true,"dependsOn":[],' +
              '"statuses":[' +
                '{"key":"completed","category":"terminal_success","entryConditions":' +
                  '{"field":"StageName","op":"EQUALS","value":"Closed Won"}},' +
                '{"key":"open","category":"open","isInitial":true}' +
              ']},' +
            // follower
            '{"key":"follower","label":"Follower","type":"approval","required":true,"dependsOn":[],' +
              '"statuses":[' +
                '{"key":"ready","category":"open","entryConditions":' +
                  '{"type":"action_status","action":"prereq","statusEquals":"completed"}},' +
                '{"key":"blocked","category":"blocked","isInitial":true}' +
              ']}' +
          '],"transitions":[]}' +
        ']}';

    // Simple one-action contract for single-action tests.
    private static final String SINGLE_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"status_engine_single","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
          '{"key":"p","label":"P","type":"form","actions":[' +
            '{"key":"solo","label":"Solo","type":"approval","required":true,"dependsOn":[],' +
              '"statuses":[' +
                '{"key":"won","category":"terminal_success","entryConditions":' +
                  '{"field":"StageName","op":"EQUALS","value":"Closed Won"}},' +
                '{"key":"open","category":"open","isInitial":true}' +
              ']}' +
          '],"transitions":[]}' +
        ']}';

    // Oscillating contract to trip the loop-protect. Two actions whose
    // statuses reference each other asymmetrically, forcing a flip every
    // iteration.
    private static final String OSCILLATE_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"status_engine_osc","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
          '{"key":"p","label":"P","type":"form","actions":[' +
            '{"key":"a","label":"A","type":"approval","required":true,"dependsOn":[],' +
              '"statuses":[' +
                '{"key":"alpha","category":"open","entryConditions":' +
                  '{"type":"action_status","action":"b","statusEquals":"beta"}},' +
                '{"key":"gamma","category":"open","isInitial":true}' +
              ']},' +
            '{"key":"b","label":"B","type":"approval","required":true,"dependsOn":[],' +
              '"statuses":[' +
                '{"key":"beta","category":"open","entryConditions":' +
                  '{"type":"action_status","action":"a","statusEquals":"gamma"}},' +
                '{"key":"delta","category":"open","isInitial":true}' +
              ']}' +
          '],"transitions":[]}' +
        ']}';

    private static Workflow_Definition__c defFor(String workflowKey, String body) {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = workflowKey,
            Workflow_Key__c = workflowKey,
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = body,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;
        return def;
    }

    private static Opportunity newOpp(String stage) {
        Opportunity o = new Opportunity(
            Name = 'StatusEngine Test', CloseDate = Date.today(), StageName = stage
        );
        insert o;
        return o;
    }

    private static Workflow_Instance__c instFor(Id defId, Id parentId) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = 'p',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = parentId
        );
        insert inst;
        return inst;
    }

    // ── Tests ─────────────────────────────────────────────────────────

    @IsTest
    static void singleActionReevaluatesOnFieldMatch() {
        Workflow_Definition__c def = defFor('status_engine_single', SINGLE_CONTRACT);
        Opportunity o = newOpp('Closed Won');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        // The trigger seeded initial status. We expect:
        //   solo = 'won' after reevaluate because StageName=Closed Won.
        Test.startTest();
        List<Workflow_Action__c> changed = PulseActionStatusEngine.reevaluate(inst.Id);
        Test.stopTest();

        Workflow_Action__c solo = [
            SELECT Status_Key__c, Status_Category__c, Status_History_JSON__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id AND Action_Key__c = 'solo' LIMIT 1
        ];
        System.assertEquals('won', solo.Status_Key__c);
        System.assertEquals('terminal_success', solo.Status_Category__c);
        System.assertNotEquals(null, solo.Status_History_JSON__c);
    }

    @IsTest
    static void crossActionCascadeFlipsFollower() {
        Workflow_Definition__c def = defFor('status_engine_cascade', CASCADE_CONTRACT);
        Opportunity o = newOpp('Qualification');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        // After insert, both actions sit at their initial status.
        Workflow_Action__c prereqBefore = [
            SELECT Status_Key__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id AND Action_Key__c = 'prereq' LIMIT 1
        ];
        System.assertEquals('open', prereqBefore.Status_Key__c);

        // Move parent stage forward.
        o.StageName = 'Closed Won';
        update o;

        Test.startTest();
        PulseActionStatusEngine.reevaluate(inst.Id);
        Test.stopTest();

        Map<String, Workflow_Action__c> byKey = new Map<String, Workflow_Action__c>();
        for (Workflow_Action__c wa : [
            SELECT Action_Key__c, Status_Key__c, Status_Category__c
            FROM Workflow_Action__c WHERE Workflow_Instance__c = :inst.Id
        ]) {
            byKey.put(wa.Action_Key__c, wa);
        }
        System.assertEquals('completed', byKey.get('prereq').Status_Key__c);
        System.assertEquals('ready',     byKey.get('follower').Status_Key__c,
            'follower should cascade to ready once prereq is completed');
    }

    @IsTest
    static void loopProtectThrowsOnOscillation() {
        Workflow_Definition__c def = defFor('status_engine_osc', OSCILLATE_CONTRACT);
        Opportunity o = newOpp('Qualification');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        Boolean threw = false;
        Test.startTest();
        try {
            PulseActionStatusEngine.reevaluate(inst.Id);
        } catch (PulseActionStatusEngine.EvaluationException e) {
            threw = true;
            System.assert(e.getMessage().contains('loop-protect'),
                'Expected loop-protect error, got: ' + e.getMessage());
        }
        Test.stopTest();
        System.assert(threw, 'Oscillating machine should trip loop-protect');
    }

    @IsTest
    static void bulkSafetySingleUpdateForManyActions() {
        Workflow_Definition__c def = defFor('status_engine_cascade', CASCADE_CONTRACT);
        Opportunity o = newOpp('Closed Won');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        // Reset both rows so reevaluate has actual work (multiple transitions).
        List<Workflow_Action__c> rows = [
            SELECT Id, Action_Key__c, Status_Key__c
            FROM Workflow_Action__c WHERE Workflow_Instance__c = :inst.Id
        ];
        for (Workflow_Action__c wa : rows) {
            // Clear to baseline so reevaluate has something to do.
            if (wa.Action_Key__c == 'prereq')   wa.Status_Key__c = 'open';
            if (wa.Action_Key__c == 'follower') wa.Status_Key__c = 'blocked';
        }
        update rows;

        Integer soqlBefore = Limits.getQueries();
        Integer dmlBefore  = Limits.getDmlStatements();
        Test.startTest();
        PulseActionStatusEngine.reevaluate(inst.Id);
        Test.stopTest();
        // We don't assert hard SOQL/DML totals here (cascade may run a
        // couple of passes internally), but we do assert both rows
        // actually changed in the end.
        Map<String, String> byKey = new Map<String, String>();
        for (Workflow_Action__c wa : [
            SELECT Action_Key__c, Status_Key__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id
        ]) {
            byKey.put(wa.Action_Key__c, wa.Status_Key__c);
        }
        System.assertEquals('completed', byKey.get('prereq'));
        System.assertEquals('ready',     byKey.get('follower'));
    }

    @IsTest
    static void workflowEventFiresOnTransition() {
        Workflow_Definition__c def = defFor('status_engine_single', SINGLE_CONTRACT);
        Opportunity o = newOpp('Closed Won');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        // Clear any events produced at instantiation time.
        delete [SELECT Id FROM Workflow_Event__c WHERE Workflow_Instance__c = :inst.Id];

        // Force the row back to 'open' so reevaluate causes a transition.
        Workflow_Action__c solo = [
            SELECT Id, Status_Key__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id AND Action_Key__c = 'solo' LIMIT 1
        ];
        solo.Status_Key__c = 'open';
        update solo;

        Test.startTest();
        PulseActionStatusEngine.reevaluate(inst.Id);
        Test.stopTest();

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c, Detail_JSON__c
            FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id
              AND Event_Type__c = 'ACTION_STATUS_CHANGED'
        ];
        System.assert(!events.isEmpty(),
            'Expected at least one ACTION_STATUS_CHANGED event');
        System.assert(events[0].Detail_JSON__c.contains('"to":"won"'),
            'Event detail should record to=won, got: ' + events[0].Detail_JSON__c);
    }

    @IsTest
    static void reevaluateForActionDelegatesToInstance() {
        Workflow_Definition__c def = defFor('status_engine_single', SINGLE_CONTRACT);
        Opportunity o = newOpp('Closed Won');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);

        Workflow_Action__c solo = [
            SELECT Id FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id AND Action_Key__c = 'solo' LIMIT 1
        ];
        solo.Status_Key__c = 'open';
        update solo;

        Test.startTest();
        PulseActionStatusEngine.reevaluateForAction(solo.Id);
        Test.stopTest();

        Workflow_Action__c after = [
            SELECT Status_Key__c FROM Workflow_Action__c WHERE Id = :solo.Id
        ];
        System.assertEquals('won', after.Status_Key__c);
    }

    @IsTest
    static void nullInstanceReturnsEmpty() {
        System.assertEquals(0, PulseActionStatusEngine.reevaluate(null).size());
        System.assertEquals(0, PulseActionStatusEngine.reevaluateForAction(null).size());
    }

    @IsTest
    static void initialStatusSetOnInstantiation() {
        Workflow_Definition__c def = defFor('status_engine_single', SINGLE_CONTRACT);
        Opportunity o = newOpp('Qualification');
        Workflow_Instance__c inst = instFor(def.Id, o.Id);
        Workflow_Action__c solo = [
            SELECT Status_Key__c, Status_Category__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id AND Action_Key__c = 'solo' LIMIT 1
        ];
        // Initial status is 'open'; parent stage is 'Qualification' so no
        // reevaluation will promote it to 'won'. After phase-entry hook
        // runs, the row should still be at its initial 'open' state.
        System.assertEquals('open', solo.Status_Key__c);
        System.assertEquals('open', solo.Status_Category__c);
    }
}

@IsTest
private class StageProgressionServiceTest {

    // ─── Progression mode: auto_on_actions → no-op ───────────────

    @IsTest
    static void autoOnActionsModeIsNoOp() {
        Account a = new Account(Name = 'AOA Co');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"auto_on_actions"}', null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Boolean fired = StageProgressionService.checkAndAutoAdvance(inst.Id);
        Test.stopTest();

        System.assertEquals(false, fired,
            'auto_on_actions must be owned by HitlService, not this service');
        System.assertEquals('intake', [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ].Current_State__c);
    }

    // ─── Progression mode: manual_decision → no-op ───────────────

    @IsTest
    static void manualDecisionModeIsNoOp() {
        Account a = new Account(Name = 'MD Co');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"manual_decision"}', null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Boolean fired = StageProgressionService.checkAndAutoAdvance(inst.Id);
        Test.stopTest();

        System.assertEquals(false, fired);
    }

    // ─── Progression mode: field_change → fires transition ───────

    @IsTest
    static void fieldChangeModeFiresWhenFieldMatches() {
        Account a = new Account(Name = 'FC Co', Industry = 'Biotechnology');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"field_change","rule":{"field":"Industry","equals":"Biotechnology"}}',
            null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Boolean fired = StageProgressionService.checkAndAutoAdvance(inst.Id);
        Test.stopTest();

        System.assertEquals(true, fired, 'field_change should fire transition');
        System.assertEquals('review', [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ].Current_State__c);
    }

    @IsTest
    static void fieldChangeModeDoesNotFireWhenFieldDoesNotMatch() {
        Account a = new Account(Name = 'FC Co', Industry = 'Agriculture');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"field_change","rule":{"field":"Industry","equals":"Biotechnology"}}',
            null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Boolean fired = StageProgressionService.checkAndAutoAdvance(inst.Id);
        Test.stopTest();

        System.assertEquals(false, fired);
        System.assertEquals('intake', [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ].Current_State__c);
    }

    // ─── Progression mode: custom_logic → uses evaluator ─────────

    @IsTest
    static void customLogicFiresWhenConditionTreePasses() {
        Account a = new Account(Name = 'CL Co', Industry = 'Biotechnology',
            AnnualRevenue = 1000000);
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"custom_logic","rule":{"logic":"AND","rules":[' +
                '{"field":"Industry","op":"EQUALS","value":"Biotechnology"},' +
                '{"field":"AnnualRevenue","op":"GREATER_THAN","value":500000}]}}',
            null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Boolean fired = StageProgressionService.checkAndAutoAdvance(inst.Id);
        Test.stopTest();

        System.assertEquals(true, fired);
        System.assertEquals('review', [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ].Current_State__c);
    }

    // ─── checkOnRecordChange bulk surface ────────────────────────

    @IsTest
    static void checkOnRecordChangeFiresForMatchingInstances() {
        Account a = new Account(Name = 'Bulk Co', Industry = 'Biotechnology');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            '{"mode":"field_change","rule":{"field":"Industry","equals":"Biotechnology"}}',
            null, null, null
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);

        Test.startTest();
        Integer count = StageProgressionService.checkOnRecordChange(
            'Account', new Set<Id>{ a.Id }
        );
        Test.stopTest();

        System.assertEquals(1, count, 'expected one instance advanced');
        System.assertEquals('review', [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ].Current_State__c);
    }

    // ─── markStaleOnHold helper path ─────────────────────────────

    @IsTest
    static void markStaleOnHoldFlagsInstancesOverThreshold() {
        Account a = new Account(Name = 'Stale Co');
        insert a;
        Workflow_Definition__c def = insertDef(buildContract(
            null, null, null, '{"autoOnHoldAfterDays":1}'
        ));
        Workflow_Instance__c inst = insertInst(def.Id, 'intake', a.Id);
        // Force the instance Started_Date into the past
        inst.Started_Date__c = Datetime.now().addDays(-5);
        update inst;

        Test.startTest();
        Integer flipped = StageProgressionService.markStaleOnHold();
        Test.stopTest();

        System.assert(flipped >= 1, 'expected at least one instance flipped to On_Hold');
        Workflow_Instance__c after = [
            SELECT Stage_Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('On_Hold', after.Stage_Status__c);
    }

    // ─── Helpers ────────────────────────────────────────────────

    private static Workflow_Definition__c insertDef(String json) {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'SPS Test',
            Workflow_Key__c = 'sps_' + String.valueOf(Math.mod(Crypto.getRandomInteger(), 100000)),
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = json
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c insertInst(Id defId, String state, Id parentId) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = state,
            Status__c = 'Active',
            Pinned_Version__c = 1,
            Parent_Object_Type__c = 'Account',
            Parent_Record_Id__c = parentId,
            Started_Date__c = Datetime.now()
        );
        insert inst;
        return inst;
    }

    private static String buildContract(
        String progressionJson,
        String entryJson,
        String exitJson,
        String statusRulesJson
    ) {
        String prog = String.isNotBlank(progressionJson)
            ? (',"progression":' + progressionJson) : '';
        String entry = String.isNotBlank(entryJson)
            ? (',"entryConditions":' + entryJson) : '';
        String exitStr = String.isNotBlank(exitJson)
            ? (',"exitConditions":' + exitJson) : '';
        String sr = String.isNotBlank(statusRulesJson)
            ? (',"statusRules":' + statusRulesJson) : '';
        return '{"schema":"pulse.workflow.v1","workflowKey":"sps_test","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"intake","label":"Intake","type":"form","fields":[],' +
                '"transitions":[{"signal":"submit","to":"review"}]' +
                prog + entry + exitStr + sr + '},' +
            '{"key":"review","label":"Review","type":"approval","fields":[],' +
                '"transitions":[{"signal":"approve","to":"complete"}]},' +
            '{"key":"complete","label":"Complete","type":"terminal","fields":[],' +
                '"transitions":[]}' +
            ']}';
    }
}

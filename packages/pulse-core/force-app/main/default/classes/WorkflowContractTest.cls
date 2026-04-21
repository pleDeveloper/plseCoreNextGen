@IsTest
private class WorkflowContractTest {

    // ─── Parse ───────────────────────────────────────────────────

    @IsTest
    static void parseValidContract() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());

        System.assertEquals('pulse.workflow.v1', wf.schemaVersion);
        System.assertEquals('test_workflow', wf.workflowKey);
        System.assertEquals(1, wf.version);
        System.assertEquals(1, wf.subjectKinds.size());
        System.assertEquals('Account', wf.subjectKinds[0]);
        System.assertEquals(4, wf.states.size());
    }

    @IsTest
    static void parseBlankJsonThrows() {
        try {
            WorkflowContract.parse('');
            System.assert(false, 'Expected ContractParseException');
        } catch (WorkflowContract.ContractParseException e) {
            System.assert(e.getMessage().contains('blank'));
        }
    }

    @IsTest
    static void parseMalformedJsonThrows() {
        try {
            WorkflowContract.parse('{not valid}');
            System.assert(false, 'Expected ContractParseException');
        } catch (WorkflowContract.ContractParseException e) {
            System.assert(e.getMessage().contains('Invalid JSON'));
        }
    }

    // ─── Validate ────────────────────────────────────────────────

    @IsTest
    static void validateValidContract() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());
        List<String> errors = WorkflowContract.validate(wf);
        System.assertEquals(0, errors.size(), 'Valid contract should have no errors: ' + errors);
    }

    @IsTest
    static void validateUnsupportedSchema() {
        WorkflowContract.Workflow wf = new WorkflowContract.Workflow();
        wf.schemaVersion = 'bad.schema';
        wf.workflowKey = 'test';
        wf.version = 1;
        wf.subjectKinds = new List<String>{ 'Account' };
        WorkflowContract.State s = new WorkflowContract.State();
        s.key = 's1';
        s.label = 'S1';
        wf.states = new List<WorkflowContract.State>{ s };

        List<String> errors = WorkflowContract.validate(wf);
        System.assert(hasError(errors, 'Unsupported schema'), errors);
    }

    @IsTest
    static void validateMissingStates() {
        WorkflowContract.Workflow wf = new WorkflowContract.Workflow();
        wf.schemaVersion = WorkflowContract.SCHEMA_VERSION;
        wf.workflowKey = 'test';
        wf.version = 1;
        wf.subjectKinds = new List<String>{ 'Account' };
        wf.states = new List<WorkflowContract.State>();

        List<String> errors = WorkflowContract.validate(wf);
        System.assert(hasError(errors, 'at least one'), errors);
    }

    @IsTest
    static void validateDuplicateFieldKey() {
        String json =
            '{"schema":"pulse.workflow.v1","workflowKey":"t","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"s1","label":"S1","type":"form","fields":[' +
            '{"key":"dup","label":"D1","type":"Text","required":false},' +
            '{"key":"dup","label":"D2","type":"Text","required":false}' +
            '],"transitions":[]}]}';
        WorkflowContract.Workflow wf = WorkflowContract.parse(json);
        List<String> errors = WorkflowContract.validate(wf);
        System.assert(hasError(errors, 'Duplicate field key'), errors);
    }

    @IsTest
    static void validateInvalidTransitionTarget() {
        String json =
            '{"schema":"pulse.workflow.v1","workflowKey":"t","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"s1","label":"S1","type":"form","fields":[],' +
            '"transitions":[{"signal":"go","to":"nonexistent"}]}]}';
        WorkflowContract.Workflow wf = WorkflowContract.parse(json);
        List<String> errors = WorkflowContract.validate(wf);
        System.assert(hasError(errors, 'unknown target'), errors);
    }

    // ─── Lookup helpers ──────────────────────────────────────────

    @IsTest
    static void getStateReturnsMatchOrNull() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());

        System.assertNotEquals(null, wf.getState('intake'));
        System.assertEquals('form', wf.getState('intake').stateType);
        System.assertEquals(null, wf.getState('nonexistent'));
    }

    @IsTest
    static void getTransitionReturnsMatchOrNull() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());
        WorkflowContract.State intake = wf.getState('intake');

        WorkflowContract.Transition submit = intake.getTransition('submit');
        System.assertNotEquals(null, submit);
        System.assertEquals('review', submit.target);
        System.assertEquals(null, intake.getTransition('nonexistent'));
    }

    @IsTest
    static void fieldDefParsesCorrectly() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());
        WorkflowContract.State intake = wf.getState('intake');

        System.assertEquals(1, intake.fields.size());
        WorkflowContract.FieldDef f = intake.fields[0];
        System.assertEquals('patient_name', f.key);
        System.assertEquals('Patient Name', f.label);
        System.assertEquals('Text', f.fieldType);
        System.assertEquals(true, f.required);
    }

    @IsTest
    static void getCurrentStateUsesInstanceField() {
        WorkflowContract.Workflow wf = WorkflowContract.parse(buildContractJson());
        Workflow_Instance__c inst = new Workflow_Instance__c(Current_State__c = 'review');

        WorkflowContract.State s = WorkflowContract.getCurrentState(wf, inst);
        System.assertNotEquals(null, s);
        System.assertEquals('review', s.key);
    }

    // ─── Helpers ─────────────────────────────────────────────────

    private static Boolean hasError(List<String> errors, String fragment) {
        for (String e : errors) {
            if (e.containsIgnoreCase(fragment)) {
                return true;
            }
        }
        return false;
    }

    private static String buildContractJson() {
        return '{"schema":"pulse.workflow.v1","workflowKey":"test_workflow","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"intake","label":"Intake","type":"form","fields":[' +
            '{"key":"patient_name","label":"Patient Name","type":"Text","required":true}' +
            '],"transitions":[' +
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

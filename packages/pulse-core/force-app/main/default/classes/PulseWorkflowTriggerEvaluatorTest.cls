@IsTest
private class PulseWorkflowTriggerEvaluatorTest {

    @IsTest
    static void nullOrEmptyJsonAlwaysMatches() {
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, null));
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, ''));
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, '{}'));
    }

    @IsTest
    static void singleRuleEqualsMatchesAndMisses() {
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        String json = '{"field":"StageName","op":"EQUALS","value":"Qualification"}';
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, json));

        String noMatch = '{"field":"StageName","op":"EQUALS","value":"Closed Won"}';
        System.assertEquals(false, PulseWorkflowTriggerEvaluator.matches(o, null, noMatch));
    }

    @IsTest
    static void andGroupRequiresAllRules() {
        Opportunity o = new Opportunity(
            Name = 'Big Deal', CloseDate = Date.today(), StageName = 'Qualification', Amount = 50000
        );
        String json =
            '{"logic":"AND","rules":[' +
              '{"field":"StageName","op":"EQUALS","value":"Qualification"},' +
              '{"field":"Amount","op":"GREATER_THAN","value":10000}' +
            ']}';
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, json));

        o.Amount = 5000;
        System.assertEquals(false, PulseWorkflowTriggerEvaluator.matches(o, null, json));
    }

    @IsTest
    static void orGroupRequiresAnyRule() {
        Opportunity o = new Opportunity(
            Name = 'Some Opp', CloseDate = Date.today(), StageName = 'Proposal/Price Quote'
        );
        String json =
            '{"logic":"OR","rules":[' +
              '{"field":"StageName","op":"EQUALS","value":"Qualification"},' +
              '{"field":"StageName","op":"EQUALS","value":"Proposal/Price Quote"}' +
            ']}';
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, json));
    }

    @IsTest
    static void nestedAndOrEvaluatesCorrectly() {
        Opportunity o = new Opportunity(
            Name = 'A', CloseDate = Date.today(), StageName = 'Qualification', Amount = 20000
        );
        String json =
            '{"logic":"AND","rules":[' +
              '{"field":"StageName","op":"EQUALS","value":"Qualification"},' +
              '{"logic":"OR","rules":[' +
                '{"field":"Amount","op":"GREATER_THAN","value":100000},' +
                '{"field":"Name","op":"STARTS_WITH","value":"A"}' +
              ']}' +
            ']}';
        System.assertEquals(true, PulseWorkflowTriggerEvaluator.matches(o, null, json));
    }

    @IsTest
    static void stringOpsMatchProperly() {
        Opportunity o = new Opportunity(
            Name = 'Midtown Tech Startup', CloseDate = Date.today(), StageName = 'Qualification'
        );
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Name","op":"CONTAINS","value":"Tech"}'));
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Name","op":"STARTS_WITH","value":"Midtown"}'));
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Name","op":"ENDS_WITH","value":"Startup"}'));
        System.assertEquals(false,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Name","op":"CONTAINS","value":"xyz"}'));
    }

    @IsTest
    static void isChangedUsesOldRecord() {
        Opportunity newO = new Opportunity(Id = null, Name = 'X', CloseDate = Date.today(), StageName = 'Negotiation/Review');
        Opportunity oldO = new Opportunity(Id = null, Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(newO, oldO,
                '{"field":"StageName","op":"IS_CHANGED"}'));

        System.assertEquals(false,
            PulseWorkflowTriggerEvaluator.matches(newO, newO,
                '{"field":"StageName","op":"IS_CHANGED"}'));
    }

    @IsTest
    static void changedToMatchesOnlyWhenNewValueMatches() {
        Opportunity newO = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Closed Won');
        Opportunity oldO = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Proposal/Price Quote');

        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(newO, oldO,
                '{"field":"StageName","op":"CHANGED_TO","value":"Closed Won"}'));

        System.assertEquals(false,
            PulseWorkflowTriggerEvaluator.matches(newO, oldO,
                '{"field":"StageName","op":"CHANGED_TO","value":"Negotiation/Review"}'));
    }

    @IsTest
    static void nullnessOpsWork() {
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Amount","op":"IS_NULL"}'));

        o.Amount = 100;
        System.assertEquals(true,
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"Amount","op":"IS_NOT_NULL"}'));
    }

    @IsTest
    static void invalidJsonThrowsEvaluationException() {
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'X');
        Boolean threw = false;
        try {
            PulseWorkflowTriggerEvaluator.matches(o, null, '{not json}');
        } catch (PulseWorkflowTriggerEvaluator.EvaluationException e) {
            threw = true;
        }
        System.assert(threw, 'Expected EvaluationException for invalid JSON');
    }

    @IsTest
    static void unsupportedOperatorThrows() {
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'X');
        Boolean threw = false;
        try {
            PulseWorkflowTriggerEvaluator.matches(o, null,
                '{"field":"StageName","op":"REGEX_MATCH","value":".*"}');
        } catch (PulseWorkflowTriggerEvaluator.EvaluationException e) {
            threw = true;
        }
        System.assert(threw, 'Expected EvaluationException for unknown operator');
    }
}

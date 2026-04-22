@IsTest
private class PulseActionStatusEvaluatorTest {

    /** Build a lightweight ActionDef+StatusDef list in memory. */
    private static WorkflowContract.ActionDef buildDef(
        String actionKey, List<Map<String, Object>> rawStatuses
    ) {
        // Ride the parser by embedding into a minimal contract JSON so we
        // exercise the same StatusDef mapping the runtime uses.
        Map<String, Object> state = new Map<String, Object>{
            'key'   => 'p',
            'label' => 'P',
            'type'  => 'form',
            'actions' => new List<Object>{ new Map<String, Object>{
                'key'      => actionKey,
                'label'    => actionKey,
                'type'     => 'approval',
                'statuses' => rawStatuses
            }}
        };
        Map<String, Object> wf = new Map<String, Object>{
            'schema'       => 'pulse.workflow.v1',
            'workflowKey'  => 'unit',
            'version'      => 1,
            'subjectKinds' => new List<Object>{ 'Opportunity' },
            'states'       => new List<Object>{ state }
        };
        WorkflowContract.Workflow parsed = WorkflowContract.parse(JSON.serialize(wf));
        return parsed.getState('p').getAction(actionKey);
    }

    private static Workflow_Action__c buildAction(String currentKey) {
        return new Workflow_Action__c(
            Action_Key__c = 'this_action',
            Phase_Key__c  = 'p',
            Status__c     = 'Pending',
            Status_Key__c = currentKey
        );
    }

    @IsTest
    static void emptyConditionsAlwaysMatchFirstStatus() {
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{ 'key' => 'open',      'category' => 'open' },
            new Map<String, Object>{ 'key' => 'completed', 'category' => 'terminal_success' }
        });
        Workflow_Action__c a = buildAction(null);
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qual');
        String out = PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>(), def, o
        );
        System.assertEquals('open', out, 'First status with {} conditions should match first');
    }

    @IsTest
    static void orderIsRespectedSecondWins() {
        // First requires StageName=Closed Won (won't match). Second is open.
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{
                'key'      => 'late_stage',
                'category' => 'open',
                'entryConditions' => new Map<String, Object>{
                    'field' => 'StageName', 'op' => 'EQUALS', 'value' => 'Closed Won'
                }
            },
            new Map<String, Object>{ 'key' => 'open', 'category' => 'open' }
        });
        Workflow_Action__c a = buildAction(null);
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        System.assertEquals('open',
            PulseActionStatusEvaluator.resolveStatusFor(a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void fieldRuleMatchesFirstStatus() {
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{
                'key'      => 'won',
                'category' => 'terminal_success',
                'entryConditions' => new Map<String, Object>{
                    'field' => 'StageName', 'op' => 'EQUALS', 'value' => 'Closed Won'
                }
            },
            new Map<String, Object>{ 'key' => 'open', 'category' => 'open' }
        });
        Workflow_Action__c a = buildAction('open');
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Closed Won');
        System.assertEquals('won',
            PulseActionStatusEvaluator.resolveStatusFor(a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void noMatchReturnsCurrentStatusKey() {
        // No status with {} fallback; condition won't match. The action's
        // current Status_Key__c should come back unchanged.
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{
                'key'      => 'ready',
                'category' => 'open',
                'entryConditions' => new Map<String, Object>{
                    'field' => 'StageName', 'op' => 'EQUALS', 'value' => 'Never'
                }
            }
        });
        Workflow_Action__c a = buildAction('current_pending');
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qualification');
        System.assertEquals('current_pending',
            PulseActionStatusEvaluator.resolveStatusFor(a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void actionStatusRuleReferencesSibling() {
        // Only match when sibling 'prereq' has status 'completed'.
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{
                'key'      => 'ready',
                'category' => 'open',
                'entryConditions' => new Map<String, Object>{
                    'type' => 'action_status', 'action' => 'prereq', 'statusEquals' => 'completed'
                }
            },
            new Map<String, Object>{ 'key' => 'blocked', 'category' => 'blocked' }
        });
        Workflow_Action__c a = buildAction('blocked');
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qual');

        // Miss: sibling not yet completed.
        System.assertEquals('blocked', PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>{ 'prereq' => 'pending' }, def, o));

        // Hit: sibling completed.
        System.assertEquals('ready', PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>{ 'prereq' => 'completed' }, def, o));
    }

    @IsTest
    static void fieldChangedRuleFalseWithoutOldRecord() {
        // The Evaluator passes oldRecord=null, so field_changed rules can
        // never match from the status evaluator path — they're designed
        // for trigger-time evaluation, not snapshot reevaluation.
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{
                'key'      => 'triggered',
                'category' => 'open',
                'entryConditions' => new Map<String, Object>{
                    'type' => 'field_changed', 'field' => 'StageName'
                }
            },
            new Map<String, Object>{ 'key' => 'idle', 'category' => 'open' }
        });
        Workflow_Action__c a = buildAction('idle');
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qual');
        System.assertEquals('idle', PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void definitionWithoutStatusesFallsBackToCurrent() {
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>());
        // Empty statuses → fallback to action.Status_Key__c
        Workflow_Action__c a = buildAction('whatever');
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qual');
        System.assertEquals('whatever', PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void legacyStatusMapsWhenStatusKeyBlank() {
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>());
        Workflow_Action__c a = new Workflow_Action__c(
            Action_Key__c = 'this_action',
            Phase_Key__c  = 'p',
            Status__c     = 'Executed'
        );
        Opportunity o = new Opportunity(Name = 'X', CloseDate = Date.today(), StageName = 'Qual');
        System.assertEquals('completed', PulseActionStatusEvaluator.resolveStatusFor(
            a, new Map<String, String>(), def, o));
    }

    @IsTest
    static void statusDefForReturnsCorrectDef() {
        WorkflowContract.ActionDef def = buildDef('this_action', new List<Map<String, Object>>{
            new Map<String, Object>{ 'key' => 'open', 'category' => 'open' },
            new Map<String, Object>{ 'key' => 'done', 'category' => 'terminal_success' }
        });
        WorkflowContract.StatusDef sd = PulseActionStatusEvaluator.statusDefFor(def, 'done');
        System.assertNotEquals(null, sd);
        System.assertEquals('terminal_success', sd.category);
        System.assertEquals(null, PulseActionStatusEvaluator.statusDefFor(def, 'missing'));
    }

    @IsTest
    static void nullDefSafelyReturnsFallback() {
        Workflow_Action__c a = buildAction('foo');
        System.assertEquals('foo',
            PulseActionStatusEvaluator.resolveStatusFor(a, null, null, null));
    }
}

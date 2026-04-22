public with sharing class PulseAgentInvoker {

    /** Test-only flag — public (not @TestVisible private) so the trigger
     *  can read it at runtime. Only ever written from tests. */
    public static Boolean enqueueSuppressed = false;

    /**
     * Given a set of Workflow_Instance__c ids, returns only those whose
     * current state has a non-blank toolConfig.toolKey in the pinned contract.
     * Bulk-safe: parses each unique definition JSON once, not per instance.
     */
    public static Set<Id> filterAiDrivenInstances(Set<Id> instanceIds) {
        if (instanceIds == null || instanceIds.isEmpty()) {
            return new Set<Id>();
        }

        List<Workflow_Instance__c> instances = [
            SELECT Id, Current_State__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id IN :instanceIds
              AND Status__c = 'Active'
        ];

        // Cache parsed contracts by Definition Id to avoid re-parsing
        Map<Id, WorkflowContract.Workflow> parsedByDefId =
            new Map<Id, WorkflowContract.Workflow>();

        Set<Id> eligible = new Set<Id>();

        for (Workflow_Instance__c inst : instances) {
            if (String.isBlank(inst.Current_State__c)
                    || inst.Workflow_Definition__c == null
                    || String.isBlank(inst.Workflow_Definition__r.Definition_JSON__c)) {
                continue;
            }

            WorkflowContract.Workflow wf = parsedByDefId.get(inst.Workflow_Definition__c);
            if (wf == null) {
                try {
                    wf = WorkflowContract.parse(
                        inst.Workflow_Definition__r.Definition_JSON__c
                    );
                    parsedByDefId.put(inst.Workflow_Definition__c, wf);
                } catch (Exception e) {
                    continue;
                }
            }

            WorkflowContract.State state = wf.getState(inst.Current_State__c);
            if (state != null
                    && state.toolConfig != null
                    && String.isNotBlank(state.toolConfig.toolKey)) {
                eligible.add(inst.Id);
            }
        }

        return eligible;
    }
}

/**
 * PulseAgentController
 *
 * Aura-enabled bridge between the Agent Mode LWCs (pulseAgentStatusRail,
 * pulseAgentDecisionQueue, pulseAgentDecisionLog) and the orchestrator.
 *
 * All methods accept `Map<String, Object>` where non-trivial payloads are
 * required, per the Lane E pattern: typed DTOs in @AuraEnabled parameters
 * hit a known Aura deserialization bug that drops fields silently.
 */
global with sharing class PulseAgentController {

    // ─── View DTOs ──────────────────────────────────────────────

    global class AgentStateView {
        @AuraEnabled public Boolean enabled;          // false when agent mode off for this instance
        @AuraEnabled public Id      threadId;
        @AuraEnabled public Id      instanceId;
        @AuraEnabled public String  persona;
        @AuraEnabled public String  status;
        @AuraEnabled public String  autonomy;
        @AuraEnabled public List<String> autonomyOptions;
        @AuraEnabled public Datetime lastRunDate;
        @AuraEnabled public String  lastError;
        @AuraEnabled public Integer pendingCount;
    }

    global class DecisionView {
        @AuraEnabled public Id       decisionId;
        @AuraEnabled public String   decisionType;
        @AuraEnabled public String   phaseKey;
        @AuraEnabled public String   rationale;
        @AuraEnabled public String   status;
        @AuraEnabled public String   proposalJson;
        @AuraEnabled public String   questionJson;
        @AuraEnabled public String   userResponseJson;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime resolvedDate;
        @AuraEnabled public Id       relatedActionId;
        @AuraEnabled public String   relatedActionStatus;
        // Convenience preview for LWCs
        @AuraEnabled public String   toolKey;
        @AuraEnabled public String   previewKind;   // 'email' | 'record' | 'raw' | 'question'
        @AuraEnabled public Map<String, Object> previewData;
    }

    global class RunResultView {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Integer decisionsCreated;
        @AuraEnabled public String  status;
        @AuraEnabled public String  error;
    }

    // ─── getAgentState ──────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    global static AgentStateView getAgentState(Id instanceId) {
        AgentStateView v = new AgentStateView();
        v.enabled = false;
        v.instanceId = instanceId;
        v.autonomyOptions = new List<String>{
            'Propose_Only', 'Act_With_Approval', 'Autonomous_Safe'
        };
        if (instanceId == null) return v;

        // Check contract — if agent not enabled anywhere, stop here.
        List<Workflow_Instance__c> rows = [
            SELECT Id, Current_State__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId LIMIT 1
        ];
        if (rows.isEmpty()) return v;

        try {
            WorkflowContract.Workflow wf = WorkflowContract.parse(
                rows[0].Workflow_Definition__r.Definition_JSON__c
            );
            if (wf == null || !wf.agentEnabledAnywhere()) return v;
        } catch (Exception e) {
            return v;
        }
        v.enabled = true;

        List<Agent_Thread__c> threads = [
            SELECT Id, Persona_Name__c, Autonomy_Level__c, Status__c,
                   Last_Run_Date__c, Last_Error__c
            FROM Agent_Thread__c
            WHERE Workflow_Instance__c = :instanceId
            LIMIT 1
        ];
        if (!threads.isEmpty()) {
            Agent_Thread__c t = threads[0];
            v.threadId = t.Id;
            v.persona = String.isBlank(t.Persona_Name__c) ? 'Claude' : t.Persona_Name__c;
            v.status = t.Status__c;
            v.autonomy = t.Autonomy_Level__c;
            v.lastRunDate = t.Last_Run_Date__c;
            v.lastError = t.Last_Error__c;
        } else {
            v.persona = 'Claude';
            v.status = 'Idle';
            v.autonomy = 'Act_With_Approval';
        }

        v.pendingCount = [
            SELECT COUNT() FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :instanceId
              AND Status__c = 'Pending_User'
        ];
        return v;
    }

    // ─── getPendingDecisions ────────────────────────────────────

    @AuraEnabled(cacheable=false)
    global static List<DecisionView> getPendingDecisions(Id instanceId) {
        List<DecisionView> out = new List<DecisionView>();
        if (instanceId == null) return out;
        List<Agent_Decision__c> rows = [
            SELECT Id, Decision_Type__c, Phase_Key__c, Rationale__c, Status__c,
                   Proposal_JSON__c, Question_JSON__c, User_Response_JSON__c,
                   CreatedDate, Resolved_Date__c,
                   Related_Action__c, Related_Action__r.Status__c
            FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :instanceId
              AND Status__c = 'Pending_User'
            ORDER BY CreatedDate ASC
        ];
        for (Agent_Decision__c d : rows) {
            out.add(buildDecisionView(d));
        }
        return out;
    }

    // ─── getDecisionLog ─────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    global static List<DecisionView> getDecisionLog(Id instanceId) {
        List<DecisionView> out = new List<DecisionView>();
        if (instanceId == null) return out;
        List<Agent_Decision__c> rows = [
            SELECT Id, Decision_Type__c, Phase_Key__c, Rationale__c, Status__c,
                   Proposal_JSON__c, Question_JSON__c, User_Response_JSON__c,
                   CreatedDate, Resolved_Date__c,
                   Related_Action__c, Related_Action__r.Status__c
            FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :instanceId
              AND Status__c != 'Pending_User'
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
        for (Agent_Decision__c d : rows) {
            out.add(buildDecisionView(d));
        }
        return out;
    }

    // ─── approveDecision / rejectDecision / answerQuestion ──────

    @AuraEnabled
    global static RunResultView approveDecision(Map<String, Object> payload) {
        RunResultView v = new RunResultView();
        if (payload == null) {
            v.success = false; v.error = 'payload is required'; return v;
        }
        Id decisionId = coerceId(payload.get('decisionId'));
        String refined = (String) payload.get('refinedPayloadJson');
        PulseAgentOrchestrator.RunResult r =
            PulseAgentOrchestrator.approveDecision(decisionId, refined);
        v.success = r.success;
        v.decisionsCreated = r.decisionsCreated;
        v.status = r.status;
        v.error = r.error;
        return v;
    }

    @AuraEnabled
    global static RunResultView rejectDecision(Map<String, Object> payload) {
        RunResultView v = new RunResultView();
        if (payload == null) {
            v.success = false; v.error = 'payload is required'; return v;
        }
        Id decisionId = coerceId(payload.get('decisionId'));
        String reason = (String) payload.get('reason');
        PulseAgentOrchestrator.RunResult r =
            PulseAgentOrchestrator.rejectDecision(decisionId, reason);
        v.success = r.success;
        v.decisionsCreated = r.decisionsCreated;
        v.status = r.status;
        v.error = r.error;
        return v;
    }

    @AuraEnabled
    global static RunResultView answerQuestion(Map<String, Object> payload) {
        RunResultView v = new RunResultView();
        if (payload == null) {
            v.success = false; v.error = 'payload is required'; return v;
        }
        Id decisionId = coerceId(payload.get('decisionId'));
        Object respRaw = payload.get('responseJson');
        String responseJson = respRaw == null ? null
            : (respRaw instanceof String ? (String) respRaw : JSON.serialize(respRaw));
        PulseAgentOrchestrator.RunResult r =
            PulseAgentOrchestrator.answerQuestion(decisionId, responseJson);
        v.success = r.success;
        v.decisionsCreated = r.decisionsCreated;
        v.status = r.status;
        v.error = r.error;
        return v;
    }

    // ─── setAutonomy ────────────────────────────────────────────

    @AuraEnabled
    global static AgentStateView setAutonomy(Id instanceId, String autonomy) {
        if (instanceId == null || String.isBlank(autonomy)) {
            return getAgentState(instanceId);
        }
        Agent_Thread__c t = PulseAgentOrchestrator.getOrCreateThread(instanceId);
        t.Autonomy_Level__c = autonomy;
        update t;
        return getAgentState(instanceId);
    }

    // ─── kickAgent ──────────────────────────────────────────────

    @AuraEnabled
    global static RunResultView kickAgent(Id instanceId) {
        RunResultView v = new RunResultView();
        if (instanceId == null) {
            v.success = false; v.error = 'instanceId required'; return v;
        }
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(instanceId);
        v.success = r.success;
        v.decisionsCreated = r.decisionsCreated;
        v.status = r.status;
        v.error = r.error;
        return v;
    }

    // ─── Helpers ────────────────────────────────────────────────

    private static DecisionView buildDecisionView(Agent_Decision__c d) {
        DecisionView v = new DecisionView();
        v.decisionId = d.Id;
        v.decisionType = d.Decision_Type__c;
        v.phaseKey = d.Phase_Key__c;
        v.rationale = d.Rationale__c;
        v.status = d.Status__c;
        v.proposalJson = d.Proposal_JSON__c;
        v.questionJson = d.Question_JSON__c;
        v.userResponseJson = d.User_Response_JSON__c;
        v.createdDate = d.CreatedDate;
        v.resolvedDate = d.Resolved_Date__c;
        v.relatedActionId = d.Related_Action__c;
        v.relatedActionStatus = d.Related_Action__c == null
            ? null : d.Related_Action__r.Status__c;

        if (d.Decision_Type__c == 'Propose_Action' && String.isNotBlank(d.Proposal_JSON__c)) {
            Map<String, Object> prop;
            try {
                prop = (Map<String, Object>) JSON.deserializeUntyped(d.Proposal_JSON__c);
            } catch (Exception e) {
                prop = new Map<String, Object>();
            }
            v.toolKey = (String) prop.get('toolKey');
            v.previewData = new Map<String, Object>();
            v.previewData.put('toolKey', v.toolKey);
            v.previewData.put('arguments', prop.get('arguments'));
            if (v.toolKey == 'send_email') {
                v.previewKind = 'email';
            } else if (v.toolKey == 'update_record') {
                v.previewKind = 'record';
            } else {
                v.previewKind = 'raw';
            }
        } else if (d.Decision_Type__c == 'Ask_User' && String.isNotBlank(d.Question_JSON__c)) {
            Map<String, Object> q;
            try {
                q = (Map<String, Object>) JSON.deserializeUntyped(d.Question_JSON__c);
            } catch (Exception e) {
                q = new Map<String, Object>();
            }
            v.previewKind = 'question';
            v.previewData = q;
        } else if (d.Decision_Type__c == 'Advance_Phase' && String.isNotBlank(d.Proposal_JSON__c)) {
            Map<String, Object> prop;
            try {
                prop = (Map<String, Object>) JSON.deserializeUntyped(d.Proposal_JSON__c);
            } catch (Exception e) {
                prop = new Map<String, Object>();
            }
            v.previewKind = 'advance';
            v.previewData = prop;
        } else {
            v.previewKind = 'raw';
            v.previewData = new Map<String, Object>();
        }
        return v;
    }

    private static Id coerceId(Object raw) {
        if (raw == null) return null;
        if (raw instanceof Id) return (Id) raw;
        String s = String.valueOf(raw);
        return String.isBlank(s) ? null : (Id) s;
    }
}

/**
 * Lightweight predictor that aggregates Stage_Dwell__c history into per-state
 * percentile stats (median, p90) and projects when active instances are likely
 * to exit their current state.
 *
 * No ML — simple percentile-from-history. Extension packages may consume
 * StageStats and ExitPrediction via this global API.
 */
global with sharing class StageDwellPredictor {

    private static final Integer DEFAULT_LOOKBACK_DAYS = 90;
    // SOQL row cap — if exceeded, results are based on the most recent rows only
    private static final Integer SOQL_ROW_LIMIT = 50000;

    // ── DTOs ─────────────────────���───────────────────────────────────

    global class StageStats {
        @AuraEnabled global String  workflowKey;
        @AuraEnabled global String  subjectKind;
        @AuraEnabled global String  stateKey;
        @AuraEnabled global Integer sampleCount;
        @AuraEnabled global Integer medianSeconds;
        @AuraEnabled global Integer p90Seconds;
        @AuraEnabled global Integer minSeconds;
        @AuraEnabled global Integer maxSeconds;
    }

    global class ExitPrediction {
        @AuraEnabled global Id       instanceId;
        @AuraEnabled global String   currentStateKey;
        @AuraEnabled global Datetime enteredAt;
        @AuraEnabled global Integer  medianSecondsForState;
        @AuraEnabled global Integer  p90SecondsForState;
        @AuraEnabled global Datetime expectedExitDate;
        @AuraEnabled global Datetime p90ExitDate;
        @AuraEnabled global Boolean  isOverdue;
        @AuraEnabled global Integer  sampleCount;
    }

    // ── Public API ───────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<StageStats> aggregateDwellStats(
        String workflowKey,
        Integer lookbackDays
    ) {
        Integer days = (lookbackDays != null && lookbackDays > 0) ? lookbackDays : DEFAULT_LOOKBACK_DAYS;
        Datetime cutoff = Datetime.now().addDays(-days);

        // Query completed dwell rows within the lookback window
        String query = 'SELECT Workflow_Key__c, Subject_Kind__c, State_Key__c, Duration_Seconds__c'
            + ' FROM Stage_Dwell__c'
            + ' WHERE Exited_At__c != NULL AND Entered_At__c >= :cutoff';
        if (String.isNotBlank(workflowKey)) {
            query += ' AND Workflow_Key__c = :workflowKey';
        }
        query += ' ORDER BY Entered_At__c DESC LIMIT ' + SOQL_ROW_LIMIT;

        List<Stage_Dwell__c> rows = Database.query(query);

        // Group durations by (workflowKey, subjectKind, stateKey)
        Map<String, List<Integer>> buckets = new Map<String, List<Integer>>();
        Map<String, String[]> keyParts = new Map<String, String[]>();

        for (Stage_Dwell__c sd : rows) {
            String bk = bucketKey(sd.Workflow_Key__c, sd.Subject_Kind__c, sd.State_Key__c);
            if (!buckets.containsKey(bk)) {
                buckets.put(bk, new List<Integer>());
                keyParts.put(bk, new String[]{ sd.Workflow_Key__c, sd.Subject_Kind__c, sd.State_Key__c });
            }
            Integer dur = sd.Duration_Seconds__c != null ? sd.Duration_Seconds__c.intValue() : 0;
            buckets.get(bk).add(dur);
        }

        // Compute stats per bucket
        List<StageStats> results = new List<StageStats>();
        for (String bk : buckets.keySet()) {
            List<Integer> durations = buckets.get(bk);
            durations.sort();
            String[] parts = keyParts.get(bk);

            StageStats ss = new StageStats();
            ss.workflowKey = parts[0];
            ss.subjectKind = parts[1];
            ss.stateKey = parts[2];
            ss.sampleCount = durations.size();
            ss.medianSeconds = percentile(durations, 50);
            ss.p90Seconds = percentile(durations, 90);
            ss.minSeconds = durations[0];
            ss.maxSeconds = durations[durations.size() - 1];
            results.add(ss);
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    global static ExitPrediction predictExitFor(Id workflowInstanceId) {
        ExitPrediction pred = new ExitPrediction();
        pred.instanceId = workflowInstanceId;

        // Find the open dwell row for this instance
        List<Stage_Dwell__c> openRows = [
            SELECT State_Key__c, Entered_At__c, Workflow_Key__c, Subject_Kind__c
            FROM Stage_Dwell__c
            WHERE Workflow_Instance__c = :workflowInstanceId
              AND Exited_At__c = NULL
            ORDER BY Entered_At__c DESC
            LIMIT 1
        ];

        if (openRows.isEmpty()) {
            pred.sampleCount = 0;
            return pred;
        }

        Stage_Dwell__c current = openRows[0];
        pred.currentStateKey = current.State_Key__c;
        pred.enteredAt = current.Entered_At__c;

        // Look up stats for this state
        List<StageStats> stats = aggregateDwellStats(current.Workflow_Key__c, DEFAULT_LOOKBACK_DAYS);
        StageStats match = null;
        for (StageStats ss : stats) {
            if (ss.stateKey == current.State_Key__c
                && (current.Subject_Kind__c == null || ss.subjectKind == current.Subject_Kind__c)) {
                match = ss;
                break;
            }
        }

        if (match == null || match.sampleCount == 0) {
            pred.sampleCount = 0;
            return pred;
        }

        pred.sampleCount = match.sampleCount;
        pred.medianSecondsForState = match.medianSeconds;
        pred.p90SecondsForState = match.p90Seconds;

        if (pred.enteredAt != null) {
            pred.expectedExitDate = pred.enteredAt.addSeconds(match.medianSeconds);
            pred.p90ExitDate = pred.enteredAt.addSeconds(match.p90Seconds);
            pred.isOverdue = Datetime.now() > pred.p90ExitDate;
        }

        return pred;
    }

    // ── Private helpers ────────────────���─────────────────────────────

    private static String bucketKey(String wfKey, String subjectKind, String stateKey) {
        return (wfKey != null ? wfKey : '') + '|'
            + (subjectKind != null ? subjectKind : '') + '|'
            + (stateKey != null ? stateKey : '');
    }

    /**
     * Index-based percentile on a pre-sorted list.
     * pct=50 → median, pct=90 → p90.
     */
    @TestVisible
    private static Integer percentile(List<Integer> sorted, Integer pct) {
        if (sorted == null || sorted.isEmpty()) {
            return 0;
        }
        Integer idx = (Integer) Math.floor(sorted.size() * pct / 100.0);
        if (idx >= sorted.size()) {
            idx = sorted.size() - 1;
        }
        return sorted[idx];
    }
}

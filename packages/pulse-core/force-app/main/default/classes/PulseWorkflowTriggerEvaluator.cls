/**
 * PulseWorkflowTriggerEvaluator
 *
 * Evaluates a Workflow_Trigger__c Condition_JSON__c tree against an SObject
 * record, with access to the old values map so change-aware operators
 * (IS_CHANGED) can be supported.
 *
 * Condition tree shape:
 *   { "logic": "AND" | "OR",
 *     "rules": [
 *       { "field": "StageName", "op": "EQUALS", "value": "Closed Won" },
 *       { "logic": "OR", "rules": [ ... ] }
 *     ]
 *   }
 *
 * Empty / null tree → always true (fire on every event).
 *
 * Supported operators:
 *   EQUALS, NOT_EQUALS, CONTAINS, STARTS_WITH, ENDS_WITH,
 *   GREATER_THAN, LESS_THAN, IS_NULL, IS_NOT_NULL,
 *   IS_CHANGED, CHANGED_TO, CHANGED_FROM
 */
global with sharing class PulseWorkflowTriggerEvaluator {

    global class EvaluationException extends Exception {}

    /**
     * Evaluate a condition tree against a single record.
     *
     * @param record       the new/updated SObject
     * @param oldRecord    the prior version (null on insert)
     * @param conditionJson serialized condition tree (null/blank → true)
     * @return             true if the record satisfies the condition
     */
    global static Boolean matches(SObject record, SObject oldRecord, String conditionJson) {
        if (String.isBlank(conditionJson) || conditionJson.trim() == '{}') {
            return true;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(conditionJson);
        } catch (Exception e) {
            throw new EvaluationException('Invalid Condition_JSON: ' + e.getMessage());
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new EvaluationException('Condition_JSON root must be an object');
        }
        return evaluateNode((Map<String, Object>) parsed, record, oldRecord);
    }

    // ── Node evaluator ────────────────────────────────────────────────

    private static Boolean evaluateNode(
        Map<String, Object> node, SObject record, SObject oldRecord
    ) {
        // Rule leaf: has 'field' + 'op'
        if (node.containsKey('field') && node.containsKey('op')) {
            return evaluateRule(node, record, oldRecord);
        }

        // Group node: has 'logic' + 'rules'
        String logic = (String) node.get('logic');
        if (logic == null) logic = 'AND';
        logic = logic.toUpperCase();

        List<Object> rulesRaw = (List<Object>) node.get('rules');
        if (rulesRaw == null || rulesRaw.isEmpty()) {
            return true;
        }

        if (logic == 'AND') {
            for (Object r : rulesRaw) {
                if (!(r instanceof Map<String, Object>)) continue;
                if (!evaluateNode((Map<String, Object>) r, record, oldRecord)) {
                    return false;
                }
            }
            return true;
        } else if (logic == 'OR') {
            for (Object r : rulesRaw) {
                if (!(r instanceof Map<String, Object>)) continue;
                if (evaluateNode((Map<String, Object>) r, record, oldRecord)) {
                    return true;
                }
            }
            return false;
        } else {
            throw new EvaluationException('Unsupported logic operator: ' + logic);
        }
    }

    // ── Rule evaluator ────────────────────────────────────────────────

    private static Boolean evaluateRule(
        Map<String, Object> rule, SObject record, SObject oldRecord
    ) {
        String field = (String) rule.get('field');
        String op    = ((String) rule.get('op') + '').toUpperCase();
        Object value = rule.get('value');

        if (String.isBlank(field)) {
            throw new EvaluationException('Rule missing field');
        }

        Object recVal = getFieldValue(record, field);
        Object oldVal = oldRecord == null ? null : getFieldValue(oldRecord, field);

        if (op == 'IS_CHANGED') {
            return !objectEquals(recVal, oldVal);
        }
        if (op == 'CHANGED_TO') {
            return !objectEquals(recVal, oldVal) && objectEquals(recVal, value);
        }
        if (op == 'CHANGED_FROM') {
            return !objectEquals(recVal, oldVal) && objectEquals(oldVal, value);
        }
        if (op == 'IS_NULL') {
            return recVal == null;
        }
        if (op == 'IS_NOT_NULL') {
            return recVal != null;
        }
        if (op == 'EQUALS') {
            return objectEquals(recVal, value);
        }
        if (op == 'NOT_EQUALS') {
            return !objectEquals(recVal, value);
        }
        if (op == 'CONTAINS') {
            return stringOp(recVal, value, 'CONTAINS');
        }
        if (op == 'STARTS_WITH') {
            return stringOp(recVal, value, 'STARTS_WITH');
        }
        if (op == 'ENDS_WITH') {
            return stringOp(recVal, value, 'ENDS_WITH');
        }
        if (op == 'GREATER_THAN') {
            return compareNumeric(recVal, value) > 0;
        }
        if (op == 'LESS_THAN') {
            return compareNumeric(recVal, value) < 0;
        }
        throw new EvaluationException('Unsupported operator: ' + op);
    }

    // ── Field accessor ────────────────────────────────────────────────

    private static Object getFieldValue(SObject record, String field) {
        if (record == null || String.isBlank(field)) return null;
        try {
            return record.get(field);
        } catch (Exception e) {
            return null;
        }
    }

    // ── Value comparisons ─────────────────────────────────────────────

    private static Boolean objectEquals(Object a, Object b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        // Numbers: coerce to Decimal for comparison so 42 == 42.0
        if ((a instanceof Integer || a instanceof Long || a instanceof Double || a instanceof Decimal)
            && (b instanceof Integer || b instanceof Long || b instanceof Double || b instanceof Decimal)) {
            return toDecimal(a) == toDecimal(b);
        }
        return String.valueOf(a) == String.valueOf(b);
    }

    private static Boolean stringOp(Object recVal, Object target, String mode) {
        if (recVal == null || target == null) return false;
        String haystack = String.valueOf(recVal);
        String needle   = String.valueOf(target);
        if (mode == 'CONTAINS')    return haystack.contains(needle);
        if (mode == 'STARTS_WITH') return haystack.startsWith(needle);
        if (mode == 'ENDS_WITH')   return haystack.endsWith(needle);
        return false;
    }

    private static Integer compareNumeric(Object a, Object b) {
        if (a == null || b == null) return 0;
        Decimal da = toDecimal(a);
        Decimal db = toDecimal(b);
        if (da == null || db == null) return 0;
        if (da > db) return 1;
        if (da < db) return -1;
        return 0;
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return Decimal.valueOf((Integer) v);
        if (v instanceof Long)    return Decimal.valueOf((Long) v);
        if (v instanceof Double)  return Decimal.valueOf((Double) v);
        try {
            return Decimal.valueOf(String.valueOf(v));
        } catch (Exception e) {
            return null;
        }
    }
}

#!/usr/bin/env bash
# Replicate the LWC → Aura → Apex call for PulseWorkflowTriggerController.
# Tests each variant. Outputs pass/fail per method.
set -euo pipefail

ORG_ALIAS="pulse-core-next-dev"
WFDEF_ID="a05E200000YE7IzIAL"
NS="plse"
FWUID="TXFWNVprQUZzQnEtNXVXYTFLQ2ppdzJEa1N5enhOU3R5QWl2VzNveFZTbGcxMy4tMjE0NzQ4MzY0OC4xMzEwNzIwMA"

ORG=$(sf org display --target-org "$ORG_ALIAS" --json)
TOKEN=$(echo "$ORG" | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['accessToken'])")
DOM=$(echo "$ORG"   | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['instanceUrl'])")
LDOM=$(echo "$DOM"  | sed 's/my.salesforce.com/lightning.force.com/')

CK=/tmp/trigger-save-test.$$.cookies
trap 'rm -f "$CK"' EXIT
rm -f "$CK"
curl -sS -c "$CK" -L -o /dev/null "${DOM}/secur/frontdoor.jsp?sid=${TOKEN}"
curl -sS -b "$CK" -c "$CK" -L -o /dev/null "${LDOM}/one/one.app"
# Use the LAST ERIC_PROD cookie — it's the freshly minted one from this run.
AURA_TOKEN=$(grep "__Host-ERIC_PROD" "$CK" | awk -F'\t' '{print $7}' | tail -1)

CTX='{"mode":"PROD","fwuid":"'$FWUID'","app":"one:one","loaded":{},"dn":[],"globals":{},"uad":false}'

call_aura() {
  local method="$1"
  local params="$2"
  local MSG='{"actions":[{"id":"1;a","descriptor":"apex://'$NS'.PulseWorkflowTriggerController/ACTION$'$method'","callingDescriptor":"UNKNOWN","params":'$params'}]}'
  RESPONSE=$(curl -sS -b "$CK" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "User-Agent: Mozilla/5.0" \
    -H "Referer: ${LDOM}/lightning/" \
    --data-urlencode "message=${MSG}" \
    --data-urlencode "aura.context=${CTX}" \
    --data-urlencode "aura.token=${AURA_TOKEN}" \
    "${LDOM}/aura?r=1&aura.ApexAction.execute=1")
  # Extract state + returnValue + error
  python3 - "$method" <<PY
import json,sys
raw=sys.stdin.read()
method=sys.argv[1]
try:
    data=json.loads(raw)
    for a in data.get('actions',[]):
        state=a.get('state')
        err=a.get('error',[])
        rv=a.get('returnValue')
        msg=err[0].get('message','') if err else ''
        print(f"{method}: state={state} err={msg[:90]} rv={str(rv)[:120]}")
except Exception as e:
    print(f"{method}: PARSE-ERROR {e} raw={raw[:200]}")
PY
  echo "$RESPONSE" <<< ''
  # Need to get raw into python; curl output is piped via process substitution
}

# Fix: feed RESPONSE into python3 via stdin
call_aura_v2() {
  local method="$1"
  local params="$2"
  local MSG='{"actions":[{"id":"1;a","descriptor":"apex://'$NS'.PulseWorkflowTriggerController/ACTION$'$method'","callingDescriptor":"UNKNOWN","params":'$params'}]}'
  RESPONSE=$(curl -sS -b "$CK" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "User-Agent: Mozilla/5.0" \
    -H "Referer: ${LDOM}/lightning/" \
    --data-urlencode "message=${MSG}" \
    --data-urlencode "aura.context=${CTX}" \
    --data-urlencode "aura.token=${AURA_TOKEN}" \
    "${LDOM}/aura?r=1&aura.ApexAction.execute=1" 2>/dev/null)
  echo "$RESPONSE" | python3 -c "
import json,sys
raw=sys.stdin.read()
method='$method'
try:
    data=json.loads(raw)
    for a in data.get('actions',[]):
        state=a.get('state')
        err=a.get('error',[])
        rv=a.get('returnValue')
        msg=err[0].get('message','').replace(chr(10),' | ') if err else ''
        print(f'  {method}: state={state}')
        if msg: print(f'    err: {msg[:160]}')
        if rv is not None: print(f'    rv : {str(rv)[:160]}')
except Exception as e:
    print(f'  {method}: PARSE-ERROR {e} raw_start={raw[:200]}')
"
}

echo "=== H1: upsertTrigger (DTO in, UpsertResult out) ==="
call_aura_v2 "upsertTrigger" '{"payload":{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","name":"H1 probe","targetObject":"Account","eventType":"Created_or_Updated","conditionJson":"{\"logic\":\"AND\",\"rules\":[{\"field\":\"Name\",\"op\":\"IS_NOT_NULL\"}]}","initialStateKey":null,"active":true}}'

echo "=== H2: upsertTriggerV2 (DTO in, STRING out — tests response serialization) ==="
call_aura_v2 "upsertTriggerV2" '{"payload":{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","name":"H2 probe","targetObject":"Account","eventType":"Created_or_Updated","conditionJson":"{}","initialStateKey":null,"active":true}}'

echo "=== H3: upsertTriggerV3 (primitives in, STRING out — tests input deserialization) ==="
call_aura_v2 "upsertTriggerV3" '{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","targetObject":"Account","eventType":"Created_or_Updated","active":true}'

echo "=== H4: upsertTriggerV4 (DTO in, UpsertResult out, SKIPS provisioning) ==="
call_aura_v2 "upsertTriggerV4" '{"payload":{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","name":"H4 probe","targetObject":"Account","eventType":"Created_or_Updated","conditionJson":"{}","initialStateKey":null,"active":true}}'

echo "=== H5: upsertTriggerV5 (primitives in, SimpleResult out — resolveAction-twin pattern) ==="
call_aura_v2 "upsertTriggerV5" '{"workflowDefinitionId":"'$WFDEF_ID'","targetObject":"Account","eventType":"Created_or_Updated","active":true}'

echo "=== H6: upsertTriggerV6 (DTO in with STRING ids instead of Id type) ==="
call_aura_v2 "upsertTriggerV6" '{"payload":{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","name":"H6 probe","targetObject":"Account","eventType":"Created_or_Updated","conditionJson":"{}","initialStateKey":null,"active":true}}'

echo "=== H7: upsertTriggerV7 (Map<String,Object> input) ==="
call_aura_v2 "upsertTriggerV7" '{"payload":{"recordId":null,"workflowDefinitionId":"'$WFDEF_ID'","name":"H7 probe","targetObject":"Account","eventType":"Created_or_Updated","conditionJson":"{}","initialStateKey":null,"active":true}}'

echo "=== CONTROL: listTriggers (known @AuraEnabled cacheable=true — known to work) ==="
call_aura_v2 "listTriggers" '{"workflowDefinitionId":"'$WFDEF_ID'"}'

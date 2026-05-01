# Pulse Core Next — Reactivity, Push, and UX Discipline

**Status:** proposal for upstream merge
**Scope:** changes to `pulse-core` that are not workflow- or demo-specific
**Audience:** engineers implementing the next round of pulse-core LWC + Apex changes

A series of issues surfaced during a deep UX pass on a record-page workflow surface (stepper + agent decision queue + custom domain panels) led to a set of structural patterns that consistently solved them. None are tied to a specific workflow contract or domain; all of them belong in pulse-core.

This document covers five areas:

1. Real-time push via Platform Events
2. LWC reactivity discipline (render-signature diff, sessionStorage hydration, terminal kill-switch, optimistic mutation, user-edit tracking)
3. `PulseRuntimeController` contract fixes
4. Decision-queue UX patterns (thinking placeholder, friendly refine editor, public lifecycle hooks)
5. Side-by-side stepper layout

Each section is structured the same way: **problem → pattern → contract/API surface → implementation notes → backward-compat**.

---

## 1. Real-time push via Platform Events

### Problem

Record-page LWCs that show workflow state need to reflect server-side changes (phase advances, new agent decisions, executed actions) without requiring the user to refresh. The two common solutions both fail:

- **Polling** (`setInterval` + `refreshApex`) is visually noisy. Even with snapshot diffs, the act of fetching and reassigning `@track` properties triggers re-renders that disrupt scroll position, focus, and hover state. Users perceive "the page is constantly refreshing."
- **Cascading parent → child reload** via custom DOM events forces unrelated components to re-render every time any sibling acts. A click on a row in component A causes component B to refetch its entire list.

### Pattern

A single high-volume Platform Event channel that the server publishes to on **meaningful** state transitions, and that LWCs subscribe to via `lightning/empApi`. Each LWC subscribes independently and filters by instance ID. There is no parent → child cascade.

### Server contract

#### Platform Event

```
Pulse_Workflow_Update__e  (HighVolume, PublishAfterCommit)
  Instance_Id__c   (Text, 18)
```

#### Triggers

Three after-update / after-insert triggers — one per object that drives meaningful workflow state — publish events. **Each trigger filters strictly**: only changes to fields the LWC's render signature watches produce events. This is the single most important discipline in this section: if every internal `Context_JSON__c` mutation publishes an event, post-completion retry loops drive UI refreshes. **Filter to the user-visible field deltas only.**

```apex
// Workflow_Instance__c — only fire on Current_State__c, Status__c, Stage_Status__c.
trigger PulseWorkflowInstancePushTrigger on Workflow_Instance__c (after update, after insert) {
    List<Pulse_Workflow_Update__e> events = new List<Pulse_Workflow_Update__e>();
    for (Workflow_Instance__c n : Trigger.new) {
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = true;
        } else {
            Workflow_Instance__c o = Trigger.oldMap.get(n.Id);
            if (o == null) meaningful = true;
            else if (n.Current_State__c != o.Current_State__c) meaningful = true;
            else if (n.Status__c != o.Status__c) meaningful = true;
            else if (n.Stage_Status__c != o.Stage_Status__c) meaningful = true;
        }
        if (meaningful) {
            events.add(new Pulse_Workflow_Update__e(Instance_Id__c = String.valueOf(n.Id)));
        }
    }
    if (!events.isEmpty()) EventBus.publish(events);
}
```

```apex
// Workflow_Action__c — only fire on Status__c transitions or initial Pending insert.
trigger PulseWorkflowActionPushTrigger on Workflow_Action__c (after insert, after update) {
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Action__c a : Trigger.new) {
        if (a.Workflow_Instance__c == null) continue;
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = (a.Status__c == 'Pending');
        } else {
            Workflow_Action__c o = Trigger.oldMap.get(a.Id);
            if (o != null && o.Status__c != a.Status__c) meaningful = true;
        }
        if (meaningful) instanceIds.add(a.Workflow_Instance__c);
    }
    publishFor(instanceIds);
}
```

```apex
// Agent_Decision__c — only fire on user-visible decision lifecycle events.
trigger PulseAgentDecisionPushTrigger on Agent_Decision__c (after insert, after update) {
    Set<Id> instanceIds = new Set<Id>();
    for (Agent_Decision__c d : Trigger.new) {
        if (d.Workflow_Instance__c == null) continue;
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = (d.Status__c == 'Pending_User'
                       || d.Status__c == 'Auto_Executed'
                       || d.Status__c == 'Answered');
        } else {
            Agent_Decision__c old = Trigger.oldMap.get(d.Id);
            meaningful = old != null
                && old.Status__c == 'Pending_User'
                && d.Status__c != 'Pending_User';
        }
        if (meaningful) instanceIds.add(d.Workflow_Instance__c);
    }
    publishFor(instanceIds);
}
```

**Why filter at the trigger level:** the agent's runTurn loop legitimately produces `Skipped` / `Observe` / `Error` rows during its scan-and-decide pass. If those fire events, every LWC subscription receives a refresh signal even though no user-visible state changed — the agent retry loop drives a refresh loop in the UI. Filter at the source.

### LWC subscription contract

Components that care about workflow state subscribe directly. There is no parent → child cascade.

```js
import { subscribe, unsubscribe, onError } from 'lightning/empApi';

connectedCallback() {
    subscribe('/event/Pulse_Workflow_Update__e', -1, (msg) => {
        // Bail immediately if we've reached terminal (see §2).
        if (this._terminalReached) return;
        const eventId = msg?.data?.payload?.Instance_Id__c;
        if (!eventId || !this.instanceId) return;
        // Compare 15-char prefixes — event payload is 18-char, prop may be 15.
        if (String(eventId).substring(0, 15) !== String(this.instanceId).substring(0, 15)) return;
        this._refresh();
    }).then((s) => { this._empSubscription = s; })
      .catch(() => { /* fall back to user-action refresh */ });
    onError(() => {});
}

disconnectedCallback() {
    if (this._empSubscription) {
        try { unsubscribe(this._empSubscription, () => {}); } catch (e) {}
        this._empSubscription = null;
    }
}
```

Three rules:

1. **Filter by instance ID inside the handler.** Multiple workflows may publish on the same channel; only refresh when the event matches the workflow this LWC is rendering.
2. **Always have a `.catch()` fallback.** empApi can fail silently in some org configurations (CometD endpoint blocked, missing read access on the event). User-initiated refresh paths should still work.
3. **Each component subscribes independently.** Do not rely on a parent component to broadcast refresh events — that pattern (which we tried) forces the parent to know about every child's refresh path and creates whole-tree re-renders on unrelated actions.

### Backward-compat notes

- Existing components that use `setInterval` polling can keep doing so during migration — adding the Platform Event subscription is additive.
- The Platform Event itself is harmless if no LWC subscribes to it; the publish cost is small.
- Custom code that already publishes events on the channel can coexist; subscribers filter by `Instance_Id__c` content.

---

## 2. LWC reactivity discipline

A handful of patterns that, applied consistently, eliminate the visual churn that pure-reactive LWCs produce. Every one of these solved a specific user-facing complaint.

### 2.1 Render-signature diff

#### Problem

`@wire` and imperative Apex calls return new object references on every fetch. Even when the user-visible data is identical, `JSON.stringify(data)` typically differs because Apex serializes timestamps (`LastModifiedDate`, `Resolved_Date__c`, etc.) into nested fields. Reassigning the `@track` property triggers a re-render every time, even when the page should be still.

#### Pattern

Compute a **small string from only the fields the template binds to**, and skip the reassignment when the new signature equals the cached one.

```js
async _load(quiet) {
    const data = await getInstanceForRecord({ recordId: this.recordId });
    if (quiet && !data) return;  // see §2.4
    const sig = this._buildRenderSig(data);
    if (quiet && sig === this._lastSnapshot) return;
    this._lastSnapshot = sig;
    this.instance = data;
    // … any derived state seeding …
}

_buildRenderSig(data) {
    if (!data) return '';
    // Include ONLY what the template binds to. Exclude every timestamp.
    const phases = (data.allPhases || []).map((p) => {
        const fields = (p.fields || [])
            .map((f) => `${f.key}=${f.currentValue == null ? '' : String(f.currentValue)}`)
            .join(';');
        return `${p.key}:${p.status}:${fields}`;
    }).join('|');
    const actions = (data.phaseActions || [])
        .map((a) => `${a.actionId}:${a.status}:${a.toolKey || ''}`)
        .join(',');
    return [
        data.currentStateKey || '',
        data.stageStatus || '',
        data.agentEnabled === true ? '1' : '0',
        data.pendingActionCount == null ? '' : String(data.pendingActionCount),
        phases,
        actions,
    ].join('||');
}
```

For lists (decision queue, recommendation queue, etc.), the signature is the join of per-item identifying fields:

```js
const sig = (list || [])
    .map((d) => `${d.id}|${d.status}|${d.score == null ? '' : d.score}`)
    .join(',');
```

#### Why it matters

This is the difference between "the page silently keeps current" and "the page constantly flickers as I scroll."

### 2.2 sessionStorage hydration

#### Problem

When the FlexiPage re-mounts an LWC (page-region refresh, navigation back to record, parent re-render), the user briefly sees the empty / loading state before the fetch completes. On a completed workflow, this looks like an unnecessary refresh loop.

#### Pattern

Cache the last-good payload in `sessionStorage`. On mount, hydrate synchronously from the cache before the network fetch. If the cached state is terminal (see §2.3), short-circuit the entire init path.

```js
connectedCallback() {
    this._hydrateFromCache();
    if (this._terminalReached) {
        // Workflow is finished — never even subscribe.
        return;
    }
    this._loadInstance(true).then(() => {
        if (this._terminalReached) return;
        this._subscribePush();
    });
}

_cacheKey() {
    return this.recordId ? `pulseStepper:${this.recordId}` : null;
}

_hydrateFromCache() {
    try {
        const k = this._cacheKey();
        if (!k) return;
        const raw = sessionStorage.getItem(k);
        if (!raw) return;
        const data = JSON.parse(raw);
        if (!data) return;
        this.instance = data;
        this._lastSnapshot = this._buildRenderSig(data);
        this.isLoading = false;  // critical: never show empty placeholder
        if (this._isTerminal(data)) this._terminalReached = true;
    } catch (e) { /* ignore corrupt cache */ }
}

_writeCache(data) {
    try {
        const k = this._cacheKey();
        if (k && data) sessionStorage.setItem(k, JSON.stringify(data));
    } catch (e) { /* quota / disabled storage */ }
}
```

Call `_writeCache(this.instance)` after every successful load.

#### Constraints

- `sessionStorage` is bounded (~5MB). Don't cache giant payloads. The signature mechanism in §2.1 means we only need to cache enough to render the visible state; truncate or omit history fields if needed.
- Per-tab. Cross-tab synchronization is out of scope.
- Storage is best-effort — wrap in `try/catch`. Some browser configurations disable it.

### 2.3 Terminal kill-switch

#### Problem

After a workflow completes, the agent's queueable may still kick (per orchestrator design) and produce `Observe` or `Error` decisions during its scan pass. Even with filtered triggers (§1), background machinery can occasionally publish events. The LWC keeps receiving them — and as long as it processes them, the user sees post-completion churn.

#### Pattern

Once the LWC observes a **terminal instance**, set a flag, unsubscribe from the push channel, and make every refresh path a no-op. The flag is also persisted to `sessionStorage` so re-mounts of the same workflow stay sealed.

```js
async _loadInstance(quiet) {
    // … fetch + sig diff …
    this.instance = data;
    this._writeCache(this.instance);
    if (this._isTerminal(data)) {
        this._terminalReached = true;
        this._unsubscribePush();
        this._stopChildren();          // see §4 for the child contract
        try {
            sessionStorage.setItem(`pulseTerminal:${data.instanceId}`, '1');
        } catch (e) {}
    }
}

async _doRefresh() {
    if (this._refreshInFlight) return;
    if (this._terminalReached) return;  // hard stop
    // … rest of refresh …
}

_isTerminal(data) {
    if (!data) return false;
    const status = (data.status || '').toLowerCase();
    if (status === 'completed' || status === 'terminated' || status === 'cancelled') return true;
    const stateType = (data.currentStateType || '').toLowerCase();
    if (stateType === 'terminal') return true;
    // Belt-and-braces: no phase is current AND no upcoming phase remains.
    const phases = data.allPhases || [];
    if (phases.length > 0) {
        const anyOpen = phases.some((p) => p.status === 'current' || p.status === 'upcoming');
        if (!anyOpen) return true;
    }
    return false;
}
```

Components that subscribe to the channel **independently** (sibling, not child) should also self-detect via the `sessionStorage` flag in their own `connectedCallback`:

```js
connectedCallback() {
    let isTerminal = false;
    try {
        isTerminal = sessionStorage.getItem(`pulseTerminal:${this.instanceId}`) === '1';
    } catch (e) {}
    if (isTerminal) {
        this._stopped = true;
        return;
    }
    this._load(true);
    this._subscribePush();
}
```

**Why three layers:**
1. Server-side trigger filtering reduces event volume.
2. Client-side terminal flag stops refresh work for events that still arrive.
3. sessionStorage flag keeps re-mounts from re-subscribing.

### 2.4 Never null out previously-good state on a quiet refresh

#### Problem

A transient null response or network blip during a background refresh causes `this.instance = data || null`, which flips template branches (`lwc:if={isLoading}` / `lwc:if={noInstance}`) and unmounts the entire active-instance subtree. The user sees the workflow disappear briefly. When the next refresh succeeds, the subtree remounts and scroll position is lost.

#### Pattern

Quiet refreshes (those triggered by Platform Events or by sibling actions) must **never** clear the previously-good state. Errors are silent; null responses are silent; only explicit user-initiated loads (`_loadInstance(false)`) may show error or empty branches.

```js
async _loadInstance(quiet) {
    if (!this.recordId) { this.isLoading = false; return; }
    if (!quiet) this.isLoading = true;
    try {
        const data = await getInstanceForRecord({ recordId: this.recordId });
        // Never clear instance on a quiet refresh.
        if (quiet && !data) return;
        const sig = this._buildRenderSig(data);
        if (quiet && sig === this._lastSnapshot) return;
        this._lastSnapshot = sig;
        this.instance = data || this.instance;  // never overwrite with null
        this._writeCache(this.instance);
        // …
    } catch (err) {
        if (!quiet) {
            this.instance = null;
            this.error = err.body?.message || 'Failed to load';
        }
        // On quiet error: keep previous state.
    } finally {
        this.isLoading = false;
    }
}
```

Initial loading state should also render **nothing**, not a loading placeholder. With `sessionStorage` hydration the user almost never sees the empty initial state; for the rare case where they do, an empty container is less disruptive than a "Loading…" flash.

```html
<!-- Old: visible loading placeholder. -->
<template lwc:if={isLoading}>
    <c-pulse-card><p>Loading workflow…</p></c-pulse-card>
</template>

<!-- New: render nothing during load. -->
<template lwc:if={isLoading}></template>
```

### 2.5 Optimistic local mutation

#### Problem

When a user clicks a button on a list item (accept/reject/star/etc.), the typical implementation is `await save(); await refreshApex(this.wiredResult);`. The `refreshApex` re-fires the wire, which reassigns the entire list array. LWC's diff is supposed to preserve unchanged items by `key`, but in practice the array-reference change combined with the @wire reactivity causes the whole list to re-render. Scroll position is lost.

#### Pattern

Update the local state for the changed item only — preserving same-reference for unchanged items — and let the asynchronous server confirmation come through the Platform Event channel without extra UI work.

```js
async handleStatusClick(event) {
    const id = event.currentTarget.dataset.id;
    const status = event.currentTarget.dataset.status;
    this._patchLocally(id, { status });   // only the clicked item changes
    try {
        await saveReview({ payload: { recommendationId: id, status } });
        // No refreshApex. Platform Event delivery confirms in the background.
    } catch (e) {
        // Server rejected — refetch to recover real state.
        await refreshApex(this.wiredResult);
    }
}

_patchLocally(id, patch) {
    if (!this.recommendations) return;
    const next = this.recommendations.map((r) => {
        if (r.id !== id) return r;        // SAME reference → LWC diff preserves DOM
        return this.decorate({ ...r, ...patch });
    });
    this.recommendations = next;
    // Reset render-snapshot so the next push delivery WILL update us.
    this._lastSnapshot = null;
}
```

Two key rules:

1. **Unchanged items return the same reference** (`return r;` not `return {...r};`) so LWC's diff sees no prop change.
2. **Reset the snapshot** so the next legitimate server push isn't suppressed by the sig diff.

### 2.6 User-edit tracking for field-style components

#### Problem

A component that lets the user type into form fields while server-side updates are also reassigning those fields has a race: every fetch reseeds field values, wiping in-flight edits. The naïve fix — "preserve any field whose value is already in `fieldValues`" — wipes the seed too, so once any user types in any field, the server's actual values can never re-populate.

#### Pattern

Track explicitly which keys the user has typed into. Server values win for everything else.

```js
@track fieldValues = {};
_userEditedKeys = new Set();

handleFieldChange(event) {
    const key = event.currentTarget?.dataset?.fieldKey;
    if (!key) return;
    const val = event.target?.value ?? event.detail?.value ?? '';
    this.fieldValues = { ...this.fieldValues, [key]: val };
    this._userEditedKeys.add(key);
}

async handleSave() {
    await saveFieldValues({ instanceId, values: this._collectForSave() });
    this._userEditedKeys.clear();   // edits are now persisted; server values can win again
    this._seedFieldValuesFromInstance();
}

_seedFieldValuesFromInstance() {
    const fields = this.instance?.phaseFields || [];
    const next = {};
    fields.forEach((f) => {
        if (this._userEditedKeys.has(f.key)) {
            // User is in-flight on this field — keep their value.
            next[f.key] = this.fieldValues[f.key];
        } else {
            // Server value wins.
            next[f.key] = f.currentValue == null ? '' : f.currentValue;
        }
    });
    this.fieldValues = next;
}
```

---

## 3. PulseRuntimeController contract fixes

### 3.1 `getInstanceForRecord` should not be `cacheable=true`

#### Problem

`@AuraEnabled(cacheable=true)` enables Lightning's framework-level caching. Imperative calls (`await getInstanceForRecord(...)`) hit that cache, not the server. A consumer that calls the method on every Platform Event delivery (or every user action) silently gets the stale first response. The UI claims to refresh but the data never changes.

#### Fix

```diff
- @AuraEnabled(cacheable=true)
- public static InstanceView getInstanceForRecord(Id recordId) {
+ @AuraEnabled
+ public static InstanceView getInstanceForRecord(Id recordId) {
```

The cacheable form was only correct for `@wire` consumers, which use `refreshApex` to invalidate. For imperative consumers (the dominant case in pulse-core's stepper), it's a bug.

If `@wire` consumers do exist and need the cache: leave `cacheable=true` and have the imperative path do `await refreshApex(handle); ...` instead. But this is the harder path and is not what the codebase currently does.

### 3.2 Fall back to Completed / Terminated instances

#### Problem

The query filters `Status__c = 'Active'`. After a workflow completes, the page shows "No active workflow for this record" and the user loses access to the journey, captured fields, conversation history, and all the other content tied to that instance.

#### Fix

```apex
public static InstanceView getInstanceForRecord(Id recordId) {
    if (recordId == null) return null;

    // Prefer Active.
    List<Workflow_Instance__c> instances = [
        SELECT Id, Current_State__c, Status__c, Stage_Status__c, /* … */
        FROM Workflow_Instance__c
        WHERE Parent_Record_Id__c = :recordId
          AND Status__c = 'Active'
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];

    // Fall back to the most recent terminal instance so the LWC keeps
    // rendering the journey (with all phases marked done) after completion.
    if (instances.isEmpty()) {
        instances = [
            SELECT Id, Current_State__c, Status__c, Stage_Status__c, /* … */
            FROM Workflow_Instance__c
            WHERE Parent_Record_Id__c = :recordId
              AND Status__c IN ('Completed', 'Terminated')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    if (instances.isEmpty()) return null;
    return buildInstanceView(instances[0]);
}
```

If both an Active and a Terminated instance exist for the same parent (rare), Active wins. In a single-active-workflow-per-parent system this is the right default.

Apply the same pattern to any other Apex method that drives a record-page LWC — for example, methods that return per-instance pending decisions, action lists, or extracted field values.

### 3.3 `PhaseFieldSummary.currentValue` populated from `Context_JSON__c`

#### Problem

When the journey card renders a completed phase, the read-only field grid needs to display values that were captured during that phase. If `PhaseFieldSummary` only carries `key` and `label`, the LWC has no way to display values without an extra round-trip — and it has no clean way to know when the value was captured.

#### Fix

Add `currentValue` to `PhaseFieldSummary`, populated from the workflow instance's `Context_JSON__c` at view-build time:

```apex
global class PhaseFieldSummary {
    @AuraEnabled public String  key;
    @AuraEnabled public String  label;
    @AuraEnabled public String  fieldType;
    @AuraEnabled public Boolean required;
    @AuraEnabled public Object  currentValue;  // ← new
}
```

When building each `PhaseOverviewView`, parse `Context_JSON__c` once and look up each field's value:

```apex
Map<String, Object> ctx = parseContext(inst.Context_JSON__c);
for (WorkflowContract.Field f : phase.fields) {
    PhaseFieldSummary s = new PhaseFieldSummary();
    s.key = f.key;
    s.label = f.label;
    s.fieldType = f.fieldType;
    s.required = f.required;
    s.currentValue = ctx.get(f.key);  // null when not yet captured
    phaseView.fields.add(s);
}
```

This unblocks several UX improvements (notably §5 below — completed phases that show their captured values inline) without requiring the LWC to make additional Apex calls.

---

## 4. Decision-queue UX patterns

The agent decision queue is the canonical surface for human-in-the-loop approvals. Three structural patterns make it materially better.

### 4.1 Chat-style "thinking" placeholder

#### Problem

After a user clicks Approve / Reject / Refine on a decision, the queue empties (optimistic removal — see §2.5) and the user sees nothing for ~5–15 seconds while the agent's queueable processes the next turn. This reads as "the system is broken" instead of "the system is working."

#### Pattern

Show an animated "thinking" placeholder immediately on every action, auto-clear when the next decision arrives or after a 60s safety timeout. The placeholder is purely client-side state; no server fetch is needed to drive it.

```js
@track thinking = false;
_thinkingTimer = null;

async handleApprove() {
    // … optimistic remove …
    this._setThinking(true);
    try {
        await approveDecision({ /* … */ });
    } catch (e) { /* … */ }
}

_setThinking(on) {
    if (on) {
        this.thinking = true;
        if (this._thinkingTimer) clearTimeout(this._thinkingTimer);
        this._thinkingTimer = setTimeout(() => { this.thinking = false; }, 60000);
    } else {
        this.thinking = false;
        if (this._thinkingTimer) {
            clearTimeout(this._thinkingTimer);
            this._thinkingTimer = null;
        }
    }
}

async _load(quiet) {
    // … fetch decisions …
    if (this.decisions.length > 0) this._setThinking(false);  // new decision arrived
}

get showThinking() { return this.thinking && !this.hasDecisions; }
```

Template:

```html
<template lwc:if={showThinking}>
    <c-pulse-card elevated>
        <div class="decision-thinking">
            <div class="thinking-avatar">
                <span class="thinking-sparkle">✦</span>
                <span class="thinking-initial">{personaInitial}</span>
            </div>
            <div class="thinking-text-wrap">
                <span class="thinking-text">{personaName} is thinking</span>
                <span class="thinking-dots">
                    <span class="thinking-dot"></span>
                    <span class="thinking-dot"></span>
                    <span class="thinking-dot"></span>
                </span>
            </div>
            <p class="thinking-subtext">Drafting the next step — this usually takes a few seconds.</p>
        </div>
    </c-pulse-card>
</template>
```

```css
.thinking-dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--pulse-purple, #7B2FF2);
    animation: thinking-bounce 1.2s infinite ease-in-out both;
}
.thinking-dot:nth-child(2) { animation-delay: 0.15s; }
.thinking-dot:nth-child(3) { animation-delay: 0.3s; }
@keyframes thinking-bounce {
    0%, 80%, 100% { transform: scale(0.6); opacity: 0.4; }
    40% { transform: scale(1); opacity: 1; }
}
```

### 4.2 Friendly point-and-click refine editor

#### Problem

The original Refine flow had three branches: email (typed inputs), record (key/value rows), and **raw JSON textarea** for everything else. Any tool other than `send_email` and `update_record` fell through to the raw JSON branch, which is unusable for non-technical reviewers.

#### Pattern

Add a fourth `mode: 'tool'` that produces typed editable rows from the proposal's argument shape, with humanized labels and per-field input types inferred from key name and value type. Same path serializes back to a JSON payload that matches the original shape (handles the agent's habit of wrapping arguments under a `fields:` key when emulating `update_record`).

```js
handleRefineOpen() {
    const args = this.active.previewData?.arguments || {};
    let draft;
    if (this.active.preview?.isEmail) {
        draft = { mode: 'email', email: { /* … */ } };
    } else if (this.active.preview?.isRecord) {
        draft = { mode: 'record', record: { /* … */ } };
    } else if (this.active.preview?.isTool) {
        draft = this._buildToolDraft(args);   // ← new
    } else {
        draft = { mode: 'raw', raw: JSON.stringify(args, null, 2) };
    }
    // …
}

_buildToolDraft(args) {
    let wrapped = false;
    let source = args && typeof args === 'object' ? args : {};
    if (source.fields && typeof source.fields === 'object' && !Array.isArray(source.fields)) {
        source = source.fields;
        wrapped = true;
    }
    const fields = [];
    for (const [k, v] of Object.entries(source)) {
        if (k === 'top_k') continue;
        const type = this._inferFieldType(k, v);
        fields.push({
            key: k,
            label: this._humanizeKey(k),
            value: v == null ? '' : (Array.isArray(v) ? v.join(', ') : String(v)),
            type,
            isText:     type === 'text',
            isNumber:   type === 'number',
            isDate:     type === 'date',
            isLongText: type === 'longtext',
        });
    }
    return { mode: 'tool', tool: { wrapped, fields } };
}

_inferFieldType(key, value) {
    const k = String(key).toLowerCase();
    if (typeof value === 'number') return 'number';
    if (/amount|gift|budget|cost|price/.test(k)) return 'number';
    if (/deadline|due_?date|expires?$|^date$|^.*_date$/.test(k)) return 'date';
    if (/notes|description|reasoning|body|message|long/.test(k)) return 'longtext';
    if (typeof value === 'string' && value.length > 100) return 'longtext';
    return 'text';
}

_buildRefinedJson(draft) {
    // …
    if (draft.mode === 'tool') {
        const out = {};
        for (const r of draft.tool.fields) {
            if (!r.key) continue;
            let v = r.value;
            if (r.type === 'number' && v !== '' && v != null) {
                const n = Number(v);
                if (!Number.isNaN(n)) v = n;
            }
            out[r.key] = v;
        }
        // Preserve the shape the agent originally sent so the next turn's
        // context isn't surprised by a different argument layout.
        return JSON.stringify(draft.tool.wrapped ? { fields: out } : out);
    }
    // …
}
```

Template:

```html
<template lwc:elseif={activeDraft.tool}>
    <ul class="decision-refine-tool-list">
        <template for:each={activeDraft.tool.fields} for:item="f" for:index="idx">
            <li key={f.key} class="decision-refine-tool-row">
                <div class="decision-refine-tool-head">
                    <span class="decision-refine-tool-label">{f.label}</span>
                    <button type="button" data-index={idx}
                            onclick={handleRefineToolRemove}>×</button>
                </div>
                <template lwc:if={f.isLongText}>
                    <textarea rows="3" data-index={idx}
                              onchange={handleRefineToolField}>{f.value}</textarea>
                </template>
                <template lwc:elseif={f.isNumber}>
                    <input type="number" data-index={idx}
                           value={f.value} onchange={handleRefineToolField} />
                </template>
                <template lwc:elseif={f.isDate}>
                    <input type="date" data-index={idx}
                           value={f.value} onchange={handleRefineToolField} />
                </template>
                <template lwc:else>
                    <input type="text" data-index={idx}
                           value={f.value} onchange={handleRefineToolField} />
                </template>
            </li>
        </template>
    </ul>
    <button type="button" onclick={handleRefineToolAdd}>+ Add field</button>
</template>
```

The same component should also support hiding internal/technical keys from preview (`top_k`, `recordId`, `objectType`) and unwrapping `{fields: {...}}` envelopes when displaying the read-only preview rows — both in the preview path and the refine editor.

### 4.3 Public lifecycle hooks (`@api startThinking`, `@api stopUpdates`)

#### Problem

Sibling components (a custom approval surface, a chat surface, etc.) sometimes trigger an action that should produce the same UX as if the user had acted in the decision queue itself — visible "thinking" feedback while the agent works, and a hard stop when the workflow reaches terminal.

#### Pattern

Two `@api` methods on the decision queue let any sibling participate cleanly:

```js
// Show the thinking placeholder. Caller fires this immediately on the
// action; the queue auto-clears it when the next decision arrives.
@api
startThinking() {
    this._setThinking(true);
}

// Cooperative shutdown — the parent stepper calls this when it detects
// terminal state, so any in-flight subscriptions and timers stop.
@api
stopUpdates() {
    this._stopped = true;
    this._unsubscribePush();
    if (this._thinkingTimer) {
        clearTimeout(this._thinkingTimer);
        this._thinkingTimer = null;
    }
    this.thinking = false;
}
```

The `_stopped` flag should be checked at the top of every load / subscription handler so any in-flight events become no-ops:

```js
async _load(quiet) {
    if (!this.instanceId) return;
    if (this._stopped) return;   // hard stop
    // …
}

_subscribePush() {
    if (this._empSubscription) return;
    if (this._stopped) return;
    // …
}
```

This contract pairs with the Platform Event push (§1) and the terminal kill-switch (§2.3) to give a clean shutdown story: parent detects terminal, calls `child.stopUpdates()`, child unsubscribes.

---

## 5. Side-by-side stepper layout

### Problem

The stock stepper renders agent rail + decision queue + journey card in a single vertical column. Reviewers scrolling through the journey's expanded content lose access to the agent's pending proposal at the top, and any height change in the proposal area pushes journey content down — visually disruptive while reviewing.

### Pattern

A two-column CSS grid: the agent surfaces on the left ("what's next"), the workflow journey on the right ("where we are"). Critically, **the columns are layout-isolated**: height changes on either side do not push the other.

```html
<div class="stepper-split">
    <div class="stepper-split-left">
        <!-- Agent rail + decision queue -->
    </div>
    <div class="stepper-split-right">
        <!-- Header + journey card -->
    </div>
</div>
```

```css
.stepper-split {
    display: grid;
    grid-template-columns: minmax(460px, 600px) 1fr;
    gap: var(--pulse-space-4, 16px);
    /* Stops the grid from sizing rows to the tallest column —
       the right column scrolls independently of the left's height. */
    align-items: start;
}
.stepper-split-left {
    display: flex;
    flex-direction: column;
    gap: var(--pulse-space-3, 12px);
    /* Reserve a stable minimum so going from "thinking" → empty → decision
       card doesn't change the column's height. The right column reads as
       perfectly stable underneath. */
    min-height: 280px;
}
.stepper-split-right {
    display: flex;
    flex-direction: column;
    gap: var(--pulse-space-3, 12px);
    min-width: 0;          /* lets long content wrap inside grid cell */
    align-self: start;     /* defensive — independent of left column height */
}

/* Stack on narrow viewports. */
@media (max-width: 1100px) {
    .stepper-split {
        grid-template-columns: 1fr;
    }
}
```

### Why these specific CSS rules

Three rules are doing the work, and skipping any one of them re-introduces the visual coupling:

1. **`align-items: start`** on the grid — without it, both columns stretch to match the tallest. Height changes on either side push the other.
2. **`min-height: 280px`** on the left column — when the agent's "thinking" placeholder appears or disappears, the column doesn't shrink/grow; the right column doesn't shift.
3. **`min-width: 0`** on the right column — without it, long unbreakable strings (URLs, identifiers, JSON dumps) push the column wider than its grid cell, breaking the layout.

### Avoid `position: sticky`

We tried sticky positioning on the left column. It does keep the proposal in view as the user scrolls the journey on the right, but **height changes on a sticky element trigger reflows in the rest of the document**. As soon as the left column got taller (decision card appeared) or shorter (thinking cleared), the page visibly shifted. Plain grid + `align-items: start` + `min-height` gives the same visual result without the reflow side effect.

---

## Implementation order (recommended)

A safe rollout sequence that limits risk and lets each layer be tested independently:

1. **`PulseRuntimeController` fixes (§3).** Bug fix; trivially backward-compatible. Land first.
2. **Render-signature diff + sessionStorage hydration in the existing stepper (§2.1, §2.2).** Refactor the LWC; no contract changes. Test by watching for noisy re-renders during background activity.
3. **Terminal kill-switch + never-null-out (§2.3, §2.4).** Wire the flags through. Test by completing a workflow and confirming the page goes silent.
4. **Side-by-side layout (§5).** CSS-only change; opt-in via a feature flag or layout slot. Optional.
5. **Decision-queue patterns (§4).** Land in order: thinking placeholder, then friendly refine editor, then `@api` lifecycle.
6. **Platform Event push (§1).** Last — depends on the LWC discipline above to be in place, otherwise events drive bad re-renders.
7. **Optimistic mutation + user-edit tracking (§2.5, §2.6).** Apply per-component as needed.

Steps 1-3 are pure pulse-core upgrades. Step 4 is a new optional layout. Steps 5-6 are new architecture. Step 7 is per-component.

## Backward compatibility checklist

- **Existing `@wire` consumers of `getInstanceForRecord`** will silently lose framework caching after §3.1. Audit and convert to imperative + `refreshApex` if any survive.
- **The new `currentValue` field on `PhaseFieldSummary`** is additive; existing consumers ignore it.
- **The Platform Event channel** is new; nothing breaks if no subscribers exist. The triggers are new; existing triggers on the same objects must coexist (check for trigger order if needed).
- **The CSS in §5** ships as a separate class set; existing components keep their single-column rendering until they opt into `stepper-split`.
- **The decision-queue `@api` methods (§4.3)** are additive; calling them is optional.
- **The `_terminalReached` / `_stopped` flags** are component-private; nothing external depends on them.

## What this proposal does NOT include

These patterns showed up during the same UX pass but are not generic enough — they need a generalization step before they belong upstream:

- **Hardcoded phase keys in template branches** (e.g., "show this custom panel on phase X"). These should land via a contract-side `displayHints` or `customComponent` field on phase config so any workflow can plug in.
- **Domain-specific Slack/webhook plumbing.** The underlying *pattern* — workflow-event-driven external notifications — could be a pluggable adapter framework, but designing that is its own proposal.
- **Hardcoded skipped-phase reasons.** The pattern of detecting skipped phases is generic; the reasons themselves need to come from contract metadata (`skipReason` on transition definitions, perhaps).

These three should be a follow-up proposal once §1-§5 are in place.

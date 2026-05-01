import { LightningElement, api, track } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';
import getInstanceForRecord from '@salesforce/apex/PulseRuntimeController.getInstanceForRecord';
import advanceInstance from '@salesforce/apex/PulseRuntimeController.advanceInstance';
import advanceInstanceWithFields from '@salesforce/apex/PulseRuntimeController.advanceInstanceWithFields';
import resolveAction from '@salesforce/apex/PulseRuntimeController.resolveAction';
import saveFieldValues from '@salesforce/apex/PulseRuntimeController.saveFieldValues';
import getFieldQuestions from '@salesforce/apex/PulseAgentController.getFieldQuestions';
import answerQuestion from '@salesforce/apex/PulseAgentController.answerQuestion';
import dismissFieldQuestion from '@salesforce/apex/PulseAgentController.dismissFieldQuestion';

const MAX_COLLAPSED_STEPS = 5;
const TERMINAL_STATUSES = ['Executed', 'Rejected', 'Failed', 'Cancelled'];

export default class PulseRecordStepper extends LightningElement {
    @api recordId;

    @track instance = null;
    @track error = null;
    @track advanceError = null;
    @track actionError = null;
    @track fieldError = null;
    @track isLoading = true;
    @track showModal = false;
    @track selectedSignal = null;
    @track payloadText = '';
    @track isAdvancing = false;
    @track timelineExpanded = false;
    @track activityExpanded = false;
    @track resolvingActionId = null;

    // Refine state — keyed by actionId
    @track refiningActionId = null;          // currently-expanded action, if any
    @track refineDraft = {};                 // { actionId: { mode, email:{to,subject,body}, record:{fields[]}, raw } }

    // Phase field form state — fieldKey -> current edited value (string|bool)
    @track fieldValues = {};
    // Tracks keys the user actually typed into. Without this, every quiet
    // refresh would either wipe in-flight edits (if we always reseeded from
    // the server) or never let server values back in (if we always preserved
    // local state). See proposal §2.6 for the user-edit-tracking pattern.
    _userEditedKeys = new Set();
    @track isSavingFields = false;

    // Collapse state for the journey view. The current phase auto-expands
    // on load; the user can toggle others. We track the set of phase keys
    // that are EXPLICITLY collapsed and, separately, explicitly expanded,
    // so toggling a non-current phase overrides the default-collapsed.
    @track expandedPhaseKeys = new Set();
    @track collapsedPhaseKeys = new Set();

    // Agent Mode: pending Ask_User decisions keyed by fieldKey. Renders as
    // a pill next to the matching form field instead of pushing the user
    // into the generic decision queue.
    @track fieldQuestions = {};        // fieldKey -> { decisionId, prompt, inputType, expanded }
    @track fieldQuestionBusyId = null; // decisionId currently answering/dismissing

    // Reactivity discipline (proposal §2): a render-signature-diff caches
    // the last-good signature so a quiet refresh whose payload is byte-for-
    // byte equivalent (modulo timestamps and other fields the template
    // doesn't bind to) doesn't trigger a re-render.
    _lastInstanceSnapshot = null;
    _refreshInFlight = false;

    // Terminal kill-switch (proposal §2.3): once we observe a workflow that
    // has reached a terminal state, every refresh path becomes a no-op and
    // we unsubscribe from the push channel. Belt-and-braces against late
    // server-side events.
    _terminalReached = false;

    // Push channel — Pulse_Workflow_Update__e (proposal §1). The stepper
    // subscribes once on mount and reloads ONLY when an event for THIS
    // workflow lands. Events are filtered by 15-char Instance_Id__c prefix
    // so we tolerate the 15-char vs 18-char id mismatch.
    _empSubscription = null;
    _empChannel = '/event/Pulse_Workflow_Update__e';

    connectedCallback() {
        loadPulseBrandTokens(this);
        // Hydrate from sessionStorage first (proposal §2.2). If the LWC
        // re-mounts (FlexiPage refresh, navigation back to record) the user
        // sees the journey at once instead of the empty placeholder while
        // we re-fetch in the background.
        this._hydrateFromCache();
        // CRITICAL: never subscribe if hydration already showed terminal.
        // Re-mounts of completed workflows must stay completely silent.
        if (this._terminalReached) {
            this._stopChildren();
            return;
        }
        this._loadInstance(true).then(() => {
            if (this._terminalReached) {
                this._stopChildren();
                return;
            }
            this._subscribePush();
        });
        onError(() => {});
    }

    disconnectedCallback() {
        this._unsubscribePush();
    }

    // ─── Cache + push ───────────────────────────────────────────

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
            this._lastInstanceSnapshot = this._buildRenderSig(data);
            this._seedFieldValuesFromInstance();
            // CRITICAL: flip isLoading off NOW so the empty-loading branch
            // never renders on a re-mount. The user sees the cached journey
            // instantly. The fresh fetch happens silently.
            this.isLoading = false;
            // If cache shows terminal, set the hard-stop flag immediately so
            // we never even subscribe.
            if (this._isTerminal(data)) this._terminalReached = true;
        } catch (e) { /* ignore corrupt cache */ }
    }

    _writeCache(data) {
        try {
            const k = this._cacheKey();
            if (!k || !data) return;
            sessionStorage.setItem(k, JSON.stringify(data));
        } catch (e) { /* quota / disabled storage */ }
    }

    _stopChildren() {
        const dq = this.template.querySelector('c-pulse-agent-decision-queue');
        if (dq && typeof dq.stopUpdates === 'function') dq.stopUpdates();
        // Persist a sessionStorage flag so a sibling component that re-mounts
        // independently (or in a race) can self-detect terminal and skip its
        // own subscription. See proposal §2.3.
        try {
            const wfId = this.instance && this.instance.instanceId;
            if (wfId) sessionStorage.setItem(`pulseTerminal:${wfId}`, '1');
        } catch (e) {}
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
            const anyOpen = phases.some(
                (p) => p.status === 'current' || p.status === 'upcoming'
            );
            if (!anyOpen) return true;
        }
        return false;
    }

    _subscribePush() {
        if (this._empSubscription) return;
        if (this._terminalReached) return;
        subscribe(this._empChannel, -1, (msg) => {
            if (this._terminalReached) return;
            const payloadInstanceId = msg && msg.data && msg.data.payload
                && msg.data.payload.Instance_Id__c;
            const myInstanceId = this.instance && this.instance.instanceId;
            if (!payloadInstanceId || !myInstanceId) return;
            // Compare 15-char prefixes — event payload is 18-char, prop may
            // be 15. Either form prefixes consistently.
            if (String(payloadInstanceId).substring(0, 15)
                !== String(myInstanceId).substring(0, 15)) return;
            this._doRefresh();
        }).then((s) => { this._empSubscription = s; })
          .catch(() => { /* fall back to user-action refresh */ });
    }

    _unsubscribePush() {
        if (!this._empSubscription) return;
        try { unsubscribe(this._empSubscription, () => {}); } catch (e) { /* ignore */ }
        this._empSubscription = null;
    }

    async _doRefresh() {
        if (this._refreshInFlight) return;
        if (this._terminalReached) return;
        this._refreshInFlight = true;
        try {
            await this._loadInstance(true);
        } finally {
            this._refreshInFlight = false;
        }
    }

    async _loadInstance(quiet) {
        if (!this.recordId) {
            this.isLoading = false;
            return;
        }
        if (!quiet) this.isLoading = true;
        try {
            const data = await getInstanceForRecord({ recordId: this.recordId });
            // Quiet refresh that returned null: keep previous state on screen
            // (proposal §2.4). A transient null must not unmount the journey.
            if (quiet && !data) return;
            this.error = null;
            const sig = this._buildRenderSig(data);
            // Identical render signature: skip the @track reassignment so
            // LWC's diff sees no work to do. This is what keeps the page
            // visually still during a noisy push stream. Field questions
            // are an independent stream (Ask_User decisions on a different
            // object), so we still refresh them even when the instance
            // signature is unchanged.
            if (quiet && sig === this._lastInstanceSnapshot) {
                await this._loadFieldQuestions();
                return;
            }
            this._lastInstanceSnapshot = sig;
            // Never overwrite previous good state with null on a quiet path.
            this.instance = data || this.instance;
            this._writeCache(this.instance);
            this._seedFieldValuesFromInstance();
            await this._loadFieldQuestions();
            // Set the kill-switch BEFORE async work so subsequent refresh
            // calls bail out immediately, then unsubscribe and tell children.
            if (this._isTerminal(data)) {
                this._terminalReached = true;
                this._unsubscribePush();
                this._stopChildren();
            }
        } catch (err) {
            // Quiet error: leave the previous good state on screen. Only an
            // explicit user-initiated load is allowed to surface error UI.
            if (!quiet) {
                this.instance = null;
                this.error = err.body?.message || 'Failed to load workflow instance';
            }
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Render-signature diff (proposal §2.1). Builds a small string from the
     * fields the template binds to. Excludes timestamps and any field the
     * template never reads, so a quiet refresh whose payload is byte-equal
     * modulo timestamps suppresses the re-render.
     */
    _buildRenderSig(data) {
        if (!data) return '';
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

    /**
     * Pull pending Ask_User decisions keyed by fieldKey so each form field
     * can render its own pill. Silent on error — the form still works
     * without agent questions.
     */
    async _loadFieldQuestions() {
        if (!this.instance?.agentEnabled || !this.instance?.instanceId) {
            this.fieldQuestions = {};
            return;
        }
        try {
            const list = await getFieldQuestions({ instanceId: this.instance.instanceId });
            const map = {};
            (list || []).forEach((q) => {
                if (q && q.fieldKey) {
                    map[q.fieldKey] = {
                        decisionId: q.decisionId,
                        prompt: q.prompt || '',
                        inputType: q.inputType || 'free_text',
                        expanded: this.fieldQuestions[q.fieldKey]?.expanded === true,
                    };
                }
            });
            this.fieldQuestions = map;
        } catch (e) {
            // Non-fatal — leave any existing pills in place.
        }
    }

    _seedFieldValuesFromInstance() {
        const fields = this.instance?.phaseFields || [];
        const next = {};
        fields.forEach((f) => {
            // User-edit tracking (proposal §2.6): server values win for
            // every field EXCEPT the ones the user is actively typing in.
            // Without this, agent-pushed currentValues couldn't repopulate
            // an empty seed once the form mounted.
            if (this._userEditedKeys.has(f.key)) {
                next[f.key] = this.fieldValues[f.key];
            } else {
                next[f.key] = f.currentValue == null ? '' : f.currentValue;
            }
        });
        this.fieldValues = next;
    }

    // ─── Computed ───────────────────────────────────────────────

    get hasInstance() { return this.instance != null; }
    get noInstance() { return this.instance == null; }
    // Agent Mode is only surfaced when the contract says so for the current
    // phase. When disabled the record layout is unchanged (back-compat).
    get agentEnabled() { return this.instance?.agentEnabled === true; }

    // When the agent is kicked or a decision is resolved we want to re-pull
    // the instance so any new Workflow_Action__c or phase transition shows
    // up in the stepper without a page refresh.
    handleAgentKicked() { this._loadInstance(); }
    get hasError() { return this.error != null; }
    get hasAdvanceError() { return this.advanceError != null; }
    get hasActionError() { return this.actionError != null; }
    get hasFieldError() { return this.fieldError != null; }
    get hasPendingActions() { return (this.instance?.pendingActionCount || 0) > 0; }
    get pendingActionLabel() {
        const count = this.instance?.pendingActionCount || 0;
        return `${count} pending`;
    }

    get instanceStatusVariant() {
        const s = this.instance?.status;
        if (s === 'Completed') return 'success';
        if (s === 'Failed' || s === 'Cancelled') return 'error';
        return 'purple';
    }

    // ─── Stage Status badge (header) ────────────────────────────
    // Stage_Status__c is the operational override for the current phase.
    // 'Active' is the default — we intentionally render nothing for it so
    // the header stays quiet when things are fine. Other values surface as
    // a category-colored badge next to the workflow name.

    get hasStageStatus() {
        const s = this.instance?.stageStatus;
        if (s == null) return false;
        if (typeof s !== 'string') return false;
        const trimmed = s.trim();
        if (!trimmed) return false;
        return trimmed.toLowerCase() !== 'active';
    }

    get stageStatusLabel() {
        const s = this.instance?.stageStatus;
        if (!s) return '';
        // Replace underscores with spaces so picklist API values render
        // as human-friendly text (Waiting_External → Waiting External).
        return String(s).replace(/_/g, ' ');
    }

    get stageStatusVariant() {
        const s = (this.instance?.stageStatus || '').toLowerCase();
        // Mapping aligned with the action-status engine so runtime badges
        // feel coherent across the record page.
        if (s === 'escalated') return 'error';
        if (s === 'on_hold' || s === 'paused') return 'warning';
        if (s === 'waiting_external') return 'purple';
        if (s === 'complete' || s === 'completed' || s === 'success') return 'success';
        return 'gray';
    }

    // ─── Journey (allPhases) ────────────────────────────────────

    get journey() {
        const phases = this.instance?.allPhases || [];
        if (!phases.length) return [];
        const currentKey = this.instance?.currentStateKey;
        return phases.map((p) => {
            const expanded = this._isPhaseExpanded(p, currentKey);
            const isCurrent = p.status === 'current';
            const isCompleted = p.status === 'completed' || p.status === 'terminal_success';
            const isFailed = p.status === 'terminal_failure';
            const isUpcoming = p.status === 'upcoming';
            const statusLabel = this._statusLabel(p.status, this.instance?.status);
            const statusClass = this._statusClass(p.status);
            const cardClass = [
                'journey-phase',
                isCurrent ? 'journey-phase-current' : '',
                isCompleted ? 'journey-phase-completed' : '',
                isFailed ? 'journey-phase-failed' : '',
                isUpcoming ? 'journey-phase-upcoming' : '',
                expanded ? 'journey-phase-expanded' : 'journey-phase-collapsed',
            ].filter(Boolean).join(' ');
            const chevronLabel = expanded ? 'Collapse phase' : 'Expand phase';
            const numberClass = 'journey-phase-num ' + (
                isCurrent ? 'journey-phase-num-current'
                    : isCompleted ? 'journey-phase-num-complete'
                    : isFailed ? 'journey-phase-num-failed'
                    : 'journey-phase-num-upcoming'
            );
            const completedAtText = p.completedAt
                ? this._formatDateTime(p.completedAt)
                : null;
            const checkpoints = this._buildCheckpointTrail(p);
            const fieldPreviews = (p.fields || []).map((f) => {
                const val = this._lookupPhaseFieldValue(p.key, f.key, isCurrent);
                return {
                    key: f.key,
                    label: f.label,
                    typeLabel: this._fieldTypeLabel(f.fieldType),
                    required: f.required,
                    value: val,
                    hasValue: val != null && val !== '',
                };
            });
            return {
                ...p,
                expanded,
                isCurrent,
                isCompleted,
                isFailed,
                isUpcoming,
                hasFields: (p.fields || []).length > 0,
                fieldPreviews,
                statusLabel,
                statusClass,
                cardClass,
                numberClass,
                chevronLabel,
                completedAtText,
                checkpointItems: checkpoints,
                hasCheckpoints: checkpoints.length > 0,
            };
        });
    }

    get hasJourney() { return this.journey.length > 0; }

    _isPhaseExpanded(phase, currentKey) {
        if (this.expandedPhaseKeys && this.expandedPhaseKeys.has(phase.key)) return true;
        if (this.collapsedPhaseKeys && this.collapsedPhaseKeys.has(phase.key)) return false;
        // Default: expand the current phase only.
        return phase.key === currentKey;
    }

    _statusLabel(phaseStatus, instanceStatus) {
        switch (phaseStatus) {
            case 'completed':         return 'Completed';
            case 'current':           return instanceStatus === 'Paused' ? 'On hold' : 'In progress';
            case 'upcoming':          return 'Upcoming';
            case 'terminal_success':  return 'Completed';
            case 'terminal_failure':  return 'Failed';
            default:                  return phaseStatus || '';
        }
    }

    _statusClass(phaseStatus) {
        const base = 'journey-phase-status';
        const variant = {
            completed:         'journey-status-completed',
            current:           'journey-status-current',
            upcoming:          'journey-status-upcoming',
            terminal_success:  'journey-status-completed',
            terminal_failure:  'journey-status-failed',
        }[phaseStatus] || 'journey-status-upcoming';
        return `${base} ${variant}`;
    }

    _lookupPhaseFieldValue(phaseKey, fieldKey, isCurrent) {
        // For the current phase, prefer the in-flight editor value (so the
        // preview row reflects what the user is typing). For other phases,
        // show any value Apex shipped on phaseFields (current phase only
        // today); a future backend enhancement can ship a per-phase value
        // map for completed phases.
        if (isCurrent && Object.prototype.hasOwnProperty.call(this.fieldValues, fieldKey)) {
            return this.fieldValues[fieldKey];
        }
        const detailed = (this.instance?.phaseFields || []).find((f) => f.key === fieldKey);
        return detailed ? detailed.currentValue : null;
    }

    _fieldTypeLabel(fieldType) {
        if (!fieldType) return 'Text';
        const normalized = fieldType.toString();
        if (normalized.toLowerCase() === 'longtextarea') return 'Long Text';
        if (normalized.toLowerCase() === 'datetime') return 'Date/Time';
        // Capitalize first letter, leave the rest (matches contract casing).
        return normalized.charAt(0).toUpperCase() + normalized.slice(1);
    }

    _buildCheckpointTrail(phase) {
        const checkpoints = phase.checkpoints || [];
        if (!checkpoints.length) return [];
        const active = phase.activeCheckpoint;
        const isCompleted = phase.status === 'completed' || phase.status === 'terminal_success';
        const isCurrent = phase.status === 'current';
        let activeIdx = -1;
        if (isCurrent && active) {
            activeIdx = checkpoints.findIndex((c) => c === active);
        }
        return checkpoints.map((label, idx) => {
            let state;
            if (isCompleted) state = 'done';
            else if (!isCurrent) state = 'upcoming';
            else if (activeIdx < 0) state = 'upcoming';
            else if (idx < activeIdx) state = 'done';
            else if (idx === activeIdx) state = 'active';
            else state = 'upcoming';
            const dotClass = `journey-checkpoint-dot journey-checkpoint-${state}`;
            const labelClass = `journey-checkpoint-label journey-checkpoint-label-${state}`;
            return {
                key: `${phase.key}:${idx}:${label}`,
                label,
                state,
                dotClass,
                labelClass,
                isLast: idx === checkpoints.length - 1,
                showSeparator: idx < checkpoints.length - 1,
            };
        });
    }

    _formatDateTime(dt) {
        if (!dt) return null;
        try {
            const d = new Date(dt);
            if (isNaN(d.getTime())) return String(dt);
            return d.toLocaleString(undefined, {
                month: 'short', day: 'numeric', year: 'numeric',
                hour: 'numeric', minute: '2-digit',
            });
        } catch (e) {
            return String(dt);
        }
    }

    // Phase actions rendering (current phase only)
    get phaseActions() {
        const raw = this.instance?.phaseActions || [];
        return raw.map((a) => {
            const preview = this._buildPreview(a);
            const isTerminal = TERMINAL_STATUSES.includes(a.status);
            const isAiTool = a.actionType === 'AI_Tool_Call';
            const isRefining = this.refiningActionId === a.actionId;
            const draft = this.refineDraft[a.actionId] || null;
            return {
                ...a,
                isPending: a.status === 'Pending',
                isReady: a.status === 'Ready',
                isBlocked: a.status === 'Blocked',
                isTerminal,
                statusVariant: this._statusVariant(a.status),
                requiredLabel: a.required ? 'Required' : 'Optional',
                blockedReason: a.blocked && a.dependsOn && a.dependsOn.length > 0
                    ? `Waiting on: ${a.dependsOn.join(', ')}`
                    : null,
                preview,
                resolving: this.resolvingActionId === a.actionId,
                refineEligible: isAiTool && a.status === 'Pending',
                refining: isRefining,
                draftMode: draft ? draft.mode : null,
                isEmailDraft: !!(draft && draft.mode === 'email'),
                isRecordDraft: !!(draft && draft.mode === 'record'),
                isRawDraft: !!(draft && draft.mode === 'raw'),
                draftEmail: draft ? draft.email : null,
                draftRecord: draft ? draft.record : null,
                draftRaw: draft ? draft.raw : '',
            };
        });
    }

    get hasPhaseActions() {
        return this.phaseActions.length > 0;
    }

    // Phase fields — one input per contract-declared field on the current phase
    get phaseFields() {
        const fields = this.instance?.phaseFields || [];
        return fields.map((f) => {
            const val = this.fieldValues[f.key];
            const type = (f.fieldType || 'Text');
            const normType = type.toLowerCase();
            const q = this.fieldQuestions[f.key] || null;
            const hasAgentQuestion = !!q;
            const agentQuestionBusy = hasAgentQuestion
                && this.fieldQuestionBusyId === q.decisionId;
            return {
                ...f,
                isText: normType === 'text',
                isLongText: normType === 'longtextarea',
                isNumber: normType === 'number' || normType === 'percent',
                isCurrency: normType === 'currency',
                isDate: normType === 'date',
                isDateTime: normType === 'datetime',
                isPicklist: normType === 'picklist',
                isCheckbox: normType === 'checkbox' || normType === 'boolean',
                value: val == null ? '' : val,
                checkedValue: val === true || val === 'true',
                picklistOptions: (f.picklistValues || []).map((v) => ({ value: v, label: v, selected: String(val) === v })),
                requiredBadge: f.required ? 'Required' : 'Optional',
                typeLabel: this._fieldTypeLabel(f.fieldType),
                hasAgentQuestion,
                agentQuestion: q,
                agentQuestionExpanded: hasAgentQuestion && q.expanded === true,
                agentQuestionBusy,
            };
        });
    }

    get hasPhaseFields() {
        return this.phaseFields.length > 0;
    }

    // Signal buttons only appear when the phase is ready to advance.
    get shouldShowSignals() {
        if (!this.instance) return false;
        if (!this.signals.length) return false;
        if (!this.hasPhaseActions) return true;
        return this.instance.phaseComplete === true;
    }

    get signals() {
        return (this.instance?.availableSignals || []).map((s) => ({
            ...s,
            label: this._signalLabel(s.signal),
        }));
    }

    get hasSignals() {
        return this.shouldShowSignals;
    }

    get historySteps() {
        const steps = this.instance?.history || [];
        if (!this.timelineExpanded && steps.length > MAX_COLLAPSED_STEPS) {
            return steps.slice(steps.length - MAX_COLLAPSED_STEPS);
        }
        return steps;
    }

    get hasHistory() { return (this.instance?.history || []).length > 0; }
    get isTimelineCollapsible() {
        return (this.instance?.history || []).length > MAX_COLLAPSED_STEPS;
    }

    get timelineToggleLabel() {
        if (this.timelineExpanded) return 'Show less';
        const total = (this.instance?.history || []).length;
        return `Show all ${total} steps`;
    }

    get activityToggleLabel() {
        const total = (this.instance?.history || []).length;
        return this.activityExpanded
            ? 'Hide activity'
            : `Show activity (${total} step${total === 1 ? '' : 's'})`;
    }

    // Activity is collapsed-by-default for journey instances; rendered
    // inline for legacy (journey-less) instances so back-compat is intact.
    get activityOrLegacyExpanded() {
        return !this.hasJourney || this.activityExpanded;
    }

    get payloadPlaceholder() { return 'JSON payload, e.g. key: value'; }

    get modalTitle() {
        return this.selectedSignal
            ? `Advance: ${this._signalLabel(this.selectedSignal)}`
            : 'Advance workflow';
    }

    // ─── Handlers ───────────────────────────────────────────────

    handleTogglePhase(event) {
        const key = event.currentTarget?.dataset?.phaseKey;
        if (!key) return;
        const currentKey = this.instance?.currentStateKey;
        const currentlyExpanded = this._isPhaseExpanded({ key }, currentKey);
        const nextExpanded = new Set(this.expandedPhaseKeys);
        const nextCollapsed = new Set(this.collapsedPhaseKeys);
        if (currentlyExpanded) {
            nextExpanded.delete(key);
            nextCollapsed.add(key);
        } else {
            nextCollapsed.delete(key);
            nextExpanded.add(key);
        }
        this.expandedPhaseKeys = nextExpanded;
        this.collapsedPhaseKeys = nextCollapsed;
    }

    handleSignalClick(event) {
        const signal = event.currentTarget.dataset.signal;
        this.selectedSignal = signal;
        this.payloadText = '';
        this.showModal = true;
    }

    handlePayloadChange(event) { this.payloadText = event.detail.value; }

    handleModalClose() {
        this.showModal = false;
        this.selectedSignal = null;
    }

    async handleAdvanceSubmit() {
        if (!this.selectedSignal || this.isAdvancing) return;
        this.isAdvancing = true;
        this.advanceError = null;
        try {
            const payloadJson = this.payloadText || null;
            const hasFieldEdits = this.hasPhaseFields;
            const result = hasFieldEdits
                ? await advanceInstanceWithFields({
                      instanceId: this.instance.instanceId,
                      signal: this.selectedSignal,
                      payloadJson,
                      idempotencyKey: null,
                      fieldValues: this._collectFieldValuesForSave(),
                  })
                : await advanceInstance({
                      instanceId: this.instance.instanceId,
                      signal: this.selectedSignal,
                      payloadJson,
                      idempotencyKey: null,
                  });
            if (result.success) {
                this.showModal = false;
                this.selectedSignal = null;
                if (result.refreshed) {
                    this.instance = result.refreshed;
                    this._seedFieldValuesFromInstance();
                }
            } else {
                this.advanceError = result.error || 'Advance failed';
            }
        } catch (err) {
            this.advanceError = err.body?.message || 'Unexpected error';
        } finally {
            this.isAdvancing = false;
        }
    }

    handleDismissError() { this.advanceError = null; }
    handleDismissActionError() { this.actionError = null; }
    handleDismissFieldError() { this.fieldError = null; }
    handleToggleTimeline() { this.timelineExpanded = !this.timelineExpanded; }
    handleToggleActivity() { this.activityExpanded = !this.activityExpanded; }

    async handleApproveAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Approve', null);
    }

    async handleRejectAction(event) {
        const actionId = event.currentTarget.dataset.actionId;
        await this._resolveAction(actionId, 'Reject', null);
    }

    // ─── Refine (edit AI draft before approving) ─────────────────

    handleRefineOpen(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const action = (this.instance?.phaseActions || []).find((a) => a.actionId === actionId);
        if (!action) return;

        this.refineDraft = {
            ...this.refineDraft,
            [actionId]: this._initDraftFromAction(action),
        };
        this.refiningActionId = actionId;
    }

    handleRefineCancel(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const next = { ...this.refineDraft };
        delete next[actionId];
        this.refineDraft = next;
        if (this.refiningActionId === actionId) {
            this.refiningActionId = null;
        }
    }

    handleRefineEmailTo(event) {
        this._mutateDraft(event, (d, val) => { d.email.to = val; });
    }
    handleRefineEmailSubject(event) {
        this._mutateDraft(event, (d, val) => { d.email.subject = val; });
    }
    handleRefineEmailBody(event) {
        this._mutateDraft(event, (d, val) => { d.email.body = val; });
    }
    handleRefineRecordField(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const idx = Number(event.currentTarget.dataset.index);
        const which = event.currentTarget.dataset.which; // 'key' | 'value'
        const val = event.target?.value ?? event.detail?.value ?? '';
        const draft = this.refineDraft[actionId];
        if (!draft || !draft.record) return;
        const rows = draft.record.fields.slice();
        const row = { ...rows[idx] };
        row[which] = val;
        rows[idx] = row;
        this.refineDraft = {
            ...this.refineDraft,
            [actionId]: { ...draft, record: { ...draft.record, fields: rows } },
        };
    }
    handleRefineRaw(event) {
        this._mutateDraft(event, (d, val) => { d.raw = val; });
    }

    _mutateDraft(event, applyFn) {
        const actionId = event.currentTarget.dataset.actionId;
        const val = event.target?.value ?? event.detail?.value ?? '';
        const draft = this.refineDraft[actionId];
        if (!draft) return;
        const next = JSON.parse(JSON.stringify(draft));
        applyFn(next, val);
        this.refineDraft = { ...this.refineDraft, [actionId]: next };
    }

    async handleRefineApprove(event) {
        const actionId = event.currentTarget.dataset.actionId;
        const draft = this.refineDraft[actionId];
        if (!draft) return;
        let refinedJson;
        try {
            refinedJson = this._buildRefinedJson(draft);
        } catch (e) {
            this.actionError = e.message || 'Refined payload is not valid JSON';
            return;
        }
        await this._resolveAction(actionId, 'Approve', refinedJson);
        // Clear the refine state after resolving
        const next = { ...this.refineDraft };
        delete next[actionId];
        this.refineDraft = next;
        if (this.refiningActionId === actionId) this.refiningActionId = null;
    }

    async _resolveAction(actionId, decision, refinedPayloadJson) {
        if (!actionId || this.resolvingActionId) return;
        this.resolvingActionId = actionId;
        this.actionError = null;
        // Fire chat-style "thinking" feedback in the decision queue so the
        // user sees activity while the agent processes the next turn
        // (proposal §4.1 / §4.3 — startThinking is the public hook).
        const dq = this.template.querySelector('c-pulse-agent-decision-queue');
        if (dq && typeof dq.startThinking === 'function') dq.startThinking();
        try {
            const result = await resolveAction({
                actionId,
                decision,
                notes: null,
                refinedPayloadJson: refinedPayloadJson || null,
            });
            if (!result.success) {
                this.actionError = result.message || 'Action failed';
            }
        } catch (err) {
            this.actionError = err.body?.message || err?.message || 'Unexpected error';
        } finally {
            this.resolvingActionId = null;
            // Quiet refresh — the platform-event push will also fire, but a
            // local refresh here makes the post-action UI converge faster.
            await this._doRefresh();
        }
    }

    // ─── Phase fields ───────────────────────────────────────────

    handleFieldChange(event) {
        const key = event.currentTarget?.dataset?.fieldKey
            || event.target?.dataset?.fieldKey;
        if (!key) return;
        let val;
        if (event.target?.type === 'checkbox') {
            val = event.target.checked;
        } else if (event.detail && Object.prototype.hasOwnProperty.call(event.detail, 'value')) {
            val = event.detail.value;
        } else {
            val = event.target?.value ?? '';
        }
        this.fieldValues = { ...this.fieldValues, [key]: val };
        this._userEditedKeys.add(key);
    }

    handleFieldCheckboxChange(event) {
        const key = event.currentTarget?.dataset?.fieldKey;
        if (!key) return;
        const checked = event.target?.checked ?? event.detail?.checked ?? false;
        this.fieldValues = { ...this.fieldValues, [key]: checked };
        this._userEditedKeys.add(key);
    }

    async handleSaveFields() {
        if (this.isSavingFields || !this.instance?.instanceId) return;
        this.isSavingFields = true;
        this.fieldError = null;
        try {
            const values = this._collectFieldValuesForSave();
            const refreshed = await saveFieldValues({
                instanceId: this.instance.instanceId,
                values,
            });
            if (refreshed) {
                this.instance = refreshed;
                // Edits are now persisted server-side — let future pushes
                // win over this local state (proposal §2.6).
                this._userEditedKeys.clear();
                this._seedFieldValuesFromInstance();
            }
        } catch (err) {
            this.fieldError = err.body?.message || err?.message || 'Failed to save fields';
        } finally {
            this.isSavingFields = false;
        }
    }

    // ─── Agent field-question pill handlers ─────────────────────

    handleAgentQuestionToggle(event) {
        const key = event.currentTarget?.dataset?.fieldKey;
        if (!key) return;
        const q = this.fieldQuestions[key];
        if (!q) return;
        this.fieldQuestions = {
            ...this.fieldQuestions,
            [key]: { ...q, expanded: !q.expanded },
        };
    }

    async handleAgentQuestionDismiss(event) {
        const key = event.currentTarget?.dataset?.fieldKey;
        if (!key) return;
        const q = this.fieldQuestions[key];
        if (!q || !q.decisionId) return;
        this.fieldQuestionBusyId = q.decisionId;
        try {
            await dismissFieldQuestion({ payload: { decisionId: q.decisionId } });
            // Optimistically drop the pill; refresh will confirm.
            const next = { ...this.fieldQuestions };
            delete next[key];
            this.fieldQuestions = next;
            await this._loadInstance();
        } catch (e) {
            this.actionError = e.body?.message || e.message || 'Dismiss failed';
        } finally {
            this.fieldQuestionBusyId = null;
        }
    }

    async handleAgentQuestionUseValue(event) {
        const key = event.currentTarget?.dataset?.fieldKey;
        if (!key) return;
        const q = this.fieldQuestions[key];
        if (!q || !q.decisionId) return;
        const rawVal = this.fieldValues[key];
        if (rawVal === '' || rawVal == null) {
            this.actionError = 'Enter a value before confirming.';
            return;
        }
        this.fieldQuestionBusyId = q.decisionId;
        try {
            await answerQuestion({
                payload: {
                    decisionId: q.decisionId,
                    responseJson: JSON.stringify({ value: rawVal }),
                },
            });
            const next = { ...this.fieldQuestions };
            delete next[key];
            this.fieldQuestions = next;
            await this._loadInstance();
        } catch (e) {
            this.actionError = e.body?.message || e.message || 'Answer failed';
        } finally {
            this.fieldQuestionBusyId = null;
        }
    }

    _collectFieldValuesForSave() {
        const out = {};
        const fields = this.instance?.phaseFields || [];
        fields.forEach((f) => {
            if (!Object.prototype.hasOwnProperty.call(this.fieldValues, f.key)) return;
            const raw = this.fieldValues[f.key];
            if (raw === '' || raw == null) return;
            const t = (f.fieldType || 'Text').toLowerCase();
            if (t === 'checkbox' || t === 'boolean') {
                out[f.key] = raw === true || raw === 'true';
            } else if (t === 'number' || t === 'currency' || t === 'percent') {
                const n = Number(raw);
                out[f.key] = Number.isFinite(n) ? n : raw;
            } else {
                out[f.key] = raw;
            }
        });
        return out;
    }

    // ─── Helpers ────────────────────────────────────────────────

    _signalLabel(signal) {
        if (!signal) return '';
        return signal.charAt(0).toUpperCase() + signal.slice(1).replace(/_/g, ' ');
    }

    _statusVariant(status) {
        if (status === 'Executed') return 'success';
        if (status === 'Pending') return 'purple';
        if (status === 'Ready') return 'purple';
        if (status === 'Rejected' || status === 'Failed') return 'error';
        if (status === 'Blocked') return 'gray';
        if (status === 'Cancelled') return 'gray';
        return 'gray';
    }

    _buildPreview(action) {
        if (!action.requestJson) return null;
        let parsed;
        try { parsed = JSON.parse(action.requestJson); }
        catch (e) { return { kind: 'raw', raw: action.requestJson }; }

        if (action.toolKey === 'send_email' && parsed) {
            return {
                kind: 'email',
                isEmail: true,
                to: parsed.toAddress || parsed.to || '',
                subject: parsed.subject || '(no subject)',
                body: parsed.body || '',
            };
        }
        if (action.toolKey === 'update_record' && parsed) {
            const rows = [];
            if (parsed.field) rows.push({ key: parsed.field, value: String(parsed.value || '') });
            if (parsed.fields && typeof parsed.fields === 'object') {
                Object.keys(parsed.fields).forEach((k) => {
                    rows.push({ key: k, value: String(parsed.fields[k]) });
                });
            }
            return {
                kind: 'record',
                isRecord: true,
                objectType: parsed.objectType || '',
                recordId: parsed.recordId || '',
                rows,
                hasRows: rows.length > 0,
            };
        }
        return {
            kind: 'raw',
            raw: JSON.stringify(parsed, null, 2),
        };
    }

    _initDraftFromAction(action) {
        let parsed = null;
        try { parsed = action.requestJson ? JSON.parse(action.requestJson) : {}; }
        catch (e) { parsed = null; }

        if (parsed && action.toolKey === 'send_email') {
            return {
                mode: 'email',
                email: {
                    to: parsed.toAddress || parsed.to || '',
                    subject: parsed.subject || '',
                    body: parsed.body || '',
                },
                extras: Object.keys(parsed).reduce((acc, k) => {
                    if (!['toAddress', 'to', 'subject', 'body'].includes(k)) acc[k] = parsed[k];
                    return acc;
                }, {}),
            };
        }
        if (parsed && action.toolKey === 'update_record') {
            const fields = [];
            if (parsed.field) {
                fields.push({ key: parsed.field, value: String(parsed.value || '') });
            }
            if (parsed.fields && typeof parsed.fields === 'object') {
                Object.keys(parsed.fields).forEach((k) => {
                    fields.push({ key: k, value: String(parsed.fields[k]) });
                });
            }
            if (fields.length === 0) fields.push({ key: '', value: '' });
            return {
                mode: 'record',
                record: {
                    objectType: parsed.objectType || '',
                    recordId: parsed.recordId || '',
                    fields,
                },
            };
        }
        return {
            mode: 'raw',
            raw: action.requestJson
                ? (parsed ? JSON.stringify(parsed, null, 2) : action.requestJson)
                : '{}',
        };
    }

    _buildRefinedJson(draft) {
        if (draft.mode === 'raw') {
            try {
                const parsed = JSON.parse(draft.raw || '{}');
                return JSON.stringify(parsed);
            } catch (e) {
                throw new Error('Edited JSON is not valid: ' + e.message);
            }
        }
        if (draft.mode === 'email') {
            const out = { ...(draft.extras || {}) };
            if (draft.email.to) out.toAddress = draft.email.to;
            if (draft.email.subject != null) out.subject = draft.email.subject;
            if (draft.email.body != null) out.body = draft.email.body;
            return JSON.stringify(out);
        }
        if (draft.mode === 'record') {
            const out = {};
            if (draft.record.objectType) out.objectType = draft.record.objectType;
            if (draft.record.recordId) out.recordId = draft.record.recordId;
            const fields = {};
            (draft.record.fields || []).forEach((row) => {
                if (row.key) fields[row.key] = row.value;
            });
            out.fields = fields;
            return JSON.stringify(out);
        }
        return '{}';
    }
}

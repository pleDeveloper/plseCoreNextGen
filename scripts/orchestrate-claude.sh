#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
ORG_ALIAS="${ORG_ALIAS:-pulse-core-next-dev}"
DEVHUB_ALIAS="${DEVHUB_ALIAS:-PulseDevHub}"
WORKTREE_BASE="${WORKTREE_BASE:-/tmp/pulse-core-next-worktrees}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/.orchestration-logs}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypass}"
CLAUDE_STREAM_JSON="${CLAUDE_STREAM_JSON:-1}"
CLAUDE_LIVE_OUTPUT="${CLAUDE_LIVE_OUTPUT:-0}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-max}"
CLAUDE_FALLBACK_MODEL="${CLAUDE_FALLBACK_MODEL:-}"
CLAUDE_DISALLOWED_TOOLS="${CLAUDE_DISALLOWED_TOOLS:-Agent}"

LANES=(
  "lane-a|lane-a-runtime|prompts/lane-a-runtime.txt|lane-a: runtime + contract"
  "lane-b|lane-b-projection|prompts/lane-b-projection.txt|lane-b: projection + schema"
  "lane-c|lane-c-ai|prompts/lane-c-ai.txt|lane-c: ai + tools + hitl"
  "lane-d|lane-d-conversation|prompts/lane-d-conversation.txt|lane-d: conversation ingestion + extraction"
)

LANES_WAVE2=(
  "lane-c-fix|lane-c-fix|prompts/wave2-lane-c-fix.txt|wave2-c: unblock AI lane compile"
  "lane-b-fix|lane-b-fix|prompts/wave2-lane-b-fix.txt|wave2-b: unblock projection lane compile"
)

LANES_WAVE2B_TOOLING=(
  "lane-b-tooling|lane-b-tooling|prompts/wave2-lane-b-tooling.txt|wave2-b-tooling: Tooling API schema gateway"
)

LANES_WAVE2B_SPLIT=(
  "wave2b-split|wave2b-package-split|prompts/wave2b-package-split.txt|wave2b: split repo into six 2GP managed packages"
)

LANES_WAVE3A=(
  "wave3a-ui|wave3a-ui-foundation|prompts/wave3a-ui-foundation.txt|wave3a: UI foundation — primitives, Admin Studio shell, Poppins fonts"
)

LANES_WAVE3B=(
  "wave3b-builder|wave3b-workflow-builder|prompts/wave3b-workflow-builder.txt|wave3b: workflow builder canvas with live projection preview"
)

LANES_WAVE3C=(
  "wave3c-runtime|wave3c-runtime-surfaces|prompts/wave3c-runtime-surfaces.txt|wave3c: record stepper + action hub + runtime controller"
)

LANES_WAVE4A=(
  "wave4a-conv|wave4a-conversation-hub|prompts/wave4a-conversation-hub.txt|wave4a: conversation hub — review + accept AI-extracted facts"
)

LANES_WAVE5=(
  "wave5-sla|wave5-sla-bi|prompts/wave5-sla-bi.txt|wave5: Stage_Dwell__c + SLA heatmap + exit-time predictor"
)

LANES_WAVE6=(
  "wave6-admin|wave6-admin-studio-backfill|prompts/wave6-admin-studio-backfill.txt|wave6: Admin Studio backfill — AI Config, Integrations Hub, Settings panels"
)

LANES_WAVE7=(
  "wave7-library|wave7-pulse-library|prompts/wave7-pulse-library.txt|wave7: Pulse Library distribution — signed bundles + trust list + rollback"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/orchestrate-claude.sh <command>

Commands:
  preflight       Check CLI auth, repo, org, and prerequisites.
  setup-lanes     Create/update lane branches and worktrees.
  wave0           Run Wave 0 context lock + metadata foundation via Claude.
  wave1           Run Wave 1 lanes (A-D) in parallel via Claude.
  wave2           Run Wave 2 repair lanes (lane-c-fix + lane-b-fix) in parallel.
  merge-wave1     Merge Wave 1 lane branches into main in the defined order.
  merge-wave2     Merge Wave 2 fix branches into main.
  validate        Deploy + run local Apex tests. Set PKG=<name> to deploy one package.
  validate-each   Dry-run deploy each package independently and report per-package results.
  logs [target]   Tail orchestration logs.
                  target: all|wave0|wave2|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix
  logs-pretty [target]
                  Pretty-print Claude progress from logs (tools/thinking/stops).
                  target: wave0|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix
  all             Run: preflight -> setup-lanes -> wave0 -> wave1 -> merge-wave1 -> validate

Optional environment variables:
  CLAUDE_BIN      Path to Claude CLI binary (default: ~/.local/bin/claude)
  ORG_ALIAS       Scratch org alias (default: pulse-core-next-dev)
  DEVHUB_ALIAS    Dev Hub alias (default: PulseDevHub)
  WORKTREE_BASE   Base path for worktrees (default: /tmp/pulse-core-next-worktrees)
  LOG_DIR         Log output path (default: .orchestration-logs)
  CLAUDE_PERMISSION_MODE  Claude permission mode: bypass|auto (default: bypass)
  CLAUDE_UNSAFE           Backward-compatible override; set to 1 for bypass
  CLAUDE_STREAM_JSON      1 enables stream-json + partial messages in logs (default: 1)
  CLAUDE_LIVE_OUTPUT      1 mirrors Claude output to terminal via tee (default: 0)
  CLAUDE_MODEL            Claude model alias/name (default: opus)
  CLAUDE_EFFORT           Claude effort level: low|medium|high|max (default: max)
  CLAUDE_FALLBACK_MODEL   Optional fallback model (e.g., sonnet) for -p runs
  CLAUDE_DISALLOWED_TOOLS Comma/space list for --disallowedTools (default: Agent)
EOF
}

say() {
  printf '[orchestrator] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

claude_flags() {
  if [[ "${CLAUDE_UNSAFE:-0}" == "1" || "$CLAUDE_PERMISSION_MODE" == "bypass" ]]; then
    printf -- "--dangerously-skip-permissions"
  else
    printf -- "--permission-mode auto"
  fi
}

ensure_main_branch() {
  cd "$ROOT_DIR"
  current="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$current" != "main" ]]; then
    say "Switching to main branch from $current"
    git checkout main
  fi
}

run_claude_prompt() {
  local cwd="$1"
  local prompt_file="$2"
  local log_file="$3"
  local flags
  flags="$(claude_flags)"
  local -a cmd
  cmd=(
    "$CLAUDE_BIN" -p "$(cat "$prompt_file")"
    --model "$CLAUDE_MODEL"
    --effort "$CLAUDE_EFFORT"
  )

  if [[ -n "$CLAUDE_FALLBACK_MODEL" ]]; then
    cmd+=(--fallback-model "$CLAUDE_FALLBACK_MODEL")
  fi

  if [[ -n "$CLAUDE_DISALLOWED_TOOLS" ]]; then
    cmd+=(--disallowedTools "$CLAUDE_DISALLOWED_TOOLS")
  fi

  if [[ "$CLAUDE_STREAM_JSON" == "1" ]]; then
    cmd+=(--output-format stream-json --include-partial-messages --verbose)
  fi

  # shellcheck disable=SC2206
  cmd+=($flags)

  (
    cd "$cwd"
    if [[ "$CLAUDE_LIVE_OUTPUT" == "1" ]]; then
      "${cmd[@]}" 2>&1 | tee "$log_file"
    else
      "${cmd[@]}" >"$log_file" 2>&1
    fi
  )

  # Guardrail: Claude sometimes prints error text but exits 0.
  if grep -Eq '(^Execution error$|^Error: )' "$log_file"; then
    echo "Claude execution failed (see $log_file)" >&2
    return 1
  fi
}

preflight() {
  cd "$ROOT_DIR"
  require_cmd git
  require_cmd sf

  if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "Claude CLI not found at $CLAUDE_BIN" >&2
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not a git repository: $ROOT_DIR" >&2
    exit 1
  fi

  auth_json="$("$CLAUDE_BIN" auth status 2>/dev/null || true)"
  if ! printf '%s' "$auth_json" | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    echo "Claude is not authenticated. Run: $CLAUDE_BIN auth" >&2
    exit 1
  fi

  sf org display -o "$DEVHUB_ALIAS" --json >/dev/null
  sf org display -o "$ORG_ALIAS" --json >/dev/null

  say "Claude run profile: model=$CLAUDE_MODEL effort=$CLAUDE_EFFORT"
  if [[ -n "$CLAUDE_FALLBACK_MODEL" ]]; then
    say "Claude fallback model enabled: $CLAUDE_FALLBACK_MODEL"
  fi
  if [[ -n "$CLAUDE_DISALLOWED_TOOLS" ]]; then
    say "Claude disallowed tools: $CLAUDE_DISALLOWED_TOOLS"
  fi
  say "Preflight checks passed."
}

setup_lanes() {
  cd "$ROOT_DIR"
  mkdir -p "$WORKTREE_BASE"
  ensure_main_branch

  for lane in "${LANES[@]}"; do
    IFS='|' read -r lane_name branch _ _ <<<"$lane"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch "$branch"
    fi
    lane_dir="$WORKTREE_BASE/$lane_name"
    if [[ ! -d "$lane_dir/.git" && ! -f "$lane_dir/.git" ]]; then
      git worktree add "$lane_dir" "$branch"
    fi
  done

  say "Lane worktrees are ready under $WORKTREE_BASE"
}

wave0() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  log_file="$LOG_DIR/wave0.log"
  say "Running Wave 0 via Claude (log: $log_file)"
  run_claude_prompt "$ROOT_DIR" "$ROOT_DIR/prompts/wave0-context-lock.txt" "$log_file"

  say "Deploying Wave 0 changes to $ORG_ALIAS"
  sf project deploy start -o "$ORG_ALIAS"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "wave0: metadata foundation and context lock output"
  else
    say "No git changes detected after Wave 0."
  fi
}

run_lane() {
  local lane_name="$1"
  local branch="$2"
  local prompt_rel="$3"
  local commit_msg="$4"
  local lane_dir="$WORKTREE_BASE/$lane_name"
  local log_file="$LOG_DIR/${lane_name}.log"

  say "Starting $lane_name ($branch), log: $log_file"
  run_claude_prompt "$lane_dir" "$ROOT_DIR/$prompt_rel" "$log_file"

  (
    cd "$lane_dir"
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "$commit_msg"
    fi
  )
}

wave1() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/lane-a.log" "$LOG_DIR/lane-b.log" "$LOG_DIR/lane-c.log" "$LOG_DIR/lane-d.log"
  say "Follow logs with: ./scripts/orchestrate-claude.sh logs all"

  pids=()
  labels=()
  for lane in "${LANES[@]}"; do
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"

    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg" &
    pids+=("$!")
    labels+=("$lane_name")
  done

  failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      echo "Lane failed: ${labels[$i]} (see $LOG_DIR/${labels[$i]}.log)" >&2
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    echo "One or more Wave 1 lanes failed. Fix lane logs before merging." >&2
    exit 1
  fi

  say "Wave 1 lanes completed."
}

setup_wave2_lanes() {
  cd "$ROOT_DIR"
  mkdir -p "$WORKTREE_BASE"
  ensure_main_branch

  for lane in "${LANES_WAVE2[@]}"; do
    IFS='|' read -r lane_name branch _ _ <<<"$lane"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch "$branch"
    fi
    lane_dir="$WORKTREE_BASE/$lane_name"
    if [[ ! -d "$lane_dir/.git" && ! -f "$lane_dir/.git" ]]; then
      git worktree add "$lane_dir" "$branch"
    fi
  done

  say "Wave 2 lane worktrees are ready under $WORKTREE_BASE"
}

wave2() {
  setup_wave2_lanes
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/lane-c-fix.log" "$LOG_DIR/lane-b-fix.log"
  say "Follow logs with: ./scripts/orchestrate-claude.sh logs wave2"

  pids=()
  labels=()
  for lane in "${LANES_WAVE2[@]}"; do
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"

    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg" &
    pids+=("$!")
    labels+=("$lane_name")
  done

  failed=0
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      echo "Lane failed: ${labels[$i]} (see $LOG_DIR/${labels[$i]}.log)" >&2
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    echo "One or more Wave 2 lanes failed. Fix lane logs before merging." >&2
    exit 1
  fi

  say "Wave 2 lanes completed."
}

merge_wave2() {
  cd "$ROOT_DIR"
  ensure_main_branch

  git merge --no-ff lane-c-fix -m "merge wave2 lane-c-fix"
  git merge --no-ff lane-b-fix -m "merge wave2 lane-b-fix"

  say "Wave 2 branches merged into main."
}

setup_wave2b_tooling_lane() {
  cd "$ROOT_DIR"
  mkdir -p "$WORKTREE_BASE"
  ensure_main_branch

  for lane in "${LANES_WAVE2B_TOOLING[@]}"; do
    IFS='|' read -r lane_name branch _ _ <<<"$lane"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch "$branch"
    fi
    lane_dir="$WORKTREE_BASE/$lane_name"
    if [[ ! -d "$lane_dir/.git" && ! -f "$lane_dir/.git" ]]; then
      git worktree add "$lane_dir" "$branch"
    fi
  done

  say "Wave 2b-tooling lane worktree is ready under $WORKTREE_BASE"
}

wave2b_tooling() {
  setup_wave2b_tooling_lane
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/lane-b-tooling.log"
  say "Follow log with: ./scripts/orchestrate-claude.sh logs lane-b-tooling"

  for lane in "${LANES_WAVE2B_TOOLING[@]}"; do
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 2b-tooling lane completed."
}

setup_wave2b_split_lane() {
  cd "$ROOT_DIR"
  mkdir -p "$WORKTREE_BASE"
  ensure_main_branch

  for lane in "${LANES_WAVE2B_SPLIT[@]}"; do
    IFS='|' read -r lane_name branch _ _ <<<"$lane"
    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch "$branch"
    fi
    lane_dir="$WORKTREE_BASE/$lane_name"
    if [[ ! -d "$lane_dir/.git" && ! -f "$lane_dir/.git" ]]; then
      git worktree add "$lane_dir" "$branch"
    fi
  done

  say "Wave 2b-split lane worktree is ready under $WORKTREE_BASE"
}

wave2b_split() {
  setup_wave2b_split_lane
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave2b-split.log"
  say "Follow log with: ./scripts/orchestrate-claude.sh logs wave2b-split"

  for lane in "${LANES_WAVE2B_SPLIT[@]}"; do
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 2b-split lane completed."
}

setup_wave3_lane_inline() {
  # Takes lane descriptor pipe-string directly (bash 3.2 compatible — no local -n).
  cd "$ROOT_DIR"
  mkdir -p "$WORKTREE_BASE"
  ensure_main_branch

  IFS='|' read -r lane_name branch _ _ <<<"$1"
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch "$branch"
  fi
  local lane_dir="$WORKTREE_BASE/$lane_name"
  if [[ ! -d "$lane_dir/.git" && ! -f "$lane_dir/.git" ]]; then
    git worktree add "$lane_dir" "$branch"
  fi
  say "Wave 3 lane worktree ready: $lane_dir"
}

wave3a() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave3a-ui.log"

  for lane in "${LANES_WAVE3A[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave3a-ui"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 3a lane completed."
}

wave3b() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave3b-builder.log"

  for lane in "${LANES_WAVE3B[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave3b-builder"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 3b lane completed."
}

wave3c() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave3c-runtime.log"

  for lane in "${LANES_WAVE3C[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave3c-runtime"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 3c lane completed."
}

wave4a() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave4a-conv.log"

  for lane in "${LANES_WAVE4A[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave4a-conv"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 4a lane completed."
}

wave5() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave5-sla.log"

  for lane in "${LANES_WAVE5[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave5-sla"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 5 lane completed."
}

wave6() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave6-admin.log"

  for lane in "${LANES_WAVE6[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave6-admin"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 6 lane completed."
}

wave7() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/wave7-library.log"

  for lane in "${LANES_WAVE7[@]}"; do
    setup_wave3_lane_inline "$lane"
    IFS='|' read -r lane_name branch prompt_rel commit_msg <<<"$lane"
    say "Follow log with: ./scripts/orchestrate-claude.sh logs wave7-library"
    run_lane "$lane_name" "$branch" "$prompt_rel" "$commit_msg"
  done

  say "Wave 7 lane completed."
}

logs() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  local target="${1:-all}"

  touch "$LOG_DIR/wave0.log" "$LOG_DIR/lane-a.log" "$LOG_DIR/lane-b.log" \
        "$LOG_DIR/lane-c.log" "$LOG_DIR/lane-d.log" \
        "$LOG_DIR/lane-c-fix.log" "$LOG_DIR/lane-b-fix.log" \
        "$LOG_DIR/lane-b-tooling.log" "$LOG_DIR/wave2b-split.log" \
        "$LOG_DIR/wave3a-ui.log" "$LOG_DIR/wave3b-builder.log"

  case "$target" in
    all)
      tail -n 80 -F \
        "$LOG_DIR/wave0.log" \
        "$LOG_DIR/lane-a.log" \
        "$LOG_DIR/lane-b.log" \
        "$LOG_DIR/lane-c.log" \
        "$LOG_DIR/lane-d.log" \
        "$LOG_DIR/lane-c-fix.log" \
        "$LOG_DIR/lane-b-fix.log"
      ;;
    wave2)
      tail -n 120 -F \
        "$LOG_DIR/lane-c-fix.log" \
        "$LOG_DIR/lane-b-fix.log"
      ;;
    wave0|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix|lane-b-tooling|wave2b-split|wave3a-ui|wave3b-builder)
      tail -n 120 -F "$LOG_DIR/${target}.log"
      ;;
    *)
      echo "Invalid logs target: $target" >&2
      echo "Use: all|wave0|wave2|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix|lane-b-tooling|wave2b-split|wave3a-ui|wave3b-builder" >&2
      exit 1
      ;;
  esac
}

logs_pretty() {
  cd "$ROOT_DIR"
  mkdir -p "$LOG_DIR"
  local target="${1:-wave0}"
  local log_file="$LOG_DIR/${target}.log"

  case "$target" in
    wave0|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix)
      touch "$log_file"
      tail -n 120 -F "$log_file" | jq -Rr '
        (try fromjson catch empty) as $j
        | if ($j|type)!="object" then empty
          elif $j.type=="assistant" then
            ($j.message.content[]?
              | if .type=="tool_use" then
                  "[tool] " + (.name // "")
                  + (if (.input.description? // "") != "" then " - " + .input.description else "" end)
                else empty end)
          elif $j.type=="system" and $j.subtype=="task_started" then
            "[agent] started: " + ($j.description // "")
          elif $j.type=="stream_event"
               and $j.event.type=="content_block_start"
               and $j.event.content_block.type=="tool_use" then
            "[tool] " + ($j.event.content_block.name // "")
          elif $j.type=="stream_event"
               and $j.event.type=="content_block_delta"
               and $j.event.delta.type=="thinking_delta" then
            "[thinking] " + ($j.event.delta.thinking // "")
          elif $j.type=="stream_event"
               and $j.event.type=="message_delta"
               and ($j.event.delta.stop_reason != null) then
            "[stop] " + ($j.event.delta.stop_reason|tostring)
          elif $j.type=="result" then
            "[result] " + ($j.subtype // "done")
          else empty end
      '
      ;;
    *)
      echo "Invalid logs-pretty target: $target" >&2
      echo "Use: wave0|lane-a|lane-b|lane-c|lane-d|lane-c-fix|lane-b-fix" >&2
      exit 1
      ;;
  esac
}

merge_wave1() {
  cd "$ROOT_DIR"
  ensure_main_branch

  git merge --no-ff lane-a-runtime -m "merge lane-a runtime"
  git merge --no-ff lane-b-projection -m "merge lane-b projection"
  git merge --no-ff lane-c-ai -m "merge lane-c ai"
  git merge --no-ff lane-d-conversation -m "merge lane-d conversation"

  say "Wave 1 branches merged into main."
}

validate() {
  cd "$ROOT_DIR"
  local source_dir="packages"
  if [[ -n "${PKG:-}" ]]; then
    source_dir="packages/$PKG"
  fi
  sf project deploy start -o "$ORG_ALIAS" --source-dir "$source_dir"
  sf apex run test -o "$ORG_ALIAS" --test-level RunLocalTests --wait 30
}

validate_each() {
  cd "$ROOT_DIR"
  local failed=0
  for pkg_dir in packages/*/; do
    local pkg_name
    pkg_name="$(basename "$pkg_dir")"
    # Skip empty packages (no classes/objects beyond .gitkeep)
    local file_count
    file_count=$(find "$pkg_dir" -name '*.cls' -o -name '*.object-meta.xml' -o -name '*.permissionset-meta.xml' -o -name '*.field-meta.xml' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$file_count" -eq 0 ]]; then
      say "$pkg_name: skipped (empty)"
      continue
    fi
    local result
    result=$(sf project deploy start -o "$ORG_ALIAS" --dry-run --source-dir "$pkg_dir" --ignore-conflicts --json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result',{}); print(r.get('success'), r.get('numberComponentErrors'))")
    say "$pkg_name: $result"
    if [[ "$result" != "True 0" ]]; then
      failed=1
    fi
  done
  if [[ "$failed" -ne 0 ]]; then
    echo "One or more packages failed validation." >&2
    exit 1
  fi
  say "All packages validated successfully."
}

all() {
  preflight
  setup_lanes
  wave0
  wave1
  merge_wave1
  validate
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    preflight) preflight ;;
    setup-lanes) setup_lanes ;;
    wave0) wave0 ;;
    wave1) wave1 ;;
    wave2) wave2 ;;
    wave2b-tooling) wave2b_tooling ;;
    wave2b-split) wave2b_split ;;
    wave3a) wave3a ;;
    wave3b) wave3b ;;
    wave3c) wave3c ;;
    wave4a) wave4a ;;
    wave5) wave5 ;;
    wave6) wave6 ;;
    wave7) wave7 ;;
    merge-wave1) merge_wave1 ;;
    merge-wave2) merge_wave2 ;;
    validate) validate ;;
    validate-each) validate_each ;;
    logs) logs "${2:-all}" ;;
    logs-pretty) logs_pretty "${2:-wave0}" ;;
    all) all ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
ORG_ALIAS="${ORG_ALIAS:-pulse-core-next-dev}"
DEVHUB_ALIAS="${DEVHUB_ALIAS:-PulseDevHub}"
WORKTREE_BASE="${WORKTREE_BASE:-/tmp/pulse-core-next-worktrees}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/.orchestration-logs}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypass}"

LANES=(
  "lane-a|lane-a-runtime|prompts/lane-a-runtime.txt|lane-a: runtime + contract"
  "lane-b|lane-b-projection|prompts/lane-b-projection.txt|lane-b: projection + schema"
  "lane-c|lane-c-ai|prompts/lane-c-ai.txt|lane-c: ai + tools + hitl"
  "lane-d|lane-d-conversation|prompts/lane-d-conversation.txt|lane-d: conversation ingestion + extraction"
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
  merge-wave1     Merge lane branches into main in the defined order.
  validate        Deploy + run local Apex tests.
  all             Run: preflight -> setup-lanes -> wave0 -> wave1 -> merge-wave1 -> validate

Optional environment variables:
  CLAUDE_BIN      Path to Claude CLI binary (default: ~/.local/bin/claude)
  ORG_ALIAS       Scratch org alias (default: pulse-core-next-dev)
  DEVHUB_ALIAS    Dev Hub alias (default: PulseDevHub)
  WORKTREE_BASE   Base path for worktrees (default: /tmp/pulse-core-next-worktrees)
  LOG_DIR         Log output path (default: .orchestration-logs)
  CLAUDE_PERMISSION_MODE  Claude permission mode: bypass|auto (default: bypass)
  CLAUDE_UNSAFE           Backward-compatible override; set to 1 for bypass
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
  (
    cd "$cwd"
    "$CLAUDE_BIN" -p "$(cat "$prompt_file")" $flags >"$log_file" 2>&1
  )
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
  sf project deploy start -o "$ORG_ALIAS"
  sf apex run test -o "$ORG_ALIAS" --test-level RunLocalTests --wait 30
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
    merge-wave1) merge_wave1 ;;
    validate) validate ;;
    all) all ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

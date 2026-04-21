# Pulse Core Next: One-Command Automation

If you want this mostly hands-off, use the orchestrator script.

## 1) Authenticate Claude once

```bash
~/.local/bin/claude auth
~/.local/bin/claude auth status
```

You need `loggedIn: true`.

## 2) Run automated pipeline (Wave 0 + Wave 1 + merge + validate)

From repository root:

```bash
./scripts/orchestrate-claude.sh all
```

Default behavior: this runs Claude in bypass permissions mode.

## 3) If you want to force bypass mode explicitly

```bash
CLAUDE_UNSAFE=1 ./scripts/orchestrate-claude.sh all
```

Equivalent modern form:

```bash
CLAUDE_PERMISSION_MODE=bypass ./scripts/orchestrate-claude.sh all
```

Use bypass mode only in a trusted local dev environment.

## 4) If you want interactive permission mode

```bash
CLAUDE_PERMISSION_MODE=auto ./scripts/orchestrate-claude.sh all
```

## 5) Run phases separately (recommended first time)

```bash
./scripts/orchestrate-claude.sh preflight
./scripts/orchestrate-claude.sh setup-lanes
./scripts/orchestrate-claude.sh wave0
./scripts/orchestrate-claude.sh wave1
./scripts/orchestrate-claude.sh merge-wave1
./scripts/orchestrate-claude.sh validate
```

## 6) Logs

Logs are written to:

`./.orchestration-logs/`

If a lane fails in Wave 1, inspect lane logs there.

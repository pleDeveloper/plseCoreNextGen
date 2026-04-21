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
Also by default it runs with:
- model: `opus` (latest/strongest alias)
- effort: `max`

## 3) Watch Claude progress live (recommended)

In another terminal, run:

```bash
./scripts/orchestrate-claude.sh logs all
```

This tails:
- `wave0.log`
- `lane-a.log`
- `lane-b.log`
- `lane-c.log`
- `lane-d.log`

It shows streamed Claude output/events while orchestration is running.

For easier reading (tool actions + thinking summaries), use:

```bash
./scripts/orchestrate-claude.sh logs-pretty wave0
```

## 4) If you want to force bypass mode explicitly

```bash
CLAUDE_UNSAFE=1 ./scripts/orchestrate-claude.sh all
```

Equivalent modern form:

```bash
CLAUDE_PERMISSION_MODE=bypass ./scripts/orchestrate-claude.sh all
```

Use bypass mode only in a trusted local dev environment.

## 5) If you want interactive permission mode

```bash
CLAUDE_PERMISSION_MODE=auto ./scripts/orchestrate-claude.sh all
```

## 6) Run phases separately (recommended first time)

```bash
./scripts/orchestrate-claude.sh preflight
./scripts/orchestrate-claude.sh setup-lanes
./scripts/orchestrate-claude.sh wave0
./scripts/orchestrate-claude.sh wave1
./scripts/orchestrate-claude.sh merge-wave1
./scripts/orchestrate-claude.sh validate
```

## 7) Override model/effort explicitly (optional)

```bash
CLAUDE_MODEL=opus CLAUDE_EFFORT=max ./scripts/orchestrate-claude.sh all
```

Optional fallback if Opus is overloaded:

```bash
CLAUDE_MODEL=opus CLAUDE_EFFORT=max CLAUDE_FALLBACK_MODEL=sonnet ./scripts/orchestrate-claude.sh all
```

## 8) Logs

Logs are written to:

`./.orchestration-logs/`

If a lane fails in Wave 1, inspect lane logs there.

Optional: mirror Claude output directly into the orchestration terminal:

```bash
CLAUDE_LIVE_OUTPUT=1 ./scripts/orchestrate-claude.sh wave0
```

Note: for parallel wave1, live mirroring can interleave output from multiple lanes.

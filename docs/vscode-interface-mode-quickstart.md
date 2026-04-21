# Pulse Core Next: VS Code Interface Mode Quickstart

This quickstart lets you run parallel Claude sessions in VS Code interface mode using your existing git lane worktrees.

## Preconditions

1. Claude Code installed at:
   - `~/.local/bin/claude`
2. Scratch org already exists:
   - `pulse-core-next-dev`
3. Worktrees already created:
   - `/tmp/pulse-core-next-worktrees/lane-a` ... `lane-g`

## 1) Authenticate Claude once

Run in any terminal:

```bash
~/.local/bin/claude auth
~/.local/bin/claude auth status
```

You want `loggedIn: true` before starting lanes.

## 2) Open each lane in VS Code (macOS)

Your machine currently does not expose `code` on PATH, so use `open`:

```bash
open -na "Visual Studio Code" --args /tmp/pulse-core-next-worktrees/lane-a
open -na "Visual Studio Code" --args /tmp/pulse-core-next-worktrees/lane-b
open -na "Visual Studio Code" --args /tmp/pulse-core-next-worktrees/lane-c
open -na "Visual Studio Code" --args /tmp/pulse-core-next-worktrees/lane-d
```

Use four windows for Wave 1 parallel lanes.

## 3) Start Claude interface mode per lane

In each VS Code window terminal, run:

```bash
~/.local/bin/claude --ide
```

Then paste:

1. The lane preamble from:
   - `docs/claude-parallel-session-prompts.md`
2. The lane-specific prompt for that window (A, B, C, or D).

Before any lane sessions, run Wave 0 once from:
- `docs/claude-wave0-context-lock.md`

## 4) Lane ownership map (Wave 1)

- Lane A: workflow contract + runtime
- Lane B: projection + schema provisioning abstraction
- Lane C: AI provider + tools + HITL
- Lane D: conversation ingestion + extraction

Do not edit files outside lane ownership.

## 5) Commit in each lane worktree

Inside each lane window:

```bash
git add -A
git commit -m "lane-<x>: <summary>"
```

## 6) Merge lanes back on main (serial)

In your main repo (`/Users/damianmosiolek/pulse-nextgen`):

```bash
git checkout main
git merge --no-ff lane-a-runtime -m "merge lane-a runtime"
git merge --no-ff lane-b-projection -m "merge lane-b projection"
git merge --no-ff lane-c-ai -m "merge lane-c ai"
git merge --no-ff lane-d-conversation -m "merge lane-d conversation"
```

Then validate:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 30
```

## 7) Repeat for Wave 3 UI lanes

Open lanes E/F/G in separate VS Code windows and repeat the same pattern.

## Troubleshooting

1. `claude --ide` does not attach:
   - ensure only one IDE target is active for that terminal session
   - retry with plain `~/.local/bin/claude` if needed
2. Auth errors:
   - rerun `~/.local/bin/claude auth`
3. Salesforce command auth issues:
   - run commands with your configured aliases (`PulseDevHub`, `pulse-core-next-dev`)

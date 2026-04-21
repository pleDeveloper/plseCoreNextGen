# Git Workflow for Parallel Claude Lanes

Use this after `git init` baseline commit.

## 1) Create baseline branch

```bash
git branch -M main
```

## 2) Create lane branches

```bash
git branch lane-a-runtime
git branch lane-b-projection
git branch lane-c-ai
git branch lane-d-conversation
git branch lane-e-admin-ui
git branch lane-f-runtime-ui
git branch lane-g-conversation-ui
```

## 3) Create worktrees (parallel folders)

```bash
mkdir -p ../pulse-core-next-worktrees
git worktree add ../pulse-core-next-worktrees/lane-a lane-a-runtime
git worktree add ../pulse-core-next-worktrees/lane-b lane-b-projection
git worktree add ../pulse-core-next-worktrees/lane-c lane-c-ai
git worktree add ../pulse-core-next-worktrees/lane-d lane-d-conversation
git worktree add ../pulse-core-next-worktrees/lane-e lane-e-admin-ui
git worktree add ../pulse-core-next-worktrees/lane-f lane-f-runtime-ui
git worktree add ../pulse-core-next-worktrees/lane-g lane-g-conversation-ui
```

## 4) In each lane

1. Run Claude in that lane folder.
2. Keep changes within lane ownership.
3. Commit locally in that lane:

```bash
git add -A
git commit -m "lane-x: <short summary>"
```

## 5) Merge back to main in waves

Backend wave merge order:

```bash
git checkout main
git merge --no-ff lane-a-runtime -m "merge lane-a runtime"
git merge --no-ff lane-b-projection -m "merge lane-b projection"
git merge --no-ff lane-c-ai -m "merge lane-c ai"
git merge --no-ff lane-d-conversation -m "merge lane-d conversation"
```

UI wave merge order:

```bash
git merge --no-ff lane-e-admin-ui -m "merge lane-e admin ui"
git merge --no-ff lane-f-runtime-ui -m "merge lane-f runtime ui"
git merge --no-ff lane-g-conversation-ui -m "merge lane-g conversation ui"
```

## 6) Validate after each wave

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 30
```

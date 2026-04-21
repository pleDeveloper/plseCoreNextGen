# Pulse Core Next — Packaging Notes

## Package Model

All six packages are **2GP Managed**, share the single **`plse`** namespace, and are registered on the **PulseDevHub** Dev Hub org.

| Package | Directory | Dependencies |
|---|---|---|
| Pulse Core | `packages/pulse-core` | — |
| Pulse AI - Anthropic | `packages/pulse-ai-anthropic` | Pulse Core |
| Pulse Tools - Core | `packages/pulse-tools-core` | Pulse Core |
| Pulse Conversations - Core | `packages/pulse-conversations-core` | Pulse Core |
| Pulse Conversations - Recall | `packages/pulse-conversations-recall` | Pulse Core, Pulse Conversations - Core |
| Pulse Channels - Slack | `packages/pulse-channels-slack` | Pulse Core |

### Why Managed?

Managed 2GP packages hide Apex source from subscribers. This provides IP protection — subscribers cannot read, decompile, or modify the Apex implementation. Unlocked packages do not provide this protection.

### Why One Namespace?

Salesforce 2GP supports multiple managed packages under a single namespace within the same Dev Hub. Using `plse` for all packages avoids creating additional Developer Edition orgs for namespace registration. All packages share object definitions, CMDT namespacing, and permission-set naming under `plse__`.

## One-Time Setup: Create Package Records

The `sfdx-project.json` contains placeholder `0Ho...` aliases. Before building package versions, run these commands once against PulseDevHub to create the real package records:

```bash
sf package create -v PulseDevHub -n "Pulse Core"                    -t Managed -r packages/pulse-core                --no-namespace false
sf package create -v PulseDevHub -n "Pulse AI - Anthropic"          -t Managed -r packages/pulse-ai-anthropic        --no-namespace false
sf package create -v PulseDevHub -n "Pulse Tools - Core"            -t Managed -r packages/pulse-tools-core          --no-namespace false
sf package create -v PulseDevHub -n "Pulse Conversations - Core"    -t Managed -r packages/pulse-conversations-core  --no-namespace false
sf package create -v PulseDevHub -n "Pulse Conversations - Recall"  -t Managed -r packages/pulse-conversations-recall --no-namespace false
sf package create -v PulseDevHub -n "Pulse Channels - Slack"        -t Managed -r packages/pulse-channels-slack      --no-namespace false
```

Each command prints a real `0Ho...` package ID. Replace the corresponding placeholder in `sfdx-project.json` → `packageAliases`.

## Creating Managed-Beta Versions

After replacing all six aliases with real IDs:

```bash
# Core must be versioned first (other packages depend on it)
sf package version create -p "Pulse Core" -x -v PulseDevHub --wait 30

# Then extension packages (can be parallel)
sf package version create -p "Pulse AI - Anthropic" -x -v PulseDevHub --wait 30
sf package version create -p "Pulse Tools - Core" -x -v PulseDevHub --wait 30
sf package version create -p "Pulse Conversations - Core" -x -v PulseDevHub --wait 30

# Recall depends on Conversations - Core, so version that after Core + Conversations - Core
sf package version create -p "Pulse Conversations - Recall" -x -v PulseDevHub --wait 30

# Slack is empty today; version when content arrives
sf package version create -p "Pulse Channels - Slack" -x -v PulseDevHub --wait 30
```

The `-x` flag creates a managed-beta (not released) version suitable for dev iteration.

## Installing Managed-Beta in a Scratch Org

Install packages in dependency order into a fresh (unnamespaced) scratch org:

```bash
# 1. Core first
sf package install -p "Pulse Core@0.1.0-1" -o <scratch-alias> -w 10

# 2. Then extensions
sf package install -p "Pulse AI - Anthropic@0.1.0-1" -o <scratch-alias> -w 10
sf package install -p "Pulse Tools - Core@0.1.0-1" -o <scratch-alias> -w 10
sf package install -p "Pulse Conversations - Core@0.1.0-1" -o <scratch-alias> -w 10
sf package install -p "Pulse Conversations - Recall@0.1.0-1" -o <scratch-alias> -w 10
```

Use `sf package install --help` for additional options (security type, upgrade type, etc.).

## Cross-Package Visibility

Within 2GP managed packages sharing `plse`, a `public` Apex type in Package A is **not** visible to Package B at compile time. Only `global` types cross package boundaries. The interfaces and model classes that extensions implement or consume are declared `global` in Pulse Core:

- `PulseAiProvider`, `PulseAiModels`
- `PulseTool`, `PulseToolModels`
- `PulseConversationAdapter`, `PulseConversationModels`
- `SchemaDeploymentGateway` (and inner DTOs)

Runtime-internal classes (`WorkflowRuntime`, `HitlService`, `PulseAgentRunner`, etc.) remain `public` — extensions should not depend on them.

## Validation

From the repo root, validate that all source compiles together and each package compiles independently:

```bash
# All packages together
sf project deploy start -o <org-alias> --dry-run --source-dir packages --ignore-conflicts

# Each package individually
for pkg in pulse-core pulse-ai-anthropic pulse-tools-core pulse-conversations-core pulse-conversations-recall; do
  sf project deploy start -o <org-alias> --dry-run --source-dir "packages/$pkg" --ignore-conflicts
done

# Namespace-wall discipline check
./scripts/check-global-discipline.sh
```

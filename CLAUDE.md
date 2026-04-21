# Pulse Core Next (Repository Instructions for Claude)

This repository builds Pulse Core Next as a Salesforce-native workflow platform.

## Product Identity

- Product name: `Pulse Core Next`
- Namespace target: `plse`
- Legacy namespace `ple` is out of scope for new artifacts

## Architecture Non-Negotiables

1. JSON definition + native runtime state split
   - workflow contract in JSON (`pulse.workflow.v1`)
   - runtime state in reportable Salesforce objects

2. Strict surface boundary
   - admin configuration experience is separate from end-user runtime on record pages

3. Packaging model
   - managed 2GP core in `plse`
   - modular add-ons in separate packages

4. AI execution model
   - AI proposes tool calls
   - platform validates policy and executes
   - HITL supported and auditable

5. Security + integration posture
   - Named Credentials for external calls
   - no secrets in code/CMDT
   - Slack/ingress signature validation required

6. Extraction safety
   - conversation extraction results are suggestions first
   - no direct parent-field commit without verification flow

## Implementation Constraints

1. Never introduce new `ple` package artifacts.
2. Avoid hardcoded namespace prefixes in runtime logic.
3. Apex must be bulk-safe and governor-safe.
4. Keep changes scoped to the active lane/session.
5. Add tests with each backend subsystem.

## Primary Local References

- `docs/pulse-nextgen-architecture-review-and-build-plan.md`
- `docs/claude-orchestration-pulse-core-next.md`
- `docs/claude-parallel-session-prompts.md`
- `docs/claude-session-prompts-paste-ready.md`
- `docs/vscode-interface-mode-quickstart.md`

When these references conflict, prefer:
1. Architecture review/build plan
2. Orchestration playbook
3. Session prompt docs

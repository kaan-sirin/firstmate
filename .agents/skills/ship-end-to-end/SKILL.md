---
name: ship-end-to-end
description: >-
  Run FirstMate's approved two-phase end-to-end software shipping workflow. Use before dispatching a material direct or Relay-originated software ship task that needs one read-only preflight, one explicit approval, then autonomous implementation, review, CI, and a PR.
metadata:
  internal: true
---

# ship-end-to-end

Use this skill for a material software ship task.
Do not use it for a scout, a narrow read-only investigation, or an ordinary task that does not need this approval workflow.

## Phase 1 - read-only preflight

Inspect the request, repository, task, production, and fleet facts first.
Resolve every question that these sources can answer.
Do not start implementation, dispatch a worker, write production state, deploy, post externally, or change data.

Give one concise contract with the recommendation first.
Include the interpreted outcome, scope and non-goals, delivery and external-system boundaries, then put all remaining material questions in one group.
Do not ask obvious questions.

Create a JSON contract with these fields: `recommendation`, `outcome`, `scope`, `non_goals`, `delivery_boundary`, `external_boundaries`, and `questions`.
For a complete plan that the captain explicitly approved, set `complete_plan_approved` to `true`.
Create the typed record. For Slack, include the opaque source thread ID:

```sh
bin/fm-ship-end-to-end.sh preflight <task-id> --origin direct --contract <contract.json>
bin/fm-ship-end-to-end.sh preflight <task-id> --origin slack --slack-thread <thread-id> --contract <contract.json>
```

Report its fingerprint in the contract.
Wait for one explicit captain approval or correction.
For an explicitly approved direct complete plan, record the captain authority and evidence in the preflight command instead of asking a duplicate question.
The Relay bridge must create the private allowlisted approval record for Slack. Do not supply Slack authority or evidence.

## Phase 2 - approved execution

Approve only the same fingerprint:

```sh
bin/fm-ship-end-to-end.sh approve <task-id> --fingerprint <sha256> --authority direct-captain --evidence '<approval evidence>'
bin/fm-ship-end-to-end.sh approve <task-id> --fingerprint <sha256>
```

If the captain corrects the contract before approval, use `correct` and present the new fingerprint.
The durable preflight record declares this workflow. `fm-spawn.sh` verifies its current approved fingerprint before it creates an endpoint. It does not infer workflow use from brief text. A missing approval, corrected record, stale approval, mismatch, or untrusted Slack bridge record fails closed.

Then execute autonomously in an isolated worktree.
Keep normal engineering choices inside the approved contract.
Use the already selected delivery mode, yolo posture, review path, tests, CI monitoring, and PR flow.
Do not merge.

Ask again only for a new authority requirement, serious irreversible risk, agreed-outcome change, or a security, privacy, legal, or data-loss decision.
Production writes, deployments, external communication, destructive work, and data changes keep their own authority gates.

## Dashboard record

Use `bin/fm-dashboard.sh refresh` only as the canonical writer for `${FM_HOME}/data/dashboard.json`.
Consumers read that 0600 record only.
The existing watcher refreshes it on its heartbeat; do not add another daemon or parse pane text or Relay callback tails.
The executable header owns the schema and update mechanics.

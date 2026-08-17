---
name: ship-end-to-end
description: >-
  Run FirstMate's approved two-phase end-to-end software shipping workflow. Use before dispatching a direct or Relay-originated software ship task: one read-only preflight, one explicit approval, then autonomous implementation, review, CI, and a PR.
metadata:
  internal: true
---

# ship-end-to-end

Use this skill before dispatching a software ship task or promoting a scout into one.
Do not use it for a scout that remains read-only, a narrow read-only investigation, or an ordinary task with no worker dispatch.

## Phase 1 - read-only preflight

Inspect the request, repository, task, production, and fleet facts first.
Resolve every question that these sources can answer.
Do not start implementation, dispatch a worker, change project, production, or external data, deploy, or post externally.
The private preflight record is the only workflow state written before approval.

Give one concise contract with the recommendation first.
Include the interpreted outcome, scope and non-goals, delivery and external-system boundaries, then put all remaining material questions in one group.
Do not ask obvious questions.

Create a JSON contract with these fields: `recommendation`, `outcome`, `scope`, `non_goals`, `delivery_boundary`, `external_boundaries`, and `questions`.
For a complete plan that the captain explicitly approved, set `complete_plan_approved` to `true`.
Send the complete typed record through the Agent bridge's private submission path.
For direct work, publish an awaiting-approval record.
After one explicit approval, replace it with an approved record with the same fingerprint.
If the captain corrects the contract, publish a new awaiting-approval record with its new fingerprint and wait for an explicit approval of that record.
An explicitly approved complete plan can publish its approved record without a duplicate preflight question.
For Slack work, the Agent bridge verifies the allowlisted same-thread approval and publishes the already-authorized typed record.
Do not provide Slack origin, contract, authority, evidence, identity, or approval input to FirstMate.

## Phase 2 - approved execution

The durable preflight record declares this workflow. On initial dispatch, `fm-spawn.sh` verifies its current approved fingerprint before it creates an endpoint. On recovery, it re-verifies a recorded fingerprint, but a legacy ship task with no recorded workflow fingerprint continues under its existing delivery contract. It does not infer workflow use from brief text. For a task declared in this workflow, a missing approval, corrected record, stale approval on initial dispatch, or fingerprint mismatch fails closed.

Then execute autonomously in an isolated worktree.
Keep normal engineering choices inside the approved contract.
Use the already selected delivery mode, yolo posture, review path, tests, CI monitoring, and PR flow.
Do not merge.

Ask again only for a new authority requirement, serious irreversible risk, agreed-outcome change, or a security, privacy, legal, or data-loss decision.
Production writes, deployments, external communication, destructive work, and data changes keep their own authority gates.
A captain status or progress question is informational, not a stop instruction. Answer it, then continue the approved run through its current completion gate. Stop only for an explicit pause or cancel, a changed finish line, a required authority decision, or a genuine external blocker.

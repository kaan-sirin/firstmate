# Fast Repair

Fast Repair is an opt-in, per-task delivery exception for a confirmed narrow repair.
It does not change a project mode, its normal dispatch, its merge policy, or the handling of requests without the Fast Repair prefix.

## Invoke it

Use the exact request prefix `fast-repair: ` followed by the repair request.

Example:

```text
fast-repair: Correct the Secretary search result count after deleting one local draft.
```

`fast-repair:` without a following request, `Fast-repair:`, `fast repair:`, and `fast-repair :` do not activate Fast Repair.

The prefix requests an eligibility decision for that task only.

## Eligibility

Fast Repair requires typed evidence for all of these positive facts:

- A known end-user reproduction.
- A confirmed root cause.
- A narrow, isolated code change.

It also requires each of these exclusions to be explicitly `none`:

- Schema or migration change.
- Authentication change.
- Permission or authorization change.
- Secret handling change.
- Financial behavior change.
- Legal or compliance behavior change.
- External side-effect change.

An absent, empty, unknown, ambiguous, false, or otherwise different value refuses Fast Repair.
Agent confidence is not evidence.
The refusal names the condition that was not proven, and the request returns to normal intake with the project's existing delivery rules.
An eligible Fast Repair does not create a scout or add plan, design, CEO, engineering, or other review workflows.

The exact typed interface and evidence record are owned by `bin/fm-fast-repair.sh --help`.

## Delivery

Eligible work uses the built-in Codex profile `gpt-5.6-luna` with `medium` effort.
An explicit conflicting task profile refuses instead of being replaced.
The task always has `yolo=off`, so captain approval remains the only merge authority.
Fast Repair never enables auto-merge.

The repair must add a regression test that reproduces the defect and must pass focused module tests.
`bin/fm-fast-repair.sh evidence` executes and records both gates.
Missing or failed evidence blocks direct PR publication.

After those gates pass, `bin/fm-fast-repair.sh publish-pr` opens and registers the direct PR immediately.
The worker then starts the broader test command while the new PR's checks run concurrently.
Broader-test failures are recorded and surfaced as an open PR that is not green.
The Fast Repair progress check also surfaces failed PR checks.
A PR is not called ready or green until the broader test and all required PR checks pass.

The Fast Repair progress check runs about every 20 seconds only while durable task metadata records an eligible Fast Repair task.
It does not change ordinary task polling, stale handling, watcher behavior, or global defaults.

## Examples

Eligible request:

```text
fast-repair: Fix an off-by-one count in the already reproduced Secretary deletion view; the root cause is one stale in-memory filter, the one-module patch has no schema, auth, permission, secret, financial, legal, or external-effect change.
```

Refused request:

```text
fast-repair: Add an audit field when a Secretary record is deleted.
```

This is refused because it changes schema and external behavior, so it follows the normal project path.

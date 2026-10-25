# Durable native reboot requests

This interface is an automation primitive, not owner approval. Do not run these
commands on a live host without the parent's separately approved readiness,
controller continuity, wave and window. Source tests use fake commands and
ordinary disposable directories, never real reboot or storage operations.

## Commands

    nest reset reboot ID --plan --format=json
    nest reset reboot ID --execute --format=json

Human output is pretty-printed JSON by default. Exactly one true `--plan` or
`--execute` is required. `--execute` is forbidden for every other reset action and
ordinary reset (including an explicit false execute option). Reboot accepts no
preparation/resume transaction, release, root generation, capacity policy,
evidence, cleanup, legacy resume, kernel, firmware, step, begin/end, noop, test or
dry-run selection. Explicit begin/end flags are rejected even at their ordinary
defaults. Unknown options and extra positional arguments follow strict Thor
validation. IDs must match `[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}`; absent or malformed
records are errors, not candidates for creation or recovery.

Plan is read-only: it creates no lock, directory or receipt, and launches no
reboot command. It returns the normal safe transaction report plus:

* `read_only: true`
* `reboot_eligible: true` and `reboot_reason: eligible` for an exact eligible
  prepared transaction on its original boot
* `reboot_eligible: false` and `reboot_reason: already_requested` when that same
  prepared boot already has a valid reboot receipt
* `reboot_eligible: false` and `reboot_reason: already_booted` after independently
  observing the exact changed target boot, expected next selection and retained
  rollback tree (also legal for accepted/finalized history still on that boot)

An unknown/unsafe identity, changed wrong boot, wrong next/rollback selection,
missing state, unsupported state or changed transaction during plan is a refusal,
not a safe ineligibility verdict. Plan is not a reservation: execute independently
rechecks everything under the nonblocking root-owned shared host lock.

## Eligibility and at-most-once boundary

Execute requires schema-1 `prepared` state, all six successful native phase
receipts and the current bound capacity accounting contract. Historical records
without capacity admission or with older accounting remain exportable but cannot
be upgraded by this command. The stored capacity policy and observation digests
are validated; reboot does not repeat preparation or manufacture fresh admission.

Completed-phase loading and reboot eligibility use the same native outcome
contract. Aggregate phase exits remain `null` or integer `0`. Checked commands
must have boolean `success: true` and a `null` or integer `0` native exit, except
that operation `puppet` in phase `kernel` may retain integer `2` (Puppet's changed,
successful detailed exit). No other operation or phase gains that exception;
Puppet `1`, `4` and `6`, nonzero aggregate exits, booleans, strings and floats
cannot describe completed successes. Existing successful unknown (`null`) exits
retain their meaning; they are not converted into measured zero exits.

This validation does not rewrite transaction records. Valid historical failed or
stopped outcomes remain exportable with their original command/aggregate exits;
they are not reboot-eligible and do not gain retry permission. Contradictory
completed outcomes fail closed on loading, even without a reboot receipt.
Installing this source changes the CLI policy digest, so existing preparations
may correctly refuse eligibility on identity drift. Never edit or normalize the
receipt to bypass that binding.

Both eligibility and execution require the original machine, hostname, pool and
shared-state GUID; original boot, current BE/tree and exact prepared target tree;
expected target next-boot selection; unmounted target; immutable source generation;
and installed CLI/filter policy identity. Native host observation independently
checks the mounted current tree, retaining the previous current tree as rollback.
Execute reobserves those invariants immediately before intent. It never repairs
bootfs, mounts, quota, holds or datasets. A new source installation can invalidate
the recorded CLI digest; this is a deliberate refusal, not a reason to weaken it.

Under the same lock, execute commits a write-ahead intent with file fsync, atomic
rename, directory fsync and readback, then reopens and validates it. Only afterward
may it launch exactly one argv-based `systemctl --no-block reboot` client. The
client has a 10-second monotonic deadline; timeout kills/reaps only that client,
not an already submitted systemd job. There is no shell, force, hard/poweroff,
SSH, fallback, second launch or supervisor lease.

ANY persisted reboot object forbids another execute, even after a nonzero return,
client launch failure, timeout, controller disconnect, process death or lost
completion write/readback. It also forbids resuming preparation. Concurrent
callers cannot submit twice. An intent whose process died before command launch
is intentionally indistinguishable from a submitted request with lost completion.
Do not remove/edit intent to retry. Use status/export and parent-owned recovery.
The lock may disappear across reboot; the receipt is the durable guard.

## Optional receipt and report semantics

Transaction schemas retain their meaning: schema 1 is preparation, schema 2 is
explicit acceptance/lifecycle. Old records have no `reboot` object. Neither
status/export, prepare, acceptance nor finalize adds one. A valid existing object
survives acceptance/finalization and historical export unchanged.

The optional private-record and safe-report `reboot` object has exactly these keys:

    schema: 1                         (integer)
    state: intent                     (or returned)
    boot_id: original prepared boot ID (string)
    requested_at: UTC ISO8601 ending Z (native timestamp)
    command: [systemctl, --no-block, reboot]

`returned` additionally requires exactly `finished_at` (UTC ISO8601 ending Z) and
`native_exit` (integer 0 through 255). Intent has neither completion field. All
loads, including export, acceptance and finalize, validate keys, types, command,
original boot binding, successful preparation provenance and timestamp ordering:
request cannot predate completed phases and finish cannot predate request.
No command output, exception, environment or private machine identity is included.

`reboot_requested` is three-valued:

* false without a reboot object: this CLI has no recorded request; it does not
  prove an external actor never rebooted the machine.
* null with `state: intent`: command completion is unknown, NOT false.
* true with `state: returned` and exit 0: systemd submission returned success,
  NOT proof that a boot occurred or that the host is healthy/accepted.
* false with `state: returned` and a nonzero exit: a known failed attempt,
  distinguishable from no intent by the preserved reboot object. Never replay.

`success` keeps its prepared/lifecycle meaning; it does not claim reboot or
acceptance. Execute action exit is independent: exit 0 requires an observed native
return 0 AND successful durable completion write/readback. Known failure or unknown
command/completion exits 2 with a safe report when it can be reopened. Validation,
initial intent write or unrecoverable readback failure exits 3 using the existing
error envelope; killed processes may emit no report. If completion rename happened
but durability/readback failed, a reopened report may show returned exit 0 while
the action conservatively exits nonzero. Do not reinterpret that exit as permission
to submit again. JSON errors do not include command exception/output material.

Status remains a separate read-only observation of boot ID, current/next and GUIDs.
For a record containing reboot intent, status also refuses drift of the original
source/installed policy, unsafe next selection or rollback identity; it checks the
original prepared invariants on the same boot and exact postboot invariants on a
changed boot. Historical export still does not require old BE trees to survive.
`observation.boot_changed` and `observation.expected_target_booted`, not reboot
intent, describe the actual sampled boot. Wrong/current boot observations cannot
satisfy acceptance. Acceptance still needs a changed exact target boot, rollback
identity and the existing bound AcceptanceEvidence. No automatic accept/finalize
occurs after a request; reboot is not an acceptance gate result.

## Parent compatibility boundary

Existing configuration report readers deliberately reject `reboot_requested !=
false`. They are NOT compatible with returned-success or ambiguous reports until
the parent adapts them. This source change does not edit configuration, deploy,
merge, promote, approve a real reboot or complete the original R01–R12 program.
Parent-owned integration must understand null versus false, optional attempted
failure, independent action exit and actual observed boot before any rollout.

The downloadable handoff includes actual fake-runner interface fixtures and full
local/CI results. Fixture execution proves source behavior, not hardware boot
acceptance. Tests cover intent crashes, launch/timeout/nonzero outcomes, lost
completion and readback, separate-process lock contention, malformed receipts,
identity/policy drift, true TTY behavior and preserved acceptance/finalization.

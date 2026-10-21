# Accepted reset lifecycle and parent collector contract

This is a source interface, not permission to reset, reboot or clean a live host.
The CLI does not collect catalogs, enumerate user sessions, issue a reboot, deploy
packages or provision shared state. The parent Bolt integration supplies trusted,
sanitized postboot evidence and retains its underlying artifacts. Source tests
use fake commands and ordinary disposable directories, never user ZFS storage.

## Commands

```sh
nest reset accept ID --evidence /absolute/collector.json --format=json
nest reset finalize ID --cleanup=owned --plan --format=json
nest reset finalize ID --cleanup=owned --format=json
nest reset status ID --format=json
nest reset report ID --format=json
```

`accept` records evidence; it never runs the checks for the collector. The evidence
file must be a regular non-symlink UTF-8 JSON file, at most 65,536 bytes. Unknown or
missing fields are refused. `finalize --plan` creates nothing, including no lock,
and is an advisory observation rather than authorization for a later deletion.
Mutation rechecks under the preparation lock. Unsupported policy values and
legacy phase/dry-run flags are refused. Legacy `--resume` remains skip-backup,
not transaction recovery. `--resume-transaction` cannot replay an accepted cycle.

## Explicit acceptance schema

The authoritative shape is [reset-acceptance-evidence.schema.json](reset-acceptance-evidence.schema.json),
JSON Schema draft 2020-12, evidence schema 1, kind `reset_acceptance_evidence`.
The implementation additionally enforces exact binding equality and semantic
constraints which JSON Schema alone cannot express:

- `transaction_id`, `release`, `host_identity_sha256` (SHA256 of machine ID),
  `pool_guid`, `shared_state` and ordered `target_tree` equal the recorded cycle.
- `observed_boot_id` equals the live observed boot, and differs from the original
  preparation boot. Current and next boot are the exact recorded target; the
  complete current GUID/mountpoint tree equals `target_tree`. The previous
  current A/B GUID tree must still exist unchanged. Hostname, machine ID, pool
  GUID and dedicated shared-state binding must be unchanged.
- Top-level `evidence_ref` and `evidence_sha256` identify the collector's durable
  evidence bundle. Every required named gate also has its own reference and
  lowercase 64-digit SHA256 digest. References are bounded non-secret artifact
  identifiers, not arbitrary logs, URLs with credentials or shell commands.
- Required gate keys are exactly `kernel`, `root_var`, `pools`,
  `network_dns_trust`, `normal_main_apply`, `converged_repeat`, `system_failures`,
  `user_managers`, `service_canaries`. Each `result` must be `pass`. Missing,
  unknown, unavailable and failed results cannot become acceptance.
- `normal_main_apply.native_exit` is integer 0 or 2, from a real ordinary main
  catalog, not noop or a narrow class apply. `converged_repeat.native_exit` is
  integer 0 from a separate ordinary repeat. These gates require distinct
  `evidence_ref` values; one prepared/success boolean is never sufficient.
- `system_failures` and `user_managers` also require `availability: available`,
  `inventory_complete: true` and `failures` arrays, at most 128 entries each.
  Every retained failure has `identity`, `disposition: explained_historical`,
  `evidence_ref`, `evidence_sha256`. Preserve the actual unit/manager identity
  and journal/rationale in the referenced evidence; do not reset failed counters.
- `user_managers.managers` lists the actual operational user managers (at most
  128, unique `identity` values), each with `availability: available`,
  `result: pass`, `evidence_ref`, `evidence_sha256`. Missing/unreachable buses
  must refuse acceptance, not disappear from the list. An empty list is legal
  only when a complete available inventory proves no operational managers; the
  collector owns this assertion, not the CLI. It must not infer zero from an
  absent session, failed bus query or an unavailable transport.

The collector owns the meanings of kernel-qualified policy, unique root/own var,
pool health, network/DNS/trust, actual normal catalog execution, complete system
and user-manager inventories and applicable service/hardware canaries. Its bundle
must record observed policy and any explicitly superseding kernel exception.
Physical UX remains unobserved until exercised when required by release policy;
a running unit or fixture is not proof of a responsive desktop. `service_canaries`
must not pass if a release-required owner UX gate remains unobserved. Non-applicable
canaries require an explicit policy disposition in the referenced evidence.
The CLI validates structure/binding and records supplied assertions; it neither
fetches referenced artifacts nor recomputes their digests nor authenticates the
collector. This is a trusted root/Bolt boundary, not signed attestation or a
replacement for the parent's evidence materialization and readback discipline.

## State, retention and report compatibility

Preparation continues to write schema-1 `pending|stopped|prepared` receipts.
Historical schema-1 reports keep their existing shape and preparation-success
meaning. The only supported schema transition is explicit `accept` of a complete
schema-1 prepared receipt to schema 2, after all current checks and supplied
acceptance evidence pass. Unknown schemas and lifecycle fields in schema 1 are
refused. An old prepared receipt is never implicitly accepted on upgrade.

Schema-2 states are `accepted`, `finalizing`, `finalized`. Fields added to private
receipts and sanitized reports are `acceptance` (`recorded_at`, `boot_id`, exact
validated `evidence`), `owned_candidates`, `cleanup_receipts`, and, when complete,
`finalized_at`. Reports retain preparation fields and `success` meaning preparation
completed, with separate `accepted` and `finalized` flags. `reboot_requested` stays
false: no reboot-intent interface is implemented or needed to observe changed boot.
This does not claim that an external actor never requested a reboot. Reports add
`snapshot_policy: retain_origins_no_reclamation_claim`. Consumers must explicitly
support report schema 2 rather than silently treating it as schema 1. Historical
exports check host/pool/state binding but do not require old BE trees to survive.
Status is a current observation; its nested accepted flag describes the recorded
acceptance boot, not a new collector run.

Repeated accept with byte-equivalent parsed evidence is read-only/idempotent after
fresh host checks; different evidence cannot overwrite an accepted assertion.
Finalization requires that same accepted boot and fresh exact target/previous-tree
observations. It preserves both ordinary A and B. The default preparation creates
no extra BE, so the ordinary successful case has `owned_candidates: []` and deletes
nothing. `--cleanup=owned` explicitly closes the retention boundary: only after
finalize may the next transactional prepare replace the old alternate. Pending,
stopped, prepared, accepted or interrupted-finalizing cycles block another cycle.
Before the next prepare, the latest finalized cycle's accepted boot and retained
A/B identities must still match. Finalizing does not itself replace either A/B.
No receipt garbage collector, force-unlock, retention bypass or abandonment command
is provided. Legacy/manual commands do not participate in this lifecycle lock;
operators must not run them concurrently or use them to bypass retention policy.

## Exceptional cleanup and conservative snapshot policy

There is deliberately no CLI `adopt`, name/prefix selection or arbitrary cleanup
candidate registration interface. Current production preparation creates no
extras and acceptance initializes an empty inventory. Existing historical/user
extras remain untouched. This lane does not add a rollback archive/extra creation
policy. A future native creation producer must durably record its actual creation
and checked GUIDs before using the reserved private ownership shape; hand-editing
receipts or supplying names in collector evidence is not such a producer.

The reserved record shape consumed by the cleanup engine is:

- Candidate: exact `dataset`, ordered `tree` rows `{dataset,guid,mountpoint}`,
  `creation` with exact `transaction_id`, `operation: create_extra`,
  `state: complete`, identical `tree`, and UTC `created_at`.
- At most 16 candidates, each at most 128 filesystem rows, one immediate extra BE
  under this host's recorded ROOT. A/B and their descendants can never qualify.
- Cleanup receipt: exact `dataset`, identical `tree`, `state: started|complete`,
  `started_at` and (only on completion) `finished_at`. The started receipt is
  atomically fsynced/read back before the first mutation, under the host flock.

Every candidate must still have its exact recorded GUID tree, not be current or
next, and have no mounted descendants or unexpected mount beneath `/mnt/NAME`.
All candidate-local snapshots are refused, even if apparently unheld: this
conservative subset necessarily refuses held/dependent/ambiguous snapshots too.
Origins outside the tree are retained; their names are never guessed or followed.
Deletion uses only `zfs destroy -r EXACT_DATASET`, never `-R`, force, automatic
unmount, origin retirement, quota changes or bootfs changes. The engine rechecks
identities immediately before mutation, then rechecks pool inventory and unchanged
boot selection afterward. Direct concurrent root/ZFS/manual mutation is outside
the flock contract and must be excluded operationally.

On restart, an absent tree is reconciled only against its exact started/complete
deletion receipt. A pool-wide successful filesystem inventory must prove all its
GUIDs absent; renamed GUIDs, partial trees, changed GUIDs, unexplained absence or
a reappeared completed candidate stop cleanup. Failed inventory is not absence.
Other still-recorded candidates may continue after successful reconciliation;
there is no discovery of additional candidates. Repeating a finalized cycle makes
no deletion or receipt writes. A changed boot/current/next/previous-tree still
refuses a repeat. BE removal is not evidence of origin snapshot retirement or
physical space reclamation. Snapshot retirement requires a separate explicit
policy/authorization and is not implemented here.

Native `beadm destroy` now refuses next-boot deletion by default, including the
manual CLI. Select the intended safe next boot explicitly before a manual destroy.
The library-only `reselect_next: true` preserves the former manual compatibility
path for deliberate callers, not the automated cleanup path. Checked failed
unmount already stopped destroy on accepted main; that regression and its native
exit remain covered. No activation-safety floor is weakened.

## Verification and remaining integration

RSpec covers parser routing, all required-gate missing/failed/unavailable cases,
changed binding refusals, A/B no-extra finalization, retention gating, unrelated,
mounted/held/dependent/GUID-changed candidates, next-boot deletion refusal and
failed unmount. Disposable-process SIGKILL tests exercise both deletion-before-
completion and completion-before-finalized boundaries, and real process flock
contention. Fake native cleanup checks never contact a user pool.

Parent integration still owns accepted source merge, exact package/source parity,
shared-state and immutable-generation provisioning, collector implementation and
artifact retention, release-specific retention/owner UX policy and separately
authorized installed-host/live canary tests. This source lane does not establish
operational reset, reboot, collector, exceptional creation or cleanup acceptance.

# Persisted reset preparation transactions (schema 1)

This is the R02 / CLI R10 preparation and report slice. It wraps the native
backup, mount, sync, kernel, unmount and activation phases with a host lock and
write-ahead receipts. It does not make ZFS promotion, rsync, shared `/boot` or
Puppet atomic, undo a partially completed phase, or implement fleet rollout.
Reboot and transaction abandonment are not supported commands. Explicit supplied
host acceptance and R04 finalization are documented in [reset-lifecycle.md](reset-lifecycle.md).
A prepared host is not a booted/accepted host. Schema-1 details below remain the
historical preparation/export contract; only explicit acceptance advances to schema 2.

## Supported commands

These are interface examples, not authorization to reset a live host. Replace
`DIGEST` with a real 64-character lowercase hexadecimal release digest (including
the `sha256:` prefix in the argument below), and choose the exact generation path
accepted by the publisher contract below.

```sh
nest reset --plan --release sha256:DIGEST --root-generation /nest/releases/GENERATION/HOST --format=json
nest reset --transaction update-ID --release sha256:DIGEST --root-generation /nest/releases/GENERATION/HOST --capacity-policy /POLICY.json --format=json
nest reset --resume-transaction update-ID --format=json
nest reset status update-ID --format=json
nest reset report update-ID --format=json
```

`--transaction` creates one new transaction, always from backup through activation.
`--resume-transaction` reads its original release, source and policy from the
receipt; optional supplied release/path must match exactly. IDs match
`[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}`. IDs are never recycled. An unresolved transaction
blocks creation of any other transaction on that host, not just reuse of its ID.
A completed preparation still requires separate reboot/acceptance and retention
policy before the next update. The CLI will refuse preparation while next boot
is not the current BE.

Legacy reset without transaction flags remains available with its existing
semantics. In particular, `--resume` still means only skip backup and retains
its warning; it is never translated into transaction recovery. Legacy phase
selectors, kernel/firmware-only, noop/test/dry-run and transaction options cannot
be combined. Use `--plan` without a transaction ID for observation. JSON does not
make a prepare command read-only. No transaction command performs sudo internally:
run it through the authorized root execution path.

`status` reads the receipt and current host/state/BE identities. A different boot
is an observation, never permission to replay any phase or reboot. It reports
whether the recorded target tree is now current, but never marks it accepted.
Unknown current/target GUIDs fail status. `report` exports the allowlisted stored
history after host/pool/shared-state identity checks; it deliberately does not
require historical BE GUIDs to remain present after later updates. Neither
command creates a lock, directory, receipt or report file. An unavailable source
publisher is not needed to export a retained report.

The plain planner remains independent of transaction state. With release/path
arguments it additionally performs transaction storage/source preflight and
returns `transaction_preflight`. This creates nothing, including `.lock`.
Without `--capacity-policy FILE`, capacity admission remains unknown, not
implicitly approved by preflight success. New preparation requires the bound
conservative gate documented in [reset-capacity.md](reset-capacity.md), including
its supported layouts, finite-limit refusals and historical non-replay rules.

## Mandatory shared-state provisioning contract for nest/config

Provision BEFORE enabling transactional reset. The CLI provisions nothing and
has no per-BE, NFS, network-service or temporary-directory fallback.

- `/var/lib/nest/updates` must be an exact mount of a dedicated host-imported ZFS
  filesystem, for example `POOL/crypt/nest-updates`. No component of its dataset
  name may be `ROOT`. Its ZFS `mountpoint` property must equal that exact path,
  `readonly=off`, and the actual mount must be `rw`.
- The containing pool must carry `org.nest:host-id` equal to this host's stable
  `/etc/machine-id` (32 lowercase hexadecimal characters). This is a local
  provisioning assertion, not a secret or a cryptographic ownership proof. The
  config owner must establish that the pool is host-local, imported on this host
  only, and not ephemeral or a network-only update-state dependency. The CLI
  verifies ZFS mount type, pool GUID and that host binding; it does not infer the
  physical transport behind block devices.
- The mounted directory must be root-owned mode `0700`; all ancestors must be
  canonical directories, root-owned, and not group/world-writable. Receipt and
  lock files are root-owned regular single-link files mode `0600`. Symlink,
  hardlink, unsafe permission, missing mount or missing directory means refusal.
  There is no user-supplied state path CLI flag or environment override.
- Mount this same dataset from both A and B, independently of their private
  `/var`, with ordering after the selected root's `/var` and before update
  clients. Source-manage boot/mount ordering through existing ZFS/CLI manifests.
  Do not clone this dataset into either ROOT tree, bind it into the alternate
  being copied, or let an inactive tree shadow its live mount. Status can observe
  an A/B boot switch only if that same shared filesystem remains mounted.
- Parent reset filters must exclude `/var/lib/nest/updates/` from both writing
  and deletion. The transactional copy also places an unconditional exclude for
  `/var/lib/nest/updates/***` before managed filters, as defense in depth. This
  does not waive provisioning or legacy-filter integration. Keep the shared
  mount out of recursive ROOT backup/clone scopes.
- Preserve this dataset, its host binding and receipts across package upgrades,
  boots, rollback and task cleanup. Do not run general cache retention against
  it. Never unlink `.lock` to break a live lock: a second inode would defeat
  flock. There is no automatic receipt garbage collector or unresolved-state
  override. Manual recovery must inspect the actual native state; deleting a
  receipt to force another destructive backup is not a recovery interface.

No mount, dataset, pool property, package or live host was provisioned by the
source tests. The parent config lane owns desired-state provisioning, packaging,
installation, startup ordering and installed-source parity verification.

## Immutable root-generation contract

The mutable `/nest/hosts/HOST` alias used by legacy reset is NOT admitted as a
transaction source. This initial safe implementation requires a canonical local
path mounted from one dedicated, versioned ZFS filesystem, with `readonly=on`,
actual mount `ro`, no descendant filesystems or submounts, and ZFS user property
`org.nest:release=sha256:DIGEST`. Bindings include dataset GUID, creation TXG,
canonical mount path and exact release digest. The publisher must freeze that
generation, never toggle it writable/reuse it under the same identity, and retain
it until the transaction no longer needs resume. This is trusted root/publisher
immutability, not a content signature. The CLI does not publish, pull, copy or
freeze a root generation itself.

Consequently the current mutable/network-host publication alone is insufficient:
transaction mode refuses it before backup. Parent integration must provide this
immutable local generation contract (and capacity for it); do not silently fall
back to copying the mutable remote alias. Remote immutable-generation protocols
are not implemented by this slice. No automatic extra replication/rehearsal is
introduced. Legacy copy continues to use its existing Falcon transport.

The generation must contain the host's profile, package CONTENTS, one module ABI
and kernel source expected by the ordinary installer. Paths for package metadata,
kernel source and modules must resolve inside the bound source; paths used for
kernel copy must also resolve inside the bound alternate. Absolute symlinks
escaping either bound root are rejected. The selected generation supplies root,
kernel source and modules consistently; transactional copy uses local paths,
never `root@falcon:` or a later mutable host alias.

## Crash, concurrency and resume rules

One nonblocking exclusive `flock` on the host-wide `.lock` covers identity
validation, receipt writes and all native phases. Another process fails rather
than waiting and guessing what completed. A killed process releases flock, not
its unresolved transaction. The CLI does not coordinate direct manual `beadm`
or legacy reset processes: operators/orchestrators must not run those outside
this lock concurrently with transaction preparation.

Before the first side effect of each phase: create its `started` receipt, write
a unique mode-0600 file, flush/fsync the file, rename over `ID.json`, fsync the
state directory, then reopen the exact target and compare the serialized record.
Any failure prevents the next phase. A successful phase is marked `complete`
only after native checked success and applicable postconditions; a native false
result records `failed` and stops. Completed phases are skipped on resume.

- Any incomplete/failed backup, mount, kernel, unmount or activation is an
  ambiguous/manual-recovery boundary. It is NEVER replayed. A crash after clone
  or promotion but before its completion receipt therefore stops safely, even
  when that strands an otherwise finished phase. No guessed clone discovery,
  destructive default backup, re-promotion, shared-boot replay or reboot occurs.
- Only incomplete/failed root `sync` can be retried. Resume first rechecks the
  original host name/machine ID, boot ID, pool GUID, current tree GUIDs, recorded
  target tree GUIDs/mountpoints, shared-state GUID/pool, immutable source identity,
  managed-filter hash and installed CLI library hash. Before backup it also binds
  the preexisting alternate tree GUIDs. Changed boot/policy/source/destination
  identities refuse all mutation.
- Every expected destination root/child must be mounted at its exact `/mnt/A`
  or `/mnt/B` location from its recorded dataset; stacked roots, unexpected
  shared mounts and read-only destinations refuse copy. Only the existing
  matching shared `/boot` bind is admitted; root copy unconditionally excludes
  `/boot/***`. Kernel installation remains a separate non-replayable side effect.
- Transactional root rsync uses `--checksum` and normal temporary-file replacement,
  not legacy `--inplace`. This repairs equal-size/equal-mtime partial content
  rather than assuming mtime proves completion. Fixed source, fixed filters,
  checksum comparison, private target datasets and protected shared paths are
  the idempotence contract. A repeated sync increments its attempt counter;
  the phase stores the latest attempt outcome rather than a full command log.
- `pending` means preparation has not durably finished, not that a process is
  necessarily alive. `stopped` means a checked native phase returned failure.
  `prepared` means all six preparation receipts exist; it is not postboot
  acceptance. On status, changed boot ID and the expected target GUID tree are
  observations only. Reboot-request or lifecycle entries in preparation `phases`
  are rejected rather than replayed; explicit schema-2 lifecycle receipts live
  outside that phase list, as documented in [reset-lifecycle.md](reset-lifecycle.md).

Receipts are atomic; native effects are not. There is no automatic quota change,
rollback deletion, admission rehearsal, restore or reboot. Existing activation
safety (disable inactive first; actual promotion before bootfs) remains unchanged.

## Receipt and export schema 1

The private `ID.json` has `schema: 1`, `kind: "reset_transaction"`, `id`, `state`,
`release`, `source`, `host`, `shared_state`, `policy`, `target_tree`, `created_at`,
`updated_at` and ordered `phases`. Strings are UTF-8. GUIDs and TXGs are decimal
strings, not floating-point numbers. Timestamps are UTC ISO8601 strings.

- `source`: `path`, `dataset`, `guid`, `creation_txg`, `release` strings.
- `host`: `machine_id`, `hostname`, `boot_id`, `pool_guid`, `current`, `target`,
  `next_boot` strings; `current_tree` and `alternate_tree` arrays of dataset
  identity rows. `alternate_tree` is the pre-transaction rollback identity.
- `shared_state`: `dataset`, `guid`, `pool_guid` strings.
- `policy`: `filter_sha256`, `cli_sha256` strings. The CLI content digest is the
  aggregate described in [reset.md](reset.md), not merely version `0.9.0`.
- `target_tree`: null until checked backup completes; then identity rows of
  `{dataset: string, guid: string, mountpoint: string}` for the new alternate.
- `phases`: prefix of `backup,mount,sync,kernel,unmount,activate`. Each row has
  `phase`, `state` (`started|failed|complete`), positive integer `attempt`,
  `started_at` and original `boot_id`. A completed/failed row adds `finished_at`,
  `native_exit` (integer/null), and `commands`: `{operation: string,
  native_exit: integer/null, success: boolean}`. Copy/Puppet/kexec native exits
  are checked; successful BE library operations may have null native exit and
  empty command rows. This is a phase receipt, not a full shell audit log.

Export kind is `reset_transaction_report`, schema 1. It projects those safe
bindings, phases and timestamps; excludes raw machine ID, replaces it with
`host_identity_sha256`, and omits command output, exception text, environment,
keys, journals, package CONTENTS and backup payloads. `success` means only state
`prepared`. For schema 1, `reboot_requested`, `accepted` and `finalized` remain
false; explicit acceptance transitions to schema 2. A false reboot flag is not
proof that an external actor never requested a reboot. Status adds `observation` with observed `boot_id`,
`boot_changed`, `current`, `next_boot`, `expected_target_booted` and
`accepted: false`. The stored prepare outcome remains separate from observation.

Exit 0 means prepare succeeded or the requested read/export operation succeeded.
A stopped prepare exits 2. Initialization, validation or unsafe ambiguity exits
3 with the existing schema-1 error envelope; killed processes need not emit JSON.
The durable receipt survives and is the recovery source. Unknown/invalid schema,
phase order, attempt binding or prepared completeness fails closed.

## Durable report handoff (CLI R10)

The small report can be regenerated from the durable host receipt after the
worker exits. Export to stdout via `nest reset report ID --format=json`; do not
export the private receipt itself. The existing inventory-backed transport must
explicitly materialize stdout on the supervisor/artifact filesystem when that
is a different host. Do not treat a remote path as a local artifact.

The parent must write a unique staged target, flush/fsync, rename/fsync its
artifact directory, reopen that exact copied target, parse schema/kind/id/release
and state, and reconcile its phase rows before declaring a final artifact.
Retain it in the existing durable task artifact store before workspace cleanup
or lifecycle completion. A nonexistent path or partial transport output is a
failure, not a reason to repeat reset to regenerate evidence. This CLI does not
change the broker's artifact boundary or claim fleet report delivery.

## Verification and acceptance boundary

`bundle exec rake` runs fake read-command inventories; real process SIGKILL at
native phase boundaries; real flock contention; identity/missing-state/symlink/
unsafe-permission/rename/write-failure tests; a simulated A/B boot switch with
unchanged shared receipts; and real zsh/rsync in disposable ordinary directories.
The copy fixture proves checksum repair and shared boot/state exclusions. The
artifact fixture explicitly copies a sanitized report to a separate supervisor
path, reopens it and removes worker state before reading it again. Tests never
create datasets, snapshots or fixture pools on user storage.

These are source/fixture proofs, not an actual ZFS A/B switch or live reset
certification. Package/install parity, shared-state/source provisioning, real
boot/mount ordering and approved canary reset/reboot/cleanup remain parent
integration/following phases. R04 source interfaces are in [reset-lifecycle.md](reset-lifecycle.md).
Do not deploy or mutate a real host to make these
unit tests pass.

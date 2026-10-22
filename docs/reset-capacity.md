# Conservative reset capacity admission

This is a source interface, not permission to prepare, reboot, change quotas,
remove rollback, publish generations or select real-host budgets. The JSON in
[reset-capacity-policy.fixture-only.json](reset-capacity-policy.fixture-only.json)
is for fake native inventories only. It must never be used on a real host.

## Interface and exact policy

```
nest reset --plan --release sha256:DIGEST --root-generation /LOCAL/GENERATION --capacity-policy /POLICY.json --format=json
nest reset --transaction ID --release sha256:DIGEST --root-generation /LOCAL/GENERATION --capacity-policy /POLICY.json --format=json
nest reset --resume-transaction ID --format=json
```

The planner without policy still reports unknown capacity and never creates a
lock, directory or receipt. Supplying policy requires release and generation.
A missing, invalid, denied or unknown admission prevents new preparation before
backup, clone, mount, copy, package/kernel or activation effects. Invalid or
refused release-aware preflight exits 3 with the initialization error envelope;
plain observation errors retain exit 2. Both JSON and human modes fail. There
is no boolean, force or legacy `--resume` bypass. Legacy nontransaction reset
and the meaning of `--resume` are unchanged.

[The schema](reset-capacity-policy.schema.json) has exactly these fields:

- `schema`: integer 1; `kind`: `nest_reset_capacity_policy`.
- `release`: `sha256:` plus 64 lowercase hexadecimal characters, matching the
  bound release-manifest digest, not the Stage 3 build-release identifier.
- `hostname`: the exact observed hostname; `host_identity_sha256`: lowercase
  SHA256 hex of the exact existing machine-id string (no newline).
- `pool_guid` and `source_guid`: positive decimal strings, never JSON numbers.
- `write_budget_bytes`, `promotion_budget_bytes`, `physical_reserve_bytes`,
  `slop_reserve_bytes`: nonnegative JSON integers; write budget must be positive.

Duplicate keys, extra fields (including commands, paths and verdicts), boolean
or float representations of integer fields, symlink/nonregular policy files,
and inputs larger than 16 KiB refuse. The canonical policy is a flat object
sorted lexicographically by key, serialized with compact JSON; its SHA256 is
stored as lowercase hex without a prefix. Caller whitespace/key order cannot
replace a bound policy. Budgets come from the parent release policy owner;
the CLI does not select live values or claim they bound native allocations.

## Supported accounting and deliberate refusals

The implementation inspects the actual `Beadm#create` recursive snapshot name
`beadm-clone-CURRENT-to-TARGET`, per-filesystem clones and later target promotion.
It never invokes an invented promote dry-run. Probes are read-only:

- `zpool get -Hp` size, allocated, free and freeing. Freeing is observed but
  never credited. Size must equal allocated plus free.
- An explicit whole-pool filesystem/volume inventory and `zfs get -Hp` available,
  used, usedbysnapshots, referenced, logicalreferenced, quota, refquota,
  reservation, refreservation and origin for every filesystem. Missing ancestors,
  incomplete properties, nonnumeric accounting and unsupported volumes refuse.
- Whole-pool snapshot name, used and clone dependencies. Duplicate/invalid
  inventories and failed native reads refuse, never become zero or success.
- Checked `du --apparent-size --block-size=1 --summarize --one-file-system` on the
  immutable local source. The lower bound is the maximum of this apparent size,
  referenced and logicalreferenced. Sparse holes and compression are not a way
  to admit a tiny write budget. No content checksum is claimed.

Supported admission is intentionally narrow: all observed filesystems in the
pool must have unlimited quota/refquota and zero reservation/refreservation.
This includes each inherited ancestor and the source. Even a generous finite
limit or unrelated reservation refuses as unknown: this version does not claim
a complete finite-limit/promotion algebra. It never converts quota to refquota,
relaxes reservations or uses deletion of the old alternate as headroom.

Current BE datasets must have no origin dependency. Before backup the exact
recursive snapshot name must be absent. Snapshot clones must be absent before
backup; retained alternate snapshots refuse. Before activation each target
origin must be the exact current-dataset clone snapshot, whose sole clone is
that target dataset. Target snapshots refuse because promotion can transfer
names and collide. Other ambiguous snapshot/clone dependencies refuse. Thus
some otherwise usable pools (including retained clone-dependent old A/B
layouts) deliberately need separate engineering inspection; there is no
cleanup-to-fit path in this CLI.

The conservative promotion accounting bound is the sum of current-tree `used`
values, which already includes snapshot/descendant usage and deliberately may
double-count descendants. Promotion budget must cover that bound. With all
finite logical limits/reservations refused, every observed filesystem's
`available` must still cover the sum of write plus promotion budgets. Logical
available is a separate native observation that incorporates native pool/slop
and logical availability rules; it is not replaced by physical free.

Physical free must independently cover write budget + promotion budget +
physical policy reserve + configured slop reserve. Configured slop is an
additional policy allowance, not an assertion that the CLI measured or froze
OpenZFS's internal dynamic slop calculation. No freeing, rollback deletion,
compression or sparse saving is credited. Full safe observations and their
compact-JSON SHA256 are retained; an observation exceeding 32 KiB refuses so
bounded receipts remain writable.

These are conservative configured-budget checks, not mathematical allocation
bounds, guaranteed promotion, allocation reservations or live authorization.
Metadata, concurrent writers, pool changes and ZFS implementation details can
still cause ENOSPC or native refusal. Checked native failures remain decisive.
The host flock protects transactions, not arbitrary external ZFS writers.

## Immutable source locality

In addition to canonical dedicated read-only ZFS mount, no child filesystems or
submounts, release/GUID/positive creation TXG and contained kernel/package paths,
the source pool must carry `org.nest:host-id` equal to the exact stable machine-id
and its filesystem `org.nest:host` must equal the observed hostname. The configured
mountpoint must equal the actual canonical mount. The source and every ancestor
must be root-owned directories, without group/world write permissions; symlink
aliases refuse. This is trusted root publisher/local host binding, not a content
signature or proof of physical block transport. The capacity-supported layout
also requires source and destination in the same pool.

The parent must publish/transfer, validate and seal a host-local generation and
set these properties; this work does not retrofit real generations or read
live identity material. Build publication properties `org.nest:build-release`
and `org.nest:expectations` do not substitute for `org.nest:release` here.

## Durable gate and historical records

New schema-1 preparation adds `capacity` with canonical `policy`, `policy_sha256`
and a bounded `checks` array (latest 16 observations). Each check carries verdict,
policy digest, safe observations, observations digest and, for fresh rechecks,
UTC `checked_at`. The existing atomic fsync/rename/readback and flock protect
these alongside the original release/host/source/policy bindings.

Recheck occurs on entry to unfinished preparation (including safe copy-only
resume), before copy, and before backup and activation. Backup/activation are
checked again after their durable started receipt, immediately before native
effects. A failed late read leaves that phase ambiguous, never permission to
replay. No completed phase is replayed to get accounting evidence. Changed
accounting may continue only if it still admits the original budgets; changed
policy cannot replace a bound unresolved transaction. Resume normally needs
no policy path because canonical policy lives in the receipt; an optional path
must canonicalize to exactly that policy. Native failures and safe-copy-only
resume rules remain unchanged.

Historical preparation without this gate remains readable/exportable. It cannot
resume mutation or be retrofitted with a policy: export the report and inspect
native state for manual recovery, never replay. Historical accepted/finalized
lifecycle and reports retain their previous semantics and do not require a
source publisher or new accounting. Reports never export raw machine-id.

All tests use fake native inventories, disposable ordinary directories, and
real process/flock/crash fixtures. They do not establish live promotion, A/B
boot, deployment or fleet readiness. The parent retains R01–R12 integration,
policy values, packaging, real-host read-only checks and the separately
Joy-approved first disruptive canary.

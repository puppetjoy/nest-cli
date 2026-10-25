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
- An explicit whole-pool filesystem/volume inventory with positive unique GUIDs
  and `zfs get -Hp` available,
  used, usedbysnapshots, referenced, logicalreferenced, quota, refquota,
  reservation, refreservation and origin for every filesystem. Volumes instead
  report used, usedbysnapshots, referenced, logicalreferenced, reservation,
  refreservation, volsize, volblocksize and origin; filesystem-only available,
  quota and refquota are not requested or synthesized for them. Missing ancestors,
  incomplete properties and nonnumeric accounting refuse.
- Whole-pool snapshot name, GUID, used, clone dependencies and userrefs (holds).
  Origins and clone lists must be reciprocal within the complete pool inventory.
  Duplicate/invalid
  inventories and failed native reads refuse, never become zero or success.
- Checked `du --apparent-size --block-size=1 --summarize --one-file-system` on the
  immutable local source. The lower bound is the maximum of this apparent size,
  referenced and logicalreferenced. Sparse holes and compression are not a way
  to admit a tiny write budget. No content checksum is claimed.

Supported admission uses the exact affected closure: current and selected target
trees, the immutable source, and every ancestor of those roots. Source/current/
target overlap refuses. Whole-pool typed inventory must match the host's exact
current/alternate tree names and GUIDs and the source GUID. A volume anywhere
inside this closure remains unsupported. Unrelated swap/fscache volumes and
sibling finite PVC limits/reservations are observed, not treated as affected
filesystem limits. Their allocations and reservations are never credited back.
Native affected `available` and whole-pool physical free remain independent gates.

Contract 3 supports finite quota/refquota only on strict shared ancestors of
BOTH bound current and target BE roots, including pool and ROOT ancestry. For
each such ancestor, `quota - used` (when quota is nonzero) and
`refquota - referenced` (when refquota is nonzero) must independently cover the
ENTIRE write plus promotion budgets. Negative headroom refuses. Quota uses native
used including descendants/snapshots; refquota uses native referenced, never
logicalreferenced or a sum of descendants. Zero means unlimited. This deliberately
overestimates demand even where promotion might not increase shared usage.

Every affected reservation/refreservation remains unknown/refused. Finite limits
on current/target roots or descendants, the immutable source or source-only
ancestors remain unknown/refused, even with ample headroom. Clone-root properties
and broader promotion algebra are not modeled. No quota is copied, changed or
cleared, no reservation is relaxed, and rollback deletion is never headroom.

Current BE datasets must have no origin dependency. Before backup the exact
recursive snapshot name must be absent. The preexisting bound alternate may
originate in corresponding current-tree snapshots (including the ordinary old
`beadm-clone-A-to-B` origins when current is B): each snapshot must have only
that exact alternate dataset as its clone, with reciprocal origin and matching
dataset GUIDs. Those origin snapshots are retained, not cleanup candidates.
Retained alternate snapshots refuse. Before activation each target
origin must be the exact current-dataset clone snapshot, whose sole clone is
that target dataset. Target snapshots refuse because promotion can transfer
names and collide. Shared, unknown, cross-tree or source-touching dependencies
refuse. Completely unrelated held snapshots and reciprocal clone trees are
reported without authorizing their deletion. Current origins still refuse;
there is no cleanup-to-fit path, origin deletion or new destruction behavior.

The conservative promotion accounting bound is the sum of current-tree `used`
values, which already includes snapshot/descendant usage and deliberately may
double-count descendants. Promotion budget must cover that bound. In addition
to supported shared-ancestor finite-limit checks, every affected filesystem's
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

New schema-1 preparation adds `capacity` with `accounting_contract: 3`, canonical `policy`, `policy_sha256`
and a bounded `checks` array (latest 16 observations). Each check carries verdict,
policy digest, safe observations, observations digest and, for fresh rechecks,
UTC `checked_at`. The existing atomic fsync/rename/readback and flock protect
these alongside the original release/host/source/policy bindings.
Every new observation includes the same `accounting_contract: 3` and the sorted
`affected_datasets` closure, covered by its observation digest. Mixed/unknown
contracts refuse. The transaction and policy schema numbers remain unchanged.
The new `shared_ancestors` map retains exact GUID, quota, refquota, used,
referenced and available for EVERY strict shared ancestor, even unlimited ones.
Stored validation checks the exact shared closure, property types, agreement with
the full dataset observations, admitted headroom and consistent GUID/limits across
checks. It does not demand identical byte counters between checks.

Recheck occurs on entry to unfinished preparation (including safe copy-only
resume), before copy, and before backup and activation. Backup/activation are
checked again after their durable started receipt, immediately before native
effects. A failed late read leaves that phase ambiguous, never permission to
replay. No completed phase is replayed to get accounting evidence. Changed
accounting may continue only if it still admits the original budgets. Every
boundary reacquires the full native accounting; shared-ancestor names, GUIDs,
quota and refquota must still equal the bound checks. Even an increased/cleared
limit or newly finite formerly unlimited limit refuses rather than silently
rebinding. Used/referenced/available and unrelated sibling counters may change,
provided all fresh capacity gates still pass. Changed policy cannot replace a
bound unresolved transaction. Resume normally needs
no policy path because canonical policy lives in the receipt; an optional path
must canonicalize to exactly that policy. Native failures and safe-copy-only
resume rules remain unchanged.

Historical preparation without this gate, with unversioned r2 accounting, or
with valid accounting contract 2 remains readable/exportable, retaining its
exact old evidence (including old reboot receipts). It cannot
resume mutation or be retrofitted with a policy: export the report and inspect
native state for manual recovery, never replay. Historical accepted/finalized
lifecycle and reports retain their previous semantics and do not require a
source publisher or new accounting. Prepared historical evidence may still
enter the existing postboot acceptance lifecycle, never preparation replay.
Contract 2 preparation cannot resume or become reboot-eligible under contract 3,
including a completed preparation: compatibility refuses before native mutation.
Historical reboot status remains observation, not renewed execution eligibility.
No old check is relabeled as contract 3. Reports never export raw machine-id.

All tests use fake native inventories, disposable ordinary directories, and
real process/flock/crash fixtures. They do not establish live promotion, A/B
boot, deployment or fleet readiness. The parent retains R01–R12 integration,
policy values, packaging, real-host read-only checks and the separately
Joy-approved first disruptive canary.

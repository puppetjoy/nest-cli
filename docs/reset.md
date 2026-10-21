# Checked reset results and read-only planning

This slice extends the existing `nest reset`; it does not introduce transactions,
release publication, finalize, reboot, or fleet orchestration.

## Commands

```sh
nest version                       # unchanged human version
nest version --format=json         # installed library content identity; no Git needed
nest reset --plan                  # human-readable observation, no preparation
nest reset --plan --format=json    # one JSON document on stdout
nest reset --plan --resume --format=json
nest reset --plan --kernel --format=json
```

Only `--plan` is an observation-only path. It does not construct an updater,
installer, BE manager, or runtime. It performs local file reads for source hashes
and read-only `findmnt`, `zfs list`, `zfs get`, and `zpool get` subprocesses. It
never imports a pool, creates a dataset/snapshot/clone, mounts, promotes, changes
boot selection, runs rsync, invokes a package manager, or runs Puppet. Combining
`--plan` with `--noop`, `--test`, `--dry-run`, or `--resume` does not change this.
No privilege escalation is attempted by the planner; unreadable state fails
observation. The image path is descriptive, not proof of image readiness.

The existing execution interface also accepts `--format=json`, for example
`nest reset --resume --format=json`. Unlike the commands above, this EXECUTES a
reset and needs the usual explicit operational authorization. JSON does not make
execution read-only. Human execution output remains the default. In JSON mode,
copy and Puppet output goes to stderr; stdout contains the final JSON document.

`--resume` still only skips backup when the default start was `backup`. It does
not discover a completed phase, bind a transaction, validate an existing clone,
or recover an interrupted activation. A warning is emitted (in `warnings` for
JSON). Explicit `--step`, `--begin`, `--end`, and kernel/firmware selection retain
precedence. Invalid/reversed ranges fail before mutation. `--test` and `--noop`
are NOT general read-only preflights: execution can still clone/mount/activate.
Firmware reset previously only logged a message; it now fails explicitly as
unimplemented rather than reporting a firmware update that did not happen.

## Result contract (schema 1)

All JSON uses UTF-8; native exits are integers or `null` when unavailable. The
process exit is separate from the child exit: 0 means successful selected phases
(or successful plan observation), 2 means reset/observation failure, and 3 means
initialization/validation failed before execution. Thor argument errors remain
Thor errors and are not JSON envelopes. Interruptions/killed workers cannot
promise a final report. No result is persisted as a recovery transaction.

`reset_result` has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | integer, 1 | Contract version |
| `kind` | string, `reset_result` | Execution result, not a plan |
| `success` | boolean | All selected phases completed |
| `phases` | array of `{phase: string, success: boolean}` | Attempted top-level phases only; later phases are absent after failure |
| `commands` | array of `{phase: string, operation: string, native_exit: integer/null, success: boolean}` | Copy/mountpoint/Puppet/kexec checks; not a complete command audit log |
| `failed_phase` | string/null | First failed top-level phase (`sync`, `kernel`, `unmount`, `activate`, etc.) |
| `failed_operation` | string/null | Finer checked operation such as `root`, `source`, `modules`, `puppet`, `kexec`; may be null for BE failures |
| `native_exit` | integer/null | First failing native status, not CLI exit 2/3 |
| `error` | string/null | Diagnostic; never parse it to decide success |
| `warnings` | string array | Includes legacy resume warning when selected |
| `source_identity` | object | Installed code identity described below |

Failure during initialization emits a smaller envelope: `schema`, `kind`,
`success: false`, `error`, `failed_phase: "initialization"`, `native_exit`.
There are no phase/command rows or source identity if initialization did not
complete. No native status is invented for validation/library errors.

`reset_plan` has `schema: 1`, `kind: "reset_plan"`, `read_only: true`,
`observation_success` (boolean), `source_identity`, `steps` (string array),
`warnings` (string array), `current` and `target` (dataset strings), `destination`
(path), `image` (descriptive Stage 3 path), `replaces_alternate` (boolean), and
`capacity` (object). Failures add `error` and `native_exit`; fields not yet
observed are absent. Initialization failures use the smaller envelope above.
There is deliberately no `success: true` or admission-success flag on a plan.
A zero plan process exit certifies only that the requested observations were read.

`capacity` contains:

- `admission: "unknown"`, `admitted: null`, and `reason`. Neither zero exit nor
  physical free space authorizes mutation or proves a reset/promotion will fit.
- `physical_pool`: `size`, `allocated`, `free`, and `freeing`, integer bytes from
  `zpool get -Hp`. `freeing` is asynchronous reclaim, not already-free capacity.
- `reserve`: `slop_bytes: null`, `policy_reserve_bytes: null`, `reason`. Physical
  free is not allocatable headroom. This slice does not infer slop tuning or a
  deployment's reserve policy. They remain explicit unknowns.
- `datasets_and_ancestors`: array of `{dataset, properties}` for all BE
  filesystems and every ancestor to the pool. Properties are `available`, `used`,
  `usedbysnapshots`, `usedbydataset`, `usedbychildren`, `usedbyrefreservation`,
  `quota`, `refquota`, `reservation`, `refreservation`, `origin`, `canmount`, and
  `guid`. Each property is `{value: string, source: string}` from `zfs get -Hp`.
  Values are raw decimal strings or ZFS sentinel strings; sources preserve
  inherited/ancestor policy. These are logical accounting values, not pool free.
- `promotion_accounting`: `transferred_snapshot_bytes: null`,
  `snapshot_name_collisions: "unknown"`, `reason`. Promotion can transfer origin
  snapshot accounting, exceed dataset/ancestor quota, or fail on snapshot-name
  collisions even when the payload fits. No dry-run promotion is attempted.

Missing/unsupported accounting properties, failed reads, or stacked root mounts
fail observation, never admission. The planner does not remove quota, convert
quota to refquota, discard rollback, or relax reserves.

## Checked execution and activation safety

The actual tty-command 0.10.1 API is counterintuitive: `run` raises `ExitError`
on a nonzero child (and the exception has no result accessor); `run!` returns a
truthy `Result` even for failure. Real harmless Ruby subprocess regressions prove
both behaviors. The original rsync `run` path already raised on failure; this
change makes its native status explicit instead of inferring truthiness or
parsing exception text. Every root/source/modules copy checks `run!`'s status.
Puppet detailed exits 0 (converged) and 2 (changes applied) are successful and
remain distinct command rows; other codes fail. Kexec reload is also checked.

The first failing phase stops execution; source failure prevents module/Puppet
installation, modules failure prevents Puppet installation, failed unmount
prevents activation, and failed promotion prevents bootfs selection. The existing
activation-safety exception is intentional: all inactive datasets are attempted
when disabling canmount, even after one failure, then activation stops. The first
failing native code is retained across that sweep. Actual target promotion still
precedes bootfs. Partial child promotion is observable and not automatically
rolled back. Rollback datasets and quota policy are not deleted to make promotion
pass. Read failures cannot masquerade as an empty/unmounted tree. A tree mounted
outside its expected `/mnt` location is refused. Destroy now respects failed
unmount; the legacy explicit destroy-next-selection behavior is otherwise not a
new automated finalize policy.

Default backup still replaces the existing alternate. This slice is not a
transactional retention system. Shared `/boot` and kexec remain existing execution
side effects; stopping at a later failure does not undo already completed copies
or boot-asset writes. No automatic reboot occurs.

## Installed source identity and integration requirements

`nest version --format=json` reports `version`, `algorithm: "sha256"`,
`source_sha256`, and `files` (relative library path to SHA256). The aggregate is
SHA256 of sorted records `relative_path + NUL + file_hash + LF` for every
`lib/**/*.rb` file, relative to `lib/`. It includes the identity implementation
itself. It is content identity, not a signature, Git revision, or certification
that a different package with version 0.9.0 is safe. Compare the full manifest
against the accepted source/package; patches change identity intentionally.

Packaging/install/pinning and live read-only checks belong to the parent
integration lane. Package all new library files (the existing gemspec glob does
so); use an immutable accepted source revision, not the old 0.9.0 archive alone.
Retain the activation-safe version as the rollback floor. Review/remove any
redundant activation backport against the exact new package. Separately fix and
verify the managed zfs-mount startup hook's ignored-failure prefix; CLI success
alone cannot establish service fail-closed behavior. Do not deploy or run a live
reset merely to exercise these source tests.

## Verification

Run `bundle install` and `bundle exec rake`. Tests use a stateful fake ZFS
inventory and command doubles, plus harmless real Ruby subprocesses for
`tty-command`. They do not create fixture datasets on any user pool or change
live boot selection. Real-ZFS accounting, installed-package parity, startup
integration, and a separately authorized reset canary are integration acceptance,
not claimed by this source slice.

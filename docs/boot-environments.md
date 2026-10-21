# Boot environment activation, quotas and recovery

`nest beadm activate NAME` prepares an existing environment and then selects it
with the pool's `bootfs`. It now promotes the target root and each cloned
descendant **before** changing `bootfs`, including when NAME is already selected.
The update and Stage 3 reset activation steps use this same path. Promotion moves
snapshot ownership/accounting; it does not delete the source environment or its
rollback data. It can change clone dependencies even if a later step fails.
Successful promotions are not automatically reversed.

A clone's payload fitting its quota, or physical pool space being available,
does not establish that promotion will fit. Snapshot accounting, ancestor quotas,
reservations and snapshot-name conflicts can prevent promotion. Rather than
estimating this transfer from payload size, activation performs the actual ZFS
promotion while the existing root remains running, and refuses to change bootfs
if any target promotion fails. No quota or refquota is removed, enlarged or
silently converted. This CLI does not impose reset quotas; limits established by
operators, image tooling or inherited policy remain contracts enforced by ZFS.
There is no new quota override flag.

`nest beadm activate` without a name prepares the root that is actually mounted,
not the next-boot selection. The startup integration currently calls this from
`zfs-mount.service` with an error-ignoring `ExecStartPre=-...`, so a nonzero exit
does not prevent `zfs mount -a`. Activation therefore:

1. Disables automatic mounting for every inactive root and descendant first.
   Already `off` or `noauto` datasets remain so. Every inactive dataset is
   attempted even if a property write fails; incomplete safety returns an error
   before enabling or promoting anything.
2. Enables the current tree's `noauto` datasets, preserving explicit `off` policy.
3. Promotes current clones, for old installations or manually selected boots.

A promotion failure after step 1 cannot leave an inactive tree eligible for
`zfs mount -a`, and current descendants are enabled before any promotion attempt.
No live filesystem is unmounted. Root discovery requires exactly one mounted
root and exactly one valid ZFS BE dataset; stacked roots are rejected, not guessed
at or forcibly repaired. Read failures or incomplete inventories are errors.

## Recovering a failed operation

Do not reboot after failed preparation or assume the desired BE was selected.
Read `nest beadm status` and inspect `zpool get bootfs POOL` and
`zfs get -r canmount,origin,quota,refquota,used,usedbysnapshots,available POOL/ROOT`
(use the actual BE container path, which may include an encryption dataset).
Preserve the known-good environment and snapshots. Fix the reported capacity,
quota policy or snapshot-name conflict deliberately, then retry the normal
activation command. Changing a quota is an explicit operator decision, not an
automatic recovery action. If NAME was already bootfs, a failed preparation leaves
that existing selection unchanged; explicitly select the known-good BE before
any reboot if necessary.

If disabling an inactive dataset fails, its previous property may remain unsafe:
no program can guarantee a property change ZFS refuses to persist. Do not run
`zfs mount -a` in that state. The CLI reports all failed datasets and exits
nonzero, but the existing error-ignoring startup hook does not enforce that exit.
Repair the property/storage problem from a controlled recovery environment;
changing that service policy belongs to deployment configuration, not an
incident-specific CLI workaround. Likewise, an already-stacked live root needs
controlled operator recovery, never an automatic force-unmount.

These commands require exclusive administrative use: do not concurrently change
BE datasets/properties or run another activation. Promotion is a preparation
operation, not a read-only capacity probe and not an atomic multi-dataset
transaction. Later policy/storage changes can still make a subsequent boot fail.

## Accepted reset finalization and destroy policy

`nest reset accept ID --evidence FILE` and
`nest reset finalize ID --cleanup=owned [--plan]` implement the small explicit
postboot lifecycle described in [reset-lifecycle.md](reset-lifecycle.md), including
the parent collector's bounded JSON schema. Preparation alone is not acceptance.
Ordinary A/B finalization keeps both trees and deletes nothing; no historical
extra is adopted by its name. Snapshot origins remain retained and BE removal
does not establish physical reclamation.

`nest beadm destroy NAME` refuses current and next-boot environments. It never
silently reselects bootfs to enable deletion. A deliberate manual caller must
select its intended safe next boot first. The library-only `reselect_next: true`
keyword retains the old explicit compatibility path, not automated cleanup.
Failed unmount stops destroy with the checked native failure retained.
External clone-origin snapshots are not retired by matching their names; shared
or ambiguous origins remain for a separately explicit snapshot policy.

## Regression coverage

`bundle exec rake` runs RSpec and RuboCop. BE regressions use a stateful fake ZFS
command interface, including payload-fitting/promotion-exceeding quota accounting,
root and descendant failures, partial preparation, rollback retention, selection
ordering, reset/update callers, nonzero CLI exit and ambiguous root discovery.
No production pools, mounts, service changes or reboot canaries are involved.

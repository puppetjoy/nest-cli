# Guarded postboot CLI / filter evolution

This is a source-only contract. Installing or changing CLI/filter source does not
approve acceptance, waive a failed report, or authorize a host operation. The
parent must review the exact continuation command against its owner-approved
scope before using this interface. No reset or reboot replay is authorized.

## Commands

`nest reset status ID --format=json` is historical, genuinely read-only: it does
not create a lock or update a receipt. It retains the original `source`, `policy`,
`host`, `phases`, `capacity`, and `reboot` report fields. `identity_observation`
separately reports freshly observed immutable root source and installed policy,
and `source_matches_original` / `policy_matches_original` (null if unavailable).
Unknown observations are not admission. Host, pool, shared-state and BE identity
checks remain mandatory; status is not acceptance or reboot eligibility.

Preparation, resume, and reboot (including reboot plans) still require the exact
original source/policy. There is no force, ignore-drift, or transaction-rebind
option. The immutable root generation may NOT evolve: a different release,
source path, dataset, GUID, creation TXG or mount remains a refusal.

`nest reset accept ID --evidence REPORT.json --postboot-policy CONTEXT.json`
permits explicit installed CLI/filter evolution only after successful recorded
preparation and a proven changed boot into the exact prepared target. It requires
an original valid reboot receipt (intent or returned); an unknown command return
is not boot proof, but an exact independently observed changed target boot is.
An absent receipt, unchanged/empty boot ID, partial preparation, incorrect boot
selection, rollback GUID, mounts, host, pool or shared-state refuses. Native
acceptance report validation remains unchanged, including explicit historical
failure disposition; policy evidence supplies no approval or passing gate.

CONTEXT.json is a bounded JSON object with exactly these fields:

- `schema`: 1
- `kind`: `reset_postboot_policy`
- `transaction_id`: the original transaction ID
- `release`: the original immutable release
- `observed_boot_id`: the proven current boot
- `host_identity_sha256`: SHA256 of the original machine ID
- `pool_guid`, `shared_state`, `target_tree`: original exact bindings
- `source`: the complete original immutable root source identity
- `original_policy`: complete original filter/CLI digest object
- `current_policy`: complete freshly observed filter/CLI digest object
- `evidence_ref`, `evidence_sha256`: independently retained source/policy review
  evidence, using the same bounded reference/digest syntax as acceptance evidence

Both current policy values must be lowercase SHA256 digests. The object is
retained separately as `acceptance.postboot_policy`, never over original policy,
source, phases or reboot markers. It is immutable on retries. Re-observation must
match before writing. Without this object acceptance/finalize require original
source/policy equality, including transactions prepared by older versions.

`nest reset finalize ID --cleanup=owned [--plan]` consumes the retained context;
there is no finalize override. For an evolved transaction only ordinary empty
owned-candidate/cleanup inventories are permitted: no deletion of snapshots,
origins or BEs. It revalidates the exact accepted boot, current policy and all
original identity/report guards, including on idempotent retries. A subsequent
policy change refuses rather than updating context. Finalize plans remain
read-only and create no lock. Originals and retained context remain exportable
using `nest reset report ID --format=json`.

The optional context extends the existing schema-2 acceptance structure, not a
new journal, ledger or preparation schema. Older transactions without it remain
readable and valid under their original contract. Existing historical command
outcomes remain literal; changed boot observation never changes their meaning.

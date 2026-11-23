# PermitRegistry 1.1.0: compatibility with 1.0.0

## JSON exchange schema (schema.json)

- **Old documents still valid.** Every document that is valid against 1.0.0 is also valid against 1.1.0.
  Nothing was renamed, retyped or removed, and no enum value was added to `PermitStatus`.
- **New documents are not valid for 1.0.0 validators.** The 1.0.0 schema is closed (D-002), so a 1.0.0 validator
  rejects a document that contains `applicant`, `validUntilTime` or `conditions[].category`.
- **What to send a partner still on 1.0.0:** the 1.0.0 projection of the permit:
  1. drop `applicant`
  2. drop `validUntilTime`; `validUntil` (the date) stays, so 1.0.0 partners read the expiry as "end of that day"
  3. drop `category` from each entry in `conditions`
  4. leave out `keywords` (it is optional in 1.0.0)

  The projection is lossless for all 1.0.0 content. It only leaves out the new information.
- Expiry is not a `status` value, so 1.0.0 partners get no new status code. An expired permit is still `granted`
  with a `validUntil` in the past, as it was before.
- `keywords` is marked `deprecated` but is still accepted, so partners that send it are not rejected.

## Database (schema.sql / migration-from-1.0.0.sql)

- The changes are additive: nullable columns, one new enum type, one view, one partial index and two CHECK
  constraints. Both CHECKs hold for existing rows.
- The C-002 trigger (applicant required on INSERT) is commented out in the migration. Run it separately at the
  cut-over date.
- `permit_keywords` is kept. Drop it in 2.0.0.

## Deferred to 2.0.0 (breaking)

- Rename `reference` to `fileNumber`, in JSON and in the column.
- Remove `keywords` / `permit_keywords`.
- Optionally merge `validUntil` and `validUntilTime` into one date-time.
- Optionally make `PermitStatus` extensible, or add `expired` as a stored or exchanged value.

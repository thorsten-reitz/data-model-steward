# Open questions

## Q-001 Projection or major version for CR-7? (BLOCKS RELEASE) (2026-11-23)
See D-009. Can the exchange interface keep serving the three partners 1.0.0-shaped documents (without `applicant`, `validUntilDateTime` and `conditions[].category`) until each of them upgrades? Which partner is on which version? Recommended answer: yes, then release 1.1.0.

## Q-002 Time zone and producers of `validUntilDateTime` (2026-11-23)
Which local time zone defines "noon" and the derived `validUntil` date? A-001 assumes the issuing authority's zone. Which producing systems can supply a time at all?

## Q-003 Does the applicant need its own identity? (2026-11-23)
Examples: "all permits of applicant X", deduplication, a link to a business register. If yes, `Applicant` should become a class with an identifier and a reference association, which is a further change.

## Q-004 Personal data: legal basis, retention and partner access for applicant data (2026-11-23)
The name and address of a natural person are personal data. What is the retention period? May all three partners receive the applicant data, or should the projection or export leave it out for some of them?

## Q-005 Must new conditions have a category? (2026-11-23)
CR-7 doesn't say, so the category is currently optional. If it should be mandatory, add a rule like C-002 with `scope: new`.

## Q-006 Backlog for the next major version (2026-11-23)
- Rename `reference` to `fileNumber`.
- Remove `keywords`.
- Remove `validUntil` (replaced by `validUntilDateTime`).
- Make `applicant` mandatory, if old permits are back-filled.
- Switch to open content for JSON exchange.

## Working assumptions (to be confirmed)
- A-001: `validUntilDateTime` is exchanged with an explicit UTC offset. The local date for `validUntil` (C-004) is taken in the issuing authority's time zone.
- A-002: for permits that only have `validUntil`, validity ends at the end of that day (local time) when deriving "expired".
- A-003: partners only need "expired" as something they can compute, not as a status value they receive.
- A-004: within an applicant, `name` and `address` are mandatory and `organisation` is optional ("name + optional organisation + address", CR-7). The address reuses `Address`, so postalCode and city are mandatory and street is optional.

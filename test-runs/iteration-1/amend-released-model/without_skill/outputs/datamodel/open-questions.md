# Open questions

- **Q-001 Cut-over date for C-002** (applicant required for new permits). Which date, and are all registering
  applications ready to capture the applicant? The migration leaves the trigger out until this is decided.
- **Q-002 Applicant personal data.** Applicants can be natural persons. Need: privacy/DPO review, retention
  period, and whether partners may receive the applicant at all (data minimisation). If they may not, mark
  `applicant` as not exchanged before releasing 1.1.0. Also: does the applicant need its own identity (the same
  applicant across permits, contact data updates)? If so, it becomes a class later.
- **Q-003 Time zone of validUntilTime.** Assumed to be the local legal time of the issuing authority, all in
  one time zone. Confirm this, or decide whether a UTC offset is needed. Also confirm that existing date-only
  validUntil values mean "valid through the end of that day".
- **Q-004 Condition category for existing conditions.** Leave NULL (current choice), backfill as "other", or
  classify manually? Should category be mandatory for new conditions (like C-002)?
- **Q-005 Is derived "expired" enough for the permits team?** CR-7 asked for a status. If they need
  "expired" to be stored, or sent to partners as a status value, that is a breaking change for 2.0.0.
- **Q-006 Plan for 2.0.0.** When to do the breaking changes with the three partners: `fileNumber` rename,
  `keywords` removal, optional validUntil date-time merge.
- **Q-007 Exchange version handling.** How does the exchange interface serve 1.0.0 partners: a per-version
  endpoint, or version negotiation producing the 1.0.0 projection? This is needed before any producer emits
  1.1.0 documents.
- **Q-008 XSD target.** The model lists `xsd` as a target, but 1.0.0 has no XSD export. Is it still needed?

# Open questions

Raised while working in CR-7 (S2) on 2026-11-23. The owner was not available; the modeller made
the calls in D-003 to D-011. Items marked **blocking** should be answered before releasing 1.1.0.

## Questions

- **Q-001 Plan for a 2.0.0?** Candidates collected from CR-7: rename `reference` -> `fileNumber`
  (D-004); `applicant` "1, voidable" (D-005); remove `keywords` (D-009) and `validUntil` (D-007);
  optionally `expired` as a stored status (Q-002) and open content (Q-007). Each breaks all three
  partners. Recommendation: no 2.0.0 now; bundle these when there is another reason for a major
  release, after a deprecation period. Owner: decide whether and when.
- **Q-002 Is a derived "expired" enough for the permits team?** (D-006) If they need it as a
  stored status (e.g. for workflow), it can only come as a change coordinated with the partners.
  Also confirm that only granted permits can expire (A-004).
- **Q-003 Applicant as value or as identifiable party?** (D-005) A class with identity is needed
  if applicants must be searched or de-duplicated across permits, or if a permit can have
  several applicants.
- **Q-004 Personal data (blocking).** Applicant name and address are personal data. Confirm legal
  basis, retention period, access rights (including `permit_history`) and whether the three
  partners may receive applicant data at all (data-sharing agreements).
- **Q-005 Legacy validity end.** Backfill `validUntilDateTime` for existing permits (as the end of
  the `validUntil` day, local time - A-001), or leave it empty? Needs an answer before
  `validUntil` can ever be removed.
- **Q-006 Time zone(s).** Which local time zone applies to `validUntil` and to the derived expiry?
  One for all authorities (A-002) or per authority (would need `Authority.timeZone`)?
- **Q-007 Partner rollout (blocking for the exchange side).** Which of the three partners move to
  1.1.0, and when? Until then producers must send 1.0.0-conformant documents (D-010). Should a
  future major switch to open content (`exportOptions.jsonschema.closed: false`) so that
  additions stop breaking strict validators?
- **Q-008 Existing conditions.** Classify existing conditions (campaign, or default `other`)?
  Make `category` mandatory later?
- **Q-009 Release 1.1.0.** Model is at version 1.1.0 with status `draft`; exports are in
  exports/1.1.0/. On the owner's go-ahead: set `status: released`, copy model.yaml to
  releases/1.1.0/, date the CHANGELOG entry.

## Working assumptions

- **A-001** `validUntil` (date) means valid through the end of that day in local time.
- **A-002** One local time zone for all authorities (setting in views.sql, default UTC).
- **A-003** Applicant name and organisation max 200 characters; applicant address reuses `Address`.
- **A-004** Only granted permits can be expired; applied, refused and revoked permits cannot.

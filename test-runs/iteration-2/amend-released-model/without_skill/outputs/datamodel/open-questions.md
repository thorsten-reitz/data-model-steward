# Open questions

| ID | Question | Raised | Owner | Blocking |
|----|----------|--------|-------|----------|
| OQ-1 | Release 1.1.0 as drafted (D-003..D-008)? Who informs the three partners and agrees when each adopts the 1.1.0 schema? | 2026-11-23 (CR-7) | model owner | release |
| OQ-2 | Does the permits team accept that "fileNumber" is a label only in 1.x and the technical rename waits for 2.0.0 (D-003)? Is a breaking 2.0.0 wanted at all, and when? | 2026-11-23 (CR-7 item 1) | permits team / model owner | no |
| OQ-3 | Which time zone applies to validUntilTime (one zone, or per authority)? The view uses 'Europe/Berlin' as a placeholder. Is "no time = valid until end of day" correct? | 2026-11-23 (CR-7 items 3, 4) | permits team | view correctness |
| OQ-4 | Do any of the three partners send or read `keywords`? Needed before removal in 2.0.0. Should existing keyword data be archived? | 2026-11-23 (CR-7 item 6) | model owner / partners | 2.0.0 |
| OQ-5 | Is "row created after the migration" the right cut-off for C-002/C-004? Can legacy applicants be back-filled from the files, and should legacy conditions be categorised (e.g. bulk "other")? | 2026-11-23 (CR-7 items 2, 5) | permits team | no |
| OQ-6 | Should "expired" be transmitted to partners (breaking, 2.0.0)? Should it apply to statuses other than granted? | 2026-11-23 (CR-7 item 3) | permits team / partners | no |
| OQ-7 | Is an applicant with only an organisation (no person name) allowed? Currently name is required. | 2026-11-23 (CR-7 item 2) | permits team | no |
| OQ-8 | `targets` lists xsd, but 1.0.0 has no XSD export (only schema.json and schema.sql). Is the XSD target still wanted? None was produced for 1.1.0 either. | 2026-11-23 | model owner | no |

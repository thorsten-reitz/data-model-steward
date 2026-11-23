# Glossary

- **Permit**: official authorisation.
- **File number** (*fileNumber*): human-readable number under which the authority files a permit; the term the clerks use. Technical name in the 1.x model, database and JSON exchange: `reference` (see D-003).
- **Applicant**: person or organisation that applied for a permit; name, optional organisation, postal address. Mandatory for permits created from the 1.1.0 go-live; may be unknown for older permits.
- **Expired**: a granted permit whose validity end (validUntil, plus validUntilTime if given) has passed. Derived, not stored, in 1.x (D-005).
- **Validity end**: validUntil (date) plus optional validUntilTime (time of day, authority-local). Without a time the permit is valid until the end of that day.
- **Condition category**: classification of a permit condition: environmental, safety, other.
- **Keywords**: free-text tags on a permit. Deprecated since 1.1.0, to be removed in 2.0.0.

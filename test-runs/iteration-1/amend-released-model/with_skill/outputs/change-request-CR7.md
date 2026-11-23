# Change request CR-7 (from the permits team, 2026-11-15)

1. The field "reference" should be called "fileNumber" everywhere – that's what the clerks call it.
2. Every permit must have an applicant from now on (name + optional organisation + address).
   We have ~2 million existing permits; for older ones the applicant is not always known.
3. New status "expired" for permits whose validUntil has passed.
4. validUntil should include a time of day (some permits expire at noon).
5. Conditions should get a category (environmental, safety, other).
6. We no longer need the keywords field – nobody uses it.

-- Migration PermitRegistry 1.0.0 -> 1.1.0 (CR-7). Non-destructive: nothing renamed or dropped, no data removed.
-- All new columns are nullable or defaulted, so the ~2 million existing permits remain valid.
-- Review the time zone placeholder in the view (open question OQ-3) before running.
BEGIN;

CREATE TYPE permit_registry.condition_category AS ENUM ('environmental', 'safety', 'other');

-- CR-7 item 2 (applicant), item 4 (time of day), and created_at as the basis for C-002.
-- Existing rows get created_at = migration time, i.e. they count as legacy rows.
ALTER TABLE permit_registry.permit
  ADD COLUMN valid_until_time time,
  ADD COLUMN applicant_name varchar(200),
  ADD COLUMN applicant_organisation varchar(200),
  ADD COLUMN applicant_address_street varchar(200),
  ADD COLUMN applicant_address_postal_code varchar(10),
  ADD COLUMN applicant_address_city varchar(100),
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();

-- CR-7 item 5 (condition category)
ALTER TABLE permit_registry.permit_condition
  ADD COLUMN category permit_registry.condition_category,
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();

-- C-003: validUntilTime requires validUntil.
ALTER TABLE permit_registry.permit ADD CONSTRAINT permit_c003_valid_until_time
  CHECK (valid_until_time IS NULL OR valid_until IS NOT NULL);
-- Applicant is all-or-nothing: if any applicant column is set, name, postal code and city are required.
ALTER TABLE permit_registry.permit ADD CONSTRAINT permit_applicant_complete
  CHECK ((applicant_name IS NULL AND applicant_organisation IS NULL AND applicant_address_street IS NULL
          AND applicant_address_postal_code IS NULL AND applicant_address_city IS NULL)
      OR (applicant_name IS NOT NULL AND applicant_address_postal_code IS NOT NULL AND applicant_address_city IS NOT NULL));

-- C-002 / C-004: applicant (permit) and category (condition) mandatory for rows inserted from 1.1.0 on.
-- Enforced on INSERT only, so legacy rows without them can still be updated.
CREATE FUNCTION permit_registry.trg_permit_c002() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.applicant_name IS NULL THEN
    RAISE EXCEPTION 'C-002: a new permit must have an applicant (permit %)', NEW.permit_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER permit_c002 BEFORE INSERT ON permit_registry.permit
  FOR EACH ROW EXECUTE FUNCTION permit_registry.trg_permit_c002();

CREATE FUNCTION permit_registry.trg_permit_condition_c004() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.category IS NULL THEN
    RAISE EXCEPTION 'C-004: a new condition must have a category';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER permit_condition_c004 BEFORE INSERT ON permit_registry.permit_condition
  FOR EACH ROW EXECUTE FUNCTION permit_registry.trg_permit_condition_c004();

-- CR-7 item 3 / D-005: derived status incl. 'expired' (no new stored enum value, no batch job).
-- validUntilTime is authority-local time; 'Europe/Berlin' is a PLACEHOLDER until OQ-3 is answered.
CREATE VIEW permit_registry.permit_effective_status AS
SELECT p.permit_id,
       p.reference AS file_number,
       p.status,
       CASE
         WHEN p.status = 'granted' AND p.valid_until IS NOT NULL AND
              CASE WHEN p.valid_until_time IS NULL
                   THEN p.valid_until < (now() AT TIME ZONE 'Europe/Berlin')::date
                   ELSE (p.valid_until + p.valid_until_time) <= (now() AT TIME ZONE 'Europe/Berlin')
              END
         THEN 'expired'
         ELSE p.status::text
       END AS effective_status
FROM permit_registry.permit p
WHERE p.deleted_at IS NULL;
CREATE INDEX ON permit_registry.permit (valid_until) WHERE status = 'granted';

-- CR-7 item 1 (file number) and item 6 (keywords deprecated): documentation only in 1.x
COMMENT ON COLUMN permit_registry.permit.reference IS 'File number (business term: fileNumber) used by the authority. Column name kept for 1.x compatibility (D-003).';
COMMENT ON COLUMN permit_registry.permit.valid_until IS 'Last day of validity; without valid_until_time valid until end of day.';
COMMENT ON COLUMN permit_registry.permit.valid_until_time IS 'Time of day on valid_until at which the permit expires, authority-local time. NULL = end of day.';
COMMENT ON COLUMN permit_registry.permit.applicant_name IS 'Applicant name. NULL only for permits created before 1.1.0 where the applicant is unknown (C-002).';
COMMENT ON COLUMN permit_registry.permit.applicant_organisation IS 'Organisation the applicant acts for.';
COMMENT ON COLUMN permit_registry.permit.created_at IS 'Row creation time; basis for C-002 (applicant mandatory from 1.1.0 go-live).';
COMMENT ON COLUMN permit_registry.permit_condition.category IS 'Condition category. NULL only for conditions created before 1.1.0 (C-004).';
COMMENT ON COLUMN permit_registry.permit_condition.created_at IS 'Row creation time; basis for C-004.';
COMMENT ON TYPE permit_registry.condition_category IS 'Category of a permit condition.';
COMMENT ON TABLE permit_registry.permit_keywords IS 'DEPRECATED since 1.1.0 (CR-7 item 6); do not populate. Removal planned for 2.0.0 (D-007).';
COMMENT ON VIEW permit_registry.permit_effective_status IS 'Permit status including derived status expired (D-005).';

COMMIT;

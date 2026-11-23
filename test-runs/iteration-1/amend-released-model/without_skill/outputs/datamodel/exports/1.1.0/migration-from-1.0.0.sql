-- PermitRegistry: migrate a 1.0.0 database to 1.1.0 (CR-7). Hand-written; review before use.
-- Additive only: nothing renamed, retyped or dropped, no existing row changed.
-- New columns are nullable without default, so no table rewrite of the ~2M permits.
BEGIN;

CREATE TYPE permit_registry.condition_category AS ENUM ('environmental', 'safety', 'other');

-- CR-7 item 2: applicant (unknown/NULL allowed for existing permits); CR-7 item 4: time of day of expiry
ALTER TABLE permit_registry.permit
  ADD COLUMN applicant_name varchar(200),
  ADD COLUMN applicant_organisation varchar(200),
  ADD COLUMN applicant_address_street varchar(200),
  ADD COLUMN applicant_address_postal_code varchar(10),
  ADD COLUMN applicant_address_city varchar(100),
  ADD COLUMN valid_until_time time,
  ADD CONSTRAINT permit_applicant_complete CHECK (
    (applicant_name IS NULL AND applicant_organisation IS NULL AND applicant_address_street IS NULL
       AND applicant_address_postal_code IS NULL AND applicant_address_city IS NULL)
    OR (applicant_name IS NOT NULL AND applicant_address_postal_code IS NOT NULL AND applicant_address_city IS NOT NULL)),
  ADD CONSTRAINT permit_c003 CHECK (valid_until_time IS NULL OR valid_until IS NOT NULL);

-- CR-7 item 5: condition category (NULL for existing conditions)
ALTER TABLE permit_registry.permit_condition ADD COLUMN category permit_registry.condition_category;

-- CR-7 item 3: 'expired' as derived effective status (PermitStatus enum unchanged, D-005)
CREATE VIEW permit_registry.permit_effective_status AS
SELECT p.permit_id,
       p.reference AS file_number,
       p.status,
       (p.status = 'granted' AND p.valid_until IS NOT NULL
          AND p.valid_until + coalesce(p.valid_until_time, time '24:00') < localtimestamp) AS expired,
       CASE WHEN p.status = 'granted' AND p.valid_until IS NOT NULL
                 AND p.valid_until + coalesce(p.valid_until_time, time '24:00') < localtimestamp
            THEN 'expired' ELSE p.status::text END AS effective_status
FROM permit_registry.permit p
WHERE p.deleted_at IS NULL;
CREATE INDEX ON permit_registry.permit (valid_until) WHERE status = 'granted';

-- CR-7 item 1: clerks' term "file number" documented; column not renamed (D-003)
COMMENT ON COLUMN permit_registry.permit.reference IS 'File number (fileNumber): human-readable file number used by the authority.';
COMMENT ON COLUMN permit_registry.permit.applicant_name IS 'Applicant name (personal data). NULL = applicant unknown (permits registered before CR-7).';
COMMENT ON COLUMN permit_registry.permit.applicant_organisation IS 'Organisation on whose behalf the application was made (personal data).';
COMMENT ON COLUMN permit_registry.permit.valid_until_time IS 'Local time of day at which the permit expires on valid_until; NULL = end of day.';
COMMENT ON COLUMN permit_registry.permit_condition.category IS 'Category of the condition; NULL = not categorised (conditions recorded before CR-7).';
COMMENT ON TYPE permit_registry.condition_category IS 'Kind of obligation a permit condition imposes.';
COMMENT ON TYPE permit_registry.permit_status IS 'Lifecycle status of a permit as decided by the authority; expiry is derived (see permit_effective_status).';
-- CR-7 item 6: keywords deprecated; data kept until 2.0.0
COMMENT ON TABLE permit_registry.permit_keywords IS 'DEPRECATED since 1.1.0 (CR-7), to be dropped in 2.0.0. Do not populate.';
COMMENT ON VIEW permit_registry.permit_effective_status IS 'Effective status incl. derived ''expired'' (status granted and validity passed).';

COMMIT;

-- C-002 (new permits must have an applicant): run SEPARATELY at the agreed cut-over date, once every
-- registering application captures the applicant. Enforced on INSERT only, so old permits stay updatable.
-- BEGIN;
-- CREATE FUNCTION permit_registry.permit_c002_applicant_required() RETURNS trigger LANGUAGE plpgsql AS $$
-- BEGIN
--   IF NEW.applicant_name IS NULL THEN
--     RAISE EXCEPTION 'C-002: a new permit must have an applicant';
--   END IF;
--   RETURN NEW;
-- END $$;
-- CREATE TRIGGER permit_c002_applicant_required BEFORE INSERT ON permit_registry.permit
--   FOR EACH ROW EXECUTE FUNCTION permit_registry.permit_c002_applicant_required();
-- COMMIT;

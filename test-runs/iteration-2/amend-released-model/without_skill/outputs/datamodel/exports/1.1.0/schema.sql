-- PermitRegistry 1.1.0 (draft, CR-7). Hand-derived from the dmtool 1.0.0 output; regenerate with dmtool when it supports 1.1.0.
-- For an existing 1.0.0 database run migrate-1.0.0-to-1.1.0.sql instead of this file.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS permit_registry;

CREATE TYPE permit_registry.permit_status AS ENUM ('applied', 'granted', 'refused', 'revoked');
CREATE TYPE permit_registry.condition_category AS ENUM ('environmental', 'safety', 'other');

CREATE TABLE permit_registry.authority (
  authority_id text PRIMARY KEY,
  name varchar(200) NOT NULL,
  address_street varchar(200),
  address_postal_code varchar(10) NOT NULL,
  address_city varchar(100) NOT NULL
);
CREATE TABLE permit_registry.authority_history (
  history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation char(1) NOT NULL CHECK (operation IN ('I','U','D')),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  recorded_by text,
  row_data jsonb NOT NULL
);
CREATE TABLE permit_registry.permit_keywords (
  permit_permit_id uuid NOT NULL,
  ord integer NOT NULL,
  value varchar(50) NOT NULL,
  PRIMARY KEY (permit_permit_id, ord)
);
CREATE TABLE permit_registry.permit (
  permit_id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  reference varchar(40) NOT NULL UNIQUE,
  status permit_registry.permit_status NOT NULL,
  decision_date date,
  valid_until date,
  valid_until_time time,
  applicant_name varchar(200),
  applicant_organisation varchar(200),
  applicant_address_street varchar(200),
  applicant_address_postal_code varchar(10),
  applicant_address_city varchar(100),
  created_at timestamptz NOT NULL DEFAULT now(),
  site_location geometry(Polygon,4326) NOT NULL,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_to timestamptz,
  deleted_at timestamptz,
  issuer_authority_id text NOT NULL
);
CREATE TABLE permit_registry.permit_history (
  history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation char(1) NOT NULL CHECK (operation IN ('I','U','D')),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  recorded_by text,
  row_data jsonb NOT NULL
);
CREATE TABLE permit_registry.permit_condition (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  text text NOT NULL,
  due_date date,
  category permit_registry.condition_category,
  created_at timestamptz NOT NULL DEFAULT now(),
  permit_permit_id uuid NOT NULL,
  ord integer NOT NULL DEFAULT 0
);
-- Constraint C-001 on Permit: validUntil must not be before decisionDate. (not enforced; implement as CHECK/trigger if required)
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

ALTER TABLE permit_registry.permit_keywords ADD FOREIGN KEY (permit_permit_id) REFERENCES permit_registry.permit (permit_id) ON DELETE CASCADE;
ALTER TABLE permit_registry.permit ADD FOREIGN KEY (issuer_authority_id) REFERENCES permit_registry.authority (authority_id);
ALTER TABLE permit_registry.permit_condition ADD FOREIGN KEY (permit_permit_id) REFERENCES permit_registry.permit (permit_id) ON DELETE CASCADE;

CREATE INDEX ON permit_registry.authority_history ((row_data->>'authority_id'), recorded_at);
CREATE INDEX ON permit_registry.permit (issuer_authority_id);
CREATE INDEX ON permit_registry.permit_history ((row_data->>'permit_id'), recorded_at);
CREATE INDEX ON permit_registry.permit_condition (permit_permit_id);

COMMENT ON TYPE permit_registry.permit_status IS 'Lifecycle status of a permit.';
COMMENT ON TABLE permit_registry.authority IS 'Public body competent to issue permits.';
COMMENT ON COLUMN permit_registry.authority.authority_id IS 'Persistent URI of the authority.';
COMMENT ON TABLE permit_registry.authority_history IS 'History (audit) of Authority; fill via trigger on permit_registry.authority.';
COMMENT ON TABLE permit_registry.permit IS 'Official authorisation granted to an applicant for an activity at a site.';
COMMENT ON COLUMN permit_registry.permit.permit_id IS 'Stable identifier of the permit.';
COMMENT ON COLUMN permit_registry.permit.valid_from IS 'Start of validity (valid time)';
COMMENT ON COLUMN permit_registry.permit.valid_to IS 'End of validity (valid time); NULL = open';
COMMENT ON COLUMN permit_registry.permit.deleted_at IS 'Logical deletion timestamp';
COMMENT ON COLUMN permit_registry.permit.issuer_authority_id IS 'The authority that issued the permit.';
COMMENT ON TABLE permit_registry.permit_history IS 'History (versioned) of Permit; fill via trigger on permit_registry.permit.';
COMMENT ON TABLE permit_registry.permit_condition IS 'Obligation attached to a permit.';
COMMENT ON COLUMN permit_registry.permit_condition.id IS 'Surrogate key';
COMMENT ON COLUMN permit_registry.permit_condition.ord IS 'Position within the owning collection';
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

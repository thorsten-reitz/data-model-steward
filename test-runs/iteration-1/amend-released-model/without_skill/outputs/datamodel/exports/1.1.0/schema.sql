-- PermitRegistry 1.1.0 (draft). Hand-written in dmtool output style because dmtool was not available;
-- regenerate with dmtool and diff against this file before release.
-- Upgrading an existing 1.0.0 database: use migration-from-1.0.0.sql, not this file.
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
  applicant_name varchar(200),
  applicant_organisation varchar(200),
  applicant_address_street varchar(200),
  applicant_address_postal_code varchar(10),
  applicant_address_city varchar(100),
  decision_date date,
  valid_until date,
  valid_until_time time,
  site_location geometry(Polygon,4326) NOT NULL,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_to timestamptz,
  deleted_at timestamptz,
  issuer_authority_id text NOT NULL,
  CONSTRAINT permit_applicant_complete CHECK (
    (applicant_name IS NULL AND applicant_organisation IS NULL AND applicant_address_street IS NULL
       AND applicant_address_postal_code IS NULL AND applicant_address_city IS NULL)
    OR (applicant_name IS NOT NULL AND applicant_address_postal_code IS NOT NULL AND applicant_address_city IS NOT NULL)),
  CONSTRAINT permit_c003 CHECK (valid_until_time IS NULL OR valid_until IS NOT NULL)
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
  category permit_registry.condition_category,
  due_date date,
  permit_permit_id uuid NOT NULL,
  ord integer NOT NULL DEFAULT 0
);
-- Constraint C-001 on Permit: validUntil must not be before decisionDate. (not enforced; implement as CHECK/trigger if required)
-- Constraint C-002 on Permit: permits registered on/after the CR-7 cut-over must have an applicant.
-- Enforced on INSERT only, so existing permits without a known applicant can still be updated (e.g. revoked).
CREATE FUNCTION permit_registry.permit_c002_applicant_required() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.applicant_name IS NULL THEN
    RAISE EXCEPTION 'C-002: a new permit must have an applicant';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER permit_c002_applicant_required BEFORE INSERT ON permit_registry.permit
  FOR EACH ROW EXECUTE FUNCTION permit_registry.permit_c002_applicant_required();
-- Constraint C-003 on Permit: validUntilTime only together with validUntil. (enforced by CHECK permit_c003)

-- Derived attribute Permit.expired / effective status 'expired' (D-005). Compared in the session time zone;
-- set it to the authorities' time zone (open question Q-003).
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

ALTER TABLE permit_registry.permit_keywords ADD FOREIGN KEY (permit_permit_id) REFERENCES permit_registry.permit (permit_id) ON DELETE CASCADE;
ALTER TABLE permit_registry.permit ADD FOREIGN KEY (issuer_authority_id) REFERENCES permit_registry.authority (authority_id);
ALTER TABLE permit_registry.permit_condition ADD FOREIGN KEY (permit_permit_id) REFERENCES permit_registry.permit (permit_id) ON DELETE CASCADE;

CREATE INDEX ON permit_registry.authority_history ((row_data->>'authority_id'), recorded_at);
CREATE INDEX ON permit_registry.permit (issuer_authority_id);
CREATE INDEX ON permit_registry.permit (valid_until) WHERE status = 'granted';
CREATE INDEX ON permit_registry.permit_history ((row_data->>'permit_id'), recorded_at);
CREATE INDEX ON permit_registry.permit_condition (permit_permit_id);

COMMENT ON TYPE permit_registry.permit_status IS 'Lifecycle status of a permit as decided by the authority; expiry is derived (see permit_effective_status).';
COMMENT ON TYPE permit_registry.condition_category IS 'Kind of obligation a permit condition imposes.';
COMMENT ON TABLE permit_registry.authority IS 'Public body competent to issue permits.';
COMMENT ON COLUMN permit_registry.authority.authority_id IS 'Persistent URI of the authority.';
COMMENT ON TABLE permit_registry.authority_history IS 'History (audit) of Authority; fill via trigger on permit_registry.authority.';
COMMENT ON TABLE permit_registry.permit_keywords IS 'DEPRECATED since 1.1.0 (CR-7), to be dropped in 2.0.0. Do not populate.';
COMMENT ON TABLE permit_registry.permit IS 'Official authorisation granted to an applicant for an activity at a site.';
COMMENT ON COLUMN permit_registry.permit.permit_id IS 'Stable identifier of the permit.';
COMMENT ON COLUMN permit_registry.permit.reference IS 'File number (fileNumber): human-readable file number used by the authority.';
COMMENT ON COLUMN permit_registry.permit.applicant_name IS 'Applicant name (personal data). NULL = applicant unknown (permits registered before CR-7).';
COMMENT ON COLUMN permit_registry.permit.applicant_organisation IS 'Organisation on whose behalf the application was made (personal data).';
COMMENT ON COLUMN permit_registry.permit.valid_until_time IS 'Local time of day at which the permit expires on valid_until; NULL = end of day.';
COMMENT ON COLUMN permit_registry.permit.valid_from IS 'Start of validity (valid time)';
COMMENT ON COLUMN permit_registry.permit.valid_to IS 'End of validity (valid time); NULL = open';
COMMENT ON COLUMN permit_registry.permit.deleted_at IS 'Logical deletion timestamp';
COMMENT ON COLUMN permit_registry.permit.issuer_authority_id IS 'The authority that issued the permit.';
COMMENT ON TABLE permit_registry.permit_history IS 'History (versioned) of Permit; fill via trigger on permit_registry.permit.';
COMMENT ON TABLE permit_registry.permit_condition IS 'Obligation attached to a permit.';
COMMENT ON COLUMN permit_registry.permit_condition.id IS 'Surrogate key';
COMMENT ON COLUMN permit_registry.permit_condition.category IS 'Category of the condition; NULL = not categorised (conditions recorded before CR-7).';
COMMENT ON COLUMN permit_registry.permit_condition.ord IS 'Position within the owning collection';
COMMENT ON VIEW permit_registry.permit_effective_status IS 'Effective status incl. derived ''expired'' (status granted and validity passed).';

-- =============================================================================
-- Urban Tree Cadastre - physical data model (DRAFT v0.1, 2026-11-23)
-- Target: PostgreSQL >= 15, PostGIS >= 3.3
-- CRS:    ETRS89 / UTM zone 32N = EPSG:25832 (requirements UC1)
--
-- Run order: 01_schema.sql -> 02_rules_and_audit.sql -> 03_views.sql
--            -> 04_codelists_seed.sql -> (05_migrate_legacy.sql, once)
--
-- Conventions
--   * English snake_case identifiers; German display labels live in code lists.
--   * Business entities that tablets create offline (tree, inspection, measure)
--     use client-generated UUID keys so records can be created without a
--     server round-trip (A-07). Trees additionally get a short, human-readable
--     tree_number assigned by the server (continues legacy baum_nr).
--   * Code lists use natural text codes (stable, readable in the exchange file).
--   * Every mutable business table carries created_*/updated_*/row_version.
--     row_version supports optimistic locking during offline sync.
--   * is_legacy_import = true relaxes a few NOT-NULL-like checks for records
--     migrated from the legacy system, where data is incomplete (A-20).
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS cadastre;
COMMENT ON SCHEMA cadastre IS 'Urban tree cadastre - operational data (Parks Department).';

-- -----------------------------------------------------------------------------
-- Helper: who is acting? The application sets  SET LOCAL app.actor = '<login>'
-- at the start of every transaction (also for synced offline batches, using
-- the login of the inspector who captured the data).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cadastre.current_actor()
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT coalesce(nullif(current_setting('app.actor', true), ''), session_user::text)
$$;
COMMENT ON FUNCTION cadastre.current_actor() IS
  'Login of the acting user: GUC app.actor if set by the application, else the DB session user.';

-- -----------------------------------------------------------------------------
-- Enumerations (small, closed sets defined by the requirements)
-- -----------------------------------------------------------------------------
CREATE TYPE cadastre.tree_status     AS ENUM ('living', 'felled');
CREATE TYPE cadastre.defect_severity AS ENUM ('low', 'medium', 'high');
CREATE TYPE cadastre.measure_status  AS ENUM ('ordered', 'done', 'cancelled');

-- -----------------------------------------------------------------------------
-- Code lists
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.species (
    species_id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    botanical_name         text    NOT NULL,
    genus                  text    GENERATED ALWAYS AS (split_part(botanical_name, ' ', 1)) STORED,
    common_name_de         text,
    is_active              boolean NOT NULL DEFAULT true,
    replaced_by_species_id integer REFERENCES cadastre.species (species_id),
    remarks                text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version            integer     NOT NULL DEFAULT 1,
    CONSTRAINT species_name_not_blank_ck CHECK (btrim(botanical_name) <> ''),
    CONSTRAINT species_not_replaced_by_self_ck CHECK (replaced_by_species_id IS DISTINCT FROM species_id)
);
CREATE UNIQUE INDEX species_botanical_name_uq ON cadastre.species (lower(botanical_name));
COMMENT ON TABLE  cadastre.species IS
  'City species list (~900 entries), extended by the arborist team. Entries are never deleted, only deactivated (A-05).';
COMMENT ON COLUMN cadastre.species.botanical_name IS
  'Full botanical name incl. cultivar, e.g. ''Tilia cordata ''Greenspire''''. Unique case-insensitively.';
COMMENT ON COLUMN cadastre.species.replaced_by_species_id IS
  'Set when an entry is retired because of a taxonomic rename/merge; points to the accepted entry.';

CREATE TABLE cadastre.defect_type (
    defect_code text PRIMARY KEY CHECK (defect_code ~ '^[a-z][a-z0-9_]*$'),
    label_de    text    NOT NULL,
    label_en    text,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0
);
COMMENT ON TABLE cadastre.defect_type IS 'Fixed list of tree defects maintained by the department (UC2).';

CREATE TABLE cadastre.measure_type (
    measure_type_code text PRIMARY KEY CHECK (measure_type_code ~ '^[a-z][a-z0-9_]*$'),
    label_de          text    NOT NULL,
    label_en          text,
    is_felling        boolean NOT NULL DEFAULT false,
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0
);
COMMENT ON TABLE  cadastre.measure_type IS 'Kinds of arboricultural measures (pruning, felling, cabling, ...) (UC3).';
COMMENT ON COLUMN cadastre.measure_type.is_felling IS 'True for measure types that remove the tree (used to propose UC4 felling).';

CREATE TABLE cadastre.measure_priority (
    priority    smallint PRIMARY KEY CHECK (priority BETWEEN 1 AND 9),
    label_de    text NOT NULL,
    label_en    text,
    description text
);
COMMENT ON TABLE cadastre.measure_priority IS 'Priority scale for measures; 1 = most urgent (A-13).';

CREATE TABLE cadastre.vitality_class (
    vitality_class smallint PRIMARY KEY CHECK (vitality_class BETWEEN 1 AND 5),
    label_de       text NOT NULL,
    label_en       text,
    description    text
);
COMMENT ON TABLE cadastre.vitality_class IS
  'Vitality classes 1-5 as stated in the requirements (named "Roloff"). See A-10: Roloff is classically 0-3.';

CREATE TABLE cadastre.felling_reason (
    felling_reason_code text PRIMARY KEY CHECK (felling_reason_code ~ '^[a-z][a-z0-9_]*$'),
    label_de            text    NOT NULL,
    label_en            text,
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer NOT NULL DEFAULT 0
);
COMMENT ON TABLE cadastre.felling_reason IS 'Reasons why a tree was felled / removed (UC4, A-15).';

-- -----------------------------------------------------------------------------
-- People and organisations
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.staff (
    staff_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    login            text UNIQUE,
    display_name     text    NOT NULL,
    pseudonym        text    NOT NULL UNIQUE
                     DEFAULT ('P-' || upper(substr(md5(gen_random_uuid()::text), 1, 10))),
    is_inspector     boolean NOT NULL DEFAULT false,
    is_arborist      boolean NOT NULL DEFAULT false,
    is_active        boolean NOT NULL DEFAULT true,
    is_legacy_import boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version      integer     NOT NULL DEFAULT 1
);
COMMENT ON TABLE  cadastre.staff IS
  'Inspectors and arborists. PERSONAL DATA (display_name, login) - never exported to open data or the agency (A-17).';
COMMENT ON COLUMN cadastre.staff.login IS 'Account name in the city identity provider; NULL for migrated legacy names without an account.';
COMMENT ON COLUMN cadastre.staff.pseudonym IS 'Stable, non-speaking identifier used in the regional exchange file instead of the name.';

CREATE TABLE cadastre.contractor (
    contractor_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text    NOT NULL,
    is_in_house      boolean NOT NULL DEFAULT false,
    is_active        boolean NOT NULL DEFAULT true,
    is_legacy_import boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version      integer     NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX contractor_name_uq ON cadastre.contractor (lower(name));
COMMENT ON TABLE  cadastre.contractor IS 'Companies (or the in-house crew) that carry out measures (UC3, A-14).';

-- -----------------------------------------------------------------------------
-- Spatial reference units: parks and street segments (UC1)
-- Assumed to be loaded/maintained from the city GIS (A-08).
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.park (
    park_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    park_code    text UNIQUE,
    name         text    NOT NULL,
    geom         geometry(MultiPolygon, 25832),
    is_active    boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT park_geom_valid_ck CHECK (geom IS NULL OR ST_IsValid(geom))
);
CREATE INDEX park_geom_gix ON cadastre.park USING gist (geom);
COMMENT ON TABLE cadastre.park IS 'Parks and green spaces a tree can belong to.';

CREATE TABLE cadastre.street_segment (
    street_segment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_code      text UNIQUE,
    street_name       text NOT NULL,
    segment_label     text,
    geom              geometry(MultiLineString, 25832),
    is_active         boolean NOT NULL DEFAULT true,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX street_segment_geom_gix ON cadastre.street_segment USING gist (geom);
CREATE INDEX street_segment_name_ix  ON cadastre.street_segment (lower(street_name));
COMMENT ON TABLE  cadastre.street_segment IS 'Street segments (between two junctions) a street tree can belong to.';
COMMENT ON COLUMN cadastre.street_segment.segment_label IS 'Human-readable section description, e.g. ''Hauptstr. 1-35, north side''.';

-- -----------------------------------------------------------------------------
-- Tree (UC1, UC4)
-- -----------------------------------------------------------------------------
CREATE SEQUENCE cadastre.tree_number_seq AS integer START WITH 1;
COMMENT ON SEQUENCE cadastre.tree_number_seq IS
  'Public tree number. Must be set above max(legacy baum_nr) by the migration (05_migrate_legacy.sql).';

CREATE TABLE cadastre.tree (
    tree_id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tree_number                 integer NOT NULL UNIQUE DEFAULT nextval('cadastre.tree_number_seq'),
    species_id                  integer NOT NULL REFERENCES cadastre.species (species_id),
    planting_year               smallint,
    geom                        geometry(Point, 25832) NOT NULL,
    location_since              timestamptz NOT NULL DEFAULT now(),
    park_id                     integer REFERENCES cadastre.park (park_id),
    street_segment_id           integer REFERENCES cadastre.street_segment (street_segment_id),
    status                      cadastre.tree_status NOT NULL DEFAULT 'living',
    felled_on                   date,
    felling_reason_code         text REFERENCES cadastre.felling_reason (felling_reason_code),
    felling_measure_id          uuid,   -- FK added below (measure is defined later)
    compensation_trees_required smallint,
    remarks                     text,
    is_legacy_import            boolean NOT NULL DEFAULT false,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    created_by                  text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version                 integer     NOT NULL DEFAULT 1,

    CONSTRAINT tree_planting_year_ck
        CHECK (planting_year IS NULL OR planting_year BETWEEN 1700 AND 2100),
    CONSTRAINT tree_location_unit_ck
        CHECK (num_nonnulls(park_id, street_segment_id) = 1 OR is_legacy_import),
    CONSTRAINT tree_living_has_no_felling_data_ck
        CHECK (status <> 'living' OR (felled_on IS NULL AND felling_reason_code IS NULL
                                      AND felling_measure_id IS NULL AND compensation_trees_required IS NULL)),
    CONSTRAINT tree_felled_has_felling_data_ck
        CHECK (status <> 'felled' OR (felled_on IS NOT NULL AND felling_reason_code IS NOT NULL)
                                  OR is_legacy_import),
    CONSTRAINT tree_planted_before_felled_ck
        CHECK (felled_on IS NULL OR planting_year IS NULL
               OR planting_year <= extract(year FROM felled_on)),
    CONSTRAINT tree_compensation_ck
        CHECK (compensation_trees_required IS NULL OR compensation_trees_required >= 0),
    CONSTRAINT tree_geom_ck
        CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom)),
    -- Plausibility: inside the UTM 32N band (no zone prefix). Replace with the
    -- city's bounding box once known (A-19).
    CONSTRAINT tree_geom_extent_ck
        CHECK (ST_X(geom) BETWEEN 166000 AND 834000 AND ST_Y(geom) BETWEEN 5200000 AND 6200000)
);

COMMENT ON TABLE  cadastre.tree IS
  'One row per tree ever recorded. Felled trees are kept (status = felled), never deleted (UC4).';
COMMENT ON COLUMN cadastre.tree.tree_id IS 'Technical key, generated on the tablet (offline capable).';
COMMENT ON COLUMN cadastre.tree.tree_number IS 'Public, human-readable tree number (tree tag). Continues legacy baum_nr.';
COMMENT ON COLUMN cadastre.tree.planting_year IS 'Planting year if known (UC1); NULL = unknown.';
COMMENT ON COLUMN cadastre.tree.geom IS 'Current stem position, EPSG:25832. Previous positions: tree_location_history.';
COMMENT ON COLUMN cadastre.tree.location_since IS 'When the current position was recorded/corrected; maintained by trigger.';
COMMENT ON COLUMN cadastre.tree.park_id IS 'Park the tree belongs to. Exactly one of park_id / street_segment_id is set (A-09).';
COMMENT ON COLUMN cadastre.tree.felling_measure_id IS 'The measure (type is_felling) that removed the tree, if ordered through the cadastre.';
COMMENT ON COLUMN cadastre.tree.compensation_trees_required IS
  'Number of replacement trees required for this felling (from permit / tree protection by-law), A-16.';
COMMENT ON COLUMN cadastre.tree.is_legacy_import IS 'Migrated from legacy table baum; some mandatory checks are relaxed.';

-- Map view (requirement: ~5,000 trees in a bbox < 1 s) -> GiST on geom,
-- plus a partial index for the common "living trees only" map layer.
CREATE INDEX tree_geom_gix          ON cadastre.tree USING gist (geom);
CREATE INDEX tree_geom_living_gix   ON cadastre.tree USING gist (geom) WHERE status = 'living';
CREATE INDEX tree_species_ix        ON cadastre.tree (species_id);
CREATE INDEX tree_park_ix           ON cadastre.tree (park_id) WHERE park_id IS NOT NULL;
CREATE INDEX tree_street_segment_ix ON cadastre.tree (street_segment_id) WHERE street_segment_id IS NOT NULL;
CREATE INDEX tree_updated_at_ix     ON cadastre.tree (updated_at);

-- Location corrections (Other: "we need to know the previous location and when it was corrected")
CREATE TABLE cadastre.tree_location_history (
    location_history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tree_id             uuid NOT NULL REFERENCES cadastre.tree (tree_id),
    geom                geometry(Point, 25832) NOT NULL,
    valid_from          timestamptz NOT NULL,
    valid_to            timestamptz NOT NULL,
    corrected_by        text NOT NULL,
    correction_reason   text,
    CONSTRAINT tree_location_history_period_ck CHECK (valid_from <= valid_to)
);
CREATE INDEX tree_location_history_tree_ix ON cadastre.tree_location_history (tree_id, valid_to DESC);
COMMENT ON TABLE  cadastre.tree_location_history IS
  'Superseded tree positions. One row is written by trigger each time tree.geom changes. Append-only.';
COMMENT ON COLUMN cadastre.tree_location_history.valid_to IS 'Moment of the correction (= when this position stopped being current).';
COMMENT ON COLUMN cadastre.tree_location_history.correction_reason IS 'Taken from GUC app.change_reason if the application sets it.';

-- Compensation planting (UC4: a felled tree may be replaced by one or more new trees)
CREATE TABLE cadastre.tree_replacement (
    felled_tree_id      uuid NOT NULL REFERENCES cadastre.tree (tree_id),
    replacement_tree_id uuid NOT NULL REFERENCES cadastre.tree (tree_id),
    remarks             text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          text        NOT NULL DEFAULT cadastre.current_actor(),
    PRIMARY KEY (felled_tree_id, replacement_tree_id),
    CONSTRAINT tree_replacement_not_self_ck CHECK (felled_tree_id <> replacement_tree_id)
);
CREATE INDEX tree_replacement_replacement_ix ON cadastre.tree_replacement (replacement_tree_id);
COMMENT ON TABLE cadastre.tree_replacement IS
  'Links a felled tree to its compensation planting(s). Modelled n:m so one new tree can also compensate several felled trees (A-16).';

-- -----------------------------------------------------------------------------
-- Inspection (UC2)  ~200,000 rows/year, kept >= 30 years (~6 M rows)
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.inspection (
    inspection_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tree_id                uuid NOT NULL REFERENCES cadastre.tree (tree_id),
    inspected_on           date NOT NULL,
    inspector_id           uuid NOT NULL REFERENCES cadastre.staff (staff_id),
    trunk_circumference_cm smallint,
    crown_diameter_m       numeric(4,1),
    height_m               numeric(4,1),
    vitality_class         smallint REFERENCES cadastre.vitality_class (vitality_class),
    remarks                text,
    is_legacy_import       boolean NOT NULL DEFAULT false,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version            integer     NOT NULL DEFAULT 1,

    CONSTRAINT inspection_tree_uq UNIQUE (inspection_id, tree_id),   -- target of measure composite FK
    CONSTRAINT inspection_trunk_ck  CHECK (trunk_circumference_cm IS NULL OR trunk_circumference_cm BETWEEN 1 AND 2000),
    CONSTRAINT inspection_crown_ck  CHECK (crown_diameter_m IS NULL OR crown_diameter_m > 0 AND crown_diameter_m <= 60),
    CONSTRAINT inspection_height_ck CHECK (height_m IS NULL OR height_m > 0 AND height_m <= 80),
    CONSTRAINT inspection_vitality_required_ck CHECK (vitality_class IS NOT NULL OR is_legacy_import),
    CONSTRAINT inspection_date_ck   CHECK (inspected_on >= DATE '1950-01-01')
);
CREATE INDEX inspection_tree_date_ix  ON cadastre.inspection (tree_id, inspected_on DESC, created_at DESC);
CREATE INDEX inspection_date_ix       ON cadastre.inspection (inspected_on);
CREATE INDEX inspection_inspector_ix  ON cadastre.inspection (inspector_id);
CREATE INDEX inspection_updated_at_ix ON cadastre.inspection (updated_at);

COMMENT ON TABLE  cadastre.inspection IS
  'Regular tree inspection (>= 1 per tree and year). NEVER deleted (enforced by trigger + privileges); all changes audited.';
COMMENT ON COLUMN cadastre.inspection.trunk_circumference_cm IS 'Trunk circumference in cm, measured at 1.0 m above ground (A-11).';
COMMENT ON COLUMN cadastre.inspection.crown_diameter_m IS 'Crown diameter in m (0.1 m resolution).';
COMMENT ON COLUMN cadastre.inspection.height_m IS 'Tree height in m (0.1 m resolution).';
COMMENT ON COLUMN cadastre.inspection.vitality_class IS 'Vitality class 1-5 (A-10). Mandatory for new inspections.';
COMMENT ON COLUMN cadastre.inspection.inspector_id IS 'Inspector (personal data via staff).';

CREATE TABLE cadastre.inspection_defect (
    inspection_id    uuid NOT NULL REFERENCES cadastre.inspection (inspection_id),
    defect_code      text NOT NULL REFERENCES cadastre.defect_type (defect_code),
    severity         cadastre.defect_severity,
    remarks          text,
    is_legacy_import boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL DEFAULT cadastre.current_actor(),
    PRIMARY KEY (inspection_id, defect_code),
    CONSTRAINT inspection_defect_severity_required_ck CHECK (severity IS NOT NULL OR is_legacy_import)
);
CREATE INDEX inspection_defect_code_ix ON cadastre.inspection_defect (defect_code);
COMMENT ON TABLE  cadastre.inspection_defect IS
  'Defects found in an inspection; each defect type at most once per inspection, with one severity (A-12).';
COMMENT ON COLUMN cadastre.inspection_defect.severity IS 'low / medium / high. NULL only for migrated legacy defects (legacy had no severity).';

-- -----------------------------------------------------------------------------
-- Measure (UC3)  ~25,000 rows/year
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.measure (
    measure_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tree_id             uuid NOT NULL,
    inspection_id       uuid NOT NULL,
    measure_type_code   text NOT NULL REFERENCES cadastre.measure_type (measure_type_code),
    description         text,
    priority            smallint REFERENCES cadastre.measure_priority (priority),
    due_on              date,
    ordered_on          date NOT NULL DEFAULT current_date,
    ordered_by          uuid REFERENCES cadastre.staff (staff_id),
    status              cadastre.measure_status NOT NULL DEFAULT 'ordered',
    completed_on        date,
    contractor_id       integer REFERENCES cadastre.contractor (contractor_id),
    cancelled_on        date,
    cancellation_reason text,
    is_legacy_import    boolean NOT NULL DEFAULT false,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          text        NOT NULL DEFAULT cadastre.current_actor(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          text        NOT NULL DEFAULT cadastre.current_actor(),
    row_version         integer     NOT NULL DEFAULT 1,

    -- the measure's tree must be the tree of the inspection it was ordered from
    CONSTRAINT measure_inspection_fk FOREIGN KEY (inspection_id, tree_id)
        REFERENCES cadastre.inspection (inspection_id, tree_id),
    CONSTRAINT measure_order_data_required_ck
        CHECK ((priority IS NOT NULL AND due_on IS NOT NULL AND ordered_by IS NOT NULL) OR is_legacy_import),
    CONSTRAINT measure_due_after_order_ck
        CHECK (due_on IS NULL OR due_on >= ordered_on OR is_legacy_import),
    CONSTRAINT measure_done_ck
        CHECK (status <> 'done' OR (completed_on IS NOT NULL AND (contractor_id IS NOT NULL OR is_legacy_import))),
    CONSTRAINT measure_completed_only_when_done_ck
        CHECK (status = 'done' OR completed_on IS NULL),
    CONSTRAINT measure_cancelled_ck
        CHECK ((status = 'cancelled') = (cancelled_on IS NOT NULL))
);
CREATE INDEX measure_tree_ix       ON cadastre.measure (tree_id);
CREATE INDEX measure_inspection_ix ON cadastre.measure (inspection_id);
CREATE INDEX measure_open_due_ix   ON cadastre.measure (due_on, priority) WHERE status = 'ordered';
CREATE INDEX measure_contractor_ix ON cadastre.measure (contractor_id) WHERE contractor_id IS NOT NULL;
CREATE INDEX measure_updated_at_ix ON cadastre.measure (updated_at);

COMMENT ON TABLE  cadastre.measure IS
  'Measure ordered by an arborist from an inspection; later marked done (completion date + contractor) or cancelled. Never deleted.';
COMMENT ON COLUMN cadastre.measure.tree_id IS 'Redundant with inspection.tree_id for fast per-tree queries; kept consistent by composite FK.';
COMMENT ON COLUMN cadastre.measure.ordered_by IS 'Arborist who ordered the measure (personal data via staff).';
COMMENT ON COLUMN cadastre.measure.contractor_id IS 'Contractor that did the work; required when status = done (may be pre-assigned earlier).';
COMMENT ON COLUMN cadastre.measure.status IS 'ordered -> done | cancelled (A-14: cancellation added, measures are not deleted).';

ALTER TABLE cadastre.tree
    ADD CONSTRAINT tree_felling_measure_fk
    FOREIGN KEY (felling_measure_id) REFERENCES cadastre.measure (measure_id);

-- -----------------------------------------------------------------------------
-- Audit log ("auditors need to see who changed what")
-- -----------------------------------------------------------------------------
CREATE TABLE cadastre.audit_log (
    audit_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name      text        NOT NULL,
    row_key         text        NOT NULL,
    action          char(1)     NOT NULL CHECK (action IN ('I', 'U', 'D')),
    changed_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    changed_by      text        NOT NULL,
    transaction_id  bigint      NOT NULL DEFAULT txid_current(),
    changed_columns text[],
    old_row         jsonb,
    new_row         jsonb
);
CREATE INDEX audit_log_row_ix        ON cadastre.audit_log (table_name, row_key, changed_at);
CREATE INDEX audit_log_changed_at_ix ON cadastre.audit_log USING brin (changed_at);
COMMENT ON TABLE cadastre.audit_log IS
  'Append-only change log written by trigger cadastre.trg_audit(). Contains personal data (logins) - restricted access (A-18).';

COMMIT;

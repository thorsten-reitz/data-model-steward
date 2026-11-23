-- =====================================================================
-- Urban Tree Cadastre – PostgreSQL/PostGIS schema
-- Model version : 0.1.0 (first draft, 2026-11-23)
-- Target        : PostgreSQL >= 15, PostGIS >= 3.3
-- CRS           : ETRS89 / UTM zone 32N (EPSG:25832)
--
-- Run order: 01_schema.sql -> 02_audit_and_rules.sql -> 03_views.sql
--            -> 04_seed_codelists.sql -> (optional) 90_migrate_legacy.sql
-- Assumptions referenced as [A-nn] are listed in ../ASSUMPTIONS.md
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid() on PG < 13 / convenience

CREATE SCHEMA IF NOT EXISTS cadastre;
SET search_path = cadastre, public;

-- ---------------------------------------------------------------------
-- Enumerations (small, stable value sets that the business does not
-- maintain itself). Department-maintained lists are tables, see below.
-- ---------------------------------------------------------------------
CREATE TYPE tree_status      AS ENUM ('standing', 'felled', 'void');            -- [A-08]
CREATE TYPE defect_severity  AS ENUM ('low', 'medium', 'high');
CREATE TYPE measure_status   AS ENUM ('ordered', 'done', 'cancelled');          -- [A-14]
CREATE TYPE measure_priority AS ENUM ('immediate', 'high', 'normal', 'low');    -- [A-13]
CREATE TYPE data_origin      AS ENUM ('app', 'legacy_migration');               -- [A-20]

-- ---------------------------------------------------------------------
-- Common bookkeeping columns (repeated per table, documented once):
--   created_at / created_by / updated_at / updated_by : maintained by trigger
--   row_version : optimistic-locking counter for offline sync  [A-17]
-- ---------------------------------------------------------------------

-- =====================================================================
-- 1. Code lists maintained by the department
-- =====================================================================

-- Species list (~900 entries, extended by arborists a few times a year)
CREATE TABLE species (
    species_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    species_code     varchar(20)  NOT NULL UNIQUE,     -- stable city code used in exchange files [A-05]
    botanical_name   varchar(150) NOT NULL UNIQUE,     -- full name incl. cultivar, e.g. 'Acer platanoides ''Globosum'''
    genus            varchar(60)  NOT NULL,
    species_epithet  varchar(60),                      -- NULL for genus-only entries ('Tilia spec.')
    infraspecific    varchar(100),                     -- subspecies / variety / cultivar
    common_name_de   varchar(150),
    common_name_en   varchar(150),
    is_active        boolean      NOT NULL DEFAULT true, -- inactive = no longer selectable for new trees
    replaced_by_id   integer REFERENCES species(species_id),  -- taxonomic synonym handling
    note             text,
    created_at       timestamptz  NOT NULL DEFAULT now(),
    created_by       text         NOT NULL DEFAULT current_user,
    updated_at       timestamptz  NOT NULL DEFAULT now(),
    updated_by       text         NOT NULL DEFAULT current_user,
    row_version      integer      NOT NULL DEFAULT 1,
    CONSTRAINT species_not_self_replaced CHECK (replaced_by_id IS DISTINCT FROM species_id)
);
COMMENT ON TABLE species IS 'City species list. Botanical names are controlled; free text is not allowed on trees.';

-- Vitality classes as a lookup table so the scale can be changed without DDL [A-10]
CREATE TABLE vitality_class (
    vitality_class   smallint     PRIMARY KEY CHECK (vitality_class BETWEEN 0 AND 9),
    label_de         varchar(60)  NOT NULL,
    label_en         varchar(60)  NOT NULL,
    description      text
);

-- Fixed defect list maintained by the department
CREATE TABLE defect_type (
    defect_type_code varchar(30)  PRIMARY KEY,          -- e.g. 'DEADWOOD'
    label_de         varchar(100) NOT NULL,
    label_en         varchar(100) NOT NULL,
    is_active        boolean      NOT NULL DEFAULT true,
    sort_order       smallint
);

-- Measure types (pruning, felling, cabling, ...)
CREATE TABLE measure_type (
    measure_type_code varchar(30)  PRIMARY KEY,         -- e.g. 'PRUNING', 'FELLING'
    label_de          varchar(100) NOT NULL,
    label_en          varchar(100) NOT NULL,
    is_felling        boolean      NOT NULL DEFAULT false, -- completing such a measure fells the tree [A-15]
    is_active         boolean      NOT NULL DEFAULT true,
    sort_order        smallint
);

-- Reasons for felling
CREATE TABLE felling_reason (
    felling_reason_code varchar(30)  PRIMARY KEY,       -- e.g. 'TRAFFIC_SAFETY', 'CONSTRUCTION'
    label_de            varchar(100) NOT NULL,
    label_en            varchar(100) NOT NULL,
    is_active           boolean      NOT NULL DEFAULT true
);

-- =====================================================================
-- 2. Spatial reference units (park / street segment)
--    Assumed to be master data imported from the city GIS. [A-06]
-- =====================================================================
CREATE TABLE park (
    park_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    park_code    varchar(30)  NOT NULL UNIQUE,
    name         varchar(150) NOT NULL,
    geom         geometry(MultiPolygon, 25832),          -- may be NULL until GIS import is done
    is_active    boolean      NOT NULL DEFAULT true,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    created_by   text         NOT NULL DEFAULT current_user,
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    updated_by   text         NOT NULL DEFAULT current_user,
    row_version  integer      NOT NULL DEFAULT 1
);
CREATE INDEX park_geom_gix ON park USING gist (geom);

CREATE TABLE street_segment (
    street_segment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    segment_code      varchar(30)  NOT NULL UNIQUE,      -- key from the city street register
    street_name       varchar(150) NOT NULL,
    from_description  varchar(150),                      -- e.g. 'Hauptstr. 1 - 25'
    geom              geometry(MultiLineString, 25832),
    is_active         boolean      NOT NULL DEFAULT true,
    created_at        timestamptz  NOT NULL DEFAULT now(),
    created_by        text         NOT NULL DEFAULT current_user,
    updated_at        timestamptz  NOT NULL DEFAULT now(),
    updated_by        text         NOT NULL DEFAULT current_user,
    row_version       integer      NOT NULL DEFAULT 1
);
CREATE INDEX street_segment_geom_gix ON street_segment USING gist (geom);

-- =====================================================================
-- 3. Parties: staff (inspectors / arborists) and contractors
-- =====================================================================

-- Staff: PERSONAL DATA. Never exposed in open data. [A-18]
CREATE TABLE staff (
    staff_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_code   varchar(20)  NOT NULL UNIQUE,           -- pseudonymous code, safe for the agency exchange
    full_name    varchar(120) NOT NULL,                  -- personal data
    login_name   varchar(60)  UNIQUE,                    -- DB/app login, links audit entries to a person
    is_inspector boolean      NOT NULL DEFAULT false,
    is_arborist  boolean      NOT NULL DEFAULT false,
    is_active    boolean      NOT NULL DEFAULT true,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    created_by   text         NOT NULL DEFAULT current_user,
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    updated_by   text         NOT NULL DEFAULT current_user,
    row_version  integer      NOT NULL DEFAULT 1
);
COMMENT ON TABLE staff IS 'PERSONAL DATA (GDPR). Names must not leave the department; use staff_code externally.';
COMMENT ON COLUMN staff.full_name IS 'PERSONAL DATA';

CREATE TABLE contractor (
    contractor_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          varchar(150) NOT NULL UNIQUE,          -- company name (legal entity, not personal data)
    vat_id        varchar(30),
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    created_by    text         NOT NULL DEFAULT current_user,
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    updated_by    text         NOT NULL DEFAULT current_user,
    row_version   integer      NOT NULL DEFAULT 1
);

-- =====================================================================
-- 4. Core: tree
-- =====================================================================
CREATE SEQUENCE tree_number_seq START 1000000;           -- new numbers above legacy range [A-03]

CREATE TABLE tree (
    tree_id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),  -- client-generated offline [A-17]
    tree_number         integer      NOT NULL UNIQUE DEFAULT nextval('tree_number_seq'), -- public, stable id (= legacy baum_nr)
    species_id          integer      NOT NULL REFERENCES species(species_id),
    planting_year       smallint,
    location            geometry(Point, 25832) NOT NULL,
    location_corrected_at timestamptz,                   -- last correction, history in tree_location_history
    park_id             integer      REFERENCES park(park_id),
    street_segment_id   integer      REFERENCES street_segment(street_segment_id),
    status              tree_status  NOT NULL DEFAULT 'standing',
    felling_date        date,
    felling_reason_code varchar(30)  REFERENCES felling_reason(felling_reason_code),
    felling_measure_id  uuid,                            -- FK added after measure table
    compensation_required smallint,                     -- number of replacement trees required [A-16]
    void_reason         text,                            -- why a record was voided (registered in error)
    remarks             text,
    origin              data_origin  NOT NULL DEFAULT 'app',
    legacy_species_text varchar(120),                    -- original free text from legacy, for review
    created_at          timestamptz  NOT NULL DEFAULT now(),
    created_by          text         NOT NULL DEFAULT current_user,
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    updated_by          text         NOT NULL DEFAULT current_user,
    row_version         integer      NOT NULL DEFAULT 1,

    CONSTRAINT tree_planting_year_plausible
        CHECK (planting_year IS NULL OR planting_year BETWEEN 1600 AND 2100),     -- [A-04]
    -- exactly one spatial unit: a tree belongs to a park OR a street segment  [A-07]
    CONSTRAINT tree_one_spatial_unit
        CHECK (num_nonnulls(park_id, street_segment_id) = 1),
    CONSTRAINT tree_felling_consistent CHECK (
        (status = 'felled'
            AND (felling_date IS NOT NULL OR origin = 'legacy_migration')        -- legacy has no date [A-21]
            AND (felling_reason_code IS NOT NULL OR origin = 'legacy_migration'))
        OR (status <> 'felled'
            AND felling_date IS NULL AND felling_reason_code IS NULL AND felling_measure_id IS NULL)
    ),
    CONSTRAINT tree_void_has_reason CHECK (status <> 'void' OR void_reason IS NOT NULL),
    CONSTRAINT tree_compensation_nonneg CHECK (compensation_required IS NULL OR compensation_required >= 0),
    CONSTRAINT tree_location_valid CHECK (ST_IsValid(location) AND NOT ST_IsEmpty(location))
);
COMMENT ON TABLE tree IS 'One row per tree ever recorded. Trees are never deleted; felled trees keep status=felled.';
COMMENT ON COLUMN tree.tree_number IS 'Human-readable, stable public identifier (tag number). Legacy baum_nr is kept.';
COMMENT ON COLUMN tree.location IS 'Current (corrected) position, EPSG:25832. Previous positions in tree_location_history.';

CREATE INDEX tree_location_gix       ON tree USING gist (location);            -- map bbox queries
CREATE INDEX tree_location_standing_gix ON tree USING gist (location) WHERE status = 'standing';
CREATE INDEX tree_species_idx        ON tree (species_id);
CREATE INDEX tree_park_idx           ON tree (park_id)           WHERE park_id IS NOT NULL;
CREATE INDEX tree_street_segment_idx ON tree (street_segment_id) WHERE street_segment_id IS NOT NULL;
CREATE INDEX tree_updated_at_idx     ON tree (updated_at);                     -- sync "changed since"

-- Location history: one row per superseded position [UC "location correction"]
CREATE TABLE tree_location_history (
    tree_location_history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tree_id          uuid        NOT NULL REFERENCES tree(tree_id),
    location         geometry(Point, 25832) NOT NULL,   -- the PREVIOUS position
    valid_from       timestamptz NOT NULL,              -- when that position was recorded
    valid_to         timestamptz NOT NULL,              -- when it was corrected
    corrected_by     text        NOT NULL,
    correction_reason text,
    CONSTRAINT tree_location_history_period CHECK (valid_to >= valid_from)
);
CREATE INDEX tree_location_history_tree_idx ON tree_location_history (tree_id, valid_to DESC);

-- Compensation planting: a felled tree may be replaced by one or more new trees.
-- Modelled M:N so that one new tree can also compensate several felled ones. [A-16]
CREATE TABLE tree_replacement (
    felled_tree_id      uuid NOT NULL REFERENCES tree(tree_id),
    replacement_tree_id uuid NOT NULL REFERENCES tree(tree_id),
    remarks             text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          text        NOT NULL DEFAULT current_user,
    PRIMARY KEY (felled_tree_id, replacement_tree_id),
    CONSTRAINT tree_replacement_not_self CHECK (felled_tree_id <> replacement_tree_id)
);
CREATE INDEX tree_replacement_replacement_idx ON tree_replacement (replacement_tree_id);

-- =====================================================================
-- 5. Inspection (append-only in the business sense: never deleted)
-- =====================================================================
CREATE TABLE inspection (
    inspection_id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    tree_id                uuid         NOT NULL REFERENCES tree(tree_id),
    inspection_date        date         NOT NULL,
    inspector_id           integer      REFERENCES staff(staff_id),    -- NULL only for unmatched legacy rows
    trunk_circumference_cm integer,                                     -- measured at 1.0 m height [A-11]
    crown_diameter_m       numeric(4,1),
    height_m               numeric(4,1),
    vitality_class         smallint     REFERENCES vitality_class(vitality_class),
    remarks                text,
    origin                 data_origin  NOT NULL DEFAULT 'app',
    legacy_inspector_text  varchar(60),                                 -- PERSONAL DATA, legacy only
    legacy_defects_text    text,                                        -- original comma list, legacy only
    recorded_at            timestamptz,                                 -- time captured on the tablet [A-17]
    created_at             timestamptz  NOT NULL DEFAULT now(),
    created_by             text         NOT NULL DEFAULT current_user,
    updated_at             timestamptz  NOT NULL DEFAULT now(),
    updated_by             text         NOT NULL DEFAULT current_user,
    row_version            integer      NOT NULL DEFAULT 1,

    CONSTRAINT inspection_inspector_required
        CHECK (inspector_id IS NOT NULL OR origin = 'legacy_migration'),
    CONSTRAINT inspection_vitality_required
        CHECK (vitality_class IS NOT NULL OR origin = 'legacy_migration'),   -- [A-12]
    CONSTRAINT inspection_date_plausible
        CHECK (inspection_date BETWEEN DATE '1950-01-01' AND DATE '2100-12-31'),
    CONSTRAINT inspection_circumference_range
        CHECK (trunk_circumference_cm IS NULL OR trunk_circumference_cm BETWEEN 1 AND 2000),
    CONSTRAINT inspection_crown_range
        CHECK (crown_diameter_m IS NULL OR crown_diameter_m BETWEEN 0.1 AND 60),
    CONSTRAINT inspection_height_range
        CHECK (height_m IS NULL OR height_m BETWEEN 0.1 AND 80),
    UNIQUE (inspection_id, tree_id)                                      -- target for measure composite FK
);
COMMENT ON COLUMN inspection.legacy_inspector_text IS 'PERSONAL DATA';
CREATE INDEX inspection_tree_date_idx ON inspection (tree_id, inspection_date DESC, created_at DESC); -- latest inspection
CREATE INDEX inspection_date_idx      ON inspection (inspection_date);                     -- exchange period
CREATE INDEX inspection_updated_at_idx ON inspection (updated_at);
CREATE INDEX inspection_inspector_idx ON inspection (inspector_id);

CREATE TABLE inspection_defect (
    inspection_id    uuid        NOT NULL REFERENCES inspection(inspection_id),
    defect_type_code varchar(30) NOT NULL REFERENCES defect_type(defect_type_code),
    severity         defect_severity,                 -- NULL only for migrated legacy defects [A-22]
    remarks          text,
    origin           data_origin NOT NULL DEFAULT 'app',
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL DEFAULT current_user,
    PRIMARY KEY (inspection_id, defect_type_code),    -- each defect type at most once per inspection [A-09]
    CONSTRAINT inspection_defect_severity_required
        CHECK (severity IS NOT NULL OR origin = 'legacy_migration')
);
CREATE INDEX inspection_defect_type_idx ON inspection_defect (defect_type_code);

-- =====================================================================
-- 6. Measure
-- =====================================================================
CREATE TABLE measure (
    measure_id        uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
    inspection_id     uuid             NOT NULL,                 -- the inspection it was ordered from
    tree_id           uuid             NOT NULL,                 -- redundant but FK-consistent, for fast queries
    measure_type_code varchar(30)      NOT NULL REFERENCES measure_type(measure_type_code),
    ordered_by_id     integer          REFERENCES staff(staff_id),       -- arborist
    ordered_on        date             NOT NULL,
    due_date          date,
    priority          measure_priority NOT NULL DEFAULT 'normal',
    status            measure_status   NOT NULL DEFAULT 'ordered',
    completed_on      date,
    contractor_id     integer          REFERENCES contractor(contractor_id),
    cancel_reason     text,
    remarks           text,
    origin            data_origin      NOT NULL DEFAULT 'app',
    created_at        timestamptz      NOT NULL DEFAULT now(),
    created_by        text             NOT NULL DEFAULT current_user,
    updated_at        timestamptz      NOT NULL DEFAULT now(),
    updated_by        text             NOT NULL DEFAULT current_user,
    row_version       integer          NOT NULL DEFAULT 1,

    CONSTRAINT measure_inspection_fk
        FOREIGN KEY (inspection_id, tree_id) REFERENCES inspection (inspection_id, tree_id),
    CONSTRAINT measure_ordered_by_required
        CHECK (ordered_by_id IS NOT NULL OR origin = 'legacy_migration'),
    CONSTRAINT measure_due_after_order
        CHECK (due_date IS NULL OR due_date >= ordered_on),
    CONSTRAINT measure_done_consistent CHECK (
        (status = 'done'
            AND completed_on IS NOT NULL
            AND completed_on >= ordered_on
            AND (contractor_id IS NOT NULL OR origin = 'legacy_migration'))  -- [A-23]
        OR (status <> 'done' AND completed_on IS NULL)
    ),
    CONSTRAINT measure_cancel_has_reason CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
CREATE INDEX measure_tree_idx       ON measure (tree_id);
CREATE INDEX measure_inspection_idx ON measure (inspection_id);
CREATE INDEX measure_open_due_idx   ON measure (due_date) WHERE status = 'ordered';     -- work lists
CREATE INDEX measure_updated_at_idx ON measure (updated_at);
CREATE INDEX measure_contractor_idx ON measure (contractor_id);

ALTER TABLE tree
    ADD CONSTRAINT tree_felling_measure_fk
    FOREIGN KEY (felling_measure_id) REFERENCES measure(measure_id);

-- =====================================================================
-- 7. Audit log (who changed what) – filled by triggers in 02_audit_and_rules.sql
-- =====================================================================
CREATE TABLE audit_log (
    audit_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name   text        NOT NULL,
    row_pk       text        NOT NULL,                  -- primary key as text (composite keys joined by '|')
    action       char(1)     NOT NULL CHECK (action IN ('I', 'U', 'D')),
    changed_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    changed_by   text        NOT NULL,                  -- app user (app.user setting) or DB role
    db_role      text        NOT NULL DEFAULT current_user,
    client_info  text,                                  -- e.g. tablet id / sync batch id (app.client setting)
    old_values   jsonb,
    new_values   jsonb,
    changed_cols text[]
);
COMMENT ON TABLE audit_log IS 'Append-only change log. Contains personal data (who changed what); access restricted to auditors.';
CREATE INDEX audit_log_row_idx  ON audit_log (table_name, row_pk, changed_at);
CREATE INDEX audit_log_time_idx ON audit_log (changed_at);

-- =====================================================================
-- 8. Export bookkeeping (monthly agency exchange, nightly open data)
-- =====================================================================
CREATE TABLE export_run (
    export_run_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    export_kind    text        NOT NULL CHECK (export_kind IN ('open_data', 'agency_exchange')),
    period_start   date,
    period_end     date,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    record_count   integer,
    file_name      text,
    file_sha256    text,
    schema_version text,
    CONSTRAINT export_run_period CHECK (period_end IS NULL OR period_start IS NULL OR period_end >= period_start)
);

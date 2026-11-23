-- tuning.sql — TreeCadastre 0.1.0, PostgreSQL 14+ / PostGIS 3
-- HAND-WRITTEN companion to the generated schema.sql (decision D-012). Run AFTER schema.sql.
-- schema.sql is regenerated from model.yaml; this file holds what the generator cannot
-- express: defaults, rule enforcement (C-xxx), audit triggers, derived columns,
-- physical indexes for the access paths in model.yaml `nfr`, sync support and the open data view.
-- NOT YET EXECUTED against a database (no PostgreSQL available when drafted) — test before use.

SET search_path = tree_cadastre, public;

-- ---------------------------------------------------------------------------
-- 1. Defaults from model.yaml (`default:`) — not emitted by the generator
-- ---------------------------------------------------------------------------
ALTER TABLE tree         ALTER COLUMN status SET DEFAULT 'standing';
ALTER TABLE measure      ALTER COLUMN status SET DEFAULT 'ordered';
ALTER TABLE measure      ALTER COLUMN order_date SET DEFAULT current_date;
ALTER TABLE staff_member ALTER COLUMN active SET DEFAULT true;

-- ---------------------------------------------------------------------------
-- 2. Rules (constraints section of model.yaml)
-- ---------------------------------------------------------------------------
-- C-001 felled <=> felling date; reason mandatory when felled
ALTER TABLE tree ADD CONSTRAINT c001_felling_consistent CHECK (
  ((status = 'felled') = (felling_date IS NOT NULL))
  AND (status <> 'felled' OR felling_reason IS NOT NULL));
-- C-002 (static part; "not after current year" is checked by the application)
ALTER TABLE tree ADD CONSTRAINT c002_planting_before_felling CHECK (
  felling_date IS NULL OR planting_year IS NULL OR planting_year <= extract(year FROM felling_date));
ALTER TABLE tree ADD CONSTRAINT c002_planting_year_range CHECK (planting_year BETWEEN 1600 AND 2100);
-- attribute ranges from model.yaml constraints (min/max)
ALTER TABLE inspection ADD CONSTRAINT inspection_vitality_range CHECK (vitality BETWEEN 1 AND 5);
ALTER TABLE inspection ADD CONSTRAINT inspection_trunk_range CHECK (trunk_circumference BETWEEN 1 AND 2000);
ALTER TABLE inspection ADD CONSTRAINT inspection_crown_range CHECK (crown_diameter >= 0);
ALTER TABLE inspection ADD CONSTRAINT inspection_height_range CHECK (height >= 0);
ALTER TABLE tree ADD CONSTRAINT tree_vitality_range CHECK (current_vitality BETWEEN 1 AND 5);
-- C-005 each defect type at most once per inspection
ALTER TABLE inspection_defects ADD CONSTRAINT c005_defect_once UNIQUE (inspection_id, defect_type);
-- extensible code list used inside a datatype: FK not emitted by the generator
ALTER TABLE inspection_defects ADD FOREIGN KEY (defect_type) REFERENCES defect_type (code);
-- C-006 measure status / dates
ALTER TABLE measure ADD CONSTRAINT c006_done_has_completion CHECK ((status = 'done') = (completion_date IS NOT NULL));
ALTER TABLE measure ADD CONSTRAINT c006_dates CHECK (due_date >= order_date AND (completion_date IS NULL OR completion_date >= order_date));
-- C-009 (static part) a tree cannot replace itself; "replaced tree is felled" via trigger below
ALTER TABLE tree_replaced_trees ADD CONSTRAINT c009_not_self CHECK (tree_id <> replaced_trees_id);
-- C-011 location corrections must actually move the point
ALTER TABLE location_correction ADD CONSTRAINT location_correction_moves CHECK (NOT ST_Equals(previous_location, corrected_location));

-- C-003 inspections are never deleted (also blocks the cascade to inspection_defects)
CREATE OR REPLACE FUNCTION forbid_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Deleting from %.% is not allowed (rule C-003)', TG_TABLE_SCHEMA, TG_TABLE_NAME;
END $$;
CREATE TRIGGER inspection_no_delete BEFORE DELETE ON inspection FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER inspection_no_truncate BEFORE TRUNCATE ON inspection FOR EACH STATEMENT EXECUTE FUNCTION forbid_delete();
-- Recommended in addition: REVOKE DELETE, TRUNCATE ON inspection, inspection_defects FROM <app role>;

-- C-004 / C-007 no inspection after felling
CREATE OR REPLACE FUNCTION check_inspection_date() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE fd date;
BEGIN
  IF NEW.inspection_date > current_date THEN
    RAISE EXCEPTION 'Inspection date % is in the future (C-004)', NEW.inspection_date;
  END IF;
  SELECT felling_date INTO fd FROM tree WHERE id = NEW.tree_id;
  IF fd IS NOT NULL AND NEW.inspection_date > fd THEN
    RAISE EXCEPTION 'Tree % was felled on %; inspection on % not allowed (C-004)', NEW.tree_id, fd, NEW.inspection_date;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER inspection_date_check BEFORE INSERT OR UPDATE OF inspection_date, tree_id ON inspection
  FOR EACH ROW EXECUTE FUNCTION check_inspection_date();

-- C-009 replaced trees must be felled
CREATE OR REPLACE FUNCTION check_replaced_tree_felled() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tree WHERE id = NEW.replaced_trees_id AND status = 'felled') THEN
    RAISE EXCEPTION 'Tree % is not felled and cannot be compensated (C-009)', NEW.replaced_trees_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER compensation_check BEFORE INSERT OR UPDATE ON tree_replaced_trees
  FOR EACH ROW EXECUTE FUNCTION check_replaced_tree_felled();

-- C-010 record every location change as a LocationCorrection (D-004)
CREATE OR REPLACE FUNCTION record_location_correction() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT ST_Equals(OLD.location, NEW.location) THEN
    INSERT INTO location_correction (tree_id, previous_location, corrected_location, corrected_at, reason)
    VALUES (NEW.id, OLD.location, NEW.location, now(), nullif(current_setting('tree_cadastre.correction_reason', true), ''));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tree_location_correction AFTER UPDATE OF location ON tree
  FOR EACH ROW EXECUTE FUNCTION record_location_correction();

-- C-011 derived columns tree.current_vitality / last_inspection_date (D-009)
CREATE OR REPLACE FUNCTION refresh_tree_latest_inspection() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE tree t SET (current_vitality, last_inspection_date) = (
      SELECT i.vitality, i.inspection_date FROM inspection i
      WHERE i.tree_id = t.id ORDER BY i.inspection_date DESC, i.id DESC LIMIT 1)
  WHERE t.id = NEW.tree_id OR (TG_OP = 'UPDATE' AND t.id = OLD.tree_id);
  RETURN NULL;
END $$;
CREATE TRIGGER inspection_refresh_tree AFTER INSERT OR UPDATE OF vitality, inspection_date, tree_id ON inspection
  FOR EACH ROW EXECUTE FUNCTION refresh_tree_latest_inspection();

-- ---------------------------------------------------------------------------
-- 3. Audit trail (history.mode = audit) — fills the generated <table>_history tables
-- ---------------------------------------------------------------------------
-- The application sets the acting user per transaction: SET LOCAL tree_cadastre.user = '<staff id or login>';
CREATE TABLE inspection_defects_history (            -- defects belong to the audited inspection
  history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  operation char(1) NOT NULL CHECK (operation IN ('I','U','D')),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  recorded_by text,
  row_data jsonb NOT NULL
);
CREATE INDEX ON inspection_defects_history ((row_data->>'inspection_id'), recorded_at);

CREATE OR REPLACE FUNCTION audit_row() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
  EXECUTE format('INSERT INTO %I.%I (operation, recorded_by, row_data) VALUES ($1, $2, $3)',
                 TG_TABLE_SCHEMA, TG_TABLE_NAME || '_history')
    USING left(TG_OP, 1), coalesce(nullif(current_setting('tree_cadastre.user', true), ''), session_user), to_jsonb(r);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['species','site','tree','inspection','inspection_defects','measure','contractor','staff_member'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON tree_cadastre.%I
                    FOR EACH ROW EXECUTE FUNCTION tree_cadastre.audit_row()', t || '_audit', t);
  END LOOP;
END $$;
-- Note: park.area / street_segment.axis changes are not audited yet (no history tables are
-- generated for subclass tables); add them if needed (A-009).

-- ---------------------------------------------------------------------------
-- 4. Offline sync support (D-013): last modification timestamp for "changed since" queries
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['species','site','tree','inspection','measure','contractor','staff_member'] LOOP
    EXECUTE format('ALTER TABLE tree_cadastre.%I ADD COLUMN modified_at timestamptz NOT NULL DEFAULT now()', t);
    EXECUTE format('CREATE INDEX ON tree_cadastre.%I (modified_at)', t);
  END LOOP;
END $$;
CREATE OR REPLACE FUNCTION touch_modified_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.modified_at := now(); RETURN NEW; END $$;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['species','site','tree','inspection','measure','contractor','staff_member'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON tree_cadastre.%I
                    FOR EACH ROW EXECUTE FUNCTION tree_cadastre.touch_modified_at()', t || '_touch', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Indexes for the access paths in model.yaml `nfr`
-- ---------------------------------------------------------------------------
-- Map view: ~5,000 trees in a bounding box < 1 s  →  GiST on the point
CREATE INDEX tree_location_gix ON tree USING gist (location);
CREATE INDEX tree_standing_location_gix ON tree USING gist (location) WHERE status = 'standing' AND deleted_at IS NULL;
-- Inspection history of a tree, newest first (6 M rows after 30 years)
CREATE INDEX inspection_tree_date_idx ON inspection (tree_id, inspection_date DESC);
-- Monthly exchange / yearly coverage check by date range (append-mostly table)
CREATE INDEX inspection_date_brin ON inspection USING brin (inspection_date);
-- Open measures work list
CREATE INDEX measure_open_idx ON measure (due_date, priority) WHERE status = 'ordered' AND deleted_at IS NULL;
-- Species type-ahead
CREATE INDEX species_name_prefix_idx ON species (botanical_name text_pattern_ops);
-- Partitioning is NOT needed at these volumes (< 10 M rows per table); revisit above ~100 M.

-- ---------------------------------------------------------------------------
-- 6. Open data view (UC5): living trees, no personal data
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW open_data_tree AS
SELECT t.id,
       t.tree_number,
       s.botanical_name,
       t.planting_year,
       t.location,                      -- EPSG:25832; transform with ST_Transform(location, 4326) for GeoJSON/WGS84 portals
       t.current_vitality AS latest_vitality
FROM tree t
JOIN species s ON s.id = t.species_id
WHERE t.status = 'standing' AND t.deleted_at IS NULL;
COMMENT ON VIEW open_data_tree IS 'Nightly open data export (S1 UC5). Must never expose staff_member data (S1 Other).';

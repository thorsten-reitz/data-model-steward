-- Hand-written physical tuning for UrbanTreeCadastre 0.1.0 (DRAFT, decision D-013).
-- Run AFTER exports/<version>/schema.sql. Not generated: keep in sync manually when the model changes.

SET search_path = urban_tree_cadastre, public;

-- ---------------------------------------------------------------- defaults (model `default:` values)
ALTER TABLE tree         ALTER COLUMN status SET DEFAULT 'standing';
ALTER TABLE measure      ALTER COLUMN status SET DEFAULT 'ordered';
ALTER TABLE species      ALTER COLUMN active SET DEFAULT true;
ALTER TABLE staff_member ALTER COLUMN active SET DEFAULT true;
ALTER TABLE contractor   ALTER COLUMN active SET DEFAULT true;

-- ---------------------------------------------------------------- performance (nfr)
-- Map view: ~5,000 trees in a bounding box < 1 s  ->  GiST on location, partial for live records.
CREATE INDEX tree_location_gix ON tree USING gist (location) WHERE deleted_at IS NULL;
-- Latest inspection per tree (open data "latest vitality", inspector app history).
CREATE INDEX inspection_tree_date_idx ON inspection (tree_id, inspection_date DESC);
-- ~200,000 inspections/year, append-mostly, 30 years retention (~6 M rows): BRIN for date-range reports.
CREATE INDEX inspection_date_brin ON inspection USING brin (inspection_date);
-- Open measures by due date / priority.
CREATE INDEX measure_open_idx ON measure (due_date, priority) WHERE status = 'ordered' AND deleted_at IS NULL;
CREATE INDEX site_area_gix ON site USING gist (area);

-- ---------------------------------------------------------------- rules from model.yaml constraints
-- C-001 (scope new): NOT VALID = not checked for existing (legacy) rows, enforced for new/changed rows.
ALTER TABLE tree ADD CONSTRAINT c001_felling_fields
  CHECK ((status = 'felled') = (felling_date IS NOT NULL AND felling_reason IS NOT NULL)) NOT VALID;
-- C-002 (self part; the "replaced tree is felled" part needs a trigger, see TODO below)
ALTER TABLE tree ADD CONSTRAINT c002_not_self CHECK (replaced_tree_id IS NULL OR replaced_tree_id <> id);
-- C-003
ALTER TABLE tree ADD CONSTRAINT c003_planting_year
  CHECK (planting_year IS NULL OR felling_date IS NULL OR planting_year <= extract(year FROM felling_date));
-- C-005 (scope new)
ALTER TABLE inspection ADD CONSTRAINT c005_vitality_required CHECK (vitality_class IS NOT NULL) NOT VALID;
-- C-006
ALTER TABLE inspection_defect ADD CONSTRAINT c006_defect_once UNIQUE (inspection_id, defect_type);
-- C-008 (scope new; contractor part is warning-level -> report, not constraint)
ALTER TABLE measure ADD CONSTRAINT c008_completion
  CHECK ((status = 'done') = (completion_date IS NOT NULL)) NOT VALID;
-- C-011
ALTER TABLE tree_location_correction ADD CONSTRAINT c011_unique_time UNIQUE (tree_id, corrected_at);

-- C-007: inspections are never physically deleted. Enforce with privileges and a guard trigger.
CREATE OR REPLACE FUNCTION forbid_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% rows must not be deleted; set deleted_at instead', TG_TABLE_NAME;
END $$;
CREATE TRIGGER inspection_no_delete BEFORE DELETE ON inspection FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER inspection_defect_no_delete BEFORE DELETE ON inspection_defect FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER tree_no_delete BEFORE DELETE ON tree FOR EACH ROW EXECUTE FUNCTION forbid_delete();
CREATE TRIGGER measure_no_delete BEFORE DELETE ON measure FOR EACH ROW EXECUTE FUNCTION forbid_delete();

-- ---------------------------------------------------------------- audit trail ("who changed what", A-014)
-- Application sets the acting user per transaction: SET LOCAL app.user = '<staff uuid or login>';
CREATE OR REPLACE FUNCTION write_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('INSERT INTO %I.%I (operation, recorded_by, row_data) VALUES ($1, $2, $3)',
                 TG_TABLE_SCHEMA, TG_TABLE_NAME || '_history')
    USING left(TG_OP, 1),
          coalesce(current_setting('app.user', true), current_user),
          to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  RETURN NULL;
END $$;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tree','species','site','staff_member','contractor','inspection','measure'] LOOP
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON urban_tree_cadastre.%I
                    FOR EACH ROW EXECUTE FUNCTION urban_tree_cadastre.write_history()', t || '_history_trg', t);
  END LOOP;
END $$;
-- NOTE: defects and location corrections are child rows; their changes are covered by their own
-- immutability (no delete) - add history triggers for them too if auditors require it.

-- TODO C-002 (replaced tree must be felled), C-004 (warning), C-009 (measure.tree = inspection.tree):
-- implement as BEFORE INSERT/UPDATE triggers once the rules are confirmed.

-- ---------------------------------------------------------------- open data (UC5, nightly)
-- No personal data: no staff references, no remarks. Q-011: "latest vitality" = latest inspection with a vitality class.
CREATE OR REPLACE VIEW open_data_tree AS
SELECT t.id,
       t.tree_number,
       s.botanical_name,
       s.gbif_taxon_key,
       t.planting_year,
       t.location,
       lv.vitality_class AS latest_vitality_class,
       lv.inspection_date AS latest_vitality_date
FROM tree t
JOIN species s ON s.id = t.species_id
LEFT JOIN LATERAL (
  SELECT i.vitality_class, i.inspection_date
  FROM inspection i
  WHERE i.tree_id = t.id AND i.vitality_class IS NOT NULL AND i.deleted_at IS NULL
  ORDER BY i.inspection_date DESC
  LIMIT 1
) lv ON true
WHERE t.status = 'standing' AND t.deleted_at IS NULL;
COMMENT ON VIEW open_data_tree IS 'Nightly open data export (UC5): standing trees, no personal data.';

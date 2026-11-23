-- =============================================================================
-- Urban Tree Cadastre - views, open data export, regional exchange (DRAFT v0.1)
-- Requires 01_schema.sql, 02_rules_and_audit.sql.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Latest assessed vitality per tree (A-21: latest inspection that has a vitality class)
-- Uses index inspection_tree_date_ix -> one index probe per tree.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW cadastre.v_tree_latest_inspection AS
SELECT t.tree_id,
       li.inspection_id,
       li.inspected_on,
       li.vitality_class
  FROM cadastre.tree t
  LEFT JOIN LATERAL (
        SELECT i.inspection_id, i.inspected_on, i.vitality_class
          FROM cadastre.inspection i
         WHERE i.tree_id = t.tree_id
           AND i.vitality_class IS NOT NULL
         ORDER BY i.inspected_on DESC, i.created_at DESC
         LIMIT 1) li ON true;
COMMENT ON VIEW cadastre.v_tree_latest_inspection IS 'Most recent inspection with a vitality class, per tree.';

-- -----------------------------------------------------------------------------
-- Map layer for the app. Query with a bbox filter, e.g.
--   SELECT * FROM cadastre.v_tree_map
--    WHERE geom && ST_MakeEnvelope(:xmin, :ymin, :xmax, :ymax, 25832);
-- The bbox predicate is pushed into tree (GiST), the lateral lookup is per row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW cadastre.v_tree_map AS
SELECT t.tree_id,
       t.tree_number,
       t.status,
       s.botanical_name,
       t.planting_year,
       li.vitality_class AS latest_vitality_class,
       li.inspected_on   AS latest_inspection_on,
       (li.inspected_on IS NULL OR li.inspected_on < current_date - 365) AS inspection_overdue,
       t.geom
  FROM cadastre.tree t
  JOIN cadastre.species s USING (species_id)
  LEFT JOIN LATERAL (
        SELECT i.inspected_on, i.vitality_class
          FROM cadastre.inspection i
         WHERE i.tree_id = t.tree_id
           AND i.vitality_class IS NOT NULL
         ORDER BY i.inspected_on DESC, i.created_at DESC
         LIMIT 1) li ON true;
COMMENT ON VIEW cadastre.v_tree_map IS 'Map layer: one row per tree with species and latest vitality. Filter by bbox on geom.';

-- -----------------------------------------------------------------------------
-- Open measures (work list) and outstanding compensation plantings
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW cadastre.v_open_measure AS
SELECT m.measure_id, t.tree_number, m.measure_type_code, m.priority, m.due_on,
       m.due_on < current_date AS is_overdue, m.ordered_on, m.contractor_id, t.geom
  FROM cadastre.measure m
  JOIN cadastre.tree t USING (tree_id)
 WHERE m.status = 'ordered';

CREATE OR REPLACE VIEW cadastre.v_compensation_status AS
SELECT t.tree_id,
       t.tree_number,
       t.felled_on,
       t.felling_reason_code,
       t.compensation_trees_required,
       count(r.replacement_tree_id) AS compensation_trees_planted,
       greatest(coalesce(t.compensation_trees_required, 0) - count(r.replacement_tree_id), 0) AS compensation_trees_outstanding
  FROM cadastre.tree t
  LEFT JOIN cadastre.tree_replacement r ON r.felled_tree_id = t.tree_id
 WHERE t.status = 'felled'
 GROUP BY t.tree_id;
COMMENT ON VIEW cadastre.v_compensation_status IS 'UC4: felled trees with required vs. planted replacement trees.';

GRANT SELECT ON cadastre.v_tree_latest_inspection, cadastre.v_tree_map,
                cadastre.v_open_measure, cadastre.v_compensation_status
      TO cadastre_reader;

-- -----------------------------------------------------------------------------
-- Open data (UC5, nightly). Separate schema, NO personal data.
-- Created WITH NO DATA: the very first refresh must be non-concurrent
--   (REFRESH MATERIALIZED VIEW opendata.tree;), afterwards
-- refresh nightly:  REFRESH MATERIALIZED VIEW CONCURRENTLY opendata.tree;
-- (e.g. via pg_cron or the existing job scheduler), then export with ogr2ogr.
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS opendata;
COMMENT ON SCHEMA opendata IS 'Public open data products. Must never contain personal data.';

CREATE MATERIALIZED VIEW opendata.tree AS
SELECT t.tree_number                       AS tree_id,
       s.botanical_name,
       t.planting_year,
       li.vitality_class                   AS latest_vitality_class,
       t.geom::geometry(Point, 25832)      AS geom,
       ST_Transform(t.geom, 4326)::geometry(Point, 4326) AS geom_wgs84
  FROM cadastre.tree t
  JOIN cadastre.species s USING (species_id)
  LEFT JOIN cadastre.v_tree_latest_inspection li USING (tree_id)
 WHERE t.status = 'living'
WITH NO DATA;

CREATE UNIQUE INDEX opendata_tree_id_uq ON opendata.tree (tree_id);
CREATE INDEX opendata_tree_geom_gix     ON opendata.tree USING gist (geom);
COMMENT ON MATERIALIZED VIEW opendata.tree IS
  'Nightly open data snapshot of all living trees: public tree number, species, planting year, location, latest vitality (A-22).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opendata_reader') THEN
        CREATE ROLE opendata_reader NOLOGIN;
    END IF;
END;
$$;
GRANT USAGE  ON SCHEMA opendata TO opendata_reader;
GRANT SELECT ON opendata.tree   TO opendata_reader;

-- -----------------------------------------------------------------------------
-- Regional exchange file (UC5, monthly). Produces a JSON document that
-- validates against json/tree-exchange.schema.json.
--   SELECT exchange.build_exchange_file(DATE '2026-10-01', DATE '2026-10-31');        -- delta
--   SELECT exchange.build_exchange_file(DATE '2026-10-01', DATE '2026-10-31', true);  -- full
-- Delta = all trees, inspections, measures created or changed in the period (A-23).
-- Inspector/arborist names are replaced by staff.pseudonym (A-17).
-- Run with  SET TIME ZONE 'Europe/Berlin'  so period boundaries are local days.
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS exchange;

CREATE OR REPLACE FUNCTION exchange.build_exchange_file(
    p_period_start date,
    p_period_end   date,
    p_full         boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
WITH
bounds AS (
    SELECT p_period_start::timestamptz       AS ts_from,
           (p_period_end + 1)::timestamptz   AS ts_to
),
sel_tree AS (
    SELECT t.*
      FROM cadastre.tree t, bounds b
     WHERE p_full OR (t.updated_at >= b.ts_from AND t.updated_at < b.ts_to)
),
sel_inspection AS (
    SELECT i.*
      FROM cadastre.inspection i, bounds b
     WHERE p_full OR (i.updated_at >= b.ts_from AND i.updated_at < b.ts_to)
),
sel_measure AS (
    SELECT m.*
      FROM cadastre.measure m, bounds b
     WHERE p_full OR (m.updated_at >= b.ts_from AND m.updated_at < b.ts_to)
),
j_tree AS (
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'treeId',        t.tree_id,
            'treeNumber',    t.tree_number,
            'speciesId',     t.species_id,
            'botanicalName', s.botanical_name,
            'plantingYear',  t.planting_year,
            'location',      jsonb_build_object(
                                 'easting',    round(ST_X(t.geom)::numeric, 2),
                                 'northing',   round(ST_Y(t.geom)::numeric, 2),
                                 'validSince', t.location_since),
            'previousLocations', (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'easting',   round(ST_X(h.geom)::numeric, 2),
                           'northing',  round(ST_Y(h.geom)::numeric, 2),
                           'validFrom', h.valid_from,
                           'validTo',   h.valid_to) ORDER BY h.valid_to), '[]'::jsonb)
                  FROM cadastre.tree_location_history h
                 WHERE h.tree_id = t.tree_id),
            'locationUnit',  CASE
                               WHEN t.park_id IS NOT NULL THEN
                                 jsonb_build_object('type', 'park', 'id', p.park_id, 'code', p.park_code, 'name', p.name)
                               WHEN t.street_segment_id IS NOT NULL THEN
                                 jsonb_build_object('type', 'streetSegment', 'id', ss.street_segment_id,
                                                    'code', ss.segment_code, 'name', ss.street_name)
                             END,
            'status',        t.status,
            'felling',       CASE WHEN t.status = 'felled' THEN
                                 jsonb_build_object(
                                     'date',                      t.felled_on,
                                     'reasonCode',                t.felling_reason_code,
                                     'measureId',                 t.felling_measure_id,
                                     'compensationTreesRequired', t.compensation_trees_required)
                             END,
            'replacesTreeIds', (
                SELECT coalesce(jsonb_agg(r.felled_tree_id ORDER BY r.felled_tree_id), '[]'::jsonb)
                  FROM cadastre.tree_replacement r
                 WHERE r.replacement_tree_id = t.tree_id),
            'isLegacyImport', t.is_legacy_import,
            'createdAt',     t.created_at,
            'updatedAt',     t.updated_at
        ) ORDER BY t.tree_number), '[]'::jsonb) AS doc
      FROM sel_tree t
      JOIN cadastre.species s USING (species_id)
      LEFT JOIN cadastre.park p            ON p.park_id = t.park_id
      LEFT JOIN cadastre.street_segment ss ON ss.street_segment_id = t.street_segment_id
),
j_inspection AS (
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'inspectionId',         i.inspection_id,
            'treeId',               i.tree_id,
            'date',                 i.inspected_on,
            'inspector',            st.pseudonym,
            'trunkCircumferenceCm', i.trunk_circumference_cm,
            'crownDiameterM',       i.crown_diameter_m,
            'heightM',              i.height_m,
            'vitalityClass',        i.vitality_class,
            'defects', (
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'code', d.defect_code, 'severity', d.severity) ORDER BY d.defect_code), '[]'::jsonb)
                  FROM cadastre.inspection_defect d
                 WHERE d.inspection_id = i.inspection_id),
            'isLegacyImport',       i.is_legacy_import,
            'createdAt',            i.created_at,
            'updatedAt',            i.updated_at
        ) ORDER BY i.inspected_on, i.inspection_id), '[]'::jsonb) AS doc
      FROM sel_inspection i
      JOIN cadastre.staff st ON st.staff_id = i.inspector_id
),
j_measure AS (
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'measureId',     m.measure_id,
            'treeId',        m.tree_id,
            'inspectionId',  m.inspection_id,
            'typeCode',      m.measure_type_code,
            'priority',      m.priority,
            'orderedOn',     m.ordered_on,
            'dueOn',         m.due_on,
            'status',        m.status,
            'completedOn',   m.completed_on,
            'contractor',    CASE WHEN c.contractor_id IS NOT NULL THEN
                                 jsonb_build_object('id', c.contractor_id, 'name', c.name) END,
            'cancelledOn',   m.cancelled_on,
            'isLegacyImport', m.is_legacy_import,
            'createdAt',     m.created_at,
            'updatedAt',     m.updated_at
        ) ORDER BY m.ordered_on, m.measure_id), '[]'::jsonb) AS doc
      FROM sel_measure m
      LEFT JOIN cadastre.contractor c ON c.contractor_id = m.contractor_id
),
j_codelists AS (
    SELECT jsonb_build_object(
        'species', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'id', species_id, 'botanicalName', botanical_name, 'genus', genus,
                        'commonNameDe', common_name_de, 'isActive', is_active,
                        'replacedById', replaced_by_species_id) ORDER BY species_id), '[]'::jsonb)
                      FROM cadastre.species),
        'defectTypes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'code', defect_code, 'labelDe', label_de, 'labelEn', label_en, 'isActive', is_active)
                        ORDER BY sort_order, defect_code), '[]'::jsonb)
                      FROM cadastre.defect_type),
        'measureTypes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'code', measure_type_code, 'labelDe', label_de, 'labelEn', label_en,
                        'isFelling', is_felling, 'isActive', is_active)
                        ORDER BY sort_order, measure_type_code), '[]'::jsonb)
                      FROM cadastre.measure_type),
        'fellingReasons', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'code', felling_reason_code, 'labelDe', label_de, 'labelEn', label_en, 'isActive', is_active)
                        ORDER BY sort_order, felling_reason_code), '[]'::jsonb)
                      FROM cadastre.felling_reason),
        'vitalityClasses', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'code', vitality_class, 'labelDe', label_de, 'labelEn', label_en)
                        ORDER BY vitality_class), '[]'::jsonb)
                      FROM cadastre.vitality_class),
        'measurePriorities', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'code', priority, 'labelDe', label_de, 'labelEn', label_en)
                        ORDER BY priority), '[]'::jsonb)
                      FROM cadastre.measure_priority)
    ) AS doc
)
SELECT jsonb_build_object(
    'header', jsonb_build_object(
        'schemaVersion', '1.0.0',
        'exportType',    CASE WHEN p_full THEN 'full' ELSE 'delta' END,
        'periodStart',   p_period_start,
        'periodEnd',     p_period_end,
        'generatedAt',   now(),
        'sender',        coalesce(nullif(current_setting('exchange.sender_id', true), ''), 'CITY-PARKS-DEPT'),
        'crs',           'EPSG:25832',
        'counts', jsonb_build_object(
            'trees',       jsonb_array_length(jt.doc),
            'inspections', jsonb_array_length(ji.doc),
            'measures',    jsonb_array_length(jm.doc))),
    'codeLists',   jc.doc,
    'trees',       jt.doc,
    'inspections', ji.doc,
    'measures',    jm.doc)
  FROM j_tree jt, j_inspection ji, j_measure jm, j_codelists jc;
$$;

COMMENT ON FUNCTION exchange.build_exchange_file(date, date, boolean) IS
  'Builds the monthly exchange document for the regional environmental agency (schema json/tree-exchange.schema.json v1.0.0).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'exchange_exporter') THEN
        CREATE ROLE exchange_exporter NOLOGIN;
    END IF;
END;
$$;
GRANT cadastre_reader TO exchange_exporter;
GRANT USAGE ON SCHEMA exchange TO exchange_exporter;
REVOKE ALL ON FUNCTION exchange.build_exchange_file(date, date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION exchange.build_exchange_file(date, date, boolean) TO exchange_exporter;

COMMIT;

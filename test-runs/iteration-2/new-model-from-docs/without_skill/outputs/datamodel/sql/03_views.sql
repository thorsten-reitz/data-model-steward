-- =====================================================================
-- Urban Tree Cadastre – views and export functions
-- =====================================================================
SET search_path = cadastre, public;

-- ---------------------------------------------------------------------
-- Current state of every tree incl. its latest inspection.
-- Used by the map view: filter with  location && ST_MakeEnvelope(..., 25832)
-- GiST index on tree.location + (tree_id, inspection_date DESC) index on
-- inspection keep a 5,000-tree bounding box well below 1 s.          [A-25]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_tree_current AS
SELECT t.tree_id,
       t.tree_number,
       t.status,
       t.species_id,
       s.species_code,
       s.botanical_name,
       s.common_name_de,
       t.planting_year,
       t.location,
       t.park_id,
       t.street_segment_id,
       li.inspection_id      AS latest_inspection_id,
       li.inspection_date    AS latest_inspection_date,
       li.vitality_class     AS latest_vitality_class,
       t.felling_date,
       t.updated_at
FROM tree t
JOIN species s ON s.species_id = t.species_id
LEFT JOIN LATERAL (
    SELECT i.inspection_id, i.inspection_date, i.vitality_class
    FROM inspection i
    WHERE i.tree_id = t.tree_id
    ORDER BY i.inspection_date DESC, i.created_at DESC
    LIMIT 1
) li ON true;

-- Inspections that are overdue (UC2: at least once a year)          [A-26]
CREATE OR REPLACE VIEW v_inspection_overdue AS
SELECT tc.tree_id, tc.tree_number, tc.latest_inspection_date, tc.location
FROM v_tree_current tc
WHERE tc.status = 'standing'
  AND (tc.latest_inspection_date IS NULL
       OR tc.latest_inspection_date < current_date - interval '1 year');

-- Felled trees with outstanding compensation planting (UC4)
CREATE OR REPLACE VIEW v_compensation_open AS
SELECT t.tree_id, t.tree_number, t.felling_date, t.compensation_required,
       count(r.replacement_tree_id) AS replacements_recorded
FROM tree t
LEFT JOIN tree_replacement r ON r.felled_tree_id = t.tree_id
WHERE t.status = 'felled'
GROUP BY t.tree_id
HAVING count(r.replacement_tree_id) < coalesce(t.compensation_required, 1);

-- ---------------------------------------------------------------------
-- Open data (UC5, nightly). Materialized so the portal never touches the
-- live tables; contains NO personal data (no inspector, no audit columns).
-- First population: REFRESH MATERIALIZED VIEW mv_open_data_tree;
-- Then nightly:      REFRESH MATERIALIZED VIEW CONCURRENTLY mv_open_data_tree;
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_open_data_tree AS
SELECT tc.tree_number                                   AS tree_id,        -- public id [A-27]
       tc.species_code,
       tc.botanical_name,
       tc.common_name_de,
       tc.planting_year,
       round(ST_X(tc.location)::numeric, 2)             AS easting_25832,
       round(ST_Y(tc.location)::numeric, 2)             AS northing_25832,
       round(ST_X(ST_Transform(tc.location, 4326))::numeric, 7) AS lon_wgs84,
       round(ST_Y(ST_Transform(tc.location, 4326))::numeric, 7) AS lat_wgs84,
       tc.latest_vitality_class,
       tc.location                                       AS geom
FROM v_tree_current tc
WHERE tc.status = 'standing'
WITH NO DATA;

CREATE UNIQUE INDEX mv_open_data_tree_pk  ON mv_open_data_tree (tree_id);
CREATE INDEX        mv_open_data_tree_gix ON mv_open_data_tree USING gist (geom);
GRANT SELECT ON mv_open_data_tree TO open_data_reader, cadastre_export;
GRANT SELECT ON v_tree_current, v_inspection_overdue, v_compensation_open
      TO cadastre_app, cadastre_auditor, cadastre_export;

-- ---------------------------------------------------------------------
-- Monthly agency exchange file (UC5) – produces a JSON document that
-- validates against json-schema/tree-exchange.schema.json (v0.1.0).
--   trees       : full snapshot
--   inspections : created or modified in [p_start, p_end]
--   measures    : created or modified in [p_start, p_end]
-- Usage:  SELECT export_agency_exchange(DATE '2026-10-01', DATE '2026-10-31', '05315000', 'City Parks Department');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION export_agency_exchange(
    p_start            date,
    p_end              date,
    p_municipality     text,
    p_organisation     text,
    p_include_codelists boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE AS $$   -- volatile: generates fileId / generatedAt
DECLARE
    v_from  timestamptz := p_start::timestamptz;
    v_to    timestamptz := (p_end + 1)::timestamptz;
    v_trees jsonb;
    v_insp  jsonb;
    v_meas  jsonb;
    v_codes jsonb;
    v_doc   jsonb;
BEGIN
    IF p_end < p_start THEN
        RAISE EXCEPTION 'period end % before start %', p_end, p_start;
    END IF;

    -- Trees (full snapshot). "felling" only present for felled trees.
    SELECT coalesce(jsonb_agg(
             jsonb_build_object(
               'treeId',       t.tree_id,
               'treeNumber',   t.tree_number,
               'species',      jsonb_build_object('code', s.species_code, 'botanicalName', s.botanical_name),
               'plantingYear', t.planting_year,
               'location',     jsonb_build_object('easting',  round(ST_X(t.location)::numeric, 2),
                                                  'northing', round(ST_Y(t.location)::numeric, 2)),
               'locationCorrectedAt', t.location_corrected_at,
               'spatialUnit',  CASE WHEN t.park_id IS NOT NULL
                                    THEN jsonb_build_object('type','park','code',p.park_code,'name',p.name)
                                    ELSE jsonb_build_object('type','street_segment','code',ss.segment_code,'name',ss.street_name)
                               END,
               'status',       t.status,
               'lastModified', t.updated_at)
             || CASE WHEN t.status = 'felled' THEN jsonb_build_object('felling',
                    jsonb_build_object(
                      'date',                 t.felling_date,
                      'reasonCode',           t.felling_reason_code,
                      'compensationRequired', t.compensation_required,
                      'replacedByTreeNumbers',
                        coalesce((SELECT jsonb_agg(rt.tree_number ORDER BY rt.tree_number)
                                    FROM tree_replacement r
                                    JOIN tree rt ON rt.tree_id = r.replacement_tree_id
                                   WHERE r.felled_tree_id = t.tree_id), '[]'::jsonb)))
                    ELSE '{}'::jsonb END
             ORDER BY t.tree_number), '[]'::jsonb)
      INTO v_trees
      FROM tree t
      JOIN species s              ON s.species_id = t.species_id
      LEFT JOIN park p            ON p.park_id = t.park_id
      LEFT JOIN street_segment ss ON ss.street_segment_id = t.street_segment_id;

    -- Inspections (delta)
    SELECT coalesce(jsonb_agg(
             jsonb_build_object(
               'inspectionId',         i.inspection_id,
               'treeId',               i.tree_id,
               'treeNumber',           t.tree_number,
               'inspectionDate',       i.inspection_date,
               'inspectorCode',        st.staff_code,                -- pseudonym, never the name
               'trunkCircumferenceCm', i.trunk_circumference_cm,
               'crownDiameterM',       i.crown_diameter_m,
               'heightM',              i.height_m,
               'vitalityClass',        i.vitality_class,
               'defects', coalesce((SELECT jsonb_agg(jsonb_build_object('code', d.defect_type_code,
                                                                       'severity', d.severity)
                                                     ORDER BY d.defect_type_code)
                                      FROM inspection_defect d
                                     WHERE d.inspection_id = i.inspection_id), '[]'::jsonb),
               'lastModified',         greatest(i.updated_at,
                                          (SELECT max(d.created_at) FROM inspection_defect d
                                            WHERE d.inspection_id = i.inspection_id))
             ) ORDER BY i.inspection_date, i.inspection_id), '[]'::jsonb)
      INTO v_insp
      FROM inspection i
      JOIN tree t       ON t.tree_id = i.tree_id
      LEFT JOIN staff st ON st.staff_id = i.inspector_id
     WHERE (i.updated_at >= v_from AND i.updated_at < v_to)
        OR EXISTS (SELECT 1 FROM inspection_defect d
                    WHERE d.inspection_id = i.inspection_id
                      AND d.created_at >= v_from AND d.created_at < v_to);

    -- Measures (delta)
    SELECT coalesce(jsonb_agg(
             jsonb_build_object(
               'measureId',       m.measure_id,
               'inspectionId',    m.inspection_id,
               'treeId',          m.tree_id,
               'treeNumber',      t.tree_number,
               'measureTypeCode', m.measure_type_code,
               'orderedOn',       m.ordered_on,
               'dueDate',         m.due_date,
               'priority',        m.priority,
               'status',          m.status,
               'completedOn',     m.completed_on,
               'contractorName',  c.name,
               'lastModified',    m.updated_at
             ) ORDER BY m.ordered_on, m.measure_id), '[]'::jsonb)
      INTO v_meas
      FROM measure m
      JOIN tree t            ON t.tree_id = m.tree_id
      LEFT JOIN contractor c ON c.contractor_id = m.contractor_id
     WHERE m.updated_at >= v_from AND m.updated_at < v_to;

    v_doc := jsonb_build_object(
        'schemaVersion', '0.1.0',
        'header', jsonb_build_object(
            'fileId',      gen_random_uuid(),
            'sender',      jsonb_build_object('municipalityCode', p_municipality,
                                              'organisation',     p_organisation),
            'periodStart', p_start,
            'periodEnd',   p_end,
            'generatedAt', now(),
            'crs',         'EPSG:25832',
            'counts',      jsonb_build_object('trees',       jsonb_array_length(v_trees),
                                              'inspections', jsonb_array_length(v_insp),
                                              'measures',    jsonb_array_length(v_meas))),
        'trees',       v_trees,
        'inspections', v_insp,
        'measures',    v_meas);

    IF p_include_codelists THEN
        v_doc := v_doc || jsonb_build_object('codeLists', jsonb_build_object(
            'defectTypes',     (SELECT coalesce(jsonb_agg(jsonb_build_object('code', defect_type_code, 'label', label_en) ORDER BY sort_order, defect_type_code), '[]') FROM defect_type),
            'measureTypes',    (SELECT coalesce(jsonb_agg(jsonb_build_object('code', measure_type_code, 'label', label_en) ORDER BY sort_order, measure_type_code), '[]') FROM measure_type),
            'fellingReasons',  (SELECT coalesce(jsonb_agg(jsonb_build_object('code', felling_reason_code, 'label', label_en) ORDER BY felling_reason_code), '[]') FROM felling_reason),
            'vitalityClasses', (SELECT coalesce(jsonb_agg(jsonb_build_object('code', vitality_class, 'label', label_en) ORDER BY vitality_class), '[]') FROM vitality_class)));
    END IF;

    RETURN v_doc;
END $$;

GRANT EXECUTE ON FUNCTION export_agency_exchange(date, date, text, text, boolean) TO cadastre_export;

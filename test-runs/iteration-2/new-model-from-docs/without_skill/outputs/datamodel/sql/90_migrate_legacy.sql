-- =====================================================================
-- Urban Tree Cadastre – one-off migration from the legacy schema
-- (baum / kontrolle / massnahme, export of 2026-09-30).
--
-- Prerequisites
--   * 01..04 scripts have run; species list, parks and street segments
--     from the city GIS have been loaded (see ASSUMPTIONS A-06).
--   * The legacy tables are restored into schema "legacy" in the same DB.
--   * Legacy x/y are EPSG:25832 metres.                              [A-02]
--
-- Approach
--   1. Build mapping tables (species text, defect text, measure text,
--      park/street names, inspector names, contractors). Mappings are
--      auto-filled by normalised name match and MUST be reviewed before step 2.
--   2. Load trees, inspections, defects, measures in one transaction.
--   3. Everything that could not be migrated cleanly is written to
--      legacy.migration_issue for manual follow-up.
-- Run step 1, review, then run step 2 (separated by the marker below).
-- =====================================================================
SET search_path = cadastre, public;

-- ---------------------------------------------------------------------
-- STEP 1 – mapping tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS legacy.migration_issue (
    issue_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_table text NOT NULL,
    source_key   text,
    issue        text NOT NULL,
    detail       text
);

CREATE OR REPLACE FUNCTION legacy.norm(t text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(lower(regexp_replace(regexp_replace(trim(t), '[''"´`]', '', 'g'), '\s+', ' ', 'g')), '')
$$;

-- Placeholder species for unmatched legacy names (inactive => not selectable in the app)
INSERT INTO species (species_code, botanical_name, genus, common_name_de, common_name_en, is_active, note)
VALUES ('XX_UNKNOWN', 'Unknown (legacy, to be determined)', 'Unknown', 'Unbekannt (Altdaten)',
        'Unknown (legacy)', false, 'Placeholder for legacy trees whose species text could not be mapped')
ON CONFLICT (species_code) DO NOTHING;

-- 1a. Species: legacy free text -> species_id
CREATE TABLE IF NOT EXISTS legacy.map_species (
    art_lat_raw  varchar(120) PRIMARY KEY,
    species_id   integer REFERENCES cadastre.species(species_id),
    match_method text,                         -- 'exact_normalised' | 'manual' | NULL (unmatched)
    tree_count   integer
);
INSERT INTO legacy.map_species (art_lat_raw, species_id, match_method, tree_count)
SELECT b.art_lat, s.species_id, CASE WHEN s.species_id IS NOT NULL THEN 'exact_normalised' END, count(*)
FROM legacy.baum b
LEFT JOIN cadastre.species s ON legacy.norm(s.botanical_name) = legacy.norm(b.art_lat)
WHERE b.art_lat IS NOT NULL
GROUP BY b.art_lat, s.species_id
ON CONFLICT (art_lat_raw) DO NOTHING;
-- Review: SELECT * FROM legacy.map_species WHERE species_id IS NULL ORDER BY tree_count DESC;

-- 1b. Defects: tokens of the comma separated maengel list -> defect_type_code
CREATE TABLE IF NOT EXISTS legacy.map_defect (
    token_raw        text PRIMARY KEY,
    defect_type_code varchar(30) REFERENCES cadastre.defect_type(defect_type_code),
    occurrences      integer
);
INSERT INTO legacy.map_defect (token_raw, defect_type_code, occurrences)
SELECT tok, NULL, count(*)
FROM legacy.kontrolle k,
     LATERAL unnest(string_to_array(k.maengel, ',')) AS u(tok_raw),
     LATERAL (SELECT legacy.norm(u.tok_raw) AS tok) n
WHERE n.tok IS NOT NULL
GROUP BY tok
ON CONFLICT (token_raw) DO NOTHING;
-- auto-match on German or English label
UPDATE legacy.map_defect m
   SET defect_type_code = d.defect_type_code
  FROM cadastre.defect_type d
 WHERE m.defect_type_code IS NULL
   AND m.token_raw IN (legacy.norm(d.label_de), legacy.norm(d.label_en), legacy.norm(d.defect_type_code));

-- 1c. Measure types: legacy art -> measure_type_code
CREATE TABLE IF NOT EXISTS legacy.map_measure_type (
    art_raw           varchar(40) PRIMARY KEY,
    measure_type_code varchar(30) REFERENCES cadastre.measure_type(measure_type_code),
    occurrences       integer
);
INSERT INTO legacy.map_measure_type (art_raw, measure_type_code, occurrences)
SELECT m.art, mt.measure_type_code, count(*)
FROM legacy.massnahme m
LEFT JOIN cadastre.measure_type mt
       ON legacy.norm(m.art) IN (legacy.norm(mt.label_de), legacy.norm(mt.label_en), legacy.norm(mt.measure_type_code))
WHERE m.art IS NOT NULL
GROUP BY m.art, mt.measure_type_code
ON CONFLICT (art_raw) DO NOTHING;

-- 1d. Parks / streets: legacy names -> GIS master data (create placeholders if missing)
INSERT INTO park (park_code, name)
SELECT 'LEG-P-' || lpad(row_number() OVER (ORDER BY n)::text, 4, '0'), n
FROM (SELECT DISTINCT trim(b.park) AS n FROM legacy.baum b WHERE nullif(trim(b.park), '') IS NOT NULL) x
WHERE NOT EXISTS (SELECT 1 FROM park p WHERE legacy.norm(p.name) = legacy.norm(x.n));

INSERT INTO street_segment (segment_code, street_name, from_description)
SELECT 'LEG-S-' || lpad(row_number() OVER (ORDER BY n)::text, 4, '0'), n, 'legacy: whole street'
FROM (SELECT DISTINCT trim(b.strasse) AS n FROM legacy.baum b WHERE nullif(trim(b.strasse), '') IS NOT NULL) x
WHERE NOT EXISTS (SELECT 1 FROM street_segment s WHERE legacy.norm(s.street_name) = legacy.norm(x.n));

INSERT INTO street_segment (segment_code, street_name, from_description)
VALUES ('LEG-UNASSIGNED', 'Unassigned (legacy)', 'Legacy trees without park or street')
ON CONFLICT (segment_code) DO NOTHING;
-- Better (follow-up): re-assign by spatial join against GIS polygons/lines (ST_DWithin).  [A-07]

-- 1e. Inspectors (PERSONAL DATA) and contractors
INSERT INTO staff (staff_code, full_name, is_inspector, is_active)
SELECT 'LEG-' || lpad(row_number() OVER (ORDER BY n)::text, 4, '0'), n, true, false
FROM (SELECT DISTINCT trim(kontrolleur) AS n FROM legacy.kontrolle WHERE nullif(trim(kontrolleur), '') IS NOT NULL) x
WHERE NOT EXISTS (SELECT 1 FROM staff s WHERE legacy.norm(s.full_name) = legacy.norm(x.n));

INSERT INTO contractor (name)
SELECT DISTINCT trim(firma) FROM legacy.massnahme WHERE nullif(trim(firma), '') IS NOT NULL
ON CONFLICT (name) DO NOTHING;

-- =====================================================================
-- >>>>>>>>>>  REVIEW THE MAPPING TABLES BEFORE RUNNING STEP 2  <<<<<<<<<<
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 2 – load (single transaction)
-- ---------------------------------------------------------------------
BEGIN;

-- Bulk load without per-row bookkeeping/audit triggers; FKs and CHECKs stay active.
ALTER TABLE tree              DISABLE TRIGGER USER;
ALTER TABLE inspection        DISABLE TRIGGER USER;
ALTER TABLE inspection_defect DISABLE TRIGGER USER;
ALTER TABLE measure           DISABLE TRIGGER USER;

-- Issues found up front
INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', baum_nr::text, 'missing coordinates - tree NOT migrated', NULL
FROM legacy.baum WHERE x IS NULL OR y IS NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', b.baum_nr::text, 'species not mapped - placeholder XX_UNKNOWN used', b.art_lat
FROM legacy.baum b LEFT JOIN legacy.map_species m ON m.art_lat_raw = b.art_lat
WHERE m.species_id IS NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', baum_nr::text, 'both park and street set - park used', park || ' / ' || strasse
FROM legacy.baum WHERE nullif(trim(park), '') IS NOT NULL AND nullif(trim(strasse), '') IS NOT NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', baum_nr::text, 'neither park nor street - LEG-UNASSIGNED used', NULL
FROM legacy.baum WHERE nullif(trim(park), '') IS NULL AND nullif(trim(strasse), '') IS NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', baum_nr::text, 'implausible planting year - set to NULL', pflanzjahr::text
FROM legacy.baum WHERE pflanzjahr IS NOT NULL AND pflanzjahr NOT BETWEEN 1600 AND 2100;

-- Trees
CREATE TEMP TABLE map_tree ON COMMIT DROP AS
SELECT b.baum_nr, gen_random_uuid() AS tree_id
FROM legacy.baum b WHERE b.x IS NOT NULL AND b.y IS NOT NULL;

INSERT INTO tree (tree_id, tree_number, species_id, planting_year, location,
                  park_id, street_segment_id, status, felling_reason_code,
                  origin, legacy_species_text,
                  created_at, created_by, updated_at, updated_by)
SELECT mt.tree_id,
       b.baum_nr,
       coalesce(ms.species_id, (SELECT species_id FROM species WHERE species_code = 'XX_UNKNOWN')),
       CASE WHEN b.pflanzjahr BETWEEN 1600 AND 2100 THEN b.pflanzjahr END,
       ST_SetSRID(ST_MakePoint(b.x::float8, b.y::float8), 25832),
       p.park_id,
       CASE WHEN p.park_id IS NULL
            THEN coalesce(ss.street_segment_id,
                          (SELECT street_segment_id FROM street_segment WHERE segment_code = 'LEG-UNASSIGNED'))
       END,
       CASE WHEN upper(b.gefaellt) = 'J' THEN 'felled' ELSE 'standing' END::tree_status,
       CASE WHEN upper(b.gefaellt) = 'J' THEN 'UNKNOWN_LEGACY' END,
       'legacy_migration',
       b.art_lat,
       coalesce(b.angelegt_am, b.geaendert_am, now()),
       'legacy_migration',
       coalesce(b.geaendert_am, b.angelegt_am, now()),
       coalesce(b.geaendert_von, 'legacy_migration')
FROM legacy.baum b
JOIN map_tree mt                 ON mt.baum_nr = b.baum_nr
LEFT JOIN legacy.map_species ms  ON ms.art_lat_raw = b.art_lat
LEFT JOIN LATERAL (SELECT park_id FROM park WHERE legacy.norm(name) = legacy.norm(b.park)
                   ORDER BY park_id LIMIT 1) p ON true
LEFT JOIN LATERAL (SELECT street_segment_id FROM street_segment WHERE legacy.norm(street_name) = legacy.norm(b.strasse)
                   ORDER BY street_segment_id LIMIT 1) ss ON true;

-- keep the new-number sequence above all legacy numbers
SELECT setval('tree_number_seq', greatest((SELECT max(tree_number) FROM tree) + 1, 1000000), false);

-- Inspections
INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'kontrolle', k.id::text, 'tree missing or not migrated - inspection NOT migrated', k.baum_nr::text
FROM legacy.kontrolle k LEFT JOIN map_tree mt ON mt.baum_nr = k.baum_nr
WHERE mt.tree_id IS NULL;

CREATE TEMP TABLE map_inspection ON COMMIT DROP AS
SELECT k.id AS kontrolle_id, mt.tree_id, gen_random_uuid() AS inspection_id
FROM legacy.kontrolle k JOIN map_tree mt ON mt.baum_nr = k.baum_nr;

INSERT INTO inspection (inspection_id, tree_id, inspection_date, inspector_id,
                        trunk_circumference_cm, crown_diameter_m, height_m, vitality_class,
                        origin, legacy_inspector_text, legacy_defects_text,
                        created_at, created_by, updated_at, updated_by)
SELECT mi.inspection_id, mi.tree_id, k.datum, st.staff_id,
       CASE WHEN k.stammumfang BETWEEN 1 AND 2000 THEN k.stammumfang END,
       NULL,                                              -- not recorded in legacy
       CASE WHEN k.hoehe BETWEEN 0.1 AND 80 THEN k.hoehe END,
       k.vitalitaet,
       'legacy_migration', k.kontrolleur, k.maengel,
       k.datum::timestamptz, 'legacy_migration', k.datum::timestamptz, 'legacy_migration'
FROM legacy.kontrolle k
JOIN map_inspection mi ON mi.kontrolle_id = k.id
LEFT JOIN staff st     ON legacy.norm(st.full_name) = legacy.norm(k.kontrolleur);

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'kontrolle', k.id::text, 'implausible trunk circumference or height - set to NULL',
       'stammumfang=' || coalesce(k.stammumfang::text, '') || ' hoehe=' || coalesce(k.hoehe::text, '')
FROM legacy.kontrolle k JOIN map_inspection mi ON mi.kontrolle_id = k.id
WHERE (k.stammumfang IS NOT NULL AND k.stammumfang NOT BETWEEN 1 AND 2000)
   OR (k.hoehe IS NOT NULL AND k.hoehe NOT BETWEEN 0.1 AND 80);

-- Defects (unmapped tokens -> OTHER; original text kept in legacy_defects_text)
INSERT INTO inspection_defect (inspection_id, defect_type_code, severity, origin, created_at, created_by)
SELECT DISTINCT mi.inspection_id, coalesce(md.defect_type_code, 'OTHER'), NULL::defect_severity,
       'legacy_migration'::data_origin, k.datum::timestamptz, 'legacy_migration'
FROM legacy.kontrolle k
JOIN map_inspection mi ON mi.kontrolle_id = k.id,
     LATERAL unnest(string_to_array(k.maengel, ',')) AS u(tok_raw)
LEFT JOIN legacy.map_defect md ON md.token_raw = legacy.norm(u.tok_raw)
WHERE legacy.norm(u.tok_raw) IS NOT NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'kontrolle', NULL, 'defect text not mapped - OTHER used', token_raw || ' (' || occurrences || 'x)'
FROM legacy.map_defect WHERE defect_type_code IS NULL;

-- Measures
INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'massnahme', m.id::text, 'no (migrated) inspection - measure NOT migrated', m.kontrolle_id::text
FROM legacy.massnahme m LEFT JOIN map_inspection mi ON mi.kontrolle_id = m.kontrolle_id
WHERE mi.inspection_id IS NULL;

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'massnahme', m.id::text, 'date inconsistency - due/completed before inspection date, set to NULL',
       'datum=' || k.datum || ' faellig=' || coalesce(m.faellig::text, '') || ' erledigt=' || coalesce(m.erledigt::text, '')
FROM legacy.massnahme m
JOIN legacy.kontrolle k ON k.id = m.kontrolle_id
WHERE m.faellig < k.datum OR m.erledigt < k.datum;

CREATE TEMP TABLE map_measure ON COMMIT DROP AS
SELECT m.id AS massnahme_id, mi.inspection_id, mi.tree_id, gen_random_uuid() AS measure_id
FROM legacy.massnahme m JOIN map_inspection mi ON mi.kontrolle_id = m.kontrolle_id;

INSERT INTO measure (measure_id, inspection_id, tree_id, measure_type_code, ordered_by_id, ordered_on,
                     due_date, priority, status, completed_on, contractor_id, remarks, origin,
                     created_at, created_by, updated_at, updated_by)
SELECT mm.measure_id, mm.inspection_id, mm.tree_id,
       coalesce(mmt.measure_type_code, 'OTHER'),
       NULL,                                                  -- not recorded in legacy
       k.datum,                                               -- ordered on inspection day [A-21]
       CASE WHEN m.faellig >= k.datum THEN m.faellig END,
       'normal',                                              -- no priority in legacy
       CASE WHEN m.erledigt >= k.datum THEN 'done' ELSE 'ordered' END::measure_status,
       CASE WHEN m.erledigt >= k.datum THEN m.erledigt END,
       c.contractor_id,
       CASE WHEN mmt.measure_type_code IS NULL THEN 'legacy type: ' || m.art END,
       'legacy_migration',
       k.datum::timestamptz, 'legacy_migration',
       coalesce(m.erledigt, k.datum)::timestamptz, 'legacy_migration'
FROM legacy.massnahme m
JOIN map_measure mm                   ON mm.massnahme_id = m.id
JOIN legacy.kontrolle k               ON k.id = m.kontrolle_id
LEFT JOIN legacy.map_measure_type mmt ON mmt.art_raw = m.art
LEFT JOIN contractor c                ON c.name = trim(m.firma);

-- Derive felling date for felled legacy trees from their latest completed FELLING measure
UPDATE tree t
   SET felling_date = f.completed_on,
       felling_measure_id = f.measure_id
  FROM (SELECT DISTINCT ON (m.tree_id) m.tree_id, m.measure_id, m.completed_on
          FROM measure m JOIN measure_type mt ON mt.measure_type_code = m.measure_type_code
         WHERE mt.is_felling AND m.status = 'done'
         ORDER BY m.tree_id, m.completed_on DESC) f
 WHERE t.tree_id = f.tree_id AND t.status = 'felled' AND t.origin = 'legacy_migration';

INSERT INTO legacy.migration_issue (source_table, source_key, issue, detail)
SELECT 'baum', tree_number::text, 'felled tree without felling date/reason - please complete', NULL
FROM tree WHERE status = 'felled' AND origin = 'legacy_migration' AND felling_date IS NULL;

-- One baseline audit entry per tree, preserving legacy "last changed by/at"
INSERT INTO audit_log (table_name, row_pk, action, changed_at, changed_by, client_info, new_values)
SELECT 'tree', t.tree_id::text, 'I', t.updated_at, t.updated_by, 'legacy_migration 2026-09-30 export',
       jsonb_build_object('tree_number', t.tree_number, 'origin', 'legacy_migration')
FROM tree t WHERE t.origin = 'legacy_migration';

ALTER TABLE tree              ENABLE TRIGGER USER;
ALTER TABLE inspection        ENABLE TRIGGER USER;
ALTER TABLE inspection_defect ENABLE TRIGGER USER;
ALTER TABLE measure           ENABLE TRIGGER USER;

-- Reconciliation counts (compare with the legacy tables)
SELECT 'trees'       AS entity, (SELECT count(*) FROM legacy.baum)      AS legacy, (SELECT count(*) FROM tree       WHERE origin = 'legacy_migration') AS migrated
UNION ALL
SELECT 'inspections', (SELECT count(*) FROM legacy.kontrolle), (SELECT count(*) FROM inspection WHERE origin = 'legacy_migration')
UNION ALL
SELECT 'measures',    (SELECT count(*) FROM legacy.massnahme), (SELECT count(*) FROM measure    WHERE origin = 'legacy_migration');

COMMIT;

REFRESH MATERIALIZED VIEW mv_open_data_tree;

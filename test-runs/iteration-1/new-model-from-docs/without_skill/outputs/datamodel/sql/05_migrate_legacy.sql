-- =============================================================================
-- Urban Tree Cadastre - one-off migration from the legacy schema (DRAFT v0.1)
--
-- Preconditions
--   * 01-04 have been run; the species list, parks and street segments are loaded.
--   * The legacy dump (legacy_trees.sql) is restored into schema "legacy":
--       legacy.baum, legacy.kontrolle, legacy.massnahme
--   * Session time zone = Europe/Berlin (legacy timestamps have no zone, A-24).
--
-- The script has two parts:
--   PART A  (re-runnable) creates mapping tables, pre-fills them with exact
--           matches and lists what still needs manual mapping.
--           -> curate migration.species_map / defect_map / measure_type_map
--   PART B  (single transaction) checks that all mappings are complete, then
--           loads everything. Any guard failure rolls back the whole load.
-- See legacy_mapping.md for the column-by-column mapping.
-- =============================================================================

SET TIME ZONE 'Europe/Berlin';

-- =============================================================================
-- PART A - preparation (re-runnable)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS migration;

CREATE OR REPLACE FUNCTION migration.norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

-- Legacy x/y are assumed to be EPSG:25832 (A-19). Some systems store the
-- easting with the zone prefix "32" (e.g. 32 567 123.45) -> strip it.
CREATE OR REPLACE FUNCTION migration.legacy_point(p_x numeric, p_y numeric)
RETURNS geometry LANGUAGE sql IMMUTABLE AS $$
  SELECT ST_SetSRID(ST_MakePoint(
           (CASE WHEN p_x >= 32000000 THEN p_x - 32000000 ELSE p_x END)::float8,
           p_y::float8), 25832)
$$;

CREATE TABLE IF NOT EXISTS migration.species_map (
    legacy_name text PRIMARY KEY,                    -- migration.norm(baum.art_lat); '' = empty
    species_id  integer NOT NULL REFERENCES cadastre.species (species_id)
);
CREATE TABLE IF NOT EXISTS migration.defect_map (
    legacy_token text PRIMARY KEY,                   -- migration.norm(one item of kontrolle.maengel)
    defect_code  text REFERENCES cadastre.defect_type (defect_code)   -- NULL = drop deliberately (logged)
);
CREATE TABLE IF NOT EXISTS migration.measure_type_map (
    legacy_art        text PRIMARY KEY,              -- migration.norm(massnahme.art)
    measure_type_code text NOT NULL REFERENCES cadastre.measure_type (measure_type_code)
);
CREATE TABLE IF NOT EXISTS migration.inspection_map (
    legacy_id     integer PRIMARY KEY,
    inspection_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE
);
CREATE TABLE IF NOT EXISTS migration.measure_map (
    legacy_id  integer PRIMARY KEY,
    measure_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE
);
CREATE TABLE IF NOT EXISTS migration.reject (
    source_table text NOT NULL,
    source_key   text,
    reason       text NOT NULL,
    logged_at    timestamptz NOT NULL DEFAULT now()
);

-- Exact (normalised) matches are mapped automatically.
INSERT INTO migration.species_map (legacy_name, species_id)
SELECT DISTINCT migration.norm(b.art_lat), s.species_id
  FROM legacy.baum b
  JOIN cadastre.species s ON migration.norm(s.botanical_name) = migration.norm(b.art_lat)
ON CONFLICT DO NOTHING;

INSERT INTO migration.defect_map (legacy_token, defect_code)
SELECT DISTINCT migration.norm(tok), d.defect_code
  FROM legacy.kontrolle k
 CROSS JOIN LATERAL regexp_split_to_table(k.maengel, '\s*[,;]\s*') AS split(tok)
  JOIN cadastre.defect_type d
    ON migration.norm(tok) IN (migration.norm(d.label_de), migration.norm(d.label_en), d.defect_code)
ON CONFLICT DO NOTHING;

INSERT INTO migration.measure_type_map (legacy_art, measure_type_code)
SELECT DISTINCT migration.norm(m.art), mt.measure_type_code
  FROM legacy.massnahme m
  JOIN cadastre.measure_type mt
    ON migration.norm(m.art) IN (migration.norm(mt.label_de), migration.norm(mt.label_en), mt.measure_type_code)
ON CONFLICT DO NOTHING;

-- --- Work lists for manual mapping (run and curate) ---------------------------
-- Unmapped species names (with frequency):
--   SELECT migration.norm(art_lat) AS legacy_name, count(*) FROM legacy.baum
--    WHERE migration.norm(art_lat) NOT IN (SELECT legacy_name FROM migration.species_map)
--    GROUP BY 1 ORDER BY 2 DESC;
-- Unmapped defect tokens:
--   SELECT migration.norm(tok) AS token, count(*) FROM legacy.kontrolle k
--    CROSS JOIN LATERAL regexp_split_to_table(k.maengel, '\s*[,;]\s*') AS split(tok)
--    WHERE migration.norm(tok) <> '' AND migration.norm(tok) NOT IN (SELECT legacy_token FROM migration.defect_map)
--    GROUP BY 1 ORDER BY 2 DESC;
-- Unmapped measure kinds:
--   SELECT migration.norm(art), count(*) FROM legacy.massnahme
--    WHERE migration.norm(art) NOT IN (SELECT legacy_art FROM migration.measure_type_map)
--    GROUP BY 1 ORDER BY 2 DESC;
-- Unexpected felled flags:
--   SELECT gefaellt, count(*) FROM legacy.baum GROUP BY 1;
-- Implausible coordinates:
--   SELECT baum_nr, x, y FROM legacy.baum
--    WHERE x IS NULL OR y IS NULL
--       OR ST_X(migration.legacy_point(x, y)) NOT BETWEEN 166000 AND 834000
--       OR y NOT BETWEEN 5200000 AND 6200000;

-- =============================================================================
-- PART B - load (one transaction)
-- =============================================================================
BEGIN;
SET LOCAL app.actor = 'legacy-migration';

-- Guards ----------------------------------------------------------------------
DO $$
DECLARE
    n integer;
BEGIN
    IF EXISTS (SELECT 1 FROM cadastre.tree) THEN
        RAISE EXCEPTION 'cadastre.tree is not empty - migration must run on an empty cadastre';
    END IF;

    SELECT count(*) INTO n FROM legacy.baum b
     WHERE NOT EXISTS (SELECT 1 FROM migration.species_map m WHERE m.legacy_name = migration.norm(b.art_lat));
    IF n > 0 THEN RAISE EXCEPTION '% legacy trees have an unmapped species (fill migration.species_map)', n; END IF;

    SELECT count(*) INTO n FROM legacy.baum b
     WHERE b.x IS NULL OR b.y IS NULL
        OR ST_X(migration.legacy_point(b.x, b.y)) NOT BETWEEN 166000 AND 834000
        OR b.y NOT BETWEEN 5200000 AND 6200000;
    IF n > 0 THEN RAISE EXCEPTION '% legacy trees have missing or implausible coordinates (fix in legacy.baum)', n; END IF;

    SELECT count(*) INTO n FROM legacy.kontrolle k
     CROSS JOIN LATERAL regexp_split_to_table(k.maengel, '\s*[,;]\s*') AS split(tok)
     WHERE migration.norm(tok) <> ''
       AND NOT EXISTS (SELECT 1 FROM migration.defect_map d WHERE d.legacy_token = migration.norm(tok));
    IF n > 0 THEN RAISE EXCEPTION '% legacy defect entries are unmapped (fill migration.defect_map)', n; END IF;

    SELECT count(*) INTO n FROM legacy.massnahme m
     WHERE NOT EXISTS (SELECT 1 FROM migration.measure_type_map t WHERE t.legacy_art = migration.norm(m.art));
    IF n > 0 THEN RAISE EXCEPTION '% legacy measures have an unmapped kind (fill migration.measure_type_map)', n; END IF;
END;
$$;

TRUNCATE migration.reject, migration.inspection_map, migration.measure_map;

-- The initial load is not a "change": suspend audit + touch triggers.
ALTER TABLE cadastre.staff             DISABLE TRIGGER staff_audit;
ALTER TABLE cadastre.contractor        DISABLE TRIGGER contractor_audit;
ALTER TABLE cadastre.tree              DISABLE TRIGGER tree_audit;
ALTER TABLE cadastre.tree              DISABLE TRIGGER tree_touch;
ALTER TABLE cadastre.inspection        DISABLE TRIGGER inspection_audit;
ALTER TABLE cadastre.inspection_defect DISABLE TRIGGER inspection_defect_audit;
ALTER TABLE cadastre.measure           DISABLE TRIGGER measure_audit;

-- 1. Trees ---------------------------------------------------------------------
INSERT INTO cadastre.tree (tree_number, species_id, planting_year, geom, location_since,
                           park_id, street_segment_id, status, remarks, is_legacy_import,
                           created_at, created_by, updated_at, updated_by)
SELECT b.baum_nr,
       sm.species_id,
       CASE WHEN b.pflanzjahr BETWEEN 1700 AND extract(year FROM current_date) THEN b.pflanzjahr END,
       migration.legacy_point(b.x, b.y),
       coalesce(b.angelegt_am, now()),
       pk.park_id,
       CASE WHEN pk.park_id IS NULL THEN seg.street_segment_id END,
       CASE WHEN upper(btrim(b.gefaellt)) = 'J' THEN 'felled' ELSE 'living' END::cadastre.tree_status,
       nullif(concat_ws('; ',
                'Legacy Strasse: ' || nullif(btrim(b.strasse), ''),
                'Legacy Park: '    || nullif(btrim(b.park), '')), ''),
       true,
       coalesce(b.angelegt_am, now()),
       'legacy-migration',
       coalesce(b.geaendert_am, b.angelegt_am, now()),
       coalesce(nullif(btrim(b.geaendert_von), ''), 'legacy-migration')
  FROM legacy.baum b
  JOIN migration.species_map sm ON sm.legacy_name = migration.norm(b.art_lat)
  LEFT JOIN LATERAL (
        SELECT p.park_id
          FROM cadastre.park p
         WHERE migration.norm(b.park) <> ''
           AND migration.norm(p.name) = migration.norm(b.park)
         ORDER BY ST_Distance(p.geom, migration.legacy_point(b.x, b.y)) NULLS LAST
         LIMIT 1) pk ON true
  LEFT JOIN LATERAL (
        SELECT s.street_segment_id
          FROM cadastre.street_segment s
         WHERE migration.norm(b.strasse) <> ''
           AND migration.norm(s.street_name) = migration.norm(b.strasse)
           AND ST_DWithin(s.geom, migration.legacy_point(b.x, b.y), 50)
         ORDER BY ST_Distance(s.geom, migration.legacy_point(b.x, b.y))
         LIMIT 1) seg ON true;

INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'baum', t.tree_number::text, 'no park / street segment could be assigned - fix manually'
  FROM cadastre.tree t
 WHERE t.park_id IS NULL AND t.street_segment_id IS NULL;

INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'baum', b.baum_nr::text, 'planting year ' || b.pflanzjahr || ' implausible - set to NULL'
  FROM legacy.baum b
 WHERE b.pflanzjahr IS NOT NULL AND b.pflanzjahr NOT BETWEEN 1700 AND extract(year FROM current_date);

SELECT setval('cadastre.tree_number_seq', greatest((SELECT max(tree_number) FROM cadastre.tree), 1));

-- 2. Inspectors (legacy free-text names -> staff, inactive until linked to a login)
INSERT INTO cadastre.staff (display_name, is_inspector, is_active, is_legacy_import)
SELECT DISTINCT ON (migration.norm(k.kontrolleur)) btrim(k.kontrolleur), true, false, true
  FROM legacy.kontrolle k
 WHERE migration.norm(k.kontrolleur) <> ''
 ORDER BY migration.norm(k.kontrolleur), k.kontrolleur;

INSERT INTO cadastre.staff (display_name, is_inspector, is_active, is_legacy_import)
VALUES ('Unbekannt (Altdaten)', true, false, true);

-- 3. Inspections -----------------------------------------------------------------
INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'kontrolle', k.id::text,
       CASE WHEN t.tree_id IS NULL      THEN 'no / unknown baum_nr'
            WHEN k.datum > current_date THEN 'inspection date in the future'
            ELSE 'inspection date before 1950' END
  FROM legacy.kontrolle k
  LEFT JOIN cadastre.tree t ON t.tree_number = k.baum_nr
 WHERE t.tree_id IS NULL OR k.datum > current_date OR k.datum < DATE '1950-01-01';

INSERT INTO migration.inspection_map (legacy_id)
SELECT k.id
  FROM legacy.kontrolle k
  JOIN cadastre.tree t ON t.tree_number = k.baum_nr
 WHERE k.datum BETWEEN DATE '1950-01-01' AND current_date;

INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'kontrolle', k.id::text, 'stammumfang ' || k.stammumfang || ' implausible - set to NULL'
  FROM legacy.kontrolle k JOIN migration.inspection_map im ON im.legacy_id = k.id
 WHERE k.stammumfang IS NOT NULL AND k.stammumfang NOT BETWEEN 1 AND 2000
UNION ALL
SELECT 'kontrolle', k.id::text, 'hoehe ' || k.hoehe || ' implausible - set to NULL'
  FROM legacy.kontrolle k JOIN migration.inspection_map im ON im.legacy_id = k.id
 WHERE k.hoehe IS NOT NULL AND NOT (k.hoehe > 0 AND k.hoehe <= 80);

INSERT INTO cadastre.inspection (inspection_id, tree_id, inspected_on, inspector_id,
                                 trunk_circumference_cm, crown_diameter_m, height_m, vitality_class,
                                 is_legacy_import, created_at, created_by, updated_at, updated_by)
SELECT im.inspection_id,
       t.tree_id,
       k.datum,
       coalesce(st.staff_id, unk.staff_id),
       CASE WHEN k.stammumfang BETWEEN 1 AND 2000 THEN k.stammumfang END,
       NULL,                                            -- not recorded in legacy
       CASE WHEN k.hoehe > 0 AND k.hoehe <= 80 THEN k.hoehe END,
       k.vitalitaet,
       true,
       k.datum::timestamptz, 'legacy-migration',
       k.datum::timestamptz, 'legacy-migration'
  FROM legacy.kontrolle k
  JOIN migration.inspection_map im ON im.legacy_id = k.id
  JOIN cadastre.tree t ON t.tree_number = k.baum_nr
  LEFT JOIN cadastre.staff st
         ON st.is_legacy_import AND migration.norm(st.display_name) = migration.norm(k.kontrolleur)
        AND migration.norm(k.kontrolleur) <> ''
 CROSS JOIN (SELECT staff_id FROM cadastre.staff
              WHERE is_legacy_import AND display_name = 'Unbekannt (Altdaten)') unk;

-- 4. Defects (comma separated text -> rows; severity unknown = NULL) ---------------
INSERT INTO migration.reject (source_table, source_key, reason)
SELECT DISTINCT 'kontrolle', k.id::text, 'defect "' || btrim(tok) || '" deliberately dropped (defect_map NULL)'
  FROM legacy.kontrolle k
  JOIN migration.inspection_map im ON im.legacy_id = k.id
 CROSS JOIN LATERAL regexp_split_to_table(k.maengel, '\s*[,;]\s*') AS split(tok)
  JOIN migration.defect_map dm ON dm.legacy_token = migration.norm(tok) AND dm.defect_code IS NULL;

INSERT INTO cadastre.inspection_defect (inspection_id, defect_code, severity, is_legacy_import, created_at, created_by)
SELECT DISTINCT ON (im.inspection_id, dm.defect_code)
       im.inspection_id, dm.defect_code, NULL::cadastre.defect_severity, true,
       k.datum::timestamptz, 'legacy-migration'
  FROM legacy.kontrolle k
  JOIN migration.inspection_map im ON im.legacy_id = k.id
 CROSS JOIN LATERAL regexp_split_to_table(k.maengel, '\s*[,;]\s*') AS split(tok)
  JOIN migration.defect_map dm ON dm.legacy_token = migration.norm(tok) AND dm.defect_code IS NOT NULL;

-- 5. Contractors (free text -> contractor) --------------------------------------
INSERT INTO cadastre.contractor (name, is_active, is_legacy_import)
SELECT DISTINCT ON (lower(btrim(m.firma))) btrim(m.firma), false, true
  FROM legacy.massnahme m
 WHERE migration.norm(m.firma) <> ''
 ORDER BY lower(btrim(m.firma)), m.firma
ON CONFLICT DO NOTHING;

-- 6. Measures --------------------------------------------------------------------
INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'massnahme', m.id::text,
       CASE WHEN im.legacy_id IS NULL THEN 'no / rejected kontrolle - tree unknown'
            ELSE 'completion date in the future' END
  FROM legacy.massnahme m
  LEFT JOIN migration.inspection_map im ON im.legacy_id = m.kontrolle_id
 WHERE im.legacy_id IS NULL OR m.erledigt > current_date;

INSERT INTO migration.measure_map (legacy_id)
SELECT m.id
  FROM legacy.massnahme m
  JOIN migration.inspection_map im ON im.legacy_id = m.kontrolle_id
 WHERE m.erledigt IS NULL OR m.erledigt <= current_date;

INSERT INTO cadastre.measure (measure_id, tree_id, inspection_id, measure_type_code, priority, due_on,
                              ordered_on, ordered_by, status, completed_on, contractor_id,
                              is_legacy_import, created_at, created_by, updated_at, updated_by)
SELECT mm.measure_id,
       i.tree_id,
       i.inspection_id,
       tm.measure_type_code,
       NULL,                                   -- no priority in legacy
       m.faellig,
       i.inspected_on,                         -- order date unknown -> date of the inspection (A-20)
       NULL,
       CASE WHEN m.erledigt IS NOT NULL THEN 'done' ELSE 'ordered' END::cadastre.measure_status,
       m.erledigt,
       c.contractor_id,
       true,
       i.inspected_on::timestamptz, 'legacy-migration',
       coalesce(m.erledigt, i.inspected_on)::timestamptz, 'legacy-migration'
  FROM legacy.massnahme m
  JOIN migration.measure_map mm      ON mm.legacy_id = m.id
  JOIN migration.inspection_map im   ON im.legacy_id = m.kontrolle_id
  JOIN cadastre.inspection i         ON i.inspection_id = im.inspection_id
  JOIN migration.measure_type_map tm ON tm.legacy_art = migration.norm(m.art)
  LEFT JOIN cadastre.contractor c    ON lower(c.name) = lower(btrim(m.firma));

-- 7. Felling date for legacy felled trees = latest completed felling measure -------
UPDATE cadastre.tree t
   SET felled_on          = f.completed_on,
       felling_measure_id = f.measure_id
  FROM (SELECT DISTINCT ON (m.tree_id) m.tree_id, m.measure_id, m.completed_on
          FROM cadastre.measure m
          JOIN cadastre.measure_type mt USING (measure_type_code)
         WHERE mt.is_felling AND m.status = 'done'
         ORDER BY m.tree_id, m.completed_on DESC) f
 WHERE f.tree_id = t.tree_id
   AND t.status = 'felled';

INSERT INTO migration.reject (source_table, source_key, reason)
SELECT 'baum', t.tree_number::text, 'felled tree without felling date / reason - complete manually'
  FROM cadastre.tree t
 WHERE t.status = 'felled' AND (t.felled_on IS NULL OR t.felling_reason_code IS NULL);

-- Re-enable triggers -------------------------------------------------------------
ALTER TABLE cadastre.staff             ENABLE TRIGGER staff_audit;
ALTER TABLE cadastre.contractor        ENABLE TRIGGER contractor_audit;
ALTER TABLE cadastre.tree              ENABLE TRIGGER tree_audit;
ALTER TABLE cadastre.tree              ENABLE TRIGGER tree_touch;
ALTER TABLE cadastre.inspection        ENABLE TRIGGER inspection_audit;
ALTER TABLE cadastre.inspection_defect ENABLE TRIGGER inspection_defect_audit;
ALTER TABLE cadastre.measure           ENABLE TRIGGER measure_audit;

-- One audit entry documenting the load itself
INSERT INTO cadastre.audit_log (table_name, row_key, action, changed_by, new_row)
VALUES ('*', 'legacy-migration', 'I', 'legacy-migration',
        jsonb_build_object(
            'trees',       (SELECT count(*) FROM cadastre.tree),
            'inspections', (SELECT count(*) FROM cadastre.inspection),
            'defects',     (SELECT count(*) FROM cadastre.inspection_defect),
            'measures',    (SELECT count(*) FROM cadastre.measure),
            'rejects',     (SELECT count(*) FROM migration.reject)));

COMMIT;

-- Reconciliation (run after commit) -------------------------------------------------
--   SELECT 'baum' src, (SELECT count(*) FROM legacy.baum) legacy, (SELECT count(*) FROM cadastre.tree) target
--   UNION ALL SELECT 'kontrolle', (SELECT count(*) FROM legacy.kontrolle), (SELECT count(*) FROM cadastre.inspection)
--   UNION ALL SELECT 'massnahme', (SELECT count(*) FROM legacy.massnahme), (SELECT count(*) FROM cadastre.measure);
--   SELECT source_table, reason, count(*) FROM migration.reject GROUP BY 1, 2 ORDER BY 1, 3 DESC;
--   REFRESH MATERIALIZED VIEW opendata.tree;   -- first refresh must be non-concurrent

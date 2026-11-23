-- =============================================================================
-- Urban Tree Cadastre - initial code list content (DRAFT v0.1)
--
-- !! PLACEHOLDER VALUES !!  Only "deadwood", "cavity", "root damage" (defects)
-- and "pruning", "felling", "cabling" (measures) are named in the requirements.
-- Everything else is a proposal to be replaced by the department's official
-- lists (see ASSUMPTIONS.md A-10, A-12, A-13, A-15).
-- The species list (~900 entries) is loaded from the arborist team's list,
-- not from this file.
-- =============================================================================

BEGIN;

SET LOCAL app.actor = 'initial-seed';

INSERT INTO cadastre.vitality_class (vitality_class, label_de, label_en, description) VALUES
  (1, 'vital',                     'vital',                'PLACEHOLDER - full vitality, no impairment'),
  (2, 'leicht geschwächt',         'slightly impaired',    'PLACEHOLDER'),
  (3, 'deutlich geschwächt',       'clearly impaired',     'PLACEHOLDER'),
  (4, 'stark geschwächt',          'severely impaired',    'PLACEHOLDER'),
  (5, 'absterbend / abgestorben',  'dying / dead',         'PLACEHOLDER');

INSERT INTO cadastre.measure_priority (priority, label_de, label_en, description) VALUES
  (1, 'sofort',   'immediate', 'PLACEHOLDER - acute traffic-safety risk, same/next working day'),
  (2, 'dringend', 'urgent',    'PLACEHOLDER - within 4 weeks'),
  (3, 'normal',   'normal',    'PLACEHOLDER - within the current season'),
  (4, 'niedrig',  'low',       'PLACEHOLDER - when convenient / with next scheduled work');

INSERT INTO cadastre.defect_type (defect_code, label_de, label_en, sort_order) VALUES
  ('deadwood',          'Totholz',                 'Deadwood',              10),
  ('cavity',            'Höhlung',                 'Cavity',                20),
  ('root_damage',       'Wurzelschaden',           'Root damage',           30),
  ('bark_damage',       'Rindenschaden',           'Bark damage',           40),
  ('stem_crack',        'Stammriss',               'Stem crack',            50),
  ('included_bark',     'Druckzwiesel',            'Included bark fork',    60),
  ('fungal_fruit_body', 'Pilzfruchtkörper',        'Fungal fruiting body',  70),
  ('crown_break',       'Kronenbruch',             'Crown breakage',        80),
  ('lean',              'Schiefstand',             'Lean',                  90),
  ('root_plate_lift',   'Wurzelanhebung',          'Root plate lifting',   100),
  ('pest_infestation',  'Schädlingsbefall',        'Pest infestation',     110),
  ('clearance_conflict','Lichtraumprofil verletzt','Clearance conflict',   120);

INSERT INTO cadastre.measure_type (measure_type_code, label_de, label_en, is_felling, sort_order) VALUES
  ('pruning',              'Kronenpflege / Schnitt',   'Pruning',                false, 10),
  ('deadwood_removal',     'Totholzentfernung',        'Deadwood removal',       false, 20),
  ('crown_reduction',      'Kroneneinkürzung',         'Crown reduction',        false, 30),
  ('clearance_pruning',    'Lichtraumprofilschnitt',   'Clearance pruning',      false, 40),
  ('cabling',              'Kronensicherung',          'Cabling / crown bracing',false, 50),
  ('detailed_examination', 'Eingehende Untersuchung',  'Detailed examination',   false, 60),
  ('felling',              'Fällung',                  'Felling',                true,  70);

INSERT INTO cadastre.felling_reason (felling_reason_code, label_de, label_en, sort_order) VALUES
  ('traffic_safety', 'Verkehrssicherheit',   'Traffic safety',      10),
  ('dead',           'Abgestorben',          'Dead',                20),
  ('disease_pest',   'Krankheit / Schädling','Disease / pest',      30),
  ('storm_damage',   'Sturmschaden',         'Storm damage',        40),
  ('construction',   'Baumaßnahme',          'Construction works',  50),
  ('accident',       'Unfallschaden',        'Accident damage',     60),
  ('other',          'Sonstiges',            'Other',               99);

COMMIT;

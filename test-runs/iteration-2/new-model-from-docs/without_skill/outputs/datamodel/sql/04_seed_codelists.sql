-- =====================================================================
-- Urban Tree Cadastre – initial code list values (PLACEHOLDERS)
-- These are illustrative starter values. The department's authoritative
-- defect list, measure list and felling reasons must replace them. [A-28]
-- =====================================================================
SET search_path = cadastre, public;

-- Vitality classes 1-5 as stated in the requirements.  [A-10]
-- NOTE: the original Roloff scale has 4 classes (0-3). Labels below are a
-- working assumption for a 5-step city scale and need confirmation.
INSERT INTO vitality_class (vitality_class, label_de, label_en, description) VALUES
 (1, 'sehr vital',        'very vital',        'Full vigour, no visible decline'),
 (2, 'leicht geschwächt', 'slightly impaired', 'Slight reduction of vitality'),
 (3, 'deutlich geschwächt','clearly impaired', 'Clear reduction of vitality'),
 (4, 'stark geschwächt',  'severely impaired', 'Severe decline, crown dieback'),
 (5, 'absterbend / tot',  'dying / dead',      'Dying or dead tree');

INSERT INTO defect_type (defect_type_code, label_de, label_en, sort_order) VALUES
 ('DEADWOOD',      'Totholz',               'Deadwood',              10),
 ('CAVITY',        'Höhlung',               'Cavity',                20),
 ('ROOT_DAMAGE',   'Wurzelschaden',         'Root damage',           30),
 ('BARK_DAMAGE',   'Rindenschaden',         'Bark damage',           40),
 ('CRACK',         'Riss',                  'Crack',                 50),
 ('FUNGUS',        'Pilzbefall',            'Fungal fruiting bodies',60),
 ('CO_DOMINANT',   'Zwiesel',               'Co-dominant stems',     70),
 ('LEANING',       'Schiefstand',           'Leaning',               80),
 ('CLEARANCE',     'Lichtraumprofil',       'Clearance infringement',90),
 ('OTHER',         'Sonstiger Mangel',      'Other defect',          99);

INSERT INTO measure_type (measure_type_code, label_de, label_en, is_felling, sort_order) VALUES
 ('PRUNING',        'Rückschnitt / Pflegeschnitt', 'Pruning',              false, 10),
 ('DEADWOOD_REMOVAL','Totholzentfernung',          'Deadwood removal',     false, 20),
 ('CROWN_REDUCTION','Kroneneinkürzung',            'Crown reduction',      false, 30),
 ('CABLING',        'Kronensicherung',             'Cabling / bracing',    false, 40),
 ('CLEARANCE_CUT',  'Lichtraumprofilschnitt',      'Clearance pruning',    false, 50),
 ('DETAILED_EXAM',  'Eingehende Untersuchung',     'Detailed examination', false, 60),
 ('FELLING',        'Fällung',                     'Felling',              true,  90),
 ('OTHER',          'Sonstige Maßnahme',           'Other measure',        false, 99);

INSERT INTO felling_reason (felling_reason_code, label_de, label_en) VALUES
 ('TRAFFIC_SAFETY', 'Verkehrssicherheit',  'Traffic safety'),
 ('DEAD',           'Abgestorben',         'Dead tree'),
 ('DISEASE',        'Krankheit / Schädling','Disease or pest'),
 ('STORM',          'Sturmschaden',        'Storm damage'),
 ('CONSTRUCTION',   'Baumaßnahme',         'Construction project'),
 ('OTHER',          'Sonstiger Grund',     'Other reason'),
 ('UNKNOWN_LEGACY', 'Unbekannt (Altdaten)','Unknown (legacy data)');

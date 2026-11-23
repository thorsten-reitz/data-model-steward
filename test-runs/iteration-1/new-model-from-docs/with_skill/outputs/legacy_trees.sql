-- legacy schema (exported 2026-09-30)
CREATE TABLE baum (
  baum_nr      integer PRIMARY KEY,
  art_lat      varchar(120),          -- botanical name, free text (!)
  pflanzjahr   smallint,
  x            numeric(10,2),
  y            numeric(10,2),
  strasse      varchar(100),
  park         varchar(100),
  gefaellt     char(1) DEFAULT 'N',   -- 'J' = felled
  angelegt_am  timestamp,
  geaendert_am timestamp,
  geaendert_von varchar(30)
);
CREATE TABLE kontrolle (
  id         serial PRIMARY KEY,
  baum_nr    integer REFERENCES baum(baum_nr),
  datum      date NOT NULL,
  kontrolleur varchar(60),
  vitalitaet smallint CHECK (vitalitaet BETWEEN 1 AND 5),
  stammumfang integer,
  hoehe      numeric(4,1),
  maengel    text                   -- comma separated list
);
CREATE TABLE massnahme (
  id          serial PRIMARY KEY,
  kontrolle_id integer REFERENCES kontrolle(id),
  art         varchar(40),
  faellig     date,
  erledigt    date,
  firma       varchar(100)
);

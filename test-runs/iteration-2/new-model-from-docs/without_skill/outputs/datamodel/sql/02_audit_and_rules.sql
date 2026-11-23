-- =====================================================================
-- Urban Tree Cadastre – triggers: bookkeeping, audit, no-delete rules,
-- location history, roles & privileges.
--
-- The application identifies the end user per transaction with
--     SET LOCAL app.user   = '<login_name>';
--     SET LOCAL app.client = '<tablet-id / sync-batch-id>';          (optional)
--     SET LOCAL app.correction_reason = 'GPS error, re-measured';    (optional, location fixes)
-- If not set, the database role name is recorded.            [A-19]
-- =====================================================================
SET search_path = cadastre, public;

CREATE OR REPLACE FUNCTION app_user() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('app.user', true), ''), current_user::text)
$$;

-- ---------------------------------------------------------------------
-- 1. Bookkeeping: created_by / updated_at / updated_by / row_version
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_bookkeeping() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := coalesce(NEW.created_at, now());
        NEW.created_by := app_user();
        NEW.updated_at := NEW.created_at;
        NEW.updated_by := NEW.created_by;
        NEW.row_version := 1;
    ELSE
        -- immutable creation data
        NEW.created_at := OLD.created_at;
        NEW.created_by := OLD.created_by;
        NEW.updated_at := now();
        NEW.updated_by := app_user();
        NEW.row_version := OLD.row_version + 1;
    END IF;
    RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['species','park','street_segment','staff','contractor',
                             'tree','inspection','measure']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_bookkeeping()',
                       t || '_bookkeeping', t);
    END LOOP;
END $$;

-- Optimistic locking for offline sync: the client sends the row_version it
-- edited; if the server row moved on, the update is rejected.        [A-17]
-- Usage: UPDATE tree SET ..., row_version = <client_version> WHERE tree_id = ...;
CREATE OR REPLACE FUNCTION trg_optimistic_lock() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.row_version IS DISTINCT FROM OLD.row_version THEN
        RAISE EXCEPTION 'Concurrent modification of % (server version %, client version %)',
              TG_TABLE_NAME, OLD.row_version, NEW.row_version
              USING ERRCODE = 'serialization_failure';
    END IF;
    RETURN NEW;
END $$;
-- Must fire before trg_bookkeeping (triggers fire alphabetically by name).
CREATE TRIGGER tree_a_optimistic_lock       BEFORE UPDATE ON tree       FOR EACH ROW EXECUTE FUNCTION trg_optimistic_lock();
CREATE TRIGGER inspection_a_optimistic_lock BEFORE UPDATE ON inspection FOR EACH ROW EXECUTE FUNCTION trg_optimistic_lock();
CREATE TRIGGER measure_a_optimistic_lock    BEFORE UPDATE ON measure    FOR EACH ROW EXECUTE FUNCTION trg_optimistic_lock();

-- ---------------------------------------------------------------------
-- 2. Generic audit trigger.  TG_ARGV = primary key column names.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = cadastre, public AS $$
DECLARE
    o jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
    n jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END;
    r jsonb := coalesce(n, o);
    pk text;
    cols text[];
BEGIN
    SELECT string_agg(r ->> col, '|' ORDER BY ord)
      INTO pk
      FROM unnest(TG_ARGV) WITH ORDINALITY AS a(col, ord);

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(key ORDER BY key) INTO cols
          FROM jsonb_each(n) e
         WHERE e.value IS DISTINCT FROM o -> e.key
           AND e.key NOT IN ('updated_at','updated_by','row_version');
        IF cols IS NULL THEN
            RETURN NULL;                       -- no-op update, nothing to log
        END IF;
    END IF;

    INSERT INTO audit_log (table_name, row_pk, action, changed_by, client_info,
                           old_values, new_values, changed_cols)
    VALUES (TG_TABLE_NAME, pk, left(TG_OP, 1), app_user(),
            nullif(current_setting('app.client', true), ''), o, n, cols);
    RETURN NULL;
END $$;

CREATE TRIGGER tree_audit              AFTER INSERT OR UPDATE OR DELETE ON tree              FOR EACH ROW EXECUTE FUNCTION trg_audit('tree_id');
CREATE TRIGGER inspection_audit        AFTER INSERT OR UPDATE OR DELETE ON inspection        FOR EACH ROW EXECUTE FUNCTION trg_audit('inspection_id');
CREATE TRIGGER inspection_defect_audit AFTER INSERT OR UPDATE OR DELETE ON inspection_defect FOR EACH ROW EXECUTE FUNCTION trg_audit('inspection_id','defect_type_code');
CREATE TRIGGER measure_audit           AFTER INSERT OR UPDATE OR DELETE ON measure           FOR EACH ROW EXECUTE FUNCTION trg_audit('measure_id');
CREATE TRIGGER tree_replacement_audit  AFTER INSERT OR UPDATE OR DELETE ON tree_replacement  FOR EACH ROW EXECUTE FUNCTION trg_audit('felled_tree_id','replacement_tree_id');
CREATE TRIGGER species_audit           AFTER INSERT OR UPDATE OR DELETE ON species           FOR EACH ROW EXECUTE FUNCTION trg_audit('species_id');
CREATE TRIGGER staff_audit             AFTER INSERT OR UPDATE OR DELETE ON staff             FOR EACH ROW EXECUTE FUNCTION trg_audit('staff_id');
CREATE TRIGGER contractor_audit        AFTER INSERT OR UPDATE OR DELETE ON contractor        FOR EACH ROW EXECUTE FUNCTION trg_audit('contractor_id');
CREATE TRIGGER defect_type_audit       AFTER INSERT OR UPDATE OR DELETE ON defect_type       FOR EACH ROW EXECUTE FUNCTION trg_audit('defect_type_code');
CREATE TRIGGER measure_type_audit      AFTER INSERT OR UPDATE OR DELETE ON measure_type      FOR EACH ROW EXECUTE FUNCTION trg_audit('measure_type_code');

-- ---------------------------------------------------------------------
-- 3. No-delete rules (enforced for every role, incl. table owner)
--    Trees: UC4 – never deleted (use status 'felled' or 'void').
--    Inspections: UC2 – never deleted.
--    Measures: kept for history (use status 'cancelled').
--    Location history and audit log: append-only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_forbid_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Deleting from % is not allowed (%)', TG_TABLE_NAME, coalesce(TG_ARGV[0], 'business rule')
          USING ERRCODE = 'restrict_violation';
END $$;

CREATE TRIGGER tree_no_delete       BEFORE DELETE ON tree       FOR EACH ROW EXECUTE FUNCTION trg_forbid_delete('UC4: set status felled/void instead');
CREATE TRIGGER inspection_no_delete BEFORE DELETE ON inspection FOR EACH ROW EXECUTE FUNCTION trg_forbid_delete('UC2: inspections are never deleted');
CREATE TRIGGER measure_no_delete    BEFORE DELETE ON measure    FOR EACH ROW EXECUTE FUNCTION trg_forbid_delete('set status cancelled instead');
CREATE TRIGGER tree_location_history_no_change BEFORE UPDATE OR DELETE ON tree_location_history
    FOR EACH ROW EXECUTE FUNCTION trg_forbid_delete('location history is append-only');
CREATE TRIGGER audit_log_no_change  BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_forbid_delete('audit log is append-only');
-- TRUNCATE bypasses row triggers:
CREATE TRIGGER tree_no_truncate       BEFORE TRUNCATE ON tree       FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_delete('no truncate');
CREATE TRIGGER inspection_no_truncate BEFORE TRUNCATE ON inspection FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_delete('no truncate');
CREATE TRIGGER measure_no_truncate    BEFORE TRUNCATE ON measure    FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_delete('no truncate');
CREATE TRIGGER audit_log_no_truncate  BEFORE TRUNCATE ON audit_log  FOR EACH STATEMENT EXECUTE FUNCTION trg_forbid_delete('no truncate');
-- Note: inspection_defect rows MAY be deleted to correct a wrongly recorded defect;
-- the deletion is captured in audit_log.                             [A-09]

-- ---------------------------------------------------------------------
-- 4. Location correction history
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_tree_location_history() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT ST_Equals(NEW.location, OLD.location) THEN
        INSERT INTO tree_location_history (tree_id, location, valid_from, valid_to,
                                           corrected_by, correction_reason)
        VALUES (OLD.tree_id, OLD.location,
                coalesce(OLD.location_corrected_at, OLD.created_at),
                now(), app_user(),
                nullif(current_setting('app.correction_reason', true), ''));
        NEW.location_corrected_at := now();
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tree_location_history BEFORE UPDATE OF location ON tree
    FOR EACH ROW EXECUTE FUNCTION trg_tree_location_history();

-- ---------------------------------------------------------------------
-- 5. New trees must use an active species
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_tree_species_active() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.origin = 'app'
       AND (TG_OP = 'INSERT' OR NEW.species_id IS DISTINCT FROM OLD.species_id)
       AND NOT EXISTS (SELECT 1 FROM species s WHERE s.species_id = NEW.species_id AND s.is_active) THEN
        RAISE EXCEPTION 'Species % is inactive and cannot be assigned', NEW.species_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tree_species_active BEFORE INSERT OR UPDATE OF species_id ON tree
    FOR EACH ROW EXECUTE FUNCTION trg_tree_species_active();

-- ---------------------------------------------------------------------
-- 6. Compensation links: left side must be a felled tree
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_tree_replacement_check() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tree WHERE tree_id = NEW.felled_tree_id AND status = 'felled') THEN
        RAISE EXCEPTION 'Tree % is not felled; cannot record a replacement for it', NEW.felled_tree_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER tree_replacement_check BEFORE INSERT OR UPDATE ON tree_replacement
    FOR EACH ROW EXECUTE FUNCTION trg_tree_replacement_check();

-- ---------------------------------------------------------------------
-- 7. Roles and privileges (NOLOGIN group roles; grant to real logins)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_app')      THEN CREATE ROLE cadastre_app NOLOGIN;      END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_auditor')  THEN CREATE ROLE cadastre_auditor NOLOGIN;  END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_export')   THEN CREATE ROLE cadastre_export NOLOGIN;   END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'open_data_reader')  THEN CREATE ROLE open_data_reader NOLOGIN;  END IF;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA cadastre FROM PUBLIC;
GRANT USAGE ON SCHEMA cadastre TO cadastre_app, cadastre_auditor, cadastre_export, open_data_reader;

-- application: read/write, but no DELETE on protected tables
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA cadastre TO cadastre_app;
GRANT DELETE ON inspection_defect, tree_replacement TO cadastre_app;
REVOKE INSERT, UPDATE ON audit_log, tree_location_history, export_run FROM cadastre_app;
REVOKE SELECT ON audit_log FROM cadastre_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA cadastre TO cadastre_app;

-- auditors: read everything, incl. audit log
GRANT SELECT ON ALL TABLES IN SCHEMA cadastre TO cadastre_auditor;

-- export job: read everything except audit log; write export_run
GRANT SELECT ON ALL TABLES IN SCHEMA cadastre TO cadastre_export;
REVOKE SELECT ON audit_log FROM cadastre_export;
GRANT INSERT, UPDATE ON export_run TO cadastre_export;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA cadastre TO cadastre_export;
-- open_data_reader gets only the open data view (granted in 03_views.sql)

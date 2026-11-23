-- =============================================================================
-- Urban Tree Cadastre - triggers, business rules, audit, roles (DRAFT v0.1)
-- Requires 01_schema.sql.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Housekeeping on UPDATE: updated_at / updated_by / row_version,
--    created_* are immutable.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cadastre.trg_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.created_at  := OLD.created_at;
    NEW.created_by  := OLD.created_by;
    NEW.updated_at  := now();
    NEW.updated_by  := cadastre.current_actor();
    NEW.row_version := OLD.row_version + 1;
    RETURN NEW;
END;
$$;

CREATE TRIGGER species_touch     BEFORE UPDATE ON cadastre.species    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();
CREATE TRIGGER staff_touch       BEFORE UPDATE ON cadastre.staff      FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();
CREATE TRIGGER contractor_touch  BEFORE UPDATE ON cadastre.contractor FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();
CREATE TRIGGER tree_touch        BEFORE UPDATE ON cadastre.tree       FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();
CREATE TRIGGER inspection_touch  BEFORE UPDATE ON cadastre.inspection FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();
CREATE TRIGGER measure_touch     BEFORE UPDATE ON cadastre.measure    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_touch();

-- -----------------------------------------------------------------------------
-- 2. Location history: every change of tree.geom archives the old position.
--    Applications may SET LOCAL app.change_reason = '...' to document why.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cadastre.trg_tree_location_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER                       -- app role has no INSERT on the history table
SET search_path = cadastre, public, pg_temp
AS $$
BEGIN
    IF NOT ST_Equals(NEW.geom, OLD.geom) THEN
        INSERT INTO cadastre.tree_location_history
               (tree_id, geom, valid_from, valid_to, corrected_by, correction_reason)
        VALUES (OLD.tree_id, OLD.geom, OLD.location_since, now(), cadastre.current_actor(),
                nullif(current_setting('app.change_reason', true), ''));
        NEW.location_since := now();
    ELSE
        NEW.location_since := OLD.location_since;   -- not editable by hand
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tree_location_history
    BEFORE UPDATE OF geom, location_since ON cadastre.tree
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_tree_location_history();

-- -----------------------------------------------------------------------------
-- 3. Deletion ban (UC2 "inspections must never be deleted", UC4 "felled trees
--    are not deleted", measures are cancelled instead). Belt and braces:
--    privileges (section 6) AND triggers, so even table owners are stopped.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cadastre.trg_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Rows of %.% must not be deleted (use status / cancellation / deactivation instead)',
                    TG_TABLE_SCHEMA, TG_TABLE_NAME
          USING ERRCODE = 'restrict_violation';
END;
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['species', 'staff', 'contractor', 'tree', 'tree_location_history',
                             'tree_replacement', 'inspection', 'measure', 'audit_log']
    LOOP
        EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON cadastre.%I
                        FOR EACH ROW EXECUTE FUNCTION cadastre.trg_forbid_delete()', t || '_no_delete', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON cadastre.%I
                        FOR EACH STATEMENT EXECUTE FUNCTION cadastre.trg_forbid_delete()', t || '_no_truncate', t);
    END LOOP;
END;
$$;

-- tree_location_history and audit_log are append-only: no UPDATE either.
CREATE OR REPLACE FUNCTION cadastre.trg_forbid_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Rows of %.% are append-only', TG_TABLE_SCHEMA, TG_TABLE_NAME
          USING ERRCODE = 'restrict_violation';
END;
$$;
CREATE TRIGGER tree_location_history_no_update BEFORE UPDATE ON cadastre.tree_location_history
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_forbid_update();
CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON cadastre.audit_log
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_forbid_update();

-- -----------------------------------------------------------------------------
-- 4. Business rules that need other rows
-- -----------------------------------------------------------------------------
-- 4a. New trees / species changes must use an active species.
CREATE OR REPLACE FUNCTION cadastre.trg_tree_active_species()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF (TG_OP = 'INSERT' OR NEW.species_id IS DISTINCT FROM OLD.species_id)
       AND NOT NEW.is_legacy_import
       AND NOT EXISTS (SELECT 1 FROM cadastre.species s
                        WHERE s.species_id = NEW.species_id AND s.is_active) THEN
        RAISE EXCEPTION 'Species % is not active in the species list', NEW.species_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER tree_active_species BEFORE INSERT OR UPDATE OF species_id ON cadastre.tree
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_tree_active_species();

-- 4b. No inspections / measures dated in the future (CHECK cannot use current_date).
CREATE OR REPLACE FUNCTION cadastre.trg_inspection_not_in_future()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.inspected_on > current_date THEN
        RAISE EXCEPTION 'Inspection date % lies in the future', NEW.inspected_on
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER inspection_not_in_future BEFORE INSERT OR UPDATE OF inspected_on ON cadastre.inspection
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_inspection_not_in_future();

CREATE OR REPLACE FUNCTION cadastre.trg_measure_dates()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.completed_on > current_date THEN
        RAISE EXCEPTION 'Completion date % lies in the future', NEW.completed_on USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.completed_on < NEW.ordered_on AND NOT NEW.is_legacy_import THEN
        RAISE EXCEPTION 'Completion date % is before order date %', NEW.completed_on, NEW.ordered_on
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER measure_dates BEFORE INSERT OR UPDATE ON cadastre.measure
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_measure_dates();

-- 4c. Felling: felling_measure_id must be a measure of a felling type for the same tree.
CREATE OR REPLACE FUNCTION cadastre.trg_tree_felling_measure()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.felling_measure_id IS NOT NULL AND NOT EXISTS (
           SELECT 1
             FROM cadastre.measure m
             JOIN cadastre.measure_type mt USING (measure_type_code)
            WHERE m.measure_id = NEW.felling_measure_id
              AND m.tree_id    = NEW.tree_id
              AND mt.is_felling) THEN
        RAISE EXCEPTION 'felling_measure_id % is not a felling measure of tree %',
                        NEW.felling_measure_id, NEW.tree_id
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER tree_felling_measure BEFORE INSERT OR UPDATE OF felling_measure_id ON cadastre.tree
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_tree_felling_measure();

-- 4d. Compensation: the replaced tree must be felled, the replacement tree must be
--     planted no earlier than the felling year.  Checked when the link is created
--     (deferred to commit so an offline batch can insert in any order).
CREATE OR REPLACE FUNCTION cadastre.trg_tree_replacement_check()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_felled cadastre.tree;
    v_new    cadastre.tree;
BEGIN
    SELECT * INTO v_felled FROM cadastre.tree WHERE tree_id = NEW.felled_tree_id;
    SELECT * INTO v_new    FROM cadastre.tree WHERE tree_id = NEW.replacement_tree_id;
    IF v_felled.status <> 'felled' THEN
        RAISE EXCEPTION 'Tree % is not felled and cannot be replaced', v_felled.tree_number
              USING ERRCODE = 'check_violation';
    END IF;
    IF v_new.status <> 'living' THEN
        RAISE EXCEPTION 'Replacement tree % is not living', v_new.tree_number
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER tree_replacement_check
    AFTER INSERT OR UPDATE ON cadastre.tree_replacement
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_tree_replacement_check();

-- -----------------------------------------------------------------------------
-- 5. Generic audit trigger.  TG_ARGV = primary key column name(s).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cadastre.trg_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = cadastre, public, pg_temp
AS $$
DECLARE
    v_old  jsonb;
    v_new  jsonb;
    v_key  text;
    v_cols text[];
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW); END IF;

    SELECT string_agg(coalesce(v_new, v_old) ->> a.col, '|' ORDER BY a.ord)
      INTO v_key
      FROM unnest(TG_ARGV) WITH ORDINALITY AS a(col, ord);

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(n.key ORDER BY n.key)
          INTO v_cols
          FROM jsonb_each(v_new) AS n
         WHERE n.value IS DISTINCT FROM v_old -> n.key
           AND n.key NOT IN ('updated_at', 'updated_by', 'row_version');
        IF v_cols IS NULL THEN
            RETURN NULL;                       -- nothing of substance changed
        END IF;
    END IF;

    INSERT INTO cadastre.audit_log (table_name, row_key, action, changed_by, changed_columns, old_row, new_row)
    VALUES (TG_TABLE_NAME, v_key, left(TG_OP, 1), cadastre.current_actor(), v_cols, v_old, v_new);
    RETURN NULL;
END;
$$;

CREATE TRIGGER species_audit           AFTER INSERT OR UPDATE OR DELETE ON cadastre.species           FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('species_id');
CREATE TRIGGER staff_audit             AFTER INSERT OR UPDATE OR DELETE ON cadastre.staff             FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('staff_id');
CREATE TRIGGER contractor_audit        AFTER INSERT OR UPDATE OR DELETE ON cadastre.contractor        FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('contractor_id');
CREATE TRIGGER tree_audit              AFTER INSERT OR UPDATE OR DELETE ON cadastre.tree              FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('tree_id');
CREATE TRIGGER tree_replacement_audit  AFTER INSERT OR UPDATE OR DELETE ON cadastre.tree_replacement  FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('felled_tree_id', 'replacement_tree_id');
CREATE TRIGGER inspection_audit        AFTER INSERT OR UPDATE OR DELETE ON cadastre.inspection        FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('inspection_id');
CREATE TRIGGER inspection_defect_audit AFTER INSERT OR UPDATE OR DELETE ON cadastre.inspection_defect FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('inspection_id', 'defect_code');
CREATE TRIGGER measure_audit           AFTER INSERT OR UPDATE OR DELETE ON cadastre.measure           FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('measure_id');
CREATE TRIGGER defect_type_audit       AFTER INSERT OR UPDATE OR DELETE ON cadastre.defect_type       FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('defect_code');
CREATE TRIGGER measure_type_audit      AFTER INSERT OR UPDATE OR DELETE ON cadastre.measure_type      FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('measure_type_code');
CREATE TRIGGER felling_reason_audit    AFTER INSERT OR UPDATE OR DELETE ON cadastre.felling_reason    FOR EACH ROW EXECUTE FUNCTION cadastre.trg_audit('felling_reason_code');

-- -----------------------------------------------------------------------------
-- 6. Roles and privileges (NOLOGIN group roles; login roles are granted these)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_reader')   THEN CREATE ROLE cadastre_reader   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_editor')   THEN CREATE ROLE cadastre_editor   NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_codelist') THEN CREATE ROLE cadastre_codelist NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cadastre_auditor')  THEN CREATE ROLE cadastre_auditor  NOLOGIN; END IF;
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA cadastre FROM PUBLIC;
GRANT USAGE ON SCHEMA cadastre TO cadastre_reader, cadastre_editor, cadastre_codelist, cadastre_auditor;

-- reader: everything except the audit log
GRANT SELECT ON ALL TABLES IN SCHEMA cadastre TO cadastre_reader;
REVOKE SELECT ON cadastre.audit_log FROM cadastre_reader;

-- editor (app service account): insert/update business data, never DELETE/TRUNCATE
GRANT cadastre_reader TO cadastre_editor;
GRANT INSERT, UPDATE ON cadastre.tree, cadastre.tree_replacement, cadastre.inspection,
                        cadastre.measure, cadastre.contractor, cadastre.staff
      TO cadastre_editor;
GRANT INSERT, UPDATE, DELETE ON cadastre.inspection_defect TO cadastre_editor;   -- defect lines are corrected within an inspection (audited)
GRANT USAGE ON SEQUENCE cadastre.tree_number_seq TO cadastre_editor;

-- code list maintainers (arborist team: species list; department: defect/measure types)
GRANT cadastre_reader TO cadastre_codelist;
GRANT INSERT, UPDATE ON cadastre.species, cadastre.defect_type, cadastre.measure_type,
                        cadastre.felling_reason, cadastre.measure_priority, cadastre.vitality_class,
                        cadastre.park, cadastre.street_segment
      TO cadastre_codelist;

-- auditors: read everything incl. audit log
GRANT cadastre_reader TO cadastre_auditor;
GRANT SELECT ON cadastre.audit_log TO cadastre_auditor;

COMMIT;

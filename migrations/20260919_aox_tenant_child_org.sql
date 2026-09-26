-- RLS/VPD oleada hijas B: UK padre (id, org), org_id NOT NULL en hijas,
-- indices, FK compuesta, drop FK legado USER_INTEGRATION -> APP_USER_LEGACY,
-- indices org faltantes en HAS_ORG. VPD sigue off.
-- Como AOXDEV. Idempotente.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_child_org ===

DECLARE
    v_nulls     NUMBER;
    v_mismatch  NUMBER;
    v_ncols     NUMBER;

    PROCEDURE run_ddl(pi_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_sql;
        DBMS_OUTPUT.PUT_LINE('OK: ' || SUBSTR(pi_sql, 1, 180));
    EXCEPTION
        WHEN OTHERS THEN
            -- -955 name used, -1408 column list indexed, -1430 column exists,
            -- -1442 already NOT NULL, -2260 one PK, -2261 unique exists,
            -- -2264 constraint name used, -2275 FK exists, -2443 drop missing
            IF SQLCODE NOT IN (-955, -1408, -1430, -1442, -2260, -2261, -2264, -2275, -2443) THEN
                DBMS_OUTPUT.PUT_LINE('FAIL: ' || SQLERRM || ' :: ' || SUBSTR(pi_sql, 1, 180));
                RAISE;
            END IF;
            DBMS_OUTPUT.PUT_LINE('SKIP(' || SQLCODE || '): ' || SUBSTR(pi_sql, 1, 160));
    END;

    PROCEDURE drop_constraint(pi_table IN VARCHAR2, pi_name IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || pi_table || ' DROP CONSTRAINT ' || pi_name;
        DBMS_OUTPUT.PUT_LINE('DROP CONSTRAINT ' || pi_name);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-2443, -942) THEN
                RAISE;
            END IF;
            DBMS_OUTPUT.PUT_LINE('SKIP DROP CONSTRAINT ' || pi_name);
    END;

    PROCEDURE add_org_col(pi_table IN VARCHAR2) IS
        v_exists NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_exists
          FROM user_tab_columns
         WHERE table_name = UPPER(pi_table)
           AND column_name = 'ORG_ID_ORGANIZATION';
        IF v_exists = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE ' || pi_table || ' ADD org_id_organization NUMBER';
            DBMS_OUTPUT.PUT_LINE('ADD org_id_organization ' || pi_table);
        ELSE
            DBMS_OUTPUT.PUT_LINE('org_id_organization ya existe en ' || pi_table);
        END IF;
    END;

    PROCEDURE ensure_not_null(pi_table IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE
            'ALTER TABLE ' || pi_table || ' MODIFY org_id_organization NUMBER NOT NULL';
        DBMS_OUTPUT.PUT_LINE('NOT NULL ' || pi_table || '.org_id_organization');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-1442) THEN
                RAISE;
            END IF;
            DBMS_OUTPUT.PUT_LINE('SKIP NOT NULL ' || pi_table);
    END;

    PROCEDURE ensure_index(pi_name IN VARCHAR2, pi_ddl IN VARCHAR2, pi_want_cols IN NUMBER) IS
    BEGIN
        SELECT COUNT(*)
          INTO v_ncols
          FROM user_ind_columns
         WHERE index_name = UPPER(pi_name);
        IF v_ncols = pi_want_cols THEN
            DBMS_OUTPUT.PUT_LINE('INDEX OK ' || pi_name);
            RETURN;
        END IF;
        IF v_ncols > 0 THEN
            BEGIN
                EXECUTE IMMEDIATE 'DROP INDEX ' || pi_name;
                DBMS_OUTPUT.PUT_LINE('DROP INDEX ' || pi_name || ' (ncols=' || v_ncols || ')');
            EXCEPTION
                WHEN OTHERS THEN
                    IF SQLCODE NOT IN (-1418, -2429) THEN
                        RAISE;
                    END IF;
                    DBMS_OUTPUT.PUT_LINE('SKIP DROP INDEX ' || pi_name || ': ' || SQLERRM);
                    run_ddl(pi_ddl);
                    RETURN;
            END;
        END IF;
        run_ddl(pi_ddl);
    END;
BEGIN
    -- 1) UK padre (id, org) para FK compuesta
    run_ddl('ALTER TABLE ai_chat_session ADD CONSTRAINT uq_ai_chat_ses_id_org UNIQUE (id_session, org_id_organization)');
    run_ddl('ALTER TABLE professional ADD CONSTRAINT uq_pro_id_org UNIQUE (id_professional, org_id_organization)');
    run_ddl('ALTER TABLE location ADD CONSTRAINT uq_loc_id_org UNIQUE (id_location, org_id_organization)');
    run_ddl('ALTER TABLE professional_schedule_exception ADD CONSTRAINT uq_sch_exc_id_org UNIQUE (id_schedule_exception, org_id_organization)');
    run_ddl('ALTER TABLE org_refund_dispute ADD CONSTRAINT uq_refund_disp_id_org UNIQUE (id_dispute, org_id_organization)');
    run_ddl('ALTER TABLE org_member ADD CONSTRAINT uq_om_id_org UNIQUE (id_org_member, org_id_organization)');

    -- 2) Columna org en hijas B
    add_org_col('ai_chat_message');
    add_org_col('professional_image');
    add_org_col('professional_schedule_exception_slot');
    add_org_col('org_refund_dispute_evidence');
    add_org_col('user_integration');

    -- 3) Backfill desde el padre
    EXECUTE IMMEDIATE q'[
        UPDATE ai_chat_message m
           SET org_id_organization = (
                 SELECT s.org_id_organization
                   FROM ai_chat_session s
                  WHERE s.id_session = m.ses_id_session
               )
         WHERE m.org_id_organization IS NULL
    ]';
    EXECUTE IMMEDIATE q'[
        UPDATE professional_image i
           SET org_id_organization = (
                 SELECT p.org_id_organization
                   FROM professional p
                  WHERE p.id_professional = i.pro_id_professional
               )
         WHERE i.org_id_organization IS NULL
    ]';
    EXECUTE IMMEDIATE q'[
        UPDATE professional_schedule_exception_slot s
           SET org_id_organization = (
                 SELECT e.org_id_organization
                   FROM professional_schedule_exception e
                  WHERE e.id_schedule_exception = s.exc_id_schedule_exception
               )
         WHERE s.org_id_organization IS NULL
    ]';
    EXECUTE IMMEDIATE q'[
        UPDATE org_refund_dispute_evidence e
           SET org_id_organization = (
                 SELECT d.org_id_organization
                   FROM org_refund_dispute d
                  WHERE d.id_dispute = e.dispute_id
               )
         WHERE e.org_id_organization IS NULL
    ]';
    EXECUTE IMMEDIATE q'[
        UPDATE user_integration ui
           SET org_id_organization = (
                 SELECT m.org_id_organization
                   FROM org_member m
                  WHERE m.id_org_member = ui.usr_id_user
               )
         WHERE ui.org_id_organization IS NULL
    ]';
    COMMIT;

    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ai_chat_message WHERE org_id_organization IS NULL' INTO v_nulls;
    IF v_nulls > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Backfill ai_chat_message dejo ' || v_nulls || ' NULL');
    END IF;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM professional_image WHERE org_id_organization IS NULL' INTO v_nulls;
    IF v_nulls > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Backfill professional_image dejo ' || v_nulls || ' NULL');
    END IF;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM professional_schedule_exception_slot WHERE org_id_organization IS NULL' INTO v_nulls;
    IF v_nulls > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Backfill slot dejo ' || v_nulls || ' NULL');
    END IF;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM org_refund_dispute_evidence WHERE org_id_organization IS NULL' INTO v_nulls;
    IF v_nulls > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Backfill evidence dejo ' || v_nulls || ' NULL');
    END IF;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_integration WHERE org_id_organization IS NULL' INTO v_nulls;
    IF v_nulls > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Backfill user_integration dejo ' || v_nulls || ' NULL');
    END IF;

    EXECUTE IMMEDIATE q'[
        SELECT COUNT(*)
          FROM professional_schedule_exception_slot s
          JOIN professional_schedule_exception e
            ON e.id_schedule_exception = s.exc_id_schedule_exception
          JOIN location l
            ON l.id_location = s.loc_id_location
         WHERE e.org_id_organization <> l.org_id_organization
            OR s.org_id_organization <> e.org_id_organization
            OR s.org_id_organization <> l.org_id_organization
    ]' INTO v_mismatch;
    IF v_mismatch > 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Slots con org distinta entre exception y location: ' || v_mismatch);
    END IF;

    ensure_not_null('ai_chat_message');
    ensure_not_null('professional_image');
    ensure_not_null('professional_schedule_exception_slot');
    ensure_not_null('org_refund_dispute_evidence');
    ensure_not_null('user_integration');

    -- 4) Indices hijas B (VPD org + CASCADE parent_pk)
    run_ddl('CREATE INDEX idx_msg_org ON ai_chat_message (org_id_organization)');
    run_ddl('CREATE INDEX idx_msg_session ON ai_chat_message (ses_id_session, org_id_organization)');
    run_ddl('CREATE INDEX idx_prof_image_org ON professional_image (org_id_organization)');
    run_ddl('CREATE INDEX idx_prof_image_pro ON professional_image (pro_id_professional, org_id_organization)');
    run_ddl('CREATE INDEX idx_sch_exc_slot_org ON professional_schedule_exception_slot (org_id_organization)');
    ensure_index(
        'idx_sch_exc_slot_exc',
        'CREATE INDEX idx_sch_exc_slot_exc ON professional_schedule_exception_slot (exc_id_schedule_exception, org_id_organization)',
        2
    );
    run_ddl('CREATE INDEX idx_sch_exc_slot_loc ON professional_schedule_exception_slot (loc_id_location, org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_evidence_org ON org_refund_dispute_evidence (org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_evidence_disp_org ON org_refund_dispute_evidence (dispute_id, org_id_organization)');
    run_ddl('CREATE INDEX idx_uint_org ON user_integration (org_id_organization)');
    ensure_index(
        'idx_uint_user',
        'CREATE INDEX idx_uint_user ON user_integration (usr_id_user, org_id_organization)',
        2
    );

    -- 5) Indices org faltantes en HAS_ORG (~14)
    run_ddl('CREATE INDEX idx_ai_chat_ses_org ON ai_chat_session (org_id_organization)');
    run_ddl('CREATE INDEX idx_asr_org ON appointment_session_record (org_id_organization)');
    run_ddl('CREATE INDEX idx_customer_phone_audit_org ON customer_phone_audit (org_id_organization, issue_code)');
    run_ddl('CREATE INDEX idx_embedding_outbox_org ON embedding_sync_outbox (org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_comp_org ON org_refund_dispute_compensation (org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_ledger_org ON org_refund_dispute_ledger (org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_notify_org ON org_refund_notify_outbox (org_id_organization)');
    run_ddl('CREATE INDEX idx_refund_strike_org ON org_refund_strike (org_id_organization)');
    run_ddl('CREATE INDEX idx_sch_org ON professional_schedule (org_id_organization)');
    run_ddl('CREATE INDEX idx_sch_exc_org ON professional_schedule_exception (org_id_organization)');
    run_ddl('CREATE INDEX idx_specialty_org ON specialty (org_id_organization)');
    run_ddl('CREATE INDEX idx_sub_cn_org ON subscription_credit_note (org_id_organization)');
    run_ddl('CREATE INDEX idx_sub_einv_outbox_org ON subscription_einvoice_outbox (org_id_organization)');
    run_ddl('CREATE INDEX idx_unotif_org ON user_notification (org_id_organization)');

    -- 6) Drop FK simple / legado, luego FK compuesta
    drop_constraint('ai_chat_message', 'fk_msg_session');
    run_ddl(q'[ALTER TABLE ai_chat_message ADD CONSTRAINT fk_msg_session
        FOREIGN KEY (ses_id_session, org_id_organization)
        REFERENCES ai_chat_session (id_session, org_id_organization) ON DELETE CASCADE]');

    drop_constraint('professional_image', 'fk_prof_image');
    run_ddl(q'[ALTER TABLE professional_image ADD CONSTRAINT fk_prof_image
        FOREIGN KEY (pro_id_professional, org_id_organization)
        REFERENCES professional (id_professional, org_id_organization) ON DELETE CASCADE]');

    drop_constraint('professional_schedule_exception_slot', 'fk_sch_exc_slot_exception');
    drop_constraint('professional_schedule_exception_slot', 'fk_sch_exc_slot_location');
    run_ddl(q'[ALTER TABLE professional_schedule_exception_slot ADD CONSTRAINT fk_sch_exc_slot_exception
        FOREIGN KEY (exc_id_schedule_exception, org_id_organization)
        REFERENCES professional_schedule_exception (id_schedule_exception, org_id_organization) ON DELETE CASCADE]');
    run_ddl(q'[ALTER TABLE professional_schedule_exception_slot ADD CONSTRAINT fk_sch_exc_slot_location
        FOREIGN KEY (loc_id_location, org_id_organization)
        REFERENCES location (id_location, org_id_organization) ON DELETE CASCADE]');

    drop_constraint('org_refund_dispute_evidence', 'fk_refund_evidence_dispute');
    run_ddl(q'[ALTER TABLE org_refund_dispute_evidence ADD CONSTRAINT fk_refund_evidence_dispute
        FOREIGN KEY (dispute_id, org_id_organization)
        REFERENCES org_refund_dispute (id_dispute, org_id_organization) ON DELETE CASCADE]');

    drop_constraint('user_integration', 'fk_uint_user');
    drop_constraint('user_integration', 'fk_user_integration_member');
    run_ddl(q'[ALTER TABLE user_integration ADD CONSTRAINT fk_uint_member
        FOREIGN KEY (usr_id_user, org_id_organization)
        REFERENCES org_member (id_org_member, org_id_organization) ON DELETE CASCADE]');

    run_ddl(q'[COMMENT ON COLUMN ai_chat_message.org_id_organization IS
        'Org denormalizada desde ai_chat_session. FK compuesta (sesion, org) impide desviarla.']');
    run_ddl(q'[COMMENT ON COLUMN professional_image.org_id_organization IS
        'Org denormalizada desde professional. FK compuesta (profesional, org) impide desviarla.']');
    run_ddl(q'[COMMENT ON COLUMN professional_schedule_exception_slot.org_id_organization IS
        'Org denormalizada. Dos FK compuestas (exception y location) fuerzan la misma org.']');
    run_ddl(q'[COMMENT ON COLUMN org_refund_dispute_evidence.org_id_organization IS
        'Org denormalizada desde org_refund_dispute. FK compuesta (dispute, org) impide desviarla.']');
    run_ddl(q'[COMMENT ON COLUMN user_integration.org_id_organization IS
        'Org denormalizada desde org_member. Sin FK legado a APP_USER_LEGACY.']');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DDL hijas B + HAS_ORG OK');
END;
/

@@../triggers/TRG_AOX_CHILD_ORG.sql
@@../packages/PKG_AOX_CHAT_API.pls
@@../packages/PKG_AOX_SCHEDULE_EXCEPTION_API.pls
@@../packages/PKG_AOX_REFUND_DISPUTES_API.pls
@@../packages/PKG_AOX_BUCKET.pls
@@../packages/PKG_AOX_INTEGRATION_API.pls

PROMPT --- Probes hijas B
DECLARE
    v_cnt       NUMBER;
    v_org       NUMBER;
    v_pro       NUMBER;
    v_fk_legacy NUMBER;
    v_fk_cols   NUMBER;
    v_missing   NUMBER;
    v_raised    BOOLEAN := FALSE;
BEGIN
    SELECT COUNT(*)
      INTO v_fk_legacy
      FROM user_constraints
     WHERE constraint_name = 'FK_UINT_USER'
       AND table_name = 'USER_INTEGRATION';
    IF v_fk_legacy <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: FK_UINT_USER legado sigue en USER_INTEGRATION');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe drop FK_UINT_USER OK');

    SELECT COUNT(*)
      INTO v_fk_cols
      FROM user_cons_columns
     WHERE constraint_name = 'FK_UINT_MEMBER';
    IF v_fk_cols <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: FK_UINT_MEMBER deberia tener 2 columnas, tiene ' || v_fk_cols);
    END IF;

    SELECT COUNT(*)
      INTO v_fk_cols
      FROM user_cons_columns
     WHERE constraint_name = 'FK_SCH_EXC_SLOT_EXCEPTION';
    IF v_fk_cols <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: FK_SCH_EXC_SLOT_EXCEPTION no es compuesta');
    END IF;
    SELECT COUNT(*)
      INTO v_fk_cols
      FROM user_cons_columns
     WHERE constraint_name = 'FK_SCH_EXC_SLOT_LOCATION';
    IF v_fk_cols <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: FK_SCH_EXC_SLOT_LOCATION no es compuesta');
    END IF;

    SELECT COUNT(*)
      INTO v_missing
      FROM (
            SELECT 'AI_CHAT_SESSION' t FROM dual UNION ALL
            SELECT 'APPOINTMENT_SESSION_RECORD' FROM dual UNION ALL
            SELECT 'CUSTOMER_PHONE_AUDIT' FROM dual UNION ALL
            SELECT 'EMBEDDING_SYNC_OUTBOX' FROM dual UNION ALL
            SELECT 'ORG_REFUND_DISPUTE_COMPENSATION' FROM dual UNION ALL
            SELECT 'ORG_REFUND_DISPUTE_LEDGER' FROM dual UNION ALL
            SELECT 'ORG_REFUND_NOTIFY_OUTBOX' FROM dual UNION ALL
            SELECT 'ORG_REFUND_STRIKE' FROM dual UNION ALL
            SELECT 'PROFESSIONAL_SCHEDULE' FROM dual UNION ALL
            SELECT 'PROFESSIONAL_SCHEDULE_EXCEPTION' FROM dual UNION ALL
            SELECT 'SPECIALTY' FROM dual UNION ALL
            SELECT 'SUBSCRIPTION_CREDIT_NOTE' FROM dual UNION ALL
            SELECT 'SUBSCRIPTION_EINVOICE_OUTBOX' FROM dual UNION ALL
            SELECT 'USER_NOTIFICATION' FROM dual
           ) want
     WHERE NOT EXISTS (
            SELECT 1
              FROM user_ind_columns ic
             WHERE ic.table_name = want.t
               AND ic.column_name = 'ORG_ID_ORGANIZATION'
               AND ic.column_position = 1
           );
    IF v_missing <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: ' || v_missing || ' HAS_ORG sin indice org');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe indices HAS_ORG OK');

    SELECT COUNT(*)
      INTO v_cnt
      FROM user_tab_columns
     WHERE table_name IN (
             'AI_CHAT_MESSAGE',
             'PROFESSIONAL_IMAGE',
             'PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT',
             'ORG_REFUND_DISPUTE_EVIDENCE',
             'USER_INTEGRATION'
           )
       AND column_name = 'ORG_ID_ORGANIZATION'
       AND nullable = 'N';
    IF v_cnt <> 5 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: hijas B org NOT NULL esperadas 5, hay ' || v_cnt);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe hijas org NOT NULL OK');

    SELECT p.org_id_organization, p.id_professional
      INTO v_org, v_pro
      FROM professional p
     WHERE ROWNUM = 1;

    BEGIN
        INSERT INTO professional_image (
            pro_id_professional, org_id_organization, file_name, mime_type
        ) VALUES (
            v_pro, v_org + 999999, 'probe-mismatch.jpg', 'image/jpeg'
        );
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20000, 'Probe: INSERT org mismatch debio fallar');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20000 THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            ROLLBACK;
            DBMS_OUTPUT.PUT_LINE('Probe INSERT mismatch rechazado: ' || SQLCODE);
    END;

    IF NOT v_raised THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: no se rechazo el INSERT cruzado');
    END IF;

    DBMS_OUTPUT.PUT_LINE('Probes hijas B OK');
END;
/

-- RLS/VPD oleada 2 (publico): ORG_PUBLIC_DIRECTORY + ORG_PUBLIC_TOKEN.
-- Lookup slug/token sin leer tablas tenant. Nunca set_org desde org_id JSON.
-- Como AOXDEV. Idempotente.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_public_directory ===

DECLARE
    v_exists NUMBER;
    PROCEDURE run_ddl(pi_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_sql;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE NOT IN (-955, -2260, -2261, -2275, -1408, -1442) THEN
                RAISE;
            END IF;
    END;
BEGIN
    SELECT COUNT(*) INTO v_exists FROM user_tables WHERE table_name = 'ORG_PUBLIC_DIRECTORY';
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE org_public_directory (
              org_id_organization    NUMBER         NOT NULL,
              profile_slug           VARCHAR2(100)  NOT NULL,
              is_listed              NUMBER(1)      DEFAULT 1 NOT NULL,
              is_unpublished         NUMBER(1)      DEFAULT 0 NOT NULL,
              blocks_public_booking  NUMBER(1)      DEFAULT 0 NOT NULL,
              updated_at             TIMESTAMP(6)   DEFAULT CURRENT_TIMESTAMP NOT NULL
            ) INITRANS 10
        ]';
        DBMS_OUTPUT.PUT_LINE('CREATED org_public_directory');
    ELSE
        DBMS_OUTPUT.PUT_LINE('org_public_directory ya existe');
    END IF;

    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT pk_org_public_directory PRIMARY KEY (org_id_organization)');
    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT uq_org_public_dir_slug UNIQUE (profile_slug)');
    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT fk_org_public_dir_org FOREIGN KEY (org_id_organization) REFERENCES organization (id_organization) ON DELETE CASCADE');
    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_listed CHECK (is_listed IN (0, 1))');
    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_unpub CHECK (is_unpublished IN (0, 1))');
    run_ddl('ALTER TABLE org_public_directory ADD CONSTRAINT chk_org_public_dir_blocks CHECK (blocks_public_booking IN (0, 1))');

    SELECT COUNT(*) INTO v_exists FROM user_tables WHERE table_name = 'ORG_PUBLIC_TOKEN';
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE org_public_token (
              token_hash          RAW(32)       NOT NULL,
              org_id_organization NUMBER        NOT NULL,
              app_id_appointment  NUMBER        NULL,
              token_kind          VARCHAR2(30)  DEFAULT 'APPOINTMENT_MANAGE' NOT NULL,
              created_at          TIMESTAMP(6)  DEFAULT CURRENT_TIMESTAMP NOT NULL,
              updated_at          TIMESTAMP(6)  DEFAULT CURRENT_TIMESTAMP NOT NULL
            ) INITRANS 10
        ]';
        DBMS_OUTPUT.PUT_LINE('CREATED org_public_token');
    ELSE
        DBMS_OUTPUT.PUT_LINE('org_public_token ya existe');
    END IF;

    run_ddl('ALTER TABLE org_public_token ADD CONSTRAINT pk_org_public_token PRIMARY KEY (token_hash)');
    run_ddl('CREATE INDEX idx_org_pub_tok_org ON org_public_token (org_id_organization)');
    run_ddl('CREATE UNIQUE INDEX uq_org_pub_tok_app_kind ON org_public_token (app_id_appointment, token_kind)');
    run_ddl('ALTER TABLE org_public_token ADD CONSTRAINT fk_org_pub_tok_org FOREIGN KEY (org_id_organization) REFERENCES organization (id_organization) ON DELETE CASCADE');
    run_ddl('ALTER TABLE org_public_token ADD CONSTRAINT fk_org_pub_tok_app FOREIGN KEY (app_id_appointment) REFERENCES appointment (id_appointment) ON DELETE CASCADE');
    run_ddl('ALTER TABLE org_public_token ADD CONSTRAINT chk_org_pub_tok_kind CHECK (token_kind IN (''APPOINTMENT_MANAGE''))');
END;
/

@@../packages/PKG_AOX_PUBLIC_DIRECTORY.pls
@@../packages/PKG_AOX_SESSION.pls
@@../packages/PKG_AOX_UTIL.pls
@@../packages/PKG_AOX_WORKSPACE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls
@@../packages/PKG_AOX_REFUND_DISPUTES_API.pls
@@../triggers/TRG_ORG_PUBLIC_DIRECTORY.sql

PROMPT --- Backfill directory + tokens
BEGIN
    pkg_aox_public_directory.pr_refresh_all;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('pr_refresh_all OK');
END;
/

PROMPT --- Probes public directory
DECLARE
    v_dir_cnt   NUMBER;
    v_ws_cnt    NUMBER;
    v_tok_cnt   NUMBER;
    v_app_cnt   NUMBER;
    v_slug      workspace_setting.profile_slug%TYPE;
    v_org_a     NUMBER;
    v_org_b     NUMBER;
    v_token     appointment.public_manage_token%TYPE;
    v_bind_org  NUMBER;
    v_bind_app  NUMBER;
    v_ctx_org   NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_dir_cnt FROM org_public_directory WHERE is_listed = 1;
    SELECT COUNT(*)
      INTO v_ws_cnt
      FROM workspace_setting ws
     WHERE ws.profile_slug IS NOT NULL
       AND TRIM(ws.profile_slug) IS NOT NULL
       AND pkg_aox_util.fn_is_reserved_org_slug(ws.profile_slug) = 0;

    IF v_dir_cnt <> v_ws_cnt THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe directory: listed=' || v_dir_cnt || ' workspace_slugs=' || v_ws_cnt
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe directory filas=' || v_dir_cnt || ' OK');

    SELECT COUNT(*) INTO v_tok_cnt FROM org_public_token;
    SELECT COUNT(*)
      INTO v_app_cnt
      FROM appointment
     WHERE public_manage_token IS NOT NULL
       AND TRIM(public_manage_token) IS NOT NULL;
    IF v_tok_cnt <> v_app_cnt THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe tokens: token_rows=' || v_tok_cnt || ' appointments=' || v_app_cnt
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe tokens filas=' || v_tok_cnt || ' OK');

    IF v_dir_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Probe bind slug omitido (directorio vacio)');
        pkg_aox_session.clear;
        DBMS_OUTPUT.PUT_LINE('=== 20260919_aox_public_directory probes OK ===');
        RETURN;
    END IF;

    SELECT profile_slug, org_id_organization
      INTO v_slug, v_org_a
      FROM org_public_directory
     WHERE is_listed = 1
       AND ROWNUM = 1;

    pkg_aox_session.pr_bind_tenant_from_public_slug(v_slug, v_bind_org);
    v_ctx_org := pkg_aox_session.fn_current_org_id;
    IF v_bind_org <> v_org_a OR v_ctx_org <> v_org_a THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe bind slug contexto inesperado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe bind slug org=' || v_org_a || ' OK');

    BEGIN
        pkg_aox_session.pr_bind_tenant_from_public_slug('slug-inexistente-vpd-' || TO_CHAR(SYSDATE, 'HH24MISS'));
        RAISE_APPLICATION_ERROR(-20000, 'Probe bind slug inexistente debio fallar');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20025 THEN
                RAISE;
            END IF;
            IF pkg_aox_session.fn_current_org_id IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe leftover tras slug inexistente');
            END IF;
            DBMS_OUTPUT.PUT_LINE('Probe bind slug inexistente rechazado y clear OK');
    END;

    -- JSON org_id de otra org no debe ganar: el choke solo acepta slug.
    SELECT MIN(org_id_organization), MAX(org_id_organization)
      INTO v_org_a, v_org_b
      FROM org_public_directory
     WHERE is_listed = 1;

    IF v_org_a IS NOT NULL AND v_org_b IS NOT NULL AND v_org_a <> v_org_b THEN
        SELECT profile_slug INTO v_slug
          FROM org_public_directory
         WHERE org_id_organization = v_org_a;

        pkg_aox_session.pr_bind_tenant_from_public_slug(v_slug, v_bind_org);
        IF v_bind_org = v_org_b THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe: slug A no debe resolver org B');
        END IF;
        IF pkg_aox_session.fn_current_org_id <> v_org_a THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe: contexto no es org del slug');
        END IF;
        DBMS_OUTPUT.PUT_LINE('Probe slug A ignora org_id B OK');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Probe slug cruzado omitido (una sola org listada)');
    END IF;

    IF v_app_cnt = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Probe bind token omitido (sin citas)');
        pkg_aox_session.clear;
        DBMS_OUTPUT.PUT_LINE('=== 20260919_aox_public_directory probes OK ===');
        RETURN;
    END IF;

    SELECT public_manage_token
      INTO v_token
      FROM appointment
     WHERE public_manage_token IS NOT NULL
       AND ROWNUM = 1;

    pkg_aox_session.pr_bind_tenant_from_public_token(v_token, v_bind_org, v_bind_app);
    IF v_bind_org IS NULL OR v_bind_app IS NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe bind token no resolvio org/cita');
    END IF;
    IF pkg_aox_session.fn_current_org_id <> v_bind_org THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe bind token contexto inesperado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe bind token app=' || v_bind_app || ' org=' || v_bind_org || ' OK');

    BEGIN
        pkg_aox_session.pr_bind_tenant_from_public_token('deadbeefdeadbeefdeadbeefdeadbeef');
        RAISE_APPLICATION_ERROR(-20000, 'Probe bind token inexistente debio fallar');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -20025 THEN
                RAISE;
            END IF;
            IF pkg_aox_session.fn_current_org_id IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe leftover tras token inexistente');
            END IF;
            DBMS_OUTPUT.PUT_LINE('Probe bind token inexistente rechazado y clear OK');
    END;

    pkg_aox_session.clear;
    DBMS_OUTPUT.PUT_LINE('=== 20260919_aox_public_directory probes OK ===');
END;
/

-- RLS/VPD oleada 1: PKG_AOX_SESSION + AOX_TENANT_CTX + probe DBMS_RLS.
-- Como AOXDEV (PDB_DBA). Si CREATE CONTEXT o DBMS_RLS da ORA-01031,
-- repetir esos dos pasos como usuario ADMIN de la ADB (no HASEL_ADMIN).
-- No activa politicas en tablas de negocio.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_session ===

@@../packages/PKG_AOX_SESSION.pls
@@../functions/FN_AOX_TENANT_VPD_PREDICATE.pls

PROMPT --- CREATE CONTEXT aox_tenant_ctx
BEGIN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE CONTEXT aox_tenant_ctx USING pkg_aox_session';
    DBMS_OUTPUT.PUT_LINE('CONTEXT aox_tenant_ctx OK (AOXDEV)');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('CONTEXT FAILED as AOXDEV: ' || SQLERRM);
        RAISE;
END;
/

PROMPT --- Probes contexto + DBMS_RLS (tabla scratch, se elimina)
DECLARE
    v_cnt        NUMBER;
    v_mode       VARCHAR2(30);
    v_org        NUMBER;
    v_job_ok     BOOLEAN := FALSE;
    v_ins_ok     BOOLEAN := FALSE;
    c_probe_tab  CONSTANT VARCHAR2(30) := 'AOX_VPD_PRIV_PROBE';
    c_probe_pol  CONSTANT VARCHAR2(30) := 'AOX_TENANT_VPD_PROBE';
BEGIN
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE ' || c_probe_tab || ' PURGE';
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    EXECUTE IMMEDIATE '
        CREATE TABLE ' || c_probe_tab || ' (
            id                   NUMBER PRIMARY KEY,
            org_id_organization  NUMBER NOT NULL
        )';

    DBMS_RLS.ADD_POLICY(
        object_schema   => USER,
        object_name     => c_probe_tab,
        policy_name     => c_probe_pol,
        function_schema => USER,
        policy_function => 'FN_AOX_TENANT_VPD_PREDICATE',
        statement_types => 'SELECT,INSERT,UPDATE,DELETE',
        update_check    => TRUE,
        enable          => FALSE,
        policy_type     => DBMS_RLS.DYNAMIC
    );
    DBMS_OUTPUT.PUT_LINE('DBMS_RLS.ADD_POLICY enable=FALSE OK');

    EXECUTE IMMEDIATE 'INSERT INTO ' || c_probe_tab || ' (id, org_id_organization) VALUES (1, 10)';
    EXECUTE IMMEDIATE 'INSERT INTO ' || c_probe_tab || ' (id, org_id_organization) VALUES (2, 20)';
    COMMIT;

    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: con policy disabled se esperaban 2 filas, hay ' || v_cnt);
    END IF;

    DBMS_RLS.ENABLE_POLICY(
        object_schema => USER,
        object_name   => c_probe_tab,
        policy_name   => c_probe_pol,
        enable        => TRUE
    );
    DBMS_OUTPUT.PUT_LINE('DBMS_RLS.ENABLE_POLICY OK');

    pkg_aox_session.clear;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: sin contexto se esperaban 0 filas, hay ' || v_cnt);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe sin contexto -> 0 filas OK');

    pkg_aox_session.set_org(10);
    v_org  := pkg_aox_session.fn_current_org_id;
    v_mode := pkg_aox_session.fn_access_mode;
    IF v_org <> 10 OR v_mode <> 'TENANT' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe set_org(10) contexto inesperado');
    END IF;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 1 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe org 10: se esperaba 1 fila, hay ' || v_cnt);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe set_org(10) -> 1 fila OK');

    -- Pool A luego B: no debe quedar bleed de org 10.
    pkg_aox_session.set_org(20);
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 1 OR pkg_aox_session.fn_current_org_id <> 20 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe pool A->B: bleed o count=' || v_cnt);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe pool 10 luego 20 -> 1 fila org 20 OK');

    pkg_aox_session.clear;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe clear: se esperaban 0 filas, hay ' || v_cnt);
    END IF;

    BEGIN
        EXECUTE IMMEDIATE 'INSERT INTO ' || c_probe_tab || ' (id, org_id_organization) VALUES (3, 10)';
        v_ins_ok := TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            v_ins_ok := FALSE;
    END;
    IF v_ins_ok THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: INSERT sin contexto debio rechazarse');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe INSERT sin contexto rechazado OK');

    BEGIN
        pkg_aox_session.begin_job;
        v_job_ok := TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            v_job_ok := FALSE;
    END;
    IF v_job_ok THEN
        pkg_aox_session.end_job;
        RAISE_APPLICATION_ERROR(-20000, 'Probe: begin_job fuera de scheduler debio fallar');
    END IF;
    IF pkg_aox_session.fn_access_mode IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: leftover ACCESS_MODE tras begin_job rechazado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe begin_job fuera de job rechazado y sin leftover OK');

    -- Membresia: user de org B no puede set_org(org A).
    DECLARE
        v_org_a    NUMBER;
        v_user_a   NUMBER;
        v_user_b   NUMBER;
        v_mem_ok   BOOLEAN := FALSE;
    BEGIN
        SELECT m.org_id_organization, m.id_org_member
          INTO v_org_a, v_user_a
          FROM org_member m
          JOIN platform_user pu
            ON pu.id_platform_user = m.platform_user_id
         WHERE m.is_active = 1
           AND pu.is_active = 1
         FETCH FIRST 1 ROW ONLY;

        BEGIN
            SELECT m.id_org_member
              INTO v_user_b
              FROM org_member m
             WHERE m.org_id_organization <> v_org_a
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_user_b := NULL;
        END;

        pkg_aox_session.set_org(v_org_a, v_user_a);
        IF pkg_aox_session.fn_current_org_id <> v_org_a
           OR pkg_aox_session.fn_current_user_id <> v_user_a THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe membresia valida: contexto inesperado');
        END IF;
        DBMS_OUTPUT.PUT_LINE('Probe set_org con membresia activa OK');

        IF v_user_b IS NOT NULL THEN
            BEGIN
                pkg_aox_session.set_org(v_org_a, v_user_b);
                v_mem_ok := TRUE;
            EXCEPTION
                WHEN OTHERS THEN
                    v_mem_ok := FALSE;
            END;
            IF v_mem_ok THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe: set_org cross-org debio fallar');
            END IF;
            IF pkg_aox_session.fn_current_org_id IS NOT NULL
               OR pkg_aox_session.fn_access_mode IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe: leftover tras set_org cross-org');
            END IF;
            DBMS_OUTPUT.PUT_LINE('Probe set_org cross-org rechazado y clear OK');
        END IF;
    END;

    -- pr_bind_tenant_from_jwt + clear en EXCEPTION (token invalido y JWT cross-org).
    DECLARE
        v_org_a     NUMBER;
        v_user_a    NUMBER;
        v_role_a    NUMBER;
        v_org_b     NUMBER;
        v_token     VARCHAR2(4000);
        v_secret    RAW(256);
        v_bind_org  NUMBER;
        v_bind_user NUMBER;
        v_bind_role NUMBER;
        v_bind_ok   BOOLEAN := FALSE;
        v_sc        NUMBER;
        v_body      CLOB;
    BEGIN
        SELECT m.org_id_organization, m.id_org_member, m.rol_id_role
          INTO v_org_a, v_user_a, v_role_a
          FROM org_member m
          JOIN platform_user pu
            ON pu.id_platform_user = m.platform_user_id
         WHERE m.is_active = 1
           AND pu.is_active = 1
         FETCH FIRST 1 ROW ONLY;

        BEGIN
            SELECT m.org_id_organization
              INTO v_org_b
              FROM org_member m
             WHERE m.org_id_organization <> v_org_a
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_org_b := v_org_a + 9999;
        END;

        pkg_aox_session.set_org(v_org_a, v_user_a);
        BEGIN
            pkg_aox_session.pr_bind_tenant_from_jwt('Bearer token-invalido');
            v_bind_ok := TRUE;
        EXCEPTION
            WHEN OTHERS THEN
                v_bind_ok := FALSE;
        END;
        IF v_bind_ok THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe: bind JWT invalido debio fallar');
        END IF;
        IF pkg_aox_session.fn_current_org_id IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe: leftover tras bind JWT invalido');
        END IF;
        DBMS_OUTPUT.PUT_LINE('Probe pr_bind JWT invalido + clear en EXCEPTION OK');

        pkg_aox_session.set_org(v_org_a);
        pkg_aox_util.pr_handle_api_exception(v_sc, v_body, -20001, 'Token invalido o expirado.');
        IF pkg_aox_session.fn_current_org_id IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20000, 'Probe: pr_handle_api_exception no limpio el contexto');
        END IF;
        DBMS_OUTPUT.PUT_LINE('Probe pr_handle_api_exception clear OK');

        IF fn_get_parameter('JWT_TOKEN') IS NOT NULL THEN
            v_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));
            v_token := apex_jwt.encode(
                p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
                p_sub           => 'aox-tenant-probe',
                p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
                p_exp_sec       => 120,
                p_other_claims  => '"user_id": ' || v_user_a
                                   || ', "role_id": ' || v_role_a
                                   || ', "organization_id": ' || v_org_a,
                p_signature_key => v_secret
            );
            pkg_aox_session.pr_bind_tenant_from_jwt(
                pi_auth_header => 'Bearer ' || v_token,
                po_org_id      => v_bind_org,
                po_user_id     => v_bind_user,
                po_role_id     => v_bind_role
            );
            IF v_bind_org <> v_org_a OR v_bind_user <> v_user_a
               OR pkg_aox_session.fn_current_org_id <> v_org_a THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe: bind JWT valido no seteo el tenant');
            END IF;
            DBMS_OUTPUT.PUT_LINE('Probe pr_bind JWT valido OK');

            v_token := apex_jwt.encode(
                p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
                p_sub           => 'aox-tenant-probe-xorg',
                p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
                p_exp_sec       => 120,
                p_other_claims  => '"user_id": ' || v_user_a
                                   || ', "role_id": ' || v_role_a
                                   || ', "organization_id": ' || v_org_b,
                p_signature_key => v_secret
            );
            v_bind_ok := FALSE;
            BEGIN
                pkg_aox_session.pr_bind_tenant_from_jwt('Bearer ' || v_token);
                v_bind_ok := TRUE;
            EXCEPTION
                WHEN OTHERS THEN
                    v_bind_ok := FALSE;
            END;
            IF v_bind_ok THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe: bind JWT cross-org debio fallar');
            END IF;
            IF pkg_aox_session.fn_current_org_id IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20000, 'Probe: leftover tras bind JWT cross-org');
            END IF;
            DBMS_OUTPUT.PUT_LINE('Probe pr_bind JWT cross-org rechazado y clear OK');
        ELSE
            DBMS_OUTPUT.PUT_LINE('Probe JWT encode omitido (JWT_TOKEN ausente)');
        END IF;
    END;

    -- Kill switch: DISABLE_POLICY (no DROP) restaura visibilidad en la scratch.
    DBMS_RLS.ENABLE_POLICY(
        object_schema => USER,
        object_name   => c_probe_tab,
        policy_name   => c_probe_pol,
        enable        => FALSE
    );
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || c_probe_tab INTO v_cnt;
    IF v_cnt <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe DISABLE_POLICY: se esperaban 2 filas, hay ' || v_cnt);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe DISABLE_POLICY kill switch OK');

    DBMS_RLS.DROP_POLICY(
        object_schema => USER,
        object_name   => c_probe_tab,
        policy_name   => c_probe_pol
    );
    EXECUTE IMMEDIATE 'DROP TABLE ' || c_probe_tab || ' PURGE';
    pkg_aox_session.clear;
    DBMS_OUTPUT.PUT_LINE('Probe scratch eliminada. Politicas de negocio: ninguna.');
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            DBMS_RLS.DROP_POLICY(
                object_schema => USER,
                object_name   => 'AOX_VPD_PRIV_PROBE',
                policy_name   => 'AOX_TENANT_VPD_PROBE'
            );
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE AOX_VPD_PRIV_PROBE PURGE';
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        BEGIN
            pkg_aox_session.clear;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
        RAISE;
END;
/

PROMPT === 20260919_aox_tenant_session listo ===

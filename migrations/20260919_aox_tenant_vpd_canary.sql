-- Canario VPD: ENABLE_POLICY solo CUSTOMER y APPOINTMENT.
-- Probes: sin contexto, pool org A luego B, cross-org INSERT/UPDATE, JWT.
-- Si sangra: pr_disable_canary (DISABLE, no DROP) y falla la migracion.
-- Como AOXDEV. El resto A/B sigue enable=FALSE.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_vpd_canary ===

@@../packages/PKG_AOX_TENANT_VPD.pls
@@../policies/04_aox_tenant_vpd_canary.sql

PROMPT --- Probes canario CUSTOMER / APPOINTMENT
DECLARE
    c_org_a      CONSTANT NUMBER := 1;
    c_org_b      CONSTANT NUMBER := 5;
    v_cust_a     NUMBER;
    v_app_a      NUMBER;
    v_n          NUMBER;
    v_enabled    NUMBER;
    v_other_en   NUMBER;
    v_ok         BOOLEAN;
    v_id         NUMBER;
    v_secret     RAW(2000);
    v_token      VARCHAR2(4000);
    v_user_a     NUMBER;
    v_role_a     NUMBER;
    v_bind_org   NUMBER;
    v_bind_user  NUMBER;
    v_bind_role  NUMBER;
    v_bind_ok    BOOLEAN;
    v_prof       NUMBER;

    PROCEDURE pr_kill_and_raise(pi_msg IN VARCHAR2) IS
    BEGIN
        pkg_aox_tenant_vpd.pr_disable_canary;
        pkg_aox_session.clear;
        RAISE_APPLICATION_ERROR(-20000, 'KILL SWITCH canario: ' || pi_msg);
    END;
BEGIN
    SELECT COUNT(*)
      INTO v_enabled
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND object_name IN ('CUSTOMER', 'APPOINTMENT')
       AND enable = 'YES';
    IF v_enabled <> 2 THEN
        pr_kill_and_raise('canario ENABLE esperado 2, hay ' || v_enabled);
    END IF;

    SELECT COUNT(*)
      INTO v_other_en
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND object_name NOT IN ('CUSTOMER', 'APPOINTMENT')
       AND enable = 'YES';
    IF v_other_en <> 0 THEN
        pr_kill_and_raise('se habilitaron tablas fuera del canario: ' || v_other_en);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe ENABLE solo CUSTOMER+APPOINTMENT OK');

    pkg_aox_session.set_org(c_org_a);
    SELECT COUNT(*) INTO v_cust_a FROM customer;
    SELECT COUNT(*) INTO v_app_a FROM appointment;
    IF v_cust_a = 0 OR v_app_a = 0 THEN
        pr_kill_and_raise('org A sin filas canario (cust=' || v_cust_a || ' app=' || v_app_a || ')');
    END IF;

    pkg_aox_session.clear;
    SELECT COUNT(*) INTO v_n FROM customer;
    IF v_n <> 0 THEN
        pr_kill_and_raise('CUSTOMER sin contexto vio ' || v_n || ' filas');
    END IF;
    SELECT COUNT(*) INTO v_n FROM appointment;
    IF v_n <> 0 THEN
        pr_kill_and_raise('APPOINTMENT sin contexto vio ' || v_n || ' filas');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe sin contexto -> 0 filas OK');

    SELECT COUNT(*) INTO v_prof FROM professional;
    IF v_prof = 0 THEN
        pr_kill_and_raise('PROFESSIONAL (policy off) no deberia quedar vacia');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe PROFESSIONAL sigue visible (no canario) OK');

    pkg_aox_session.set_org(c_org_a);
    SELECT COUNT(*) INTO v_n FROM customer;
    IF v_n <> v_cust_a THEN
        pr_kill_and_raise('set_org(A) CUSTOMER=' || v_n || ' esperado ' || v_cust_a);
    END IF;

    pkg_aox_session.set_org(c_org_b);
    SELECT COUNT(*) INTO v_n FROM customer;
    IF v_n <> 0 THEN
        pr_kill_and_raise('pool A->B CUSTOMER sangra ' || v_n || ' filas');
    END IF;
    SELECT COUNT(*) INTO v_n FROM appointment;
    IF v_n <> 0 THEN
        pr_kill_and_raise('pool A->B APPOINTMENT sangra ' || v_n || ' filas');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe pool org 1 luego 5 -> 0 filas OK');

    pkg_aox_session.clear;
    v_ok := FALSE;
    BEGIN
        INSERT INTO customer (org_id_organization, full_name, is_active)
        VALUES (c_org_a, 'vpd-canary-nocontext', 1);
        v_ok := TRUE;
        ROLLBACK;
    EXCEPTION
        WHEN OTHERS THEN
            v_ok := FALSE;
            ROLLBACK;
    END;
    IF v_ok THEN
        pr_kill_and_raise('INSERT CUSTOMER sin contexto no fue rechazado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe INSERT sin contexto rechazado OK');

    pkg_aox_session.set_org(c_org_a);
    v_ok := FALSE;
    BEGIN
        INSERT INTO customer (org_id_organization, full_name, is_active)
        VALUES (c_org_b, 'vpd-canary-xorg', 1);
        v_ok := TRUE;
        ROLLBACK;
    EXCEPTION
        WHEN OTHERS THEN
            v_ok := FALSE;
            ROLLBACK;
    END;
    IF v_ok THEN
        pr_kill_and_raise('INSERT CUSTOMER org B con contexto A no fue rechazado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe INSERT cross-org update_check OK');

    pkg_aox_session.set_org(c_org_a);
    SELECT MIN(id_appointment) INTO v_id FROM appointment;
    v_ok := FALSE;
    BEGIN
        UPDATE appointment
           SET org_id_organization = c_org_b
         WHERE id_appointment = v_id;
        v_ok := TRUE;
        ROLLBACK;
    EXCEPTION
        WHEN OTHERS THEN
            v_ok := FALSE;
            ROLLBACK;
    END;
    IF v_ok THEN
        pr_kill_and_raise('UPDATE APPOINTMENT a org B con contexto A no fue rechazado');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe UPDATE cross-org update_check OK');

    SELECT m.id_org_member, m.rol_id_role
      INTO v_user_a, v_role_a
      FROM org_member m
     WHERE m.org_id_organization = c_org_a
       AND m.is_active = 1
     FETCH FIRST 1 ROW ONLY;

    IF fn_get_parameter('JWT_TOKEN') IS NOT NULL THEN
        v_secret := utl_raw.cast_to_raw(fn_get_parameter('JWT_TOKEN'));
        v_token := apex_jwt.encode(
            p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
            p_sub           => 'aox-vpd-canary',
            p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
            p_exp_sec       => 120,
            p_other_claims  => '"user_id": ' || v_user_a
                               || ', "role_id": ' || v_role_a
                               || ', "organization_id": ' || c_org_a,
            p_signature_key => v_secret
        );
        pkg_aox_session.pr_bind_tenant_from_jwt(
            pi_auth_header => 'Bearer ' || v_token,
            po_org_id      => v_bind_org,
            po_user_id     => v_bind_user,
            po_role_id     => v_bind_role
        );
        SELECT COUNT(*) INTO v_n FROM customer;
        IF v_n <> v_cust_a THEN
            pr_kill_and_raise('JWT org A CUSTOMER=' || v_n || ' esperado ' || v_cust_a);
        END IF;

        v_token := apex_jwt.encode(
            p_iss           => NVL(fn_get_parameter('JWT_ISSUER'), 'hasel-api'),
            p_sub           => 'aox-vpd-canary-xorg',
            p_aud           => NVL(fn_get_parameter('JWT_AUDIENCE'), 'hasel-app'),
            p_exp_sec       => 120,
            p_other_claims  => '"user_id": ' || v_user_a
                               || ', "role_id": ' || v_role_a
                               || ', "organization_id": ' || c_org_b,
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
            pr_kill_and_raise('JWT cruzado user A + org B debio fallar');
        END IF;
        SELECT COUNT(*) INTO v_n FROM customer;
        IF v_n <> 0 THEN
            pr_kill_and_raise('tras JWT cruzado CUSTOMER visible=' || v_n);
        END IF;
        DBMS_OUTPUT.PUT_LINE('Probe JWT org A OK y cruzado fail-closed OK');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Probe JWT omitido (JWT_TOKEN ausente)');
    END IF;

    pkg_aox_session.clear;
    DBMS_OUTPUT.PUT_LINE('Probes canario OK. Kill switch no disparado.');
EXCEPTION
    WHEN OTHERS THEN
        BEGIN
            pkg_aox_tenant_vpd.pr_disable_canary;
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

PROMPT === 20260919_aox_tenant_vpd_canary listo ===

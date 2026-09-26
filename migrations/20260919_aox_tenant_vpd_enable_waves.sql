-- Enable VPD resto A en oleadas 3-5 + hijas B. Probe SELECT por oleada.
-- Si sangra: DISABLE solo esa oleada y RAISE. Kill switch total: policies/03.
-- No habilitar las ~47 juntas. Como AOXDEV. Idempotente (ENABLE_POLICY).

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_vpd_enable_waves ===

@@../packages/PKG_AOX_TENANT_VPD.pls

DECLARE
    c_org_a NUMBER;
    c_org_b NUMBER;

    TYPE t_snap IS TABLE OF NUMBER INDEX BY VARCHAR2(80);
    v_snap_a    t_snap;
    v_snap_b    t_snap;
    v_snap_all  t_snap;
    v_already   t_snap;

    PROCEDURE pr_kill_wave(pi_tabs IN SYS.ODCIVARCHAR2LIST, pi_msg IN VARCHAR2) IS
    BEGIN
        pkg_aox_tenant_vpd.pr_disable_tables(pi_tabs);
        pkg_aox_session.clear;
        RAISE_APPLICATION_ERROR(-20000, 'KILL SWITCH oleada: ' || pi_msg);
    END;

    FUNCTION fn_cnt(pi_table IN VARCHAR2, pi_where IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
        v_n   NUMBER;
        v_sql VARCHAR2(4000);
    BEGIN
        v_sql := 'SELECT COUNT(*) FROM ' || DBMS_ASSERT.SIMPLE_SQL_NAME(pi_table);
        IF pi_where IS NOT NULL THEN
            v_sql := v_sql || ' WHERE ' || pi_where;
        END IF;
        EXECUTE IMMEDIATE v_sql INTO v_n;
        RETURN v_n;
    END;

    PROCEDURE pr_snapshot(pi_tabs IN SYS.ODCIVARCHAR2LIST) IS
        v_en NUMBER;
    BEGIN
        pkg_aox_session.clear;
        FOR i IN 1 .. pi_tabs.COUNT LOOP
            SELECT COUNT(*)
              INTO v_en
              FROM user_policies
             WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
               AND object_name = pi_tabs(i)
               AND enable = 'YES';
            v_already(pi_tabs(i)) := v_en;
            v_snap_all(pi_tabs(i)) := fn_cnt(pi_tabs(i));
            v_snap_a(pi_tabs(i)) := fn_cnt(pi_tabs(i), 'org_id_organization = ' || c_org_a);
            v_snap_b(pi_tabs(i)) := fn_cnt(pi_tabs(i), 'org_id_organization = ' || c_org_b);
        END LOOP;
    END;

    PROCEDURE pr_probe(pi_name IN VARCHAR2, pi_tabs IN SYS.ODCIVARCHAR2LIST) IS
        v_en    NUMBER;
        v_n     NUMBER;
        v_other NUMBER;
    BEGIN
        FOR i IN 1 .. pi_tabs.COUNT LOOP
            SELECT COUNT(*)
              INTO v_en
              FROM user_policies
             WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
               AND object_name = pi_tabs(i)
               AND enable = 'YES';
            IF v_en <> 1 THEN
                pr_kill_wave(pi_tabs, pi_name || ' ' || pi_tabs(i) || ' ENABLE=NO');
            END IF;

            pkg_aox_session.clear;
            v_n := fn_cnt(pi_tabs(i));
            IF v_n <> 0 THEN
                pr_kill_wave(pi_tabs, pi_name || ' ' || pi_tabs(i) || ' sin contexto vio ' || v_n);
            END IF;

            IF v_already(pi_tabs(i)) = 1 THEN
                pkg_aox_session.set_org(c_org_a);
                v_other := fn_cnt(pi_tabs(i), 'org_id_organization <> ' || c_org_a);
                pkg_aox_session.set_org(c_org_b);
                v_n := fn_cnt(pi_tabs(i), 'org_id_organization <> ' || c_org_b);
                IF v_other <> 0 OR v_n <> 0 THEN
                    pr_kill_wave(pi_tabs, pi_name || ' ' || pi_tabs(i) || ' cross-org');
                END IF;
                CONTINUE;
            END IF;

            pkg_aox_session.set_org(c_org_a);
            v_n := fn_cnt(pi_tabs(i));
            v_other := fn_cnt(pi_tabs(i), 'org_id_organization <> ' || c_org_a);
            IF v_n <> v_snap_a(pi_tabs(i)) OR v_other <> 0 THEN
                pr_kill_wave(
                    pi_tabs,
                    pi_name || ' ' || pi_tabs(i) || ' org A n=' || v_n
                    || ' esperado ' || v_snap_a(pi_tabs(i))
                );
            END IF;

            pkg_aox_session.set_org(c_org_b);
            v_n := fn_cnt(pi_tabs(i));
            v_other := fn_cnt(pi_tabs(i), 'org_id_organization <> ' || c_org_b);
            IF v_n <> v_snap_b(pi_tabs(i)) OR v_other <> 0 THEN
                pr_kill_wave(
                    pi_tabs,
                    pi_name || ' ' || pi_tabs(i) || ' org B n=' || v_n
                    || ' esperado ' || v_snap_b(pi_tabs(i))
                );
            END IF;
        END LOOP;
        pkg_aox_session.clear;
        DBMS_OUTPUT.PUT_LINE('Probe SQL OK ' || pi_name);
    END;

    PROCEDURE pr_run_wave(pi_name IN VARCHAR2, pi_tabs IN SYS.ODCIVARCHAR2LIST) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('--- Oleada ' || pi_name || ' ---');
        pr_snapshot(pi_tabs);
        pkg_aox_tenant_vpd.pr_enable_tables(pi_tabs);
        pr_probe(pi_name, pi_tabs);
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                pkg_aox_tenant_vpd.pr_disable_tables(pi_tabs);
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
BEGIN
    -- Orgs de prueba segun los datos del ambiente (antes fijas 1 y 5 de aoxdevelop).
    -- A: la org con mas citas (y clientes). B: primera org vacia (sin clientes ni citas)
    -- con un miembro activo: los probes esperan 0 filas al cambiar a B.
    -- Se cuentan con set_org por org, asi funciona aunque CUSTOMER/APPOINTMENT ya tengan VPD.
    DECLARE
        v_c     NUMBER;
        v_a     NUMBER;
        v_best1 NUMBER := -1;
    BEGIN
        FOR o IN (SELECT og.id_organization
                    FROM organization og
                   WHERE EXISTS (SELECT 1 FROM org_member m
                                  WHERE m.org_id_organization = og.id_organization
                                    AND m.is_active = 1)
                   ORDER BY og.id_organization) LOOP
            pkg_aox_session.set_org(o.id_organization);
            SELECT COUNT(*) INTO v_c FROM customer;
            SELECT COUNT(*) INTO v_a FROM appointment;
            IF v_c > 0 AND v_a > v_best1 THEN
                v_best1 := v_a; c_org_a := o.id_organization;
            ELSIF v_c = 0 AND v_a = 0 AND c_org_b IS NULL THEN
                c_org_b := o.id_organization;
            END IF;
        END LOOP;
        pkg_aox_session.clear;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_session.clear;
            RAISE;
    END;
    IF c_org_a IS NULL OR c_org_b IS NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probes VPD: falta org A con datos u org B vacia con miembro activo');
    END IF;
    DBMS_OUTPUT.PUT_LINE('Orgs de prueba: A=' || c_org_a || ' B=' || c_org_b);
    pr_run_wave('A1-booking-core', SYS.ODCIVARCHAR2LIST(
        'LOCATION', 'SERVICE', 'PROFESSIONAL', 'PROFESSIONAL_SERVICE', 'PROFESSIONAL_SCHEDULE'
    ));
    pr_run_wave('A2-workspace-hours', SYS.ODCIVARCHAR2LIST(
        'WORKSPACE_SETTING', 'SPECIALTY', 'ORGANIZATION_SPECIALTY',
        'PROFESSIONAL_SCHEDULE_EXCEPTION', 'LOCATION_CLOSURE'
    ));
    pr_run_wave('A3-customer-ext', SYS.ODCIVARCHAR2LIST(
        'APPOINTMENT_ATTACHMENT', 'APPOINTMENT_SERIES', 'APPOINTMENT_SESSION_RECORD',
        'CUSTOMER_PHONE_AUDIT', 'CUSTOMER_ODONTOGRAM_EVENT'
    ));
    pr_run_wave('A4-payments-gallery', SYS.ODCIVARCHAR2LIST(
        'CUSTOMER_BODY_SNAPSHOT', 'PAYMENT_TRANSACTION', 'ORG_PAYMENT_SETTINGS',
        'ORG_PAYMENT_CARD', 'ORG_GALLERY_IMAGE'
    ));
    pr_run_wave('A5-subscription', SYS.ODCIVARCHAR2LIST(
        'ORG_SUBSCRIPTION', 'ORG_SUBSCRIPTION_INVOICE', 'ORG_SUBSCRIPTION_ACCESS_AUDIT',
        'ORG_ADDON', 'ORG_STORAGE_ADDON'
    ));
    pr_run_wave('A6-billing', SYS.ODCIVARCHAR2LIST(
        'ORG_BILLING_PROFILE', 'ORG_BILLING_CREDIT_LEDGER', 'SUBSCRIPTION_CREDIT_NOTE',
        'SUBSCRIPTION_EINVOICE_OUTBOX', 'ORG_ROLE_CAPABILITY'
    ));
    pr_run_wave('A7-refunds', SYS.ODCIVARCHAR2LIST(
        'ORG_REFUND_CLAIM', 'ORG_REFUND_DISPUTE', 'ORG_REFUND_DISPUTE_COMPENSATION',
        'ORG_REFUND_DISPUTE_LEDGER', 'ORG_REFUND_STRIKE'
    ));
    pr_run_wave('A8-ops-chat', SYS.ODCIVARCHAR2LIST(
        'ORG_REFUND_ENFORCEMENT_AUDIT', 'ORG_REFUND_NOTIFY_OUTBOX', 'ORG_INTEGRATION',
        'USER_NOTIFICATION', 'AI_CHAT_SESSION'
    ));
    pr_run_wave('A9-embeddings', SYS.ODCIVARCHAR2LIST(
        'EMBEDDING_SYNC_OUTBOX', 'ORG_ENTITY_EMBEDDING'
    ));
    pr_run_wave('B-children', SYS.ODCIVARCHAR2LIST(
        'AI_CHAT_MESSAGE', 'ORG_REFUND_DISPUTE_EVIDENCE', 'PROFESSIONAL_IMAGE',
        'PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT', 'USER_INTEGRATION'
    ));

    IF pkg_aox_tenant_vpd.fn_enabled_count <> pkg_aox_tenant_vpd.fn_target_count THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'VPD enabled=' || pkg_aox_tenant_vpd.fn_enabled_count
            || ' target=' || pkg_aox_tenant_vpd.fn_target_count
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE(
        'Oleadas A+B OK. enabled=' || pkg_aox_tenant_vpd.fn_enabled_count
        || '/' || pkg_aox_tenant_vpd.fn_target_count
    );
END;
/

PROMPT === 20260919_aox_tenant_vpd_enable_waves listo ===
-- HTTP (directorio/hub/pool/booking/hijas): python3 scripts/enable_vpd_waves.py

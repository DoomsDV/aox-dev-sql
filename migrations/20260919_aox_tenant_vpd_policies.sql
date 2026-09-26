-- RLS/VPD oleada: ADD_POLICY enable FALSE sobre tablas A/B.
-- Predicado fn_aox_tenant_vpd_predicate (ya existe). No ENABLE en negocio.
-- Kill switch: DISABLE_POLICY (policies/03_aox_tenant_vpd_kill_switch.sql), no DROP.
-- Como AOXDEV (PDB_DBA). El paquete necesita GRANT EXECUTE ON sys.dbms_rls
-- TO aoxdev (directo; policies/00_grant_dbms_rls.sql como ADMIN).
-- Si ORA-01031, ejecutar ese grant como ADMIN de la ADB (no HASEL_ADMIN). Idempotente.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_tenant_vpd_policies ===

@@../packages/PKG_AOX_TENANT_VPD.pls
@@../policies/02_aox_tenant_vpd.sql

PROMPT --- Probes policies disabled (kill switch manual: policies/03, no DROP)
DECLARE
    v_targets      NUMBER;
    v_policies     NUMBER;
    v_enabled      NUMBER;
    v_wrong_fn     NUMBER;
    v_no_upd_chk   NUMBER;
    v_not_dynamic  NUMBER;
    v_excluded     NUMBER;
    v_cust_all     NUMBER;
    v_cust_clear   NUMBER;
    v_img_all      NUMBER;
    v_img_clear    NUMBER;
    v_stmt_gap     NUMBER;
BEGIN
    v_targets  := pkg_aox_tenant_vpd.fn_target_count;
    v_policies := pkg_aox_tenant_vpd.fn_policy_count;
    v_enabled  := pkg_aox_tenant_vpd.fn_enabled_count;

    IF v_targets <> 49 THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe: se esperaban 49 tablas A/B, hay ' || v_targets
        );
    END IF;
    IF v_policies <> v_targets THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe: policies=' || v_policies || ' targets=' || v_targets
        );
    END IF;
    SELECT COUNT(*)
      INTO v_enabled
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND enable = 'YES'
       AND object_name NOT IN ('CUSTOMER', 'APPOINTMENT');
    IF v_enabled <> 0 THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe: policies enabled fuera del canario: ' || v_enabled
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe ADD_POLICY x' || v_policies || ' (canario CUSTOMER/APPOINTMENT permitido) OK');

    SELECT COUNT(*)
      INTO v_wrong_fn
      FROM user_policies p
     WHERE p.policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND UPPER(p."FUNCTION") <> pkg_aox_tenant_vpd.c_policy_fn;
    IF v_wrong_fn <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: ' || v_wrong_fn || ' policies con fn distinta');
    END IF;

    SELECT COUNT(*)
      INTO v_no_upd_chk
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND NVL(chk_option, 'NO') <> 'YES';
    IF v_no_upd_chk <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: ' || v_no_upd_chk || ' sin update_check');
    END IF;

    SELECT COUNT(*)
      INTO v_not_dynamic
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND NVL(policy_type, 'DYNAMIC') <> 'DYNAMIC';
    IF v_not_dynamic <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: ' || v_not_dynamic || ' no DYNAMIC');
    END IF;

    SELECT COUNT(*)
      INTO v_stmt_gap
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND (sel <> 'YES' OR ins <> 'YES' OR upd <> 'YES' OR del <> 'YES');
    IF v_stmt_gap <> 0 THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe: ' || v_stmt_gap || ' policies sin SELECT,INSERT,UPDATE,DELETE'
        );
    END IF;

    SELECT COUNT(*)
      INTO v_excluded
      FROM user_policies
     WHERE object_name IN (
             'ORG_MEMBER',
             'ORG_INVITATION',
             'ORG_PUBLIC_DIRECTORY',
             'ORG_PUBLIC_TOKEN',
             'APP_USER_LEGACY',
             'ORGANIZATION',
             'PLATFORM_USER',
             'APP_USER_SESSION',
             'APP_USER_EMAIL_VERIFICATION',
             'APP_USER_PWD_RESET',
             'USER_FCM_DEVICES',
             'PUSH_CAMPAIGN',
             'PUSH_CAMPAIGN_DELIVERY',
             'PUSH_CAMPAIGN_VAR',
             'AOX_API_LOG',
             'AOX_AI_LOG',
             'AOX_FCM_LOG',
             'AOX_PUSH_FCM_LOG',
             'AOX_WHATSAPP_TEMPLATE_LOG',
             'AOX_LOG_WEBHOOK_META',
             'SUBSCRIPTION_EINVOICE_WEBHOOK_LOG',
             'API_IDEMPOTENCY_KEY',
             'API_RATE_LIMIT_BUCKET',
             'APP_PARAMETER',
             'ROLE',
             'CAPABILITY',
             'ROLE_CAPABILITY_DEFAULT',
             'CITIES',
             'DEPARTMENTS',
             'ORG_SPECIALTY'
           );
    IF v_excluded <> 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'Probe: policies en tablas C/D/publico: ' || v_excluded);
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe sin policies en C/D/publico OK');

    SELECT COUNT(*) INTO v_img_all FROM professional_image;
    pkg_aox_session.clear;
    SELECT COUNT(*) INTO v_cust_clear FROM customer;
    SELECT COUNT(*) INTO v_img_clear FROM professional_image;
    SELECT COUNT(*)
      INTO v_enabled
      FROM user_policies
     WHERE policy_name = pkg_aox_tenant_vpd.c_policy_name
       AND object_name = 'CUSTOMER'
       AND enable = 'YES';
    IF v_enabled = 0 THEN
        SELECT COUNT(*) INTO v_cust_all FROM customer;
        -- Releer con contexto vacio ya hecho; si disabled, ambos iguales.
        pkg_aox_session.set_org(1);
        SELECT COUNT(*) INTO v_cust_all FROM customer;
        pkg_aox_session.clear;
        SELECT COUNT(*) INTO v_cust_clear FROM customer;
        IF v_cust_all <> v_cust_clear THEN
            RAISE_APPLICATION_ERROR(
                -20000,
                'Probe: CUSTOMER filtrada con policy disabled (' || v_cust_clear || '/' || v_cust_all || ')'
            );
        END IF;
    ELSE
        IF v_cust_clear <> 0 THEN
            RAISE_APPLICATION_ERROR(
                -20000,
                'Probe: CUSTOMER canario enabled pero visible sin contexto (' || v_cust_clear || ')'
            );
        END IF;
    END IF;
    IF v_img_all <> v_img_clear THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Probe: PROFESSIONAL_IMAGE filtrada con policy disabled'
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE('Probe visibilidad (canario-aware) OK');

    DBMS_OUTPUT.PUT_LINE('Probes VPD disabled OK. ENABLE queda para oleada posterior.');
END;
/

PROMPT === 20260919_aox_tenant_vpd_policies listo ===

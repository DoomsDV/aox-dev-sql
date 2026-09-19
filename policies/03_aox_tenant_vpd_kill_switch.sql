-- Kill switch VPD tenant: DISABLE_POLICY (no DROP).
-- Restaura visibilidad full en tablas A/B sin borrar la policy.
-- Lo corre la migracion 20260919_aox_tenant_vpd_policies (esta oleada).
-- No esta en FASE 6 de install_all (para no pisar un ENABLE posterior).
-- Uso manual: @@policies/03_aox_tenant_vpd_kill_switch.sql
-- No reactivar desde este archivo.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT --- policies/03_aox_tenant_vpd_kill_switch: DISABLE (no DROP) ---

BEGIN
    pkg_aox_tenant_vpd.pr_disable_all;
    IF pkg_aox_tenant_vpd.fn_enabled_count <> 0 THEN
        RAISE_APPLICATION_ERROR(
            -20000,
            'Kill switch: quedaron policies enabled='
            || pkg_aox_tenant_vpd.fn_enabled_count
        );
    END IF;
    DBMS_OUTPUT.PUT_LINE(
        'Kill switch OK: policies='
        || pkg_aox_tenant_vpd.fn_policy_count
        || ' enabled=0'
    );
END;
/

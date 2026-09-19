-- Canario VPD: ENABLE_POLICY solo CUSTOMER y APPOINTMENT.
-- No habilita el resto A/B. Kill switch: pkg_aox_tenant_vpd.pr_disable_canary
-- (o policies/03 para todas).
-- Si ORA-01031: GRANT EXECUTE ON sys.dbms_rls TO aoxdev (ADMIN).

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT --- policies/04_aox_tenant_vpd_canary: ENABLE CUSTOMER + APPOINTMENT ---

BEGIN
    pkg_aox_tenant_vpd.pr_ensure_policies;
    pkg_aox_tenant_vpd.pr_enable_canary;
END;
/

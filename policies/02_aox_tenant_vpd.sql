-- Policies VPD tenant A/B: ADD_POLICY enable FALSE.
-- Predicado: fn_aox_tenant_vpd_predicate. No habilita tablas de negocio.
-- Kill switch (no DROP): @@policies/03_aox_tenant_vpd_kill_switch.sql
-- Si ORA-01031: GRANT EXECUTE ON sys.dbms_rls TO aoxdev  (usuario ADMIN de la ADB).
-- Ese grant directo esta en policies/00_grant_dbms_rls.sql (no corre como AOXDEV).
BEGIN
    pkg_aox_tenant_vpd.pr_ensure_policies;
END;
/

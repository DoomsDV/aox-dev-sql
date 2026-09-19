-- Prerrequisito ADMIN (no AOXDEV): grant directo para que el paquete
-- pkg_aox_tenant_vpd vea DBMS_RLS (los roles no aplican en definer rights).
-- Usuario ADMIN de aoxdevelop, misma wallet. No incluye password.
--   GRANT EXECUTE ON sys.dbms_rls TO aoxdev;
GRANT EXECUTE ON sys.dbms_rls TO aoxdev;

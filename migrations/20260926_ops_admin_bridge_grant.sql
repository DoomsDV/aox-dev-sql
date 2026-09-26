-- GRANT EXECUTE del bridge ops al control plane (HASEL_ADMIN).
-- Lo otorga el owner SaaS: aox-admin-dev-sql/20260906_ops_role_primary_fix lo intentaba
-- conectado como HASEL_ADMIN, que no puede otorgar privilegios sobre objetos ajenos (ORA-00942).
-- Correr despues de compilar packages/PKG_AOX_OPS_ADMIN_BRIDGE.pls y de crear HASEL_ADMIN,
-- antes de las migraciones de aox-admin-dev-sql. Como AOXDEV / WKSP_AOX. Idempotente.

SET SERVEROUTPUT ON

BEGIN
    EXECUTE IMMEDIATE 'GRANT EXECUTE ON pkg_aox_ops_admin_bridge TO hasel_admin';
    DBMS_OUTPUT.PUT_LINE('GRANT EXECUTE pkg_aox_ops_admin_bridge TO hasel_admin OK');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1917 THEN
            DBMS_OUTPUT.PUT_LINE('SKIP: el usuario HASEL_ADMIN no existe todavia');
        ELSE
            RAISE;
        END IF;
END;
/

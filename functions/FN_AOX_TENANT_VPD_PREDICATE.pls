PROMPT CREATE OR REPLACE FUNCTION fn_aox_tenant_vpd_predicate
CREATE OR REPLACE FUNCTION fn_aox_tenant_vpd_predicate (
    pi_schema IN VARCHAR2,
    pi_object IN VARCHAR2
) RETURN VARCHAR2
IS
    v_session_user VARCHAR2(128);
    v_access_mode  VARCHAR2(30);
BEGIN
    -- Cero SQL a tablas. Predicado leido por DBMS_RLS en cada statement.
    v_session_user := SYS_CONTEXT('USERENV', 'SESSION_USER');
    IF v_session_user = 'HASEL_ADMIN' THEN
        RETURN '1=1';
    END IF;

    v_access_mode := SYS_CONTEXT('AOX_TENANT_CTX', 'ACCESS_MODE');
    IF v_access_mode = 'JOB'
       AND SYS_CONTEXT('USERENV', 'BG_JOB_ID') IS NOT NULL THEN
        RETURN '1=1';
    END IF;

    IF SYS_CONTEXT('AOX_TENANT_CTX', 'ORG_ID') IS NULL THEN
        RETURN '1=2';
    END IF;

    RETURN q'[org_id_organization = TO_NUMBER(SYS_CONTEXT('AOX_TENANT_CTX','ORG_ID') DEFAULT NULL ON CONVERSION ERROR)]';
END fn_aox_tenant_vpd_predicate;
/

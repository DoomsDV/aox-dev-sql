-- Pase 2026-09, paso 1 (ADMIN). Correr como ADMIN en Database Actions > SQL (F5).
-- Antes de ejecutar: reemplazar CAMBIAR_PASSWORD por la password de HASEL_ADMIN
-- (la misma que HASEL_ADMIN_PASSWORD en ~/.config/aox_prod.env o aox_rehearsal.env).
-- Solo corre en la base de prod (G9549F707E8EBFA_AOX) o en el clon de ensayo.

SET SERVEROUTPUT ON

BEGIN
    IF SYS_CONTEXT('USERENV', 'DB_NAME') NOT IN ('G9549F707E8EBFA_AOX', 'G9549F707E8EBFA_AOXREHEARSAL') THEN
        RAISE_APPLICATION_ERROR(-20000, 'BASE INESPERADA: ' || SYS_CONTEXT('USERENV', 'DB_NAME'));
    END IF;
END;
/

-- 1) Usuario HASEL_ADMIN (grants/README.md + los privilegios que tiene en DEV).
CREATE USER hasel_admin IDENTIFIED BY "CAMBIAR_PASSWORD"
    DEFAULT TABLESPACE data
    QUOTA UNLIMITED ON data
    TEMPORARY TABLESPACE temp;

GRANT CONNECT, RESOURCE TO hasel_admin;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE,
      CREATE SEQUENCE, CREATE TRIGGER, CREATE SYNONYM, CREATE TYPE TO hasel_admin;
GRANT UNLIMITED TABLESPACE TO hasel_admin;
-- 20260907_ops_push_campaigns crea el job HASEL_ADMIN_DISPATCH_CAMPAIGNS.
GRANT CREATE JOB TO hasel_admin;
GRANT EXECUTE ON sys.dbms_crypto TO hasel_admin;
GRANT EXECUTE ON dbms_cloud TO hasel_admin;

-- Resource principal (lectura del bucket). Si el ADB no lo tiene habilitado, se informa y sigue.
BEGIN
    DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => 'HASEL_ADMIN');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('resource principal HASEL_ADMIN: ' || SQLERRM);
END;
/

-- 2) ACL de red: Azure OpenAI (embeddings KB) + OCI Object Storage (scripts/acl_hasel_admin_kb.sql).
DECLARE
    PROCEDURE grant_connect(p_host VARCHAR2) IS
    BEGIN
        DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
            host       => p_host,
            lower_port => 443,
            upper_port => 443,
            ace        => xs$ace_type(
                              privilege_list => xs$name_list('connect'),
                              principal_name => 'HASEL_ADMIN',
                              principal_type => xs_acl.ptype_db));
    END grant_connect;
BEGIN
    grant_connect('hasel-openai-api.openai.azure.com');
    grant_connect('objectstorage.sa-saopaulo-1.oraclecloud.com');
    COMMIT;
END;
/

-- 3) HASEL_ADMIN en el workspace APEX de prod (AOX), para usar OCI_BUCKET_CRED.
BEGIN
    APEX_INSTANCE_ADMIN.ADD_SCHEMA(p_workspace => 'AOX', p_schema => 'HASEL_ADMIN');
    COMMIT;
END;
/

-- 4) VPD: grant directo de DBMS_RLS al owner SaaS (policies/00_grant_dbms_rls.sql).
GRANT EXECUTE ON sys.dbms_rls TO wksp_aox;

-- 5) Verificacion.
SELECT username, account_status FROM dba_users WHERE username = 'HASEL_ADMIN';
SELECT grantee, privilege FROM dba_sys_privs WHERE grantee = 'HASEL_ADMIN' ORDER BY 2;
SELECT grantee, owner || '.' || table_name AS objeto, privilege
  FROM dba_tab_privs
 WHERE (grantee = 'HASEL_ADMIN' AND table_name IN ('DBMS_CRYPTO', 'DBMS_CLOUD'))
    OR (grantee = 'WKSP_AOX' AND table_name = 'DBMS_RLS')
 ORDER BY 1, 2;
SELECT host, principal, privilege FROM dba_host_aces WHERE principal = 'HASEL_ADMIN' ORDER BY 1;
SELECT workspace_name, schema FROM apex_workspace_schemas WHERE schema = 'HASEL_ADMIN';

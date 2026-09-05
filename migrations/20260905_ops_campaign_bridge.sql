-- Vistas + grants para campanas push desde HASEL_ADMIN (lectura audiencia/roles en aoxdev).
-- Ejecutar como AOXDEV. Compilar PKG_AOX_OPS_ADMIN_BRIDGE por separado.

CREATE OR REPLACE VIEW v_ops_role_lov AS
SELECT r.id_role,
       r.name
  FROM role r
 WHERE r.is_active = 1;
/

COMMENT ON TABLE v_ops_role_lov IS 'LOV roles activos para campanas ops. GRANT SELECT a HASEL_ADMIN.';
/

CREATE OR REPLACE VIEW v_ops_campaign_audience AS
SELECT pu.id_platform_user,
       pu.first_name,
       pu.last_name,
       pu.email,
       om.id_org_member,
       om.org_id_organization,
       om.rol_id_role,
       r.name AS role_name
  FROM platform_user pu
  JOIN org_member om
    ON om.platform_user_id = pu.id_platform_user
   AND om.is_active = 1
  JOIN role r
    ON r.id_role = om.rol_id_role
   AND r.is_active = 1
 WHERE pu.is_active = 1;
/

COMMENT ON TABLE v_ops_campaign_audience IS 'Miembros activos (staff) elegibles para campanas push ops. Sin tokens FCM.';
/

CREATE OR REPLACE VIEW v_ops_campaign_fcm_token AS
SELECT f.platform_user_id,
       f.fcm_token
  FROM user_fcm_devices f
  JOIN platform_user pu
    ON pu.id_platform_user = f.platform_user_id
   AND pu.is_active = 1;
/

COMMENT ON TABLE v_ops_campaign_fcm_token IS 'Tokens FCM por platform_user activo (campanas ops).';
/

GRANT SELECT ON v_ops_role_lov TO hasel_admin;
/

GRANT SELECT ON v_ops_campaign_audience TO hasel_admin;
/

GRANT SELECT ON v_ops_campaign_fcm_token TO hasel_admin;
/

PROMPT === v_ops_campaign_* + grants a hasel_admin ===

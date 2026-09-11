-- Audiencia staff para encuesta de producto Hasel (ops panel).
-- Ejecutar como AOXDEV. GRANT SELECT a HASEL_ADMIN.

CREATE OR REPLACE VIEW v_ops_survey_audience AS
SELECT pu.id_platform_user,
       pu.first_name,
       pu.last_name,
       pu.email,
       om.id_org_member,
       om.org_id_organization,
       o.name AS org_name,
       om.rol_id_role,
       r.name AS role_name,
       p.phone_number
  FROM platform_user pu
  JOIN org_member om
    ON om.platform_user_id = pu.id_platform_user
   AND om.is_active = 1
  JOIN role r
    ON r.id_role = om.rol_id_role
   AND r.is_active = 1
  JOIN organization o
    ON o.id_organization = om.org_id_organization
  LEFT JOIN professional p
    ON p.usr_id_user = om.id_org_member
   AND p.org_id_organization = om.org_id_organization
   AND p.is_active = 1
 WHERE pu.is_active = 1;
/

COMMENT ON TABLE v_ops_survey_audience IS
  'Staff activo para encuesta de producto Hasel (ops). Telefono desde professional si existe.';
/

GRANT SELECT ON v_ops_survey_audience TO hasel_admin;
/

PROMPT === v_ops_survey_audience + grant a hasel_admin ===

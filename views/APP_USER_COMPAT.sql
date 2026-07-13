PROMPT CREATE OR REPLACE VIEW app_user
-- Vista de compatibilidad: expone el contrato historico de app_user (lecturas en paquetes legacy).
-- Escrituras deben ir a platform_user + org_member (PKG_AOX_AUTH_API, PKG_AOX_PROFESSIONAL_API, PKG_AOX_USER_API).
CREATE OR REPLACE VIEW app_user AS
SELECT
  m.id_org_member       AS id_user,
  m.org_id_organization AS org_id_organization,
  m.rol_id_role         AS rol_id_role,
  pu.apex_user_name     AS apex_user_name,
  pu.first_name         AS first_name,
  pu.last_name          AS last_name,
  pu.email              AS email,
  m.is_active           AS is_active,
  m.created_at          AS created_at,
  pu.password_hash      AS password_hash,
  pu.email_verified_at  AS email_verified_at,
  m.platform_user_id    AS platform_user_id
FROM org_member m
INNER JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
/

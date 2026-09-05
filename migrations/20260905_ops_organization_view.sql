-- Vista redactada para lectura cross-schema desde HASEL_ADMIN (Fase 1 allowlist)
-- Ejecutar como AOXDEV. Sin PII de clientes ni secretos.

CREATE OR REPLACE VIEW v_ops_organization AS
SELECT o.id_organization,
       o.name,
       ws.profile_slug AS slug,
       NVL(s.status, 'UNKNOWN') AS subscription_status,
       o.created_at
  FROM organization o
  LEFT JOIN workspace_setting ws ON ws.org_id_organization = o.id_organization
  LEFT JOIN org_subscription s ON s.org_id_organization = o.id_organization;

COMMENT ON TABLE v_ops_organization IS 'Lectura ops: orgs tenant (sin PII). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_organization TO hasel_admin;

PROMPT === v_ops_organization + grant a hasel_admin ===

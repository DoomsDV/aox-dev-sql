-- Amplia v_ops_organization con plan y campos de suscripcion (sin PII).
-- Ejecutar como AOXDEV. CREATE OR REPLACE conserva GRANT SELECT a hasel_admin.

CREATE OR REPLACE VIEW v_ops_organization AS
SELECT o.id_organization,
       o.name,
       ws.profile_slug AS slug,
       NVL(s.status, 'UNKNOWN') AS subscription_status,
       p.code AS plan_code,
       p.name AS plan_name,
       NVL(s.billing_exempt, 0) AS billing_exempt,
       s.current_period_end,
       s.last_charge_at,
       o.created_at
  FROM organization o
  LEFT JOIN workspace_setting ws ON ws.org_id_organization = o.id_organization
  LEFT JOIN org_subscription s ON s.org_id_organization = o.id_organization
  LEFT JOIN ref_plan p ON p.id_plan = s.pln_id_plan;

COMMENT ON TABLE v_ops_organization IS 'Lectura ops: orgs tenant, plan y suscripcion (sin PII). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_organization TO hasel_admin;

PROMPT === v_ops_organization billing + grant a hasel_admin ===

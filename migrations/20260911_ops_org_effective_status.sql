-- Estado efectivo de suscripcion para ops (misma logica que fn_get_subscription_state).
-- Ejecutar como AOXDEV. CREATE OR REPLACE conserva GRANT SELECT a hasel_admin.

CREATE OR REPLACE VIEW v_ops_organization AS
SELECT x.id_organization,
       x.name,
       x.slug,
       x.subscription_status,
       x.plan_code,
       x.plan_name,
       x.billing_exempt,
       x.current_period_end,
       x.grace_ends_at,
       x.trial_ends_at,
       x.auto_renew,
       x.last_charge_at,
       x.created_at,
       CASE
         WHEN x.subscription_status IN ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') THEN 0
         ELSE 1
       END AS can_write
  FROM (
    SELECT o.id_organization,
           o.name,
           ws.profile_slug AS slug,
           CASE
             WHEN s.org_id_organization IS NULL THEN 'UNKNOWN'
             WHEN NVL(s.is_founder, 0) = 1
               OR NVL(s.billing_exempt, 0) = 1
               OR s.status = 'FOUNDER' THEN 'FOUNDER'
             WHEN s.status = 'TRIAL'
              AND (s.trial_ends_at IS NULL OR SYSTIMESTAMP <= s.trial_ends_at) THEN 'TRIAL'
             WHEN s.status = 'TRIAL' THEN 'TRIAL_EXPIRED'
             WHEN s.status = 'ACTIVE'
              AND (s.current_period_end IS NULL OR SYSTIMESTAMP <= s.current_period_end) THEN 'ACTIVE'
             WHEN s.status = 'ACTIVE'
              AND SYSTIMESTAMP <= NVL(s.grace_ends_at, s.current_period_end + NUMTODSINTERVAL(3, 'DAY')) THEN 'PAST_DUE'
             WHEN s.status = 'ACTIVE' THEN 'READ_ONLY'
             WHEN s.status = 'PAST_DUE'
              AND SYSTIMESTAMP <= NVL(
                    s.grace_ends_at,
                    NVL(s.current_period_end, SYSTIMESTAMP) + NUMTODSINTERVAL(3, 'DAY')
                  ) THEN 'PAST_DUE'
             WHEN s.status = 'PAST_DUE' THEN 'READ_ONLY'
             WHEN s.status = 'READ_ONLY' THEN 'READ_ONLY'
             WHEN s.status = 'CANCELED' THEN 'CANCELED'
             ELSE NVL(s.status, 'UNKNOWN')
           END AS subscription_status,
           p.code AS plan_code,
           p.name AS plan_name,
           NVL(s.billing_exempt, 0) AS billing_exempt,
           s.current_period_end,
           CASE
             WHEN s.status IN ('ACTIVE', 'PAST_DUE') THEN
                 NVL(s.grace_ends_at, s.current_period_end + NUMTODSINTERVAL(3, 'DAY'))
             ELSE s.grace_ends_at
           END AS grace_ends_at,
           s.trial_ends_at,
           NVL(s.auto_renew, 1) AS auto_renew,
           s.last_charge_at,
           o.created_at
      FROM organization o
      LEFT JOIN workspace_setting ws ON ws.org_id_organization = o.id_organization
      LEFT JOIN org_subscription s ON s.org_id_organization = o.id_organization
      LEFT JOIN ref_plan p ON p.id_plan = s.pln_id_plan
  ) x;

COMMENT ON TABLE v_ops_organization IS 'Lectura ops: orgs tenant, plan y estado efectivo de suscripcion (sin PII).';

GRANT SELECT ON v_ops_organization TO hasel_admin;

PROMPT === v_ops_organization effective_status + grant a hasel_admin ===

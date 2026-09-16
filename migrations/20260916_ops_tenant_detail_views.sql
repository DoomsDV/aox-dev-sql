-- HAS-74: campos redacted necesarios para la ficha de tenant en Hasel Admin.
-- Ejecutar como AOXDEV antes de las migraciones de HASEL_ADMIN.
-- No exponer XML, e-mail fiscal, CDC ni informacion de clientes.

CREATE OR REPLACE VIEW v_ops_analytics_invoice AS
SELECT i.id_invoice,
       i.org_id_organization,
       i.sub_id_subscription,
       i.invoice_type,
       i.pln_id_plan,
       i.amount,
       i.gross_amount,
       i.credit_applied,
       i.currency,
       i.status,
       i.created_at,
       i.due_date,
       i.paid_at,
       i.period_start,
       i.period_end,
       i.einvoice_kude_url AS kude_url
  FROM org_subscription_invoice i;

COMMENT ON TABLE v_ops_analytics_invoice IS
  'Lectura ops: facturas SaaS para ficha tenant, cartera y aging (sin XML/email/CDC).';

GRANT SELECT ON v_ops_analytics_invoice TO hasel_admin;

CREATE OR REPLACE VIEW v_ops_organization AS
SELECT x.id_organization,
       x.name,
       x.slug,
       x.subscription_status,
       x.plan_code,
       x.plan_name,
       x.plan_price_amount,
       x.plan_currency,
       x.is_founder,
       x.billing_exempt,
       x.current_period_end,
       x.grace_ends_at,
       x.trial_started_at,
       x.trial_ends_at,
       x.auto_renew,
       x.last_charge_at,
       x.created_at,
       x.billing_name,
       x.billing_doc_type,
       x.billing_doc_number,
       x.refund_enforcement_level,
       CASE
         WHEN x.subscription_status IN ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') THEN 0
         ELSE 1
       END AS can_write,
       x.ops_access_locked
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
           NVL(p.price_amount, 0) AS plan_price_amount,
           p.currency AS plan_currency,
           NVL(s.is_founder, 0) AS is_founder,
           NVL(s.billing_exempt, 0) AS billing_exempt,
           s.current_period_end,
           CASE
             WHEN s.status IN ('ACTIVE', 'PAST_DUE') THEN
                 NVL(s.grace_ends_at, s.current_period_end + NUMTODSINTERVAL(3, 'DAY'))
             ELSE s.grace_ends_at
           END AS grace_ends_at,
           s.trial_started_at,
           s.trial_ends_at,
           NVL(s.auto_renew, 1) AS auto_renew,
           s.last_charge_at,
           o.created_at,
           bp.billing_name,
           bp.billing_doc_type,
           bp.billing_doc_number,
           NVL(ps.refund_enforcement_level, 'NONE') AS refund_enforcement_level,
           CASE WHEN s.status = 'READ_ONLY' THEN 1 ELSE 0 END AS ops_access_locked
      FROM organization o
      LEFT JOIN workspace_setting ws ON ws.org_id_organization = o.id_organization
      LEFT JOIN org_subscription s ON s.org_id_organization = o.id_organization
      LEFT JOIN ref_plan p ON p.id_plan = s.pln_id_plan
      LEFT JOIN org_billing_profile bp ON bp.org_id_organization = o.id_organization
      LEFT JOIN org_payment_settings ps ON ps.org_id_organization = o.id_organization
  ) x;

COMMENT ON TABLE v_ops_organization IS
  'Lectura ops: tenant, facturacion y estado efectivo sin e-mail ni datos de clientes.';

GRANT SELECT ON v_ops_organization TO hasel_admin;

PROMPT === HAS-74 tenant detail views ready ===

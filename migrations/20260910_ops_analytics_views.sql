-- Vistas redactadas de analiticas para lectura cross-schema desde HASEL_ADMIN
-- Ejecutar como AOXDEV. Hechos sin PII de clientes ni secretos.

CREATE OR REPLACE VIEW v_ops_analytics_appointment AS
SELECT a.id_appointment,
       a.org_id_organization,
       a.start_time,
       a.created_at,
       a.status,
       a.payment_status,
       a.attendance_status,
       a.refund_status,
       a.deposit_amount,
       a.refund_amount,
       a.paid_at
  FROM appointment a;

COMMENT ON TABLE v_ops_analytics_appointment IS 'Lectura ops: hechos de citas (sin PII). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_analytics_appointment TO hasel_admin;

CREATE OR REPLACE VIEW v_ops_analytics_payment AS
SELECT p.id_transaction,
       p.org_id_organization,
       p.amount,
       p.currency,
       p.payment_status,
       p.payment_channel,
       p.provider,
       p.created_at,
       p.processed_at
  FROM payment_transaction p;

COMMENT ON TABLE v_ops_analytics_payment IS 'Lectura ops: hechos de senas (sin raw/OCR/recibos). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_analytics_payment TO hasel_admin;

CREATE OR REPLACE VIEW v_ops_analytics_invoice AS
SELECT i.id_invoice,
       i.org_id_organization,
       i.invoice_type,
       i.amount,
       i.gross_amount,
       i.credit_applied,
       i.currency,
       i.status,
       i.created_at,
       i.paid_at,
       i.period_start,
       i.period_end
  FROM org_subscription_invoice i;

COMMENT ON TABLE v_ops_analytics_invoice IS 'Lectura ops: facturas SaaS (sin XML/email/CDC). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_analytics_invoice TO hasel_admin;

PROMPT === v_ops_analytics_* + grant a hasel_admin ===

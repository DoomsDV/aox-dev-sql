-- Vista redactada: disputas para admin console (sin PII de clientes)
-- Ejecutar como AOXDEV.

CREATE OR REPLACE VIEW v_ops_refund_dispute AS
SELECT d.id_dispute,
       d.org_id_organization,
       o.name AS org_name,
       ws.profile_slug AS org_slug,
       d.app_id_appointment,
       d.dispute_source,
       d.dispute_status,
       d.proof_due_at,
       d.ops_review_due_at,
       d.opened_at,
       d.closed_at,
       d.resolution_code,
       d.close_reason,
       NVL(ops.refund_enforcement_level, 'NONE') AS refund_enforcement_level
  FROM org_refund_dispute d
  JOIN organization o ON o.id_organization = d.org_id_organization
  LEFT JOIN workspace_setting ws ON ws.org_id_organization = d.org_id_organization
  LEFT JOIN org_payment_settings ops ON ops.org_id_organization = d.org_id_organization;

COMMENT ON TABLE v_ops_refund_dispute IS 'Lectura ops: disputas de reembolso (sin PII cliente). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_refund_dispute TO hasel_admin;

PROMPT === v_ops_refund_dispute + grant a hasel_admin ===

-- Vista redactada: evidencia OCR de disputas para admin console
-- (sin OCR_RAW, SHA256 ni OBJECT_KEY). Ejecutar como AOXDEV.

CREATE OR REPLACE VIEW v_ops_refund_dispute_evidence AS
SELECT e.id_evidence,
       e.dispute_id,
       e.attempt_n,
       e.mime_type,
       e.size_bytes,
       e.ocr_status,
       e.ocr_amount,
       e.ocr_alias_hint,
       e.ocr_confidence,
       e.review_decision,
       e.uploaded_at,
       pkg_aox_bucket.fn_public_object_url(e.object_key) AS proof_url
  FROM org_refund_dispute_evidence e;

COMMENT ON TABLE v_ops_refund_dispute_evidence IS 'Lectura ops: comprobantes de disputa (sin OCR_RAW ni object_key). GRANT SELECT a HASEL_ADMIN.';

GRANT SELECT ON v_ops_refund_dispute_evidence TO hasel_admin;

PROMPT === v_ops_refund_dispute_evidence + grant a hasel_admin ===

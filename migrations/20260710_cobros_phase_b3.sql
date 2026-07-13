-- Migracion: Fase B3 Cobros - revision manual de comprobantes
-- Columnas de auditoria de aprobacion/rechazo + indice de cola

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (reviewed_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (reviewed_by NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (reject_reason VARCHAR2(400) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN payment_transaction.reviewed_at IS
  'Momento en que el staff aprobo o rechazo el comprobante SIPAP.';
/

COMMENT ON COLUMN payment_transaction.reviewed_by IS
  'user_id del staff que reviso el comprobante.';
/

COMMENT ON COLUMN payment_transaction.reject_reason IS
  'Motivo corto de rechazo (borrosa / monto / sin HASEL).';
/

BEGIN
  EXECUTE IMMEDIATE
    'CREATE INDEX idx_paytx_org_ocr_created ON payment_transaction (org_id_organization, ocr_status, created_at)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

COMMIT;
/

PROMPT === Fase B3 DDL finalizada ===

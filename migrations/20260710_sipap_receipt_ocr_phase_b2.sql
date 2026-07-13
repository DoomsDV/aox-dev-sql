-- Migracion: Fase B2 Cobros SIPAP - comprobante + OCR
-- Roadmap Hasel: upload a bucket (path ordenado) + extraccion gpt-4o/mini

--------------------------------------------------------------------------------
PROMPT === 1. Columnas receipt / OCR en payment_transaction ===
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (receipt_object_key VARCHAR2(500) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (receipt_url VARCHAR2(1000) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (receipt_mime_type VARCHAR2(150) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (receipt_uploaded_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_raw_json CLOB NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_reference VARCHAR2(64) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_amount NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_transferred_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_confidence NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_status VARCHAR2(20) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (ocr_checked_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE payment_transaction ADD CONSTRAINT chk_paytx_ocr_status CHECK (
      ocr_status IS NULL
      OR ocr_status IN ('PENDING','MATCH','MISMATCH','MANUAL_REVIEW','FAILED')
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2260, -2264, -2275) THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN payment_transaction.receipt_object_key IS
  'Object key relativo en bucket: organizations/{org}/payments/{yyyy}/{mm}/{customer}/{id}.{ext}';
/

COMMENT ON COLUMN payment_transaction.receipt_url IS
  'URL del comprobante (pruebas: bucket publico). En prod usar PAR/proxy.';
/

COMMENT ON COLUMN payment_transaction.ocr_status IS
  'PENDING|MATCH|MISMATCH|MANUAL_REVIEW|FAILED — ciclo OCR del comprobante SIPAP.';
/

--------------------------------------------------------------------------------
PROMPT === 2. Parametro deployment OCR (opcional; default gpt-4o via AZURE_OPENAI_DEPLOYMENT) ===
--------------------------------------------------------------------------------
MERGE INTO app_parameter t
USING (
  SELECT
    'AZURE_OPENAI_RECEIPT_DEPLOYMENT' AS param_key,
    'gpt-4o' AS param_value,
    'Deployment Azure OpenAI multimodal para OCR de comprobantes SIPAP (gpt-4o o gpt-4o-mini).' AS description
  FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (s.param_key, s.param_value, s.description)
WHEN MATCHED THEN
  UPDATE SET description = s.description;
/

COMMIT;
/

PROMPT === Fase B2 DDL finalizada ===

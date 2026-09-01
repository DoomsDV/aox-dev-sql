-- Entrega fiscal recuperable: el mail_id se confirma antes de push_queue para
-- distinguir un fallo previo al encolado de un resultado de entrega ambiguo.
PROMPT === reconciliacion de correo fiscal ===

DECLARE
  PROCEDURE add_col(p_ddl IN VARCHAR2, p_column IN VARCHAR2) IS
    l_count NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_count
      FROM user_tab_columns
     WHERE table_name = 'ORG_SUBSCRIPTION_INVOICE'
       AND column_name = p_column;
    IF l_count = 0 THEN
      EXECUTE IMMEDIATE p_ddl;
    END IF;
  END add_col;
BEGIN
  add_col(
    'ALTER TABLE org_subscription_invoice ADD (einvoice_email_queued_at TIMESTAMP(6) WITH TIME ZONE)',
    'EINVOICE_EMAIL_QUEUED_AT'
  );
  add_col(
    'ALTER TABLE org_subscription_invoice ADD (einvoice_email_reconciled_at TIMESTAMP(6) WITH TIME ZONE)',
    'EINVOICE_EMAIL_RECONCILED_AT'
  );
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE org_subscription_invoice DROP CONSTRAINT chk_orginv_einvoice_email_status';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE <> -2443 THEN
      RAISE;
    END IF;
END;
/

ALTER TABLE org_subscription_invoice
  ADD CONSTRAINT chk_orginv_einvoice_email_status CHECK (
    einvoice_email_status IN ('NONE', 'PENDING', 'QUEUED', 'UNKNOWN', 'SENT', 'FAILED')
  )
/

MERGE INTO app_parameter t
USING (
  SELECT 'EINVOICE_STAGING_FAULTS_ENABLED' AS param_key,
         '0' AS param_value,
         'Solo aoxdev: permite inyecciones de fallo fiscal de una ejecución.' AS description
    FROM dual
  UNION ALL
  SELECT 'EINVOICE_STAGING_FAULT_AFTER_PUSH_QUEUE',
         '0',
         'Solo aoxdev: falla una vez luego de apex_mail.push_queue.'
    FROM dual
  UNION ALL
  SELECT 'EINVOICE_STAGING_FAULT_ORG_ID',
         '0',
         'Solo aoxdev: organización QA autorizada para la inyección de fallo fiscal.'
    FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (s.param_key, s.param_value, s.description)
/

COMMENT ON COLUMN org_subscription_invoice.einvoice_email_status IS
  'NONE | PENDING | QUEUED | UNKNOWN | SENT | FAILED. UNKNOWN no crea un segundo mail.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_queued_at IS
  'Cuando mail_id y ambos adjuntos quedaron confirmados antes de push_queue.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_reconciled_at IS
  'Última conciliación del mail_id contra APEX Mail.';

COMMIT;
PROMPT === OK: reconciliacion de correo fiscal ===

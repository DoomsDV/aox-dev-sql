-- Migracion: Fase B Cobros SIPAP - referencia HASEL + snapshot de politica
-- Roadmap Hasel: reserva publica con transferencia (sin Pagopar comercio)

--------------------------------------------------------------------------------
PROMPT === 1. payment_transaction.payment_reference ===
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (payment_reference VARCHAR2(32) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF; -- column already exists
END;
/

BEGIN
  EXECUTE IMMEDIATE
    'CREATE UNIQUE INDEX uq_paytx_payment_reference ON payment_transaction (payment_reference)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN payment_transaction.payment_reference IS
  'Codigo HASEL-XXXXXXXX para asunto SIPAP / conciliacion OCR. Unique cuando no es null.';

--------------------------------------------------------------------------------
PROMPT === 2. appointment policy snapshot ===
--------------------------------------------------------------------------------
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (policy_code_snapshot VARCHAR2(20) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (policy_accepted_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE appointment ADD CONSTRAINT chk_app_policy_snapshot CHECK (
      policy_code_snapshot IS NULL
      OR policy_code_snapshot IN ('FLEXIBLE','MODERATE','STRICT')
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2260, -2275) THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN appointment.policy_code_snapshot IS
  'Politica de reembolso vigente al reservar con seña (FLEXIBLE|MODERATE|STRICT).';

COMMENT ON COLUMN appointment.policy_accepted_at IS
  'Momento en que el cliente acepto la politica en la reserva publica.';

--------------------------------------------------------------------------------
PROMPT === 3. Parametro minutos de hold SIPAP (default 60) ===
--------------------------------------------------------------------------------
MERGE INTO app_parameter t
USING (
  SELECT
    'SIPAP_PAYMENT_PENDING_MINUTES' AS param_key,
    '60' AS param_value,
    'Minutos de vigencia del hold de seña SIPAP antes de expirar.' AS description
  FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value, description)
  VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT === Fase B DDL finalizada ===

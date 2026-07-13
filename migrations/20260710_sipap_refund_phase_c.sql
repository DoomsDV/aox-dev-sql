-- Migracion: Fase C - Reembolso cancelacion cliente
-- Columnas refund_* en appointment + param template WA (envio en C2)

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_status VARCHAR2(20) DEFAULT ''NONE'' NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_amount NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_alias VARCHAR2(100) NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_requested_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_alias_submitted_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_sent_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (refund_marked_by NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment DROP CONSTRAINT chk_app_refund_status';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -2443 THEN RAISE; END IF;
END;
/

ALTER TABLE appointment
  ADD CONSTRAINT chk_app_refund_status CHECK (
    refund_status IN (
      'NONE',
      'NOT_APPLICABLE',
      'AWAITING_ALIAS',
      'PENDING',
      'SENT',
      'WAIVED'
    )
  )
/

COMMENT ON COLUMN appointment.refund_status IS
  'Ciclo de reembolso de seña: NONE|NOT_APPLICABLE|AWAITING_ALIAS|PENDING|SENT|WAIVED. Independiente de appointment.status.';
/

COMMENT ON COLUMN appointment.refund_amount IS
  'Monto a reembolsar (Gs). 100% si cancela el negocio; segun politica snapshot si cancela el cliente.';
/

COMMENT ON COLUMN appointment.refund_alias IS
  'Alias SIPAP del cliente para recibir el reembolso.';
/

COMMENT ON COLUMN appointment.refund_requested_at IS
  'Momento en que se origino el reembolso (cancelacion con monto > 0).';
/

COMMENT ON COLUMN appointment.refund_alias_submitted_at IS
  'Momento en que el cliente cargo el alias. Inicio del SLA 48h habiles (Fase D).';
/

COMMENT ON COLUMN appointment.refund_sent_at IS
  'Momento en que el staff marco el reembolso como enviado.';
/

COMMENT ON COLUMN appointment.refund_marked_by IS
  'user_id del staff que marco SENT.';
/

BEGIN
  EXECUTE IMMEDIATE
    'CREATE INDEX idx_app_org_refund_status ON appointment (org_id_organization, refund_status)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

-- Template WA C2 (solo seed; envio en Fase C2)
MERGE INTO app_parameter t
USING (
    SELECT
        'META_WA_TEMPLATE_REFUND_ALIAS' AS param_key,
        'cancelacion_y_reembolso_v1' AS param_value,
        'Plantilla Meta: cancelacion negocio + pedir alias SIPAP (boton https://hasel.app/r/{{token}}).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);
/

COMMIT;
/

PROMPT === Fase C DDL + META_WA_TEMPLATE_REFUND_ALIAS finalizada ===

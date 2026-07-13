-- Migración: Seña por servicio + Pagopar + auditoría de pagos
-- Ejecutar en producción: docs/DEPLOY_PRODUCTION_CHECKLIST.md (fase 3.2)

PROMPT === 1. Referencia formas de pago Pagopar ===
@@../tables/REF_PAGOPAR_FORMA_PAGO.sql

MERGE INTO ref_pagopar_forma_pago t
USING (
  SELECT 9  AS id_forma_pago, 'BANCARD_CARD' AS code, 'Tarjeta débito/crédito' AS title, 1 AS is_enabled_web, 1 AS sort_order FROM dual UNION ALL
  SELECT 24 AS id_forma_pago, 'PAGO_QR'      AS code, 'Pago QR'                AS title, 1 AS is_enabled_web, 2 AS sort_order FROM dual
) s
ON (t.id_forma_pago = s.id_forma_pago)
WHEN NOT MATCHED THEN
  INSERT (id_forma_pago, code, title, is_enabled_web, sort_order)
  VALUES (s.id_forma_pago, s.code, s.title, s.is_enabled_web, s.sort_order);

COMMIT;

PROMPT === 2. Columnas de seña en service ===
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD (requires_deposit NUMBER(1,0) DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD (deposit_type VARCHAR2(10) NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD (deposit_value NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD CONSTRAINT chk_ser_requires_deposit CHECK (requires_deposit IN (0, 1))';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2275) THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE service ADD CONSTRAINT chk_ser_deposit_type CHECK (deposit_type IS NULL OR deposit_type IN (''PERCENT'', ''FIXED''))';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2275) THEN RAISE; END IF;
END;
/

UPDATE service SET requires_deposit = 0 WHERE requires_deposit IS NULL;
COMMIT;

PROMPT === 3. Columnas de pago en appointment ===
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (payment_status VARCHAR2(20) DEFAULT ''NONE'' NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (deposit_amount NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (pagopar_hash VARCHAR2(128) NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (payment_expires_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (paid_at TIMESTAMP(6) WITH TIME ZONE NULL)';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

UPDATE appointment SET payment_status = 'NONE' WHERE payment_status IS NULL OR payment_status = 'PENDING';
COMMIT;

BEGIN
  EXECUTE IMMEDIATE '
    ALTER TABLE appointment ADD CONSTRAINT chk_app_payment_status CHECK (
      payment_status IN (
        ''NONE'', ''PENDING'', ''PAID'', ''PAID_TRANSFER'', ''PAID_CASH'',
        ''EXEMPT'', ''EXPIRED'', ''FAILED''
      )
    )';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2275) THEN RAISE; END IF;
END;
/

PROMPT === 4. Tablas org_integration y payment_transaction ===
@@../tables/ORG_INTEGRATION.sql
@@../tables/PAYMENT_TRANSACTION.sql

PROMPT === 5. Parámetros opcionales Pagopar (ajustar URLs en producción) ===
MERGE INTO app_parameter t
USING (
  SELECT 'PAGOPAR_API_INICIAR_URL' AS param_key, 'https://api.pagopar.com/api/comercios/2.0/iniciar-transaccion' AS param_value FROM dual UNION ALL
  SELECT 'PAGOPAR_CHECKOUT_BASE_URL' AS param_key, 'https://www.pagopar.com/pagos/' AS param_value FROM dual UNION ALL
  SELECT 'PAGOPAR_API_PEDIDOS_URL' AS param_key, 'https://api.pagopar.com/api/pedidos/1.1/traer' AS param_value FROM dual UNION ALL
  SELECT 'PAYMENT_PENDING_MINUTES' AS param_key, '15' AS param_value FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
  INSERT (param_key, param_value) VALUES (s.param_key, s.param_value);

COMMIT;

PROMPT === 6. Recompilar paquetes ===
@@../packages/PKG_AOX_ORG_INTEGRATION_API.pls
@@../packages/PKG_AOX_PAGOPAR_API.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls
@@../packages/PKG_AOX_APPOINTMENT_API.pls

PROMPT === Migración Pagopar finalizada ===

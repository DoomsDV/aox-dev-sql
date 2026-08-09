-- Framework generico de Idempotency-Key (estilo Stripe): tabla + soporte en
-- PKG_AOX_UTIL (pr_idempotency_begin/complete/release). Ver plan
-- "Idempotencia raiz pagos y reservas". Objetivo inmediato: eliminar el
-- riesgo de doble cobro en pr_charge_target (checkout/activate/billing cycle).

PROMPT === 20260809_idempotency_key_framework ===

BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE TABLE api_idempotency_key (
            scope_code            VARCHAR2(64)  NOT NULL,
            idem_key              VARCHAR2(255) NOT NULL,
            request_hash          VARCHAR2(64)  NOT NULL,
            status                VARCHAR2(20)  DEFAULT 'IN_PROGRESS' NOT NULL,
            response_status_code  NUMBER,
            response_payload      CLOB,
            created_at            TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
            completed_at          TIMESTAMP WITH TIME ZONE,
            expires_at            TIMESTAMP WITH TIME ZONE NOT NULL,
            CONSTRAINT pk_api_idempotency_key PRIMARY KEY (scope_code, idem_key),
            CONSTRAINT ck_api_idempotency_status CHECK (status IN ('IN_PROGRESS', 'COMPLETED'))
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE INDEX ix_api_idempotency_expires
            ON api_idempotency_key (expires_at)
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        COMMENT ON TABLE api_idempotency_key IS
          'Framework generico de Idempotency-Key: dedupe de reintentos de operaciones mutantes por scope+key. status=IN_PROGRESS mientras se procesa; COMPLETED guarda response_status_code/response_payload para replay exacto en reintentos.'
    ]';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

PROMPT === 20260809_idempotency_key_framework done ===

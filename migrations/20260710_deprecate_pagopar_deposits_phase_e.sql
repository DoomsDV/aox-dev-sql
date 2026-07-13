-- Fase E: Deprecar Pagopar de senas (solo SIPAP).
-- - Job de expiracion apunta a PKG_AOX_PAYMENTS_API
-- - Defaults de payment_transaction alineados a SIPAP
-- - Endpoints legacy /public/payments y /pagopar/respuesta siguen registrados
--   pero PKG_AOX_PAGOPAR_API responde HTTP 410 (GONE).
-- NO toca: /pagopar/v1/subscription/webhook ni billing de suscripcion.

PROMPT === Fase E: deprecar Pagopar senas ===

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE payment_transaction MODIFY (
            provider DEFAULT 'sipap',
            payment_channel DEFAULT 'TRANSFER'
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-1442, -1451) THEN
            RAISE;
        END IF;
END;
/

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_EXPIRE_PENDING_PAYMENTS', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_EXPIRE_PENDING_PAYMENTS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_payments_api.pr_expire_pending_payments; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=2',
        enabled         => TRUE,
        comments        => 'Expira holds SIPAP (y legacy Pagopar) con payment_expires_at vencido'
    );
    COMMIT;
END;
/

PROMPT Fase E migration OK. Recompilar packages:
PROMPT   PKG_AOX_PAYMENT_SETTINGS_API, PKG_AOX_PAYMENTS_API, PKG_AOX_PAGOPAR_API,
PROMPT   PKG_AOX_ORG_INTEGRATION_API, PKG_AOX_PUBLIC_BOOKING_API, PKG_AOX_APPOINTMENT_API
/

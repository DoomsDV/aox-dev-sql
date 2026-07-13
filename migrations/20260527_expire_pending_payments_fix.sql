-- Expiración de holds de seña (incluye pagopar_hash NULL tras error en iniciar-transaccion).
-- Ejecutar en el esquema de la app (ej. HASEL) después de recompilar PKG_AOX_PAGOPAR_API.

PROMPT === 1) Limpieza única: citas PENDING vencidas (hold web / Pagopar no completado) ===

DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR rec IN (
        SELECT a.id_appointment, a.org_id_organization, a.deposit_amount, a.pagopar_hash
          FROM appointment a
         WHERE a.payment_status = 'PENDING'
           AND a.payment_expires_at IS NOT NULL
           AND a.payment_expires_at < CURRENT_TIMESTAMP
           AND a.status = 'PENDIENTE'
    ) LOOP
        UPDATE appointment
           SET payment_status = 'EXPIRED',
               status = 'CANCELADO',
               updated_at = CURRENT_TIMESTAMP
         WHERE id_appointment = rec.id_appointment
           AND payment_status = 'PENDING';

        IF SQL%ROWCOUNT > 0 THEN
            v_count := v_count + 1;

            UPDATE payment_transaction
               SET payment_status = 'EXPIRED',
                   processed_at = CURRENT_TIMESTAMP
             WHERE app_id_appointment = rec.id_appointment
               AND provider = 'pagopar'
               AND payment_status = 'PENDING';

            BEGIN
                INSERT INTO payment_transaction (
                    org_id_organization, app_id_appointment, provider, external_reference,
                    id_pedido_comercio, idempotency_key, amount, payment_status,
                    payment_channel, source, processed_at
                ) VALUES (
                    rec.org_id_organization, rec.id_appointment, 'pagopar', rec.pagopar_hash,
                    'EXP-' || rec.id_appointment, 'EXPIRE:' || rec.id_appointment,
                    NVL(rec.deposit_amount, 0), 'EXPIRED', 'PAGOPAR', 'EXPIRE_JOB', CURRENT_TIMESTAMP
                );
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN NULL;
            END;
        END IF;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Citas expiradas en limpieza: ' || v_count);
END;
/

PROMPT === 2) Job recurrente DBMS_SCHEDULER (cada 2 minutos) ===

BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_EXPIRE_PENDING_PAYMENTS', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_EXPIRE_PENDING_PAYMENTS',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PKG_AOX_PAGOPAR_API.PR_EXPIRE_PENDING_PAYMENTS',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=2',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Cancela reservas PENDIENTE con seña no pagada tras payment_expires_at'
    );
END;
/

PROMPT === Verificar job ===
-- SELECT job_name, enabled, state, last_start_date, next_run_date
--   FROM user_scheduler_jobs
--  WHERE job_name = 'HASEL_EXPIRE_PENDING_PAYMENTS';

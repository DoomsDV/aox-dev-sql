-- Migracion: Job de cobro recurrente de suscripcion (SOLO PRODUCCION)
-- Plan: pagopar_recurrente_suscripcion
--
-- IMPORTANTE: este script NO se ejecuta en DEV (aoxdev). Queda registrado en el repo
-- para crear el job recien al pasar a produccion. En DEV el cobro se dispara a mano
-- (pr_activate_subscription) o llamando pr_run_billing_cycle puntualmente.
--
-- El job corre DIARIO a las 03:00 hora America/Asuncion y delega en
-- PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE (cobro + dunning).
-- El paso a PAST_DUE (3 dias de gracia) -> READ_ONLY lo deriva
-- PKG_AOX_SUBSCRIPTION_API.FN_GET_SUBSCRIPTION_STATE a partir de current_period_end.

PROMPT === Crear job HASEL_SUBSCRIPTION_BILLING_CYCLE (ejecutar SOLO en produccion) ===
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_SUBSCRIPTION_BILLING_CYCLE', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_SUBSCRIPTION_BILLING_CYCLE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_subscription_billing_api.pr_run_billing_cycle; END;',
        start_date      => TO_TIMESTAMP_TZ('2026-01-01 03:00:00 America/Asuncion', 'YYYY-MM-DD HH24:MI:SS TZR'),
        repeat_interval => 'FREQ=DAILY; BYHOUR=3; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Cobro mensual recurrente de suscripcion Hasel (Pagopar pago-recurrente) + dunning. Corre 03:00 hora Paraguay.'
    );
    COMMIT;
END;
/

PROMPT === Job HASEL_SUBSCRIPTION_BILLING_CYCLE creado ===

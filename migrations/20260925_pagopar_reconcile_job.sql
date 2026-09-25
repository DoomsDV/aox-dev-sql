-- Reconciliación de pedidos Pagopar de suscripción (paso 3 de Pagopar: consultar estado).
--
-- Si la notificación de Pagopar no llega (URL mal cargada, caída del ORDS, etc.), la
-- factura queda PENDING aunque el cobro se haya aprobado. El job consulta
-- pedidos/1.1/traer para las facturas PENDING con pedido de más de 10 minutos y, si
-- Pagopar las da por pagadas, las confirma por el mismo camino que el webhook
-- (PAID + FE + mail), con la misma guarda de lote bloqueado: no duplica nada.
--
-- Idempotente: recompila el paquete y recrea el job.

PROMPT === Paquete billing (pr_reconcile_pagopar_pending) ===
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

PROMPT === Job HASEL_PAGOPAR_RECONCILE (cada 10 min) ===
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_PAGOPAR_RECONCILE', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_PAGOPAR_RECONCILE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_subscription_billing_api.pr_reconcile_pagopar_pending(pi_min_age_minutes => 10, pi_limit => 20); END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=10',
        enabled         => TRUE,
        comments        => 'Confirma facturas Pagopar PENDING cuyo pedido ya figura pagado (notificacion perdida)'
    );
END;
/

PROMPT === Job HASEL_PAGOPAR_RECONCILE registrado ===

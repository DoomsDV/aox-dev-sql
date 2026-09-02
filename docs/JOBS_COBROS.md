# Jobs de Cobros / disputas (DEV y prod)

## `HASEL_REFUND_DISPUTE_CHECK`

Corre cada 15 minutos:

```sql
BEGIN
    pkg_aox_refund_disputes_api.pr_process_dispute_timeouts(100);
    pkg_aox_refund_disputes_api.pr_process_notify_outbox(50);
END;
```

- Timeouts/strikes: `pr_process_dispute_timeouts` (commit por fila).
- Campanita de disputa: `pr_process_notify_outbox` lee `org_refund_notify_outbox`.

### ORA-02014 (arreglado 2026-09-02)

`FETCH FIRST n ROWS ONLY FOR UPDATE SKIP LOCKED` sobre la tabla de outbox fallaba el 100% de las corridas (`ORA-02014`). El `SELECT` ahora limita con subconsulta + `ROWNUM` y aplica `FOR UPDATE SKIP LOCKED` sobre la tabla base.

### Cómo chequear salud

```sql
SELECT job_name, enabled, state, run_count, failure_count,
       last_start_date, next_run_date
  FROM user_scheduler_jobs
 WHERE job_name IN (
        'HASEL_REFUND_DISPUTE_CHECK',
        'HASEL_EXPIRE_PENDING_PAYMENTS'
       );

SELECT log_date, status, error#, additional_info
  FROM user_scheduler_job_run_details
 WHERE job_name = 'HASEL_REFUND_DISPUTE_CHECK'
 ORDER BY log_date DESC
 FETCH FIRST 10 ROWS ONLY;

SELECT status, COUNT(*)
  FROM org_refund_notify_outbox
 GROUP BY status;
```

Si `failure_count` crece en cada corrida, el job no está entregando notificaciones. Tras un arreglo de código, la siguiente corrida OK suele resetear el contador; si no, deshabilitar/habilitar el job.

```sql
BEGIN
    DBMS_SCHEDULER.disable('HASEL_REFUND_DISPUTE_CHECK');
    DBMS_SCHEDULER.enable('HASEL_REFUND_DISPUTE_CHECK');
END;
/
```

No hay alerta automática hoy: este query es el monitoreo mínimo antes de un pase a producción.

# Jobs de Cobros / disputas (DEV y prod)

## `HASEL_REFUND_DISPUTE_CHECK`

Corre cada 15 minutos como red de seguridad:

```sql
BEGIN
    pkg_aox_refund_disputes_api.pr_process_dispute_timeouts(100);
    pkg_aox_refund_disputes_api.pr_process_notify_outbox(50);
END;
```

- Timeouts/strikes: `pr_process_dispute_timeouts` (commit por fila).
- `DISPUTE_OPENED` y `CUSTOMER_INSISTED` intentan entregar campanita + FCM
  inmediatamente después del commit del request público.
- `OPS_REVIEW_OVERDUE` se encola desde el job.
- `pr_process_notify_outbox` procesa los pendientes y los `PROCESSING`
  stale (lease de 5 minutos); es el camino de reintento, no el camino feliz.
- `notified` en la API publica = campanita durable creada; `notification_queued=1`
  indica que FCM sigue pendiente o en curso en otro worker.

### ORA-02014 (arreglado 2026-09-02)

`FETCH FIRST n ROWS ONLY FOR UPDATE SKIP LOCKED` sobre la tabla de outbox fallaba el 100% de las corridas (`ORA-02014`). El `SELECT` ahora limita con subconsulta + `ROWNUM` y aplica `FOR UPDATE SKIP LOCKED` sobre la tabla base.

### ORA-01002 (arreglado 2026-09-04)

No usar `COMMIT` dentro de un `FOR rec IN (SELECT ... FOR UPDATE ...)`.
El fetch implícito queda inválido después del primer commit y el siguiente
registro puede fallar con `ORA-01002: fetch out of sequence`. El worker primero
captura los IDs con `BULK COLLECT`, cierra el cursor y recién después procesa
cada fila con commit independiente.

Los errores de campanita o respuestas HTTP no-2xx de FCM dejan la fila
reintentable (`PENDING`) hasta agotar ocho intentos. Una campanita ya existente
por `dedupe_key` no se duplica; los pushes fallidos se vuelven a intentar.

`PROCESSING` fresco no se reclama dos veces: `processing_started_at` actua como
lease y solo filas stale (>5 min) vuelven al worker. Los intentos suben al fallar,
no al reclamar la fila.

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

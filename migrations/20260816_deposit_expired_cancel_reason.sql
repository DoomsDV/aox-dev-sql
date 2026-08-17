-- Seña vencida: persistir motivo DEPOSIT_EXPIRED y alinear refund_status.
-- Backfill de holds expirados por EXPIRE_JOB (cancel_reason NULL).

PROMPT === 1. Backfill appointment.cancel_reason = DEPOSIT_EXPIRED ===
UPDATE /*+ no_parallel */ appointment a
   SET a.cancel_reason = 'DEPOSIT_EXPIRED',
       a.refund_status = CASE
           WHEN a.refund_status = 'NONE' THEN 'NOT_APPLICABLE'
           ELSE a.refund_status
       END
 WHERE a.status = 'CANCELADO'
   AND a.payment_status = 'EXPIRED'
   AND a.cancel_reason IS NULL
   AND EXISTS (
       SELECT 1
         FROM payment_transaction pt
        WHERE pt.app_id_appointment = a.id_appointment
          AND pt.source = 'EXPIRE_JOB'
   );

COMMIT;

PROMPT === 2. Packages ===
@@../packages/PKG_AOX_PAYMENTS_API.pls
@@../packages/PKG_AOX_APPOINTMENT_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === deposit_expired cancel_reason finalizada ===

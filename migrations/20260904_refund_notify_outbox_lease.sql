-- Lease de processing para org_refund_notify_outbox (evita doble entrega y huérfanos).

PROMPT === org_refund_notify_outbox.processing_started_at ===
DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_count
      FROM user_tab_columns
     WHERE table_name = 'ORG_REFUND_NOTIFY_OUTBOX'
       AND column_name = 'PROCESSING_STARTED_AT';

    IF v_count = 0 THEN
        EXECUTE IMMEDIATE q'[
            ALTER TABLE org_refund_notify_outbox
              ADD (processing_started_at TIMESTAMP(6) WITH TIME ZONE)
        ]';
    END IF;
END;
/

COMMENT ON COLUMN org_refund_notify_outbox.processing_started_at IS
  'Timestamp del ultimo reclamo a PROCESSING; usado para recuperar filas stale sin doble entrega.';

PROMPT === idx_refund_notify_processing ===
BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE INDEX idx_refund_notify_processing
          ON org_refund_notify_outbox (status, processing_started_at, created_at)
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN
            RAISE;
        END IF;
END;
/

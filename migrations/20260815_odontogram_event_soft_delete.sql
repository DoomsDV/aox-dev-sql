-- Soft delete de hallazgos del odontograma (auditoria clinica).
-- Nunca DELETE FROM customer_odontogram_event.

DECLARE
    v_exists NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_exists
      FROM user_tab_columns
     WHERE table_name = 'CUSTOMER_ODONTOGRAM_EVENT'
       AND column_name = 'DELETED_AT';

    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE
            'ALTER TABLE customer_odontogram_event ADD (
                deleted_at      TIMESTAMP(6) WITH TIME ZONE NULL,
                deleted_by_user NUMBER NULL
            )';
    END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE
        'CREATE INDEX idx_odoevt_org_cus_active
            ON customer_odontogram_event (
                org_id_organization,
                cus_id_customer,
                deleted_at,
                created_at
            )';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -955 THEN
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN customer_odontogram_event.deleted_at IS 'Soft delete. NULL = activo. Nunca se borra la fila.';
COMMENT ON COLUMN customer_odontogram_event.deleted_by_user IS 'platform_user_id del JWT que anulo el hallazgo.';

COMMIT;

PROMPT OK: odontogram event soft delete

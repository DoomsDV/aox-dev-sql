-- Facturacion consolidada: FK opcional al addon en la factura
-- (permite prorrateo sin resolver el addon por monto).

PROMPT === org_subscription_invoice.sad_id_storage_addon ===

DECLARE
    v_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_exists
      FROM user_tab_columns
     WHERE table_name = 'ORG_SUBSCRIPTION_INVOICE'
       AND column_name = 'SAD_ID_STORAGE_ADDON';
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE
            'ALTER TABLE org_subscription_invoice ADD (sad_id_storage_addon NUMBER NULL)';
    END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE
        'ALTER TABLE org_subscription_invoice ADD CONSTRAINT fk_orginv_storage_addon
         FOREIGN KEY (sad_id_storage_addon) REFERENCES ref_storage_addon (id_storage_addon)';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2275, -2260) THEN -- already exists
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN org_subscription_invoice.sad_id_storage_addon IS
  'Addon de storage asociado (facturas STORAGE_ADDON prorrateadas o mid-cycle).';

COMMIT;

PROMPT OK: sad_id_storage_addon

-- Comprobantes SIPAP cuentan en storage_used_bytes
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE payment_transaction ADD (receipt_size_bytes NUMBER DEFAULT 0 NOT NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN payment_transaction.receipt_size_bytes IS
  'Tamano del comprobante SIPAP (imagen/PDF) en bytes; suma a storage_used_bytes de la org.';

COMMIT;

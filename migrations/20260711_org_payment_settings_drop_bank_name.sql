-- Elimina bank_name denormalizado; el nombre se obtiene por JOIN a ref_sipap_bank.
PROMPT === Migration 20260711_org_payment_settings_drop_bank_name ===

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings DROP COLUMN bank_name';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE IN (-904, -00904) THEN NULL; ELSE RAISE; END IF;
END;
/

PROMPT === Migration 20260711_org_payment_settings_drop_bank_name done ===
/

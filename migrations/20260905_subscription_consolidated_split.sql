-- FE por componente: N invoices por ciclo CONSOLIDATED + org_addon_id en NCE (Fase 2 módulos).
-- Paquete: PKG_AOX_SUBSCRIPTION_BILLING_API (pr_charge_consolidated_cycle, pr_fulfill_invoice_batch).

SET SERVEROUTPUT ON

DECLARE
    PROCEDURE add_col(p_sql VARCHAR2, p_col VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        DBMS_OUTPUT.PUT_LINE('OK: ' || p_col);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -1430 THEN
                DBMS_OUTPUT.PUT_LINE('SKIP (exists): ' || p_col);
            ELSE
                RAISE;
            END IF;
    END add_col;
BEGIN
    add_col(
        'ALTER TABLE subscription_credit_note ADD (org_addon_id NUMBER NULL)',
        'SUBSCRIPTION_CREDIT_NOTE.ORG_ADDON_ID'
    );
END;
/

COMMENT ON COLUMN subscription_credit_note.org_addon_id IS
  'Fila org_addon cancelada cuando la NCE es por MODULE_ADDON.';

PROMPT === OK: 20260905_subscription_consolidated_split ===

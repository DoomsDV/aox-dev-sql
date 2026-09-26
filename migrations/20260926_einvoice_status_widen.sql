-- ORG_SUBSCRIPTION_INVOICE.EINVOICE_STATUS a VARCHAR2(30).
-- tables/ORG_SUBSCRIPTION_INVOICE.sql ya la declara de 30, pero ninguna migracion la
-- agrandaba: en prod quedo en 20 y 'SENT_PENDING_ARTIFACTS' (22) daria ORA-12899
-- al aprobarse una FE. Como AOXDEV / WKSP_AOX. Idempotente (agrandar no pierde datos).

DECLARE
    v_len NUMBER;
BEGIN
    SELECT char_length INTO v_len
      FROM user_tab_columns
     WHERE table_name = 'ORG_SUBSCRIPTION_INVOICE'
       AND column_name = 'EINVOICE_STATUS';
    IF v_len < 30 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE org_subscription_invoice MODIFY (einvoice_status VARCHAR2(30))';
        DBMS_OUTPUT.PUT_LINE('EINVOICE_STATUS ' || v_len || ' -> 30');
    ELSE
        DBMS_OUTPUT.PUT_LINE('EINVOICE_STATUS ya es ' || v_len);
    END IF;
END;
/

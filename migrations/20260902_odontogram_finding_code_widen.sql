-- Ampliar FINDING_CODE de eventos al ancho del catalogo (VARCHAR2(40)).
-- Bases migradas desde 20260814 quedaron en VARCHAR2(20); DEFECTIVE_RESTORATION (21) no entra.

DECLARE
    v_len NUMBER;
BEGIN
    SELECT data_length
      INTO v_len
      FROM user_tab_columns
     WHERE table_name = 'CUSTOMER_ODONTOGRAM_EVENT'
       AND column_name = 'FINDING_CODE';

    IF v_len < 40 THEN
        EXECUTE IMMEDIATE
            'ALTER TABLE customer_odontogram_event MODIFY finding_code VARCHAR2(40)';
    END IF;
END;
/

COMMIT;

PROMPT OK: odontogram event finding_code VARCHAR2(40)

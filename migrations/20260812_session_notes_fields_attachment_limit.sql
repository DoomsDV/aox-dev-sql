-- Notas de sesion estructuradas (3 campos CLOB) + limite de 10 adjuntos por cita.
-- Requiere redeploy de PKG_AOX_APPOINTMENT_API y PKG_AOX_CUSTOMER_API.

PROMPT === 20260812_session_notes_fields_attachment_limit ===

DECLARE
    PROCEDURE add_col(pi_ddl IN VARCHAR2, pi_column IN VARCHAR2) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
          FROM user_tab_columns
         WHERE table_name = 'APPOINTMENT_SESSION_RECORD'
           AND column_name = pi_column;
        IF v_count = 0 THEN
            EXECUTE IMMEDIATE pi_ddl;
        END IF;
    END add_col;
BEGIN
    add_col('ALTER TABLE appointment_session_record ADD (consultation_reason CLOB NULL)', 'CONSULTATION_REASON');
    add_col('ALTER TABLE appointment_session_record ADD (procedure_notes CLOB NULL)', 'PROCEDURE_NOTES');
    add_col('ALTER TABLE appointment_session_record ADD (recommendations CLOB NULL)', 'RECOMMENDATIONS');
END;
/

UPDATE appointment_session_record
   SET procedure_notes = notes
 WHERE notes IS NOT NULL
   AND procedure_notes IS NULL;

COMMIT;

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'ATTACHMENT_MAX_COUNT' AS param_key,
               '10' AS param_value,
               'Maximo de adjuntos por cita en historial de sesion' AS description
          FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260812_session_notes_fields_attachment_limit done ===

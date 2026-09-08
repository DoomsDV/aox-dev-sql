-- Encuestas CSAT post-cita (WhatsApp Flow): columnas, toggle org, params Meta, job.
-- Requiere compilar PKG_AOX_META_API, PKG_AOX_APPOINTMENT_API, PKG_AOX_WORKSPACE_API,
-- PKG_AOX_CUSTOMER_API y migración ORDS 20260908_appointment_survey_ords.sql.

PROMPT === 1) appointment.survey_* ===
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_status VARCHAR2(20) DEFAULT ''NONE'' NOT NULL)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_due_at TIMESTAMP(6) WITH TIME ZONE)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_sent_at TIMESTAMP(6) WITH TIME ZONE)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_replied_at TIMESTAMP(6) WITH TIME ZONE)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_source VARCHAR2(20))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_sent_by NUMBER)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_score NUMBER(1))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_comment VARCHAR2(400))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE appointment ADD (survey_flow_token VARCHAR2(80))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE appointment ADD CONSTRAINT chk_app_survey_status CHECK (
            survey_status IN ('NONE', 'NOT_SENT', 'SENT', 'COMPLETED', 'SKIPPED')
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2261) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE appointment ADD CONSTRAINT chk_app_survey_source CHECK (
            survey_source IS NULL OR survey_source IN ('AUTOMATIC', 'MANUAL')
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2261) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE appointment ADD CONSTRAINT chk_app_survey_score CHECK (
            survey_score IS NULL OR survey_score BETWEEN 1 AND 5
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2261) THEN RAISE; END IF;
END;
/

COMMENT ON COLUMN appointment.survey_status IS 'Ciclo encuesta CSAT: NONE|NOT_SENT|SENT|COMPLETED|SKIPPED.';
/

PROMPT === 2) workspace_setting.survey_auto_enabled ===
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE workspace_setting ADD (survey_auto_enabled NUMBER(1) DEFAULT 0 NOT NULL)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF; END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE workspace_setting ADD CONSTRAINT chk_ws_survey_auto_enabled CHECK (
            survey_auto_enabled IN (0, 1)
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2261) THEN RAISE; END IF;
END;
/

PROMPT === 3) Índice job encuestas ===
BEGIN
    EXECUTE IMMEDIATE q'[
        CREATE INDEX idx_app_survey_due
          ON appointment (
            survey_status,
            SYS_EXTRACT_UTC(survey_due_at)
          )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

PROMPT === 4) Parámetros Meta encuesta ===
MERGE INTO app_parameter t
USING (
    SELECT 'META_WA_TEMPLATE_SURVEY' AS param_key,
           'encuesta_satisfaccion_hasel_v1' AS param_value,
           'Plantilla UTILITY con botón FLOW para encuesta CSAT post-cita.' AS description
      FROM dual
    UNION ALL
    SELECT 'META_WA_FLOW_SURVEY',
           '1047139264900441',
           'Flow ID publicado encuesta_satisfaccion_flow (aoxdev).'
      FROM dual
    UNION ALL
    SELECT 'META_SURVEY_START_HOUR', '9', 'Hora inicio envío encuestas (quiet hours).' FROM dual
    UNION ALL
    SELECT 'META_SURVEY_END_HOUR', '21', 'Hora fin envío encuestas (quiet hours).' FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET t.param_value = s.param_value, t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT === 5) Job HASEL_PROCESS_SURVEY_REQUESTS ===
BEGIN
    BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => 'HASEL_PROCESS_SURVEY_REQUESTS', force => TRUE);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'HASEL_PROCESS_SURVEY_REQUESTS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN pkg_aox_meta_api.pr_process_survey_requests; END;',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY; INTERVAL=5',
        enabled         => TRUE,
        comments        => 'Encuestas CSAT: envía WhatsApp Flow post-cita (fin+2h, quiet 9-21).'
    );
    COMMIT;
END;
/

PROMPT === 20260908_appointment_survey done ===

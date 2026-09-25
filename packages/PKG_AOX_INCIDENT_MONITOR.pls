PROMPT CREATE OR REPLACE PACKAGE pkg_aox_incident_monitor
CREATE OR REPLACE PACKAGE pkg_aox_incident_monitor IS

    /**
     * Monitor de incidentes: agrupa por huella los errores inesperados de
     * aox_api_log (HTTP 5xx o ERROR sin status_code) en aox_incident y avisa
     * por WhatsApp a OPS_ALERT_PHONE. Lo invoca el job HASEL_INCIDENT_MONITOR
     * via pkg_aox_job_wrapper.
     */

    -- Procesa los errores nuevos de la ventana y envia los avisos pendientes.
    PROCEDURE pr_run (
        pi_lookback_minutes IN NUMBER DEFAULT 120,
        pi_max_alerts       IN NUMBER DEFAULT 5
    );

    -- Envia el aviso de un incidente ya registrado (tambien sirve para probar el canal).
    PROCEDURE pr_send_alert (
        pi_incident_id IN aox_incident.id_incident%TYPE
    );

    -- Marca el incidente como resuelto; si vuelve a ocurrir se reabre y avisa.
    PROCEDURE pr_resolve (
        pi_incident_id IN aox_incident.id_incident%TYPE,
        pi_note        IN VARCHAR2 DEFAULT NULL
    );

    -- Silencia un incidente conocido: sigue contando ocurrencias pero no avisa.
    PROCEDURE pr_ignore (
        pi_incident_id IN aox_incident.id_incident%TYPE,
        pi_note        IN VARCHAR2 DEFAULT NULL
    );

END pkg_aox_incident_monitor;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_incident_monitor
CREATE OR REPLACE PACKAGE BODY pkg_aox_incident_monitor IS

    c_time_zone CONSTANT VARCHAR2(30) := 'America/Asuncion';

    FUNCTION fn_env_label RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(
            fn_get_parameter('OPS_ALERT_ENV'),
            CASE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') WHEN 'WKSP_AOX' THEN 'PROD' ELSE 'DEV' END
        );
    END fn_env_label;

    -- Primera linea del error sin literales ni numeros sueltos, para que el mismo
    -- fallo con distintos ids o telefonos caiga en la misma huella.
    FUNCTION fn_normalize_error (
        pi_message IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_message VARCHAR2(4000);
    BEGIN
        v_message := REGEXP_SUBSTR(pi_message, '^[^' || CHR(10) || ']*');
        v_message := REGEXP_REPLACE(v_message, '''[^'']*''', '''?''');
        v_message := REGEXP_REPLACE(v_message, '(^|[^[:alnum:]_-])[0-9]+', '\1#');
        RETURN SUBSTR(TRIM(v_message), 1, 1000);
    END fn_normalize_error;

    FUNCTION fn_org_summary (
        pi_incident_id IN aox_incident.id_incident%TYPE
    ) RETURN VARCHAR2 IS
        v_total NUMBER;
        v_names VARCHAR2(400);
    BEGIN
        SELECT COUNT(DISTINCT org_id)
          INTO v_total
          FROM aox_incident_event
         WHERE id_incident = pi_incident_id
           AND org_id IS NOT NULL;

        IF v_total = 0 THEN
            RETURN 'Ninguna';
        END IF;

        SELECT LISTAGG(org_name, ', ') WITHIN GROUP (ORDER BY org_name)
          INTO v_names
          FROM (
                SELECT DISTINCT NVL(o.name, 'Org ' || e.org_id) org_name
                  FROM aox_incident_event e
                  LEFT JOIN organization o
                    ON o.id_organization = e.org_id
                 WHERE e.id_incident = pi_incident_id
                   AND e.org_id IS NOT NULL
                 FETCH FIRST 3 ROWS ONLY
               );

        RETURN v_names || CASE WHEN v_total > 3 THEN ' y ' || (v_total - 3) || ' mas' END;
    END fn_org_summary;

    PROCEDURE pr_register_event (
        pi_id_log        IN aox_api_log.id_log%TYPE,
        pi_occurred_at   IN aox_api_log.created_at%TYPE,
        pi_org_id        IN aox_api_log.org_id%TYPE,
        pi_api_name      IN aox_api_log.api_name%TYPE,
        pi_process_name  IN aox_api_log.process_name%TYPE,
        pi_error_code    IN aox_api_log.error_code%TYPE,
        pi_status_code   IN aox_api_log.status_code%TYPE,
        pi_error_message IN aox_api_log.error_message%TYPE
    ) IS
        v_sample      aox_incident.error_sample%TYPE;
        v_fingerprint aox_incident.fingerprint%TYPE;
        v_incident_id aox_incident.id_incident%TYPE;
    BEGIN
        v_sample := fn_normalize_error(
            NVL(pi_error_message, 'HTTP ' || NVL(TO_CHAR(pi_status_code), '?') || ' codigo ' || NVL(TO_CHAR(pi_error_code), '?'))
        );

        SELECT RAWTOHEX(STANDARD_HASH(NVL(pi_api_name, '-') || '|' || NVL(pi_process_name, '-') || '|' || v_sample, 'SHA256'))
          INTO v_fingerprint
          FROM dual;

        BEGIN
            SELECT id_incident
              INTO v_incident_id
              FROM aox_incident
             WHERE fingerprint = v_fingerprint
               FOR UPDATE;

            -- Un incidente resuelto que vuelve a ocurrir se reabre y avisa sin esperar el cooldown.
            UPDATE aox_incident
               SET occurrences     = occurrences + 1,
                   last_seen_at    = GREATEST(last_seen_at, pi_occurred_at),
                   last_attempt_at = CASE status WHEN 'RESOLVED' THEN NULL ELSE last_attempt_at END,
                   resolved_at     = CASE status WHEN 'RESOLVED' THEN NULL ELSE resolved_at END,
                   status          = CASE status WHEN 'RESOLVED' THEN 'OPEN' ELSE status END
             WHERE id_incident = v_incident_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                INSERT INTO aox_incident (
                    fingerprint,
                    api_name,
                    process_name,
                    error_code,
                    error_sample,
                    first_seen_at,
                    last_seen_at,
                    occurrences
                )
                VALUES (
                    v_fingerprint,
                    pi_api_name,
                    pi_process_name,
                    pi_error_code,
                    v_sample,
                    pi_occurred_at,
                    pi_occurred_at,
                    1
                )
                RETURNING id_incident INTO v_incident_id;
        END;

        INSERT INTO aox_incident_event (
            id_log,
            id_incident,
            org_id,
            occurred_at
        )
        VALUES (
            pi_id_log,
            v_incident_id,
            pi_org_id,
            pi_occurred_at
        );
    END pr_register_event;

    PROCEDURE pr_send_alert (
        pi_incident_id IN aox_incident.id_incident%TYPE
    ) IS
        v_incident    aox_incident%ROWTYPE;
        v_phone       app_parameter.param_value%TYPE := fn_get_parameter('OPS_ALERT_PHONE');
        v_template    app_parameter.param_value%TYPE := TRIM(fn_get_parameter('META_WA_TEMPLATE_OPS_ALERT'));
        v_env         VARCHAR2(30)  := fn_env_label;
        v_error       VARCHAR2(200);
        v_process     VARCHAR2(200);
        v_orgs        VARCHAR2(400);
        v_first_seen  VARCHAR2(30);
    BEGIN
        IF v_phone IS NULL THEN
            RAISE_APPLICATION_ERROR(-20901, 'Falta el parametro OPS_ALERT_PHONE.');
        END IF;

        SELECT *
          INTO v_incident
          FROM aox_incident
         WHERE id_incident = pi_incident_id;

        -- El intento cuenta aunque Meta falle, para no reintentar en cada corrida del job.
        UPDATE aox_incident
           SET last_attempt_at = SYSTIMESTAMP
         WHERE id_incident = pi_incident_id;
        COMMIT;

        v_error := CASE
                       WHEN LENGTH(v_incident.error_sample) > 160 THEN SUBSTR(v_incident.error_sample, 1, 157) || '...'
                       ELSE v_incident.error_sample
                   END;
        v_process    := NVL(v_incident.api_name, NVL(v_incident.process_name, '-'));
        v_orgs       := fn_org_summary(pi_incident_id);
        v_first_seen := TO_CHAR(v_incident.first_seen_at AT TIME ZONE c_time_zone, 'DD/MM/YYYY HH24:MI');

        IF v_template IS NOT NULL THEN
            pkg_aox_meta_api.pr_send_template_wa(
                pi_phone_number  => v_phone,
                pi_template_name => v_template,
                pi_body_params   => apex_t_varchar2(
                    v_env,
                    v_error,
                    v_process,
                    v_orgs,
                    TO_CHAR(v_incident.occurrences),
                    v_first_seen
                )
            );
        ELSE
            pkg_aox_meta_api.pr_send_whatsapp_text(
                pi_phone_number => v_phone,
                pi_message      => UNISTR('\D83D\DEA8') || ' Incidente en Hasel (' || v_env || ')' || CHR(10)
                                   || 'Error: ' || v_error || CHR(10)
                                   || 'Proceso: ' || v_process || CHR(10)
                                   || 'Orgs afectadas: ' || v_orgs || ' - Ocurrencias: ' || v_incident.occurrences || CHR(10)
                                   || 'Primera vez: ' || v_first_seen || CHR(10)
                                   || 'Incidente #' || pi_incident_id || ' en AOX_INCIDENT.'
            );
        END IF;

        UPDATE aox_incident
           SET last_alert_at             = SYSTIMESTAMP,
               alerts_sent               = alerts_sent + 1,
               occurrences_at_last_alert = v_incident.occurrences
         WHERE id_incident = pi_incident_id;
        COMMIT;
    END pr_send_alert;

    PROCEDURE pr_run (
        pi_lookback_minutes IN NUMBER DEFAULT 120,
        pi_max_alerts       IN NUMBER DEFAULT 5
    ) IS
        v_cooldown_minutes NUMBER := NVL(TO_NUMBER(fn_get_parameter('OPS_ALERT_COOLDOWN_MIN')), 60);
    BEGIN
        -- Solo errores inesperados: 4xx (validacion, auth, conflicto) son respuestas normales.
        FOR r IN (
            SELECT l.id_log,
                   l.created_at,
                   l.org_id,
                   l.api_name,
                   l.process_name,
                   l.error_code,
                   l.status_code,
                   l.error_message
              FROM aox_api_log l
             WHERE l.status = 'ERROR'
               AND (l.status_code IS NULL OR l.status_code >= 500)
               AND l.created_at > SYSTIMESTAMP - NUMTODSINTERVAL(pi_lookback_minutes, 'MINUTE')
               AND NOT EXISTS (
                       SELECT 1
                         FROM aox_incident_event e
                        WHERE e.id_log = l.id_log
                   )
             ORDER BY l.id_log
        ) LOOP
            pr_register_event(
                pi_id_log        => r.id_log,
                pi_occurred_at   => r.created_at,
                pi_org_id        => r.org_id,
                pi_api_name      => r.api_name,
                pi_process_name  => r.process_name,
                pi_error_code    => r.error_code,
                pi_status_code   => r.status_code,
                pi_error_message => r.error_message
            );
        END LOOP;
        COMMIT;

        IF NVL(fn_get_parameter('OPS_ALERT_ENABLED'), '0') <> '1' THEN
            RETURN;
        END IF;

        FOR i IN (
            SELECT id_incident
              FROM aox_incident
             WHERE status = 'OPEN'
               AND occurrences > occurrences_at_last_alert
               AND (last_attempt_at IS NULL
                    OR last_attempt_at < SYSTIMESTAMP - NUMTODSINTERVAL(v_cooldown_minutes, 'MINUTE'))
             ORDER BY first_seen_at
             FETCH FIRST pi_max_alerts ROWS ONLY
        ) LOOP
            BEGIN
                pr_send_alert(i.id_incident);
            EXCEPTION
                WHEN OTHERS THEN
                    -- El fallo ya queda en aox_whatsapp_template_log; se reintenta tras el cooldown.
                    ROLLBACK;
            END;
        END LOOP;
    END pr_run;

    PROCEDURE pr_resolve (
        pi_incident_id IN aox_incident.id_incident%TYPE,
        pi_note        IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE aox_incident
           SET status        = 'RESOLVED',
               resolved_at   = SYSTIMESTAMP,
               resolved_note = SUBSTR(pi_note, 1, 1000)
         WHERE id_incident = pi_incident_id;
        COMMIT;
    END pr_resolve;

    PROCEDURE pr_ignore (
        pi_incident_id IN aox_incident.id_incident%TYPE,
        pi_note        IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE aox_incident
           SET status        = 'IGNORED',
               resolved_note = SUBSTR(pi_note, 1, 1000)
         WHERE id_incident = pi_incident_id;
        COMMIT;
    END pr_ignore;

END pkg_aox_incident_monitor;
/

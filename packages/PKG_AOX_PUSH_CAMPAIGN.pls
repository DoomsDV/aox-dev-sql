PROMPT CREATE OR REPLACE PACKAGE pkg_aox_push_campaign
CREATE OR REPLACE PACKAGE pkg_aox_push_campaign IS
    /**
     * Campanas push desde Hasel_admn (canal paralelo a notificaciones fijas FCM).
     * Destinatarios: platform_user (ALL_ACTIVE o por rol ADMIN/PROFESIONAL).
     */

    PROCEDURE pr_create_campaign(
        pi_name           IN  VARCHAR2,
        pi_title_template IN  VARCHAR2,
        pi_body_template  IN  VARCHAR2,
        pi_url_template   IN  VARCHAR2 DEFAULT NULL,
        pi_audience_type  IN  VARCHAR2,
        pi_role_id        IN  NUMBER   DEFAULT NULL,
        pi_send_at        IN  TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        pi_send_now       IN  NUMBER   DEFAULT 0,
        pi_vars_json      IN  CLOB     DEFAULT NULL,
        pi_created_by     IN  VARCHAR2 DEFAULT NULL,
        po_campaign_id    OUT NUMBER
    );

    PROCEDURE pr_update_campaign(
        pi_campaign_id    IN NUMBER,
        pi_name           IN VARCHAR2,
        pi_title_template IN VARCHAR2,
        pi_body_template  IN VARCHAR2,
        pi_url_template   IN VARCHAR2 DEFAULT NULL,
        pi_audience_type  IN VARCHAR2,
        pi_role_id        IN NUMBER   DEFAULT NULL,
        pi_send_at        IN TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        pi_schedule       IN NUMBER   DEFAULT 0,
        pi_vars_json      IN CLOB     DEFAULT NULL
    );

    PROCEDURE pr_set_enabled(
        pi_campaign_id IN NUMBER,
        pi_enabled     IN NUMBER
    );

    PROCEDURE pr_cancel_campaign(pi_campaign_id IN NUMBER);

    PROCEDURE pr_delete_campaign(pi_campaign_id IN NUMBER);

    PROCEDURE pr_replace_campaign_vars(
        pi_campaign_id IN NUMBER,
        pi_vars_json   IN CLOB
    );

    /** Envio inmediato (drop job si habia). */
    PROCEDURE pr_send_now(pi_campaign_id IN NUMBER);

    /** Ejecutado por DBMS_SCHEDULER o pr_send_now. */
    PROCEDURE pr_execute_campaign(pi_campaign_id IN NUMBER);

END pkg_aox_push_campaign;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_push_campaign
CREATE OR REPLACE PACKAGE BODY pkg_aox_push_campaign IS

    c_process_name CONSTANT VARCHAR2(100) := 'PKG_AOX_PUSH_CAMPAIGN';

    FUNCTION fn_job_name(pi_campaign_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'HASEL_PUSH_CAMP_' || TO_CHAR(pi_campaign_id);
    END fn_job_name;

    FUNCTION fn_is_catalog_key(pi_key IN VARCHAR2) RETURN BOOLEAN IS
        v_cnt NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_cnt
          FROM push_var_catalog
         WHERE UPPER(var_key) = UPPER(TRIM(pi_key))
           AND is_active = 1;
        RETURN v_cnt > 0;
    END fn_is_catalog_key;

    PROCEDURE pr_validate_title_vars(pi_title IN VARCHAR2) IS
        v_pos   PLS_INTEGER := 1;
        v_start PLS_INTEGER;
        v_end   PLS_INTEGER;
        v_key   VARCHAR2(100);
        v_title VARCHAR2(4000) := NVL(pi_title, '');
    BEGIN
        LOOP
            v_start := INSTR(v_title, '{{', v_pos);
            EXIT WHEN v_start = 0;
            v_end := INSTR(v_title, '}}', v_start + 2);
            IF v_end = 0 THEN
                RAISE_APPLICATION_ERROR(-20101, 'Plantilla de titulo con {{ sin cerrar.');
            END IF;
            v_key := TRIM(SUBSTR(v_title, v_start + 2, v_end - v_start - 2));
            IF v_key IS NULL OR NOT fn_is_catalog_key(v_key) THEN
                RAISE_APPLICATION_ERROR(
                    -20102,
                    'Variable de titulo no permitida: {{' || NVL(v_key, '') ||
                    '}}. Solo catalogo (NOMBRE, APELLIDO, EMAIL).'
                );
            END IF;
            v_pos := v_end + 2;
        END LOOP;
    END pr_validate_title_vars;

    PROCEDURE pr_validate_audience(
        pi_audience_type IN VARCHAR2,
        pi_role_id       IN NUMBER
    ) IS
        v_cnt NUMBER;
    BEGIN
        IF pi_audience_type NOT IN ('ALL_ACTIVE', 'ROLE') THEN
            RAISE_APPLICATION_ERROR(-20103, 'audience_type debe ser ALL_ACTIVE o ROLE.');
        END IF;

        IF pi_audience_type = 'ALL_ACTIVE' AND pi_role_id IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20104, 'role_id debe ser NULL cuando audience_type = ALL_ACTIVE.');
        END IF;

        IF pi_audience_type = 'ROLE' THEN
            IF pi_role_id IS NULL THEN
                RAISE_APPLICATION_ERROR(-20105, 'role_id es obligatorio cuando audience_type = ROLE.');
            END IF;
            SELECT COUNT(*)
              INTO v_cnt
              FROM role
             WHERE id_role = pi_role_id
               AND is_active = 1;
            IF v_cnt = 0 THEN
                RAISE_APPLICATION_ERROR(-20106, 'role_id no existe o no esta activo.');
            END IF;
        END IF;
    END pr_validate_audience;

    FUNCTION fn_apply_token(
        pi_text  IN VARCHAR2,
        pi_key   IN VARCHAR2,
        pi_value IN VARCHAR2
    ) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(
            NVL(pi_text, ''),
            '{{' || UPPER(TRIM(pi_key)) || '}}',
            NVL(pi_value, '')
        );
    END fn_apply_token;

    FUNCTION fn_apply_all_vars(
        pi_template  IN VARCHAR2,
        pi_nombre    IN VARCHAR2,
        pi_apellido  IN VARCHAR2,
        pi_email     IN VARCHAR2,
        pi_campaign_id IN NUMBER
    ) RETURN VARCHAR2 IS
        v_out VARCHAR2(4000) := NVL(pi_template, '');
        -- Normalize keys to uppercase tokens in template by also trying as-written keys
    BEGIN
        -- Case-insensitive replace for catalog: try UPPER form first after normalizing braces content
        v_out := REPLACE(v_out, '{{NOMBRE}}',   NVL(pi_nombre, ''));
        v_out := REPLACE(v_out, '{{nombre}}',   NVL(pi_nombre, ''));
        v_out := REPLACE(v_out, '{{Nombre}}',   NVL(pi_nombre, ''));
        v_out := REPLACE(v_out, '{{APELLIDO}}', NVL(pi_apellido, ''));
        v_out := REPLACE(v_out, '{{apellido}}', NVL(pi_apellido, ''));
        v_out := REPLACE(v_out, '{{Apellido}}', NVL(pi_apellido, ''));
        v_out := REPLACE(v_out, '{{EMAIL}}',    NVL(pi_email, ''));
        v_out := REPLACE(v_out, '{{email}}',    NVL(pi_email, ''));
        v_out := REPLACE(v_out, '{{Email}}',    NVL(pi_email, ''));

        FOR rec IN (
            SELECT var_key, var_value
              FROM push_campaign_var
             WHERE id_campaign = pi_campaign_id
        ) LOOP
            v_out := REPLACE(v_out, '{{' || rec.var_key || '}}', NVL(rec.var_value, ''));
            v_out := REPLACE(v_out, '{{' || UPPER(rec.var_key) || '}}', NVL(rec.var_value, ''));
            v_out := REPLACE(v_out, '{{' || LOWER(rec.var_key) || '}}', NVL(rec.var_value, ''));
        END LOOP;

        RETURN SUBSTR(v_out, 1, 4000);
    END fn_apply_all_vars;

    PROCEDURE pr_drop_campaign_job(pi_campaign_id IN NUMBER) IS
        v_job_name push_campaign.scheduler_job_name%TYPE;
    BEGIN
        SELECT scheduler_job_name
          INTO v_job_name
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_job_name IS NOT NULL THEN
            BEGIN
                DBMS_SCHEDULER.DROP_JOB(job_name => v_job_name, force => TRUE);
            EXCEPTION
                WHEN OTHERS THEN
                    -- ORA-27475: job does not exist
                    IF SQLCODE NOT IN (-27475) THEN
                        RAISE;
                    END IF;
            END;

            UPDATE push_campaign
               SET scheduler_job_name = NULL,
                   updated_at         = CURRENT_TIMESTAMP
             WHERE id_campaign = pi_campaign_id;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END pr_drop_campaign_job;

    PROCEDURE pr_create_campaign_job(pi_campaign_id IN NUMBER) IS
        v_send_at   TIMESTAMP WITH TIME ZONE;
        v_status    VARCHAR2(20);
        v_enabled   NUMBER(1);
        v_job_name  VARCHAR2(128);
        v_action    VARCHAR2(4000);
    BEGIN
        SELECT send_at, status, is_enabled
          INTO v_send_at, v_status, v_enabled
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_enabled != 1 THEN
            RETURN;
        END IF;

        IF v_send_at IS NULL THEN
            RAISE_APPLICATION_ERROR(-20107, 'send_at es obligatorio para programar la campana.');
        END IF;

        IF v_send_at <= SYSTIMESTAMP THEN
            RAISE_APPLICATION_ERROR(-20108, 'send_at debe ser una fecha/hora futura.');
        END IF;

        pr_drop_campaign_job(pi_campaign_id);

        v_job_name := fn_job_name(pi_campaign_id);
        v_action   := 'BEGIN pkg_aox_push_campaign.pr_execute_campaign(' ||
                      TO_CHAR(pi_campaign_id) || '); END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => v_job_name,
            job_type        => 'PLSQL_BLOCK',
            job_action      => v_action,
            start_date      => v_send_at,
            repeat_interval => NULL,
            enabled         => TRUE,
            auto_drop       => TRUE,
            comments        => 'Hasel push campaign ' || TO_CHAR(pi_campaign_id)
        );

        UPDATE push_campaign
           SET scheduler_job_name = v_job_name,
               status             = 'SCHEDULED',
               updated_at         = CURRENT_TIMESTAMP
         WHERE id_campaign = pi_campaign_id;
    END pr_create_campaign_job;

    PROCEDURE pr_replace_campaign_vars(
        pi_campaign_id IN NUMBER,
        pi_vars_json   IN CLOB
    ) IS
        v_arr   json_array_t;
        v_obj   json_object_t;
        v_key   VARCHAR2(50);
        v_value VARCHAR2(4000);
        v_cnt   NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_cnt
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_cnt = 0 THEN
            RAISE_APPLICATION_ERROR(-20109, 'Campana no encontrada.');
        END IF;

        DELETE FROM push_campaign_var
         WHERE id_campaign = pi_campaign_id;

        IF pi_vars_json IS NULL OR DBMS_LOB.GETLENGTH(pi_vars_json) = 0 THEN
            RETURN;
        END IF;

        v_arr := json_array_t.parse(pi_vars_json);

        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            v_obj   := TREAT(v_arr.get(i) AS json_object_t);
            v_key   := UPPER(TRIM(v_obj.get_string('key')));
            IF v_key IS NULL THEN
                v_key := UPPER(TRIM(v_obj.get_string('var_key')));
            END IF;
            BEGIN
                v_value := v_obj.get_string('value');
            EXCEPTION
                WHEN OTHERS THEN
                    v_value := v_obj.get_string('var_value');
            END;

            IF v_key IS NOT NULL AND TRIM(v_key) IS NOT NULL THEN
                IF fn_is_catalog_key(v_key) THEN
                    RAISE_APPLICATION_ERROR(
                        -20110,
                        'La variable custom "' || v_key || '" choca con el catalogo de sistema.'
                    );
                END IF;

                INSERT INTO push_campaign_var (id_campaign, var_key, var_value)
                VALUES (pi_campaign_id, v_key, NVL(SUBSTR(v_value, 1, 4000), ''));
            END IF;
        END LOOP;

        UPDATE push_campaign
           SET updated_at = CURRENT_TIMESTAMP
         WHERE id_campaign = pi_campaign_id;
    END pr_replace_campaign_vars;

    PROCEDURE pr_assert_editable(pi_campaign_id IN NUMBER) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status
          INTO v_status
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_status IN ('SENDING', 'SENT') THEN
            RAISE_APPLICATION_ERROR(
                -20111,
                'No se puede modificar una campana en estado ' || v_status || '.'
            );
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20109, 'Campana no encontrada.');
    END pr_assert_editable;

    PROCEDURE pr_create_campaign(
        pi_name           IN  VARCHAR2,
        pi_title_template IN  VARCHAR2,
        pi_body_template  IN  VARCHAR2,
        pi_url_template   IN  VARCHAR2 DEFAULT NULL,
        pi_audience_type  IN  VARCHAR2,
        pi_role_id        IN  NUMBER   DEFAULT NULL,
        pi_send_at        IN  TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        pi_send_now       IN  NUMBER   DEFAULT 0,
        pi_vars_json      IN  CLOB     DEFAULT NULL,
        pi_created_by     IN  VARCHAR2 DEFAULT NULL,
        po_campaign_id    OUT NUMBER
    ) IS
        v_role_id NUMBER := pi_role_id;
        v_id      NUMBER;
    BEGIN
        IF TRIM(pi_name) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20112, 'name es obligatorio.');
        END IF;
        IF TRIM(pi_title_template) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20113, 'title_template es obligatorio.');
        END IF;
        IF TRIM(pi_body_template) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20114, 'body_template es obligatorio.');
        END IF;

        IF pi_audience_type = 'ALL_ACTIVE' THEN
            v_role_id := NULL;
        END IF;

        pr_validate_audience(pi_audience_type, v_role_id);
        pr_validate_title_vars(pi_title_template);

        INSERT INTO push_campaign (
            name, title_template, body_template, url_template,
            audience_type, role_id, send_at, status, is_enabled, created_by
        ) VALUES (
            TRIM(pi_name),
            TRIM(pi_title_template),
            TRIM(pi_body_template),
            NULLIF(TRIM(pi_url_template), ''),
            pi_audience_type,
            v_role_id,
            pi_send_at,
            'DRAFT',
            1,
            SUBSTR(pi_created_by, 1, 100)
        )
        RETURNING id_campaign INTO v_id;

        po_campaign_id := v_id;

        pr_replace_campaign_vars(v_id, pi_vars_json);

        IF NVL(pi_send_now, 0) = 1 THEN
            pr_execute_campaign(v_id);
        ELSIF pi_send_at IS NOT NULL THEN
            pr_create_campaign_job(v_id);
        END IF;
    END pr_create_campaign;

    PROCEDURE pr_update_campaign(
        pi_campaign_id    IN NUMBER,
        pi_name           IN VARCHAR2,
        pi_title_template IN VARCHAR2,
        pi_body_template  IN VARCHAR2,
        pi_url_template   IN VARCHAR2 DEFAULT NULL,
        pi_audience_type  IN VARCHAR2,
        pi_role_id        IN NUMBER   DEFAULT NULL,
        pi_send_at        IN TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        pi_schedule       IN NUMBER   DEFAULT 0,
        pi_vars_json      IN CLOB     DEFAULT NULL
    ) IS
        v_role_id NUMBER := pi_role_id;
    BEGIN
        pr_assert_editable(pi_campaign_id);

        IF TRIM(pi_name) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20112, 'name es obligatorio.');
        END IF;
        IF TRIM(pi_title_template) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20113, 'title_template es obligatorio.');
        END IF;
        IF TRIM(pi_body_template) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20114, 'body_template es obligatorio.');
        END IF;

        IF pi_audience_type = 'ALL_ACTIVE' THEN
            v_role_id := NULL;
        END IF;

        pr_validate_audience(pi_audience_type, v_role_id);
        pr_validate_title_vars(pi_title_template);

        -- Quitar job previo antes de cambiar datos
        pr_drop_campaign_job(pi_campaign_id);

        UPDATE push_campaign
           SET name           = TRIM(pi_name),
               title_template = TRIM(pi_title_template),
               body_template  = TRIM(pi_body_template),
               url_template   = NULLIF(TRIM(pi_url_template), ''),
               audience_type  = pi_audience_type,
               role_id        = v_role_id,
               send_at        = pi_send_at,
               status         = CASE
                                   WHEN NVL(pi_schedule, 0) = 1 AND pi_send_at IS NOT NULL THEN 'SCHEDULED'
                                   ELSE 'DRAFT'
                                END,
               error_message  = NULL,
               updated_at     = CURRENT_TIMESTAMP
         WHERE id_campaign = pi_campaign_id;

        IF pi_vars_json IS NOT NULL THEN
            pr_replace_campaign_vars(pi_campaign_id, pi_vars_json);
        END IF;

        IF NVL(pi_schedule, 0) = 1 AND pi_send_at IS NOT NULL THEN
            pr_create_campaign_job(pi_campaign_id);
        END IF;
    END pr_update_campaign;

    PROCEDURE pr_set_enabled(
        pi_campaign_id IN NUMBER,
        pi_enabled     IN NUMBER
    ) IS
        v_status  VARCHAR2(20);
        v_send_at TIMESTAMP WITH TIME ZONE;
        v_enabled NUMBER(1);
    BEGIN
        IF pi_enabled NOT IN (0, 1) THEN
            RAISE_APPLICATION_ERROR(-20115, 'pi_enabled debe ser 0 o 1.');
        END IF;

        SELECT status, send_at, is_enabled
          INTO v_status, v_send_at, v_enabled
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_status = 'SENDING' THEN
            RAISE_APPLICATION_ERROR(-20116, 'No se puede cambiar is_enabled mientras SENDING.');
        END IF;

        IF pi_enabled = 0 THEN
            pr_drop_campaign_job(pi_campaign_id);
            UPDATE push_campaign
               SET is_enabled = 0,
                   status     = CASE WHEN status IN ('SCHEDULED', 'DRAFT') THEN 'DISABLED' ELSE status END,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id_campaign = pi_campaign_id;
        ELSE
            UPDATE push_campaign
               SET is_enabled = 1,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id_campaign = pi_campaign_id;

            IF v_status IN ('DISABLED', 'CANCELLED', 'DRAFT', 'SCHEDULED', 'ERROR')
               AND v_send_at IS NOT NULL
               AND v_send_at > SYSTIMESTAMP
            THEN
                pr_create_campaign_job(pi_campaign_id);
            ELSIF v_status = 'DISABLED' THEN
                UPDATE push_campaign
                   SET status = 'DRAFT',
                       updated_at = CURRENT_TIMESTAMP
                 WHERE id_campaign = pi_campaign_id;
            END IF;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20109, 'Campana no encontrada.');
    END pr_set_enabled;

    PROCEDURE pr_cancel_campaign(pi_campaign_id IN NUMBER) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status
          INTO v_status
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_status = 'SENDING' THEN
            RAISE_APPLICATION_ERROR(-20117, 'No se puede cancelar mientras SENDING.');
        END IF;

        IF v_status = 'SENT' THEN
            RAISE_APPLICATION_ERROR(-20118, 'La campana ya fue enviada.');
        END IF;

        pr_drop_campaign_job(pi_campaign_id);

        UPDATE push_campaign
           SET status     = 'CANCELLED',
               is_enabled = 0,
               updated_at = CURRENT_TIMESTAMP
         WHERE id_campaign = pi_campaign_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20109, 'Campana no encontrada.');
    END pr_cancel_campaign;

    PROCEDURE pr_delete_campaign(pi_campaign_id IN NUMBER) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status
          INTO v_status
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        IF v_status = 'SENDING' THEN
            RAISE_APPLICATION_ERROR(-20119, 'No se puede eliminar mientras SENDING.');
        END IF;

        pr_drop_campaign_job(pi_campaign_id);

        DELETE FROM push_campaign
         WHERE id_campaign = pi_campaign_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20109, 'Campana no encontrada.');
    END pr_delete_campaign;

    PROCEDURE pr_send_now(pi_campaign_id IN NUMBER) IS
    BEGIN
        pr_drop_campaign_job(pi_campaign_id);
        pr_execute_campaign(pi_campaign_id);
    END pr_send_now;

    PROCEDURE pr_execute_campaign(pi_campaign_id IN NUMBER) IS
        v_camp         push_campaign%ROWTYPE;
        v_title        VARCHAR2(500);
        v_body         VARCHAR2(4000);
        v_url          VARCHAR2(1000);
        v_ok_count     PLS_INTEGER := 0;
        v_fail_count   PLS_INTEGER := 0;
        v_base_url     VARCHAR2(500);
        v_audience     VARCHAR2(20);
        v_role_id      NUMBER;
        v_token        VARCHAR2(1000);
        v_err_msg      VARCHAR2(4000);
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        SELECT *
          INTO v_camp
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id
         FOR UPDATE;

        IF v_camp.status = 'SENT' THEN
            RAISE_APPLICATION_ERROR(-20121, 'La campana ya fue enviada.');
        END IF;

        IF v_camp.status = 'CANCELLED' THEN
            RAISE_APPLICATION_ERROR(-20122, 'Campana cancelada.');
        END IF;

        IF v_camp.is_enabled = 0 OR v_camp.status = 'DISABLED' THEN
            RAISE_APPLICATION_ERROR(-20120, 'Campana deshabilitada.');
        END IF;

        IF v_camp.status NOT IN ('DRAFT', 'SCHEDULED', 'ERROR', 'SENDING') THEN
            RAISE_APPLICATION_ERROR(-20123, 'Estado no ejecutable: ' || v_camp.status);
        END IF;

        UPDATE push_campaign
           SET status             = 'SENDING',
               error_message      = NULL,
               scheduler_job_name = NULL,
               updated_at         = CURRENT_TIMESTAMP
         WHERE id_campaign = pi_campaign_id;

        COMMIT;

        SELECT *
          INTO v_camp
          FROM push_campaign
         WHERE id_campaign = pi_campaign_id;

        v_audience := v_camp.audience_type;
        v_role_id  := v_camp.role_id;

        v_base_url := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');

        DELETE FROM push_campaign_delivery
         WHERE id_campaign = pi_campaign_id;

        FOR rec IN (
            SELECT DISTINCT
                   pu.id_platform_user,
                   pu.first_name,
                   pu.last_name,
                   pu.email
              FROM platform_user pu
             WHERE pu.is_active = 1
               AND EXISTS (
                     SELECT 1
                       FROM org_member om
                      WHERE om.platform_user_id = pu.id_platform_user
                        AND om.is_active = 1
                        AND (
                              v_audience = 'ALL_ACTIVE'
                           OR (v_audience = 'ROLE' AND om.rol_id_role = v_role_id)
                            )
                   )
               AND EXISTS (
                     SELECT 1
                       FROM user_fcm_devices d
                      WHERE d.platform_user_id = pu.id_platform_user
                   )
        ) LOOP
            v_title := SUBSTR(
                fn_apply_all_vars(
                    v_camp.title_template,
                    rec.first_name,
                    rec.last_name,
                    rec.email,
                    pi_campaign_id
                ),
                1,
                500
            );
            v_body := fn_apply_all_vars(
                v_camp.body_template,
                rec.first_name,
                rec.last_name,
                rec.email,
                pi_campaign_id
            );

            IF v_camp.url_template IS NOT NULL THEN
                v_url := SUBSTR(
                    fn_apply_all_vars(
                        v_camp.url_template,
                        rec.first_name,
                        rec.last_name,
                        rec.email,
                        pi_campaign_id
                    ),
                    1,
                    1000
                );
            ELSE
                v_url := v_base_url || '/panel/dashboard';
            END IF;

            FOR device IN (
                SELECT f.fcm_token
                  FROM user_fcm_devices f
                 WHERE f.platform_user_id = rec.id_platform_user
            ) LOOP
                v_token := device.fcm_token;
                BEGIN
                    pkg_aox_fcm_api.pr_send_push(
                        pi_token => v_token,
                        pi_title => v_title,
                        pi_body  => v_body,
                        pi_url   => v_url
                    );

                    INSERT INTO push_campaign_delivery (
                        id_campaign, platform_user_id, fcm_token,
                        resolved_title, resolved_body, status, sent_at
                    ) VALUES (
                        pi_campaign_id,
                        rec.id_platform_user,
                        v_token,
                        v_title,
                        v_body,
                        'SENT',
                        CURRENT_TIMESTAMP
                    );
                    v_ok_count := v_ok_count + 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        v_err_msg := SUBSTR(SQLERRM, 1, 4000);
                        INSERT INTO push_campaign_delivery (
                            id_campaign, platform_user_id, fcm_token,
                            resolved_title, resolved_body, status, error_message, sent_at
                        ) VALUES (
                            pi_campaign_id,
                            rec.id_platform_user,
                            v_token,
                            v_title,
                            v_body,
                            'FAILED',
                            v_err_msg,
                            CURRENT_TIMESTAMP
                        );
                        v_fail_count := v_fail_count + 1;
                END;
            END LOOP;
        END LOOP;

        IF v_ok_count = 0 THEN
            UPDATE push_campaign
               SET status        = 'ERROR',
                   error_message = CASE
                       WHEN v_fail_count = 0 THEN 'Sin destinatarios con token FCM.'
                       ELSE 'Todos los envios fallaron (' || v_fail_count || ').'
                   END,
                   updated_at    = CURRENT_TIMESTAMP
             WHERE id_campaign = pi_campaign_id;
        ELSE
            UPDATE push_campaign
               SET status     = 'SENT',
                   sent_at    = CURRENT_TIMESTAMP,
                   error_message = CASE
                       WHEN v_fail_count > 0 THEN
                           'Enviado con fallos parciales: ok=' || v_ok_count ||
                           ', fail=' || v_fail_count
                       ELSE NULL
                   END,
                   updated_at = CURRENT_TIMESTAMP
             WHERE id_campaign = pi_campaign_id;
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            v_err_msg := SUBSTR(SQLERRM, 1, 4000);
            ROLLBACK;
            BEGIN
                UPDATE push_campaign
                   SET status        = 'ERROR',
                       error_message = v_err_msg,
                       updated_at    = CURRENT_TIMESTAMP
                 WHERE id_campaign = pi_campaign_id;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
            RAISE;
    END pr_execute_campaign;

END pkg_aox_push_campaign;
/

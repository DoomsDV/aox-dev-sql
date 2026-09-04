PROMPT CREATE OR REPLACE PACKAGE pkg_aox_fcm_api
CREATE OR REPLACE PACKAGE pkg_aox_fcm_api IS

    -- Registrar o actualizar el token FCM (Suscripción después del login)
    PROCEDURE pr_register_token(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar el token FCM (Desuscripción al hacer logout)
    PROCEDURE pr_unregister_token(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Enviar Notificación Push (Uso interno del backend)
    PROCEDURE pr_send_push(
        pi_token IN VARCHAR2,
        pi_title IN VARCHAR2,
        pi_body  IN VARCHAR2,
        pi_url   IN VARCHAR2 DEFAULT NULL
    );

    -- Notificación push al profesional (multi-org vía platform_user_id)
    PROCEDURE pr_notify_professional_appointment(
        pi_pro_id         IN NUMBER,
        pi_appointment_id IN NUMBER,
        pi_title          IN VARCHAR2,
        pi_body           IN VARCHAR2,
        pi_process_name   IN VARCHAR2,
        pi_ntype          IN VARCHAR2 DEFAULT NULL
    );

    -- Notificación push a un miembro de la organización (ADMIN u otros roles)
    PROCEDURE pr_notify_org_member(
        pi_org_member_id  IN NUMBER,
        pi_title          IN VARCHAR2,
        pi_body           IN VARCHAR2,
        pi_url            IN VARCHAR2,
        pi_process_name   IN VARCHAR2,
        pi_ntype          IN VARCHAR2 DEFAULT NULL,
        pi_appointment_id IN NUMBER   DEFAULT NULL,
        pi_holiday_id     IN NUMBER   DEFAULT NULL,
        pi_campaign_id    IN NUMBER   DEFAULT NULL,
        pi_action_type    IN VARCHAR2 DEFAULT NULL,
        pi_action_payload IN CLOB     DEFAULT NULL,
        pi_dedupe_key     IN VARCHAR2 DEFAULT NULL
    );

    -- Variante con resultado para workers transaccionales (p.ej. outbox de disputas).
    -- Mantiene separado el resultado de la campanita del resultado de FCM.
    PROCEDURE pr_notify_org_member_checked(
        pi_org_member_id    IN NUMBER,
        pi_title            IN VARCHAR2,
        pi_body             IN VARCHAR2,
        pi_url              IN VARCHAR2,
        pi_process_name     IN VARCHAR2,
        pi_ntype            IN VARCHAR2,
        pi_appointment_id   IN NUMBER,
        pi_holiday_id       IN NUMBER,
        pi_campaign_id      IN NUMBER,
        pi_action_type      IN VARCHAR2,
        pi_action_payload   IN CLOB,
        pi_dedupe_key       IN VARCHAR2,
        po_inbox_ok         OUT NUMBER,
        po_push_attempted   OUT NUMBER,
        po_push_succeeded   OUT NUMBER,
        po_push_failed      OUT NUMBER,
        po_error            OUT VARCHAR2
    );

    -- Job matutino: recordatorio diario admin/profesional (ventana 7-8 AM, TZ app)
    PROCEDURE pr_process_daily_morning_digest(
        pi_batch_size IN NUMBER DEFAULT 500
    );

END pkg_aox_fcm_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_fcm_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_fcm_api IS

    c_process_digest  CONSTANT VARCHAR2(100) := 'PKG_AOX_FCM_API.PR_PROCESS_DAILY_MORNING_DIGEST';
    c_digest_start_h  CONSTANT PLS_INTEGER    := 7;
    c_digest_end_h    CONSTANT PLS_INTEGER    := 8;

    PROCEDURE pr_send_push_checked(
        pi_token   IN VARCHAR2,
        pi_title   IN VARCHAR2,
        pi_body    IN VARCHAR2,
        pi_url     IN VARCHAR2,
        po_success OUT NUMBER,
        po_error   OUT VARCHAR2
    );

    FUNCTION fn_calendar_push_url(pi_org_member_id IN NUMBER) RETURN VARCHAR2 IS
        v_base VARCHAR2(500) := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');
    BEGIN
        IF pi_org_member_id IS NULL OR pi_org_member_id <= 0 THEN
            RETURN v_base || '/panel/calendar';
        END IF;
        RETURN v_base || '/panel/calendar?org_member_id=' || pi_org_member_id;
    END fn_calendar_push_url;

    FUNCTION fn_cobros_push_url(
        pi_org_member_id  IN NUMBER,
        pi_appointment_id IN NUMBER DEFAULT NULL
    ) RETURN VARCHAR2 IS
        v_base VARCHAR2(500) := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');
        v_url  VARCHAR2(1000);
        v_sep  VARCHAR2(2) := '?';
    BEGIN
        v_url := v_base || '/panel/cobros';
        IF pi_org_member_id IS NOT NULL AND pi_org_member_id > 0 THEN
            v_url := v_url || v_sep || 'org_member_id=' || pi_org_member_id;
            v_sep := '&';
        END IF;
        IF pi_appointment_id IS NOT NULL AND pi_appointment_id > 0 THEN
            v_url := v_url || v_sep || 'appointment=' || pi_appointment_id;
        END IF;
        RETURN v_url;
    END fn_cobros_push_url;

    FUNCTION fn_dashboard_push_url RETURN VARCHAR2 IS
        v_base VARCHAR2(500) := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');
    BEGIN
        RETURN v_base || '/panel/dashboard';
    END fn_dashboard_push_url;

    FUNCTION fn_dashboard_push_url(pi_org_member_id IN NUMBER) RETURN VARCHAR2 IS
        v_base VARCHAR2(500) := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');
    BEGIN
        IF pi_org_member_id IS NULL OR pi_org_member_id <= 0 THEN
            RETURN v_base || '/panel/dashboard';
        END IF;
        RETURN v_base || '/panel/dashboard?org_member_id=' || pi_org_member_id;
    END fn_dashboard_push_url;

    FUNCTION fn_digest_already_sent(
        pi_org_member_id IN NUMBER,
        pi_local_date    IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_count NUMBER := 0;
    BEGIN
        SELECT COUNT(*)
          INTO v_count
          FROM aox_push_fcm_log l
         WHERE l.process_name = c_process_digest
           AND l.status = 'SUCCESS'
           AND l.parameters LIKE 'org_member_id=' || pi_org_member_id || ';%'
           AND l.parameters LIKE '%local_date=' || pi_local_date || '%';

        RETURN v_count > 0;
    END fn_digest_already_sent;

    FUNCTION fn_is_professional_working_day(
        pi_pro_id      IN NUMBER,
        pi_target_date IN DATE
    ) RETURN BOOLEAN IS
        v_exception_type VARCHAR2(20);
        v_day_of_week    NUMBER;
        v_count          NUMBER := 0;
        v_target_trunc   DATE := TRUNC(pi_target_date);
    BEGIN
        IF pi_pro_id IS NULL THEN
            RETURN FALSE;
        END IF;

        v_exception_type := pkg_aox_util.fn_get_schedule_exception_type(pi_pro_id, v_target_trunc);

        IF v_exception_type = 'BLOCKED' THEN
            RETURN FALSE;
        END IF;

        IF v_exception_type = 'OVERRIDE' THEN
            SELECT COUNT(*)
              INTO v_count
              FROM professional_schedule_exception_slot s
              JOIN professional_schedule_exception e
                ON e.id_schedule_exception = s.exc_id_schedule_exception
             WHERE e.pro_id_professional = pi_pro_id
               AND e.exception_date = v_target_trunc
               AND e.exception_type = 'OVERRIDE';

            RETURN v_count > 0;
        END IF;

        v_day_of_week := v_target_trunc - TRUNC(v_target_trunc, 'IW') + 1;

        SELECT COUNT(*)
          INTO v_count
          FROM professional_schedule ps
         WHERE ps.pro_id_professional = pi_pro_id
           AND ps.day_of_week = v_day_of_week;

        RETURN v_count > 0;
    END fn_is_professional_working_day;

    FUNCTION fn_is_org_working_day(
        pi_org_id      IN NUMBER,
        pi_target_date IN DATE
    ) RETURN BOOLEAN IS
    BEGIN
        FOR rec IN (
            SELECT p.id_professional
              FROM professional p
             WHERE p.org_id_organization = pi_org_id
        ) LOOP
            IF fn_is_professional_working_day(rec.id_professional, pi_target_date) THEN
                RETURN TRUE;
            END IF;
        END LOOP;

        RETURN FALSE;
    END fn_is_org_working_day;

    FUNCTION fn_format_push_body(pi_org_name IN VARCHAR2, pi_body IN VARCHAR2) RETURN VARCHAR2 IS
        v_org_label VARCHAR2(120) := TRIM(pi_org_name);
        v_body      VARCHAR2(4000) := TRIM(pi_body);
    BEGIN
        IF v_org_label IS NULL THEN
            RETURN SUBSTR(v_body, 1, 4000);
        END IF;
        RETURN SUBSTR('[' || SUBSTR(v_org_label, 1, 80) || '] ' || v_body, 1, 4000);
    END fn_format_push_body;

    FUNCTION fn_is_digest_process(pi_process_name IN VARCHAR2) RETURN BOOLEAN IS
        v_name VARCHAR2(200) := UPPER(NVL(pi_process_name, ''));
    BEGIN
        RETURN INSTR(v_name, 'DIGEST') > 0;
    END fn_is_digest_process;

    FUNCTION fn_infer_inbox_ntype(
        pi_ntype        IN VARCHAR2,
        pi_process_name IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_type VARCHAR2(20) := UPPER(TRIM(pi_ntype));
        v_name VARCHAR2(200) := UPPER(NVL(pi_process_name, ''));
    BEGIN
        IF v_type IN ('APPOINTMENT', 'PAYMENT', 'HOLIDAY', 'SYSTEM') THEN
            RETURN v_type;
        END IF;
        IF INSTR(v_name, 'PAYMENT') > 0 THEN
            RETURN 'PAYMENT';
        END IF;
        IF INSTR(v_name, 'HOLIDAY') > 0 THEN
            RETURN 'HOLIDAY';
        END IF;
        IF INSTR(v_name, 'CAMPAIGN') > 0 OR INSTR(v_name, 'PUSH_CAMP') > 0 THEN
            RETURN 'SYSTEM';
        END IF;
        RETURN 'APPOINTMENT';
    END fn_infer_inbox_ntype;

    -- Función Privada: Validar inputs del Token FCM
    FUNCTION fn_validate_fcm_inputs(
        pi_user_id   IN NUMBER,
        pi_fcm_token IN VARCHAR2
    ) RETURN json_array_t IS
        v_errors  json_array_t := json_array_t();
        v_error   json_object_t;
    BEGIN
        IF pi_user_id IS NULL THEN
            v_error := json_object_t();
            v_error.put('field'   , 'user_id');
            v_error.put('message' , 'El ID de usuario es obligatorio.');
            v_errors.append(v_error);
        END IF;

        IF pi_fcm_token IS NULL OR TRIM(pi_fcm_token) = '' THEN
            v_error := json_object_t();
            v_error.put('field'   , 'fcm_token');
            v_error.put('message' , 'El token FCM es obligatorio.');
            v_errors.append(v_error);
        END IF;

        RETURN v_errors;
    END fn_validate_fcm_inputs;

    -- Procedimiento: Registrar Token (POST / PUT)
    PROCEDURE pr_register_token(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id              NUMBER;
        v_json_req            json_object_t;
        v_response_json       json_object_t := json_object_t();
        v_validation_errors   json_array_t;

        v_user_id             org_member.id_org_member%TYPE;
        v_platform_user_id    platform_user.id_platform_user%TYPE;
        v_jwt_member_id       org_member.id_org_member%TYPE;
        v_fcm_token           user_fcm_devices.fcm_token%TYPE;
        v_platform            user_fcm_devices.platform%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_jwt_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req  := json_object_t.parse(pi_body);
            v_user_id   := v_json_req.get_number('user_id');
            v_fcm_token := v_json_req.get_string('fcm_token');
            IF v_json_req.has('platform') THEN
                v_platform := v_json_req.get_string('platform');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_validation_errors := fn_validate_fcm_inputs(v_user_id, v_fcm_token);

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación en los campos enviados.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        DECLARE
            v_body_platform_user_id platform_user.id_platform_user%TYPE;
            v_jwt_platform_user_id  platform_user.id_platform_user%TYPE;
        BEGIN
            SELECT m.platform_user_id
              INTO v_body_platform_user_id
              FROM org_member m
             WHERE m.id_org_member = v_user_id
               AND m.is_active = 1;

            SELECT m.platform_user_id
              INTO v_jwt_platform_user_id
              FROM org_member m
             WHERE m.id_org_member = v_jwt_member_id
               AND m.is_active = 1;

            IF v_body_platform_user_id <> v_jwt_platform_user_id THEN
                po_status_code := pkg_aox_util.c_unauthorized_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'No puedes registrar notificaciones para otro usuario.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            v_platform_user_id := v_body_platform_user_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'El usuario indicado no es válido.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        MERGE INTO user_fcm_devices tgt
        USING (
            SELECT
                v_platform_user_id AS platform_user_id,
                TRIM(v_fcm_token)  AS fcm_token,
                TRIM(v_platform)   AS platform
            FROM dual
        ) src
        ON (tgt.fcm_token = src.fcm_token)
        WHEN MATCHED THEN
            UPDATE SET
                tgt.platform_user_id = src.platform_user_id,
                tgt.platform         = src.platform,
                tgt.last_used_at     = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (platform_user_id, fcm_token, platform)
            VALUES (src.platform_user_id, src.fcm_token, src.platform);

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Token FCM registrado y suscrito correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_register_token;

    -- Procedimiento: Eliminar Token (DELETE) - Ideal para el momento del Logout
    PROCEDURE pr_unregister_token(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_fcm_token         user_fcm_devices.fcm_token%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req  := json_object_t.parse(pi_body);
            v_fcm_token := v_json_req.get_string('fcm_token');
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        IF v_fcm_token IS NULL OR TRIM(v_fcm_token) = '' THEN
            RAISE_APPLICATION_ERROR(-20002, 'El token FCM es obligatorio para anular la suscripción.');
        END IF;

        DELETE FROM user_fcm_devices
        WHERE fcm_token = TRIM(v_fcm_token);

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Suscripción anulada correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_unregister_token;

    -- Procedimiento: Enviar Push llamando a nuestro microservicio en Firebase
    PROCEDURE pr_send_push(
        pi_token IN VARCHAR2,
        pi_title IN VARCHAR2,
        pi_body  IN VARCHAR2,
        pi_url   IN VARCHAR2 DEFAULT NULL
    ) IS
        l_success NUMBER;
        l_error   VARCHAR2(4000);
    BEGIN
        pr_send_push_checked(
            pi_token       => pi_token,
            pi_title       => pi_title,
            pi_body        => pi_body,
            pi_url         => pi_url,
            po_success     => l_success,
            po_error       => l_error
        );
    END pr_send_push;

    PROCEDURE pr_send_push_checked(
        pi_token   IN VARCHAR2,
        pi_title   IN VARCHAR2,
        pi_body    IN VARCHAR2,
        pi_url     IN VARCHAR2,
        po_success OUT NUMBER,
        po_error   OUT VARCHAR2
    ) IS
        l_body         CLOB;
        l_response     CLOB;
        l_status_code  NUMBER;
        l_push_url     VARCHAR2(1000) := TRIM(pi_url);
        l_firebase_url VARCHAR2(1000) := fn_get_parameter('FCM_PUSH_SERVICE_URL');
        l_fcm_bearer   VARCHAR2(4000) := fn_get_parameter('FCM_PUSH_SERVICE_BEARER');
    BEGIN
        po_success := 0;
        po_error   := NULL;

        IF l_firebase_url IS NULL THEN
            RAISE_APPLICATION_ERROR(-20070, 'No existe el parámetro FCM_PUSH_SERVICE_URL.');
        END IF;

        IF l_push_url IS NULL OR l_push_url = '' THEN
            l_push_url := fn_calendar_push_url(NULL);
        END IF;

        APEX_JSON.INITIALIZE_CLOB_OUTPUT;
        APEX_JSON.open_object;
            APEX_JSON.write('fcm_token', pi_token);
            APEX_JSON.write('title'    , pi_title);
            APEX_JSON.write('body'     , pi_body);
            APEX_JSON.write('url'      , l_push_url);
        APEX_JSON.close_object;
        l_body := APEX_JSON.get_clob_output;
        APEX_JSON.FREE_OUTPUT;

        APEX_WEB_SERVICE.g_request_headers.delete;
        APEX_WEB_SERVICE.g_request_headers(1).name  := 'Content-Type';
        APEX_WEB_SERVICE.g_request_headers(1).value := 'application/json';
        APEX_WEB_SERVICE.g_request_headers(2).name  := 'Authorization';
        APEX_WEB_SERVICE.g_request_headers(2).value := 'Bearer ' || l_fcm_bearer;

        l_response := APEX_WEB_SERVICE.make_rest_request(
            p_url         => l_firebase_url,
            p_http_method => 'POST',
            p_body        => l_body
        );

        l_status_code := APEX_WEB_SERVICE.g_status_code;
        pkg_aox_util.pr_log_push_fcm(
            pi_process_name    => 'PKG_AOX_FCM_API.PR_SEND_PUSH',
            pi_fcm_token       => pi_token,
            pi_title           => pi_title,
            pi_body            => pi_body,
            pi_status          => CASE WHEN l_status_code BETWEEN 200 AND 299 THEN 'SUCCESS' ELSE 'ERROR' END,
            pi_status_code     => l_status_code,
            pi_request_payload => l_body,
            pi_response_body   => l_response
        );

        IF l_status_code BETWEEN 200 AND 299 THEN
            po_success := 1;
        ELSE
            po_error := SUBSTR(
                'FCM HTTP ' || NVL(TO_CHAR(l_status_code), 'NULL') || ': '
                || DBMS_LOB.SUBSTR(l_response, 300, 1),
                1,
                4000
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            po_error := SUBSTR(SQLERRM, 1, 4000);
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => 'PKG_AOX_FCM_API.PR_SEND_PUSH',
                pi_fcm_token       => pi_token,
                pi_title           => pi_title,
                pi_body            => pi_body,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_payload => l_body,
                pi_response_body   => l_response
            );
    END pr_send_push_checked;

    PROCEDURE pr_notify_professional_appointment(
        pi_pro_id         IN NUMBER,
        pi_appointment_id IN NUMBER,
        pi_title          IN VARCHAR2,
        pi_body           IN VARCHAR2,
        pi_process_name   IN VARCHAR2,
        pi_ntype          IN VARCHAR2 DEFAULT NULL
    ) IS
        v_org_member_id    org_member.id_org_member%TYPE;
        v_platform_user_id platform_user.id_platform_user%TYPE;
        v_org_id           organization.id_organization%TYPE;
        v_org_name         organization.name%TYPE;
        v_push_url         VARCHAR2(1000);
        v_push_body        VARCHAR2(4000);
        v_admin_role_id    NUMBER := pkg_aox_util.fn_rol('ADMIN');
        v_inbox_type       VARCHAR2(20);
    BEGIN
        SELECT
            p.usr_id_user,
            m.platform_user_id,
            m.org_id_organization,
            o.name
        INTO
            v_org_member_id,
            v_platform_user_id,
            v_org_id,
            v_org_name
        FROM professional p
        INNER JOIN org_member m ON m.id_org_member = p.usr_id_user
        INNER JOIN organization o ON o.id_organization = m.org_id_organization
        WHERE p.id_professional = pi_pro_id;

        v_inbox_type := fn_infer_inbox_ntype(pi_ntype, pi_process_name);
        IF v_inbox_type = 'PAYMENT' THEN
            v_push_url := fn_cobros_push_url(v_org_member_id, pi_appointment_id);
        ELSE
            v_push_url := fn_calendar_push_url(v_org_member_id);
        END IF;
        v_push_body := fn_format_push_body(v_org_name, pi_body);

        IF NOT fn_is_digest_process(pi_process_name) THEN
            pkg_aox_inbox_api.pr_enqueue(
                pi_org_id         => v_org_id,
                pi_org_member_id  => v_org_member_id,
                pi_ntype          => v_inbox_type,
                pi_title          => pi_title,
                pi_body           => pi_body,
                pi_action_type    => 'OPEN_URL',
                pi_action_url     => v_push_url,
                pi_appointment_id => pi_appointment_id
            );
        END IF;

        FOR device IN (
            SELECT f.fcm_token
              FROM user_fcm_devices f
             WHERE f.platform_user_id = v_platform_user_id
        ) LOOP
            pkg_aox_fcm_api.pr_send_push(
                pi_token => device.fcm_token,
                pi_title => pi_title,
                pi_body  => v_push_body,
                pi_url   => v_push_url
            );
        END LOOP;

        -- Admins que pidieron recibir avisos de otros profesionales (sin duplicar al profesional)
        FOR admin_rec IN (
            SELECT m.id_org_member
              FROM org_member m
             WHERE m.org_id_organization = v_org_id
               AND m.is_active = 1
               AND m.rol_id_role = v_admin_role_id
               AND NVL(m.notify_all_professionals, 'N') = 'Y'
               AND m.platform_user_id <> v_platform_user_id
        ) LOOP
            pr_notify_org_member(
                pi_org_member_id  => admin_rec.id_org_member,
                pi_title          => pi_title,
                pi_body           => pi_body,
                pi_url            => CASE
                    WHEN v_inbox_type = 'PAYMENT' THEN fn_cobros_push_url(admin_rec.id_org_member, pi_appointment_id)
                    ELSE fn_calendar_push_url(admin_rec.id_org_member)
                END,
                pi_process_name   => pi_process_name || '.ADMIN_FANOUT',
                pi_ntype          => v_inbox_type,
                pi_appointment_id => pi_appointment_id
            );
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => pi_process_name,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'appointment_id=' || pi_appointment_id || ';professional_id=' || pi_pro_id
            );
            NULL;
    END pr_notify_professional_appointment;

    PROCEDURE pr_notify_org_member(
        pi_org_member_id  IN NUMBER,
        pi_title          IN VARCHAR2,
        pi_body           IN VARCHAR2,
        pi_url            IN VARCHAR2,
        pi_process_name   IN VARCHAR2,
        pi_ntype          IN VARCHAR2 DEFAULT NULL,
        pi_appointment_id IN NUMBER   DEFAULT NULL,
        pi_holiday_id     IN NUMBER   DEFAULT NULL,
        pi_campaign_id    IN NUMBER   DEFAULT NULL,
        pi_action_type    IN VARCHAR2 DEFAULT NULL,
        pi_action_payload IN CLOB     DEFAULT NULL,
        pi_dedupe_key     IN VARCHAR2 DEFAULT NULL
    ) IS
        v_platform_user_id platform_user.id_platform_user%TYPE;
        v_org_id           organization.id_organization%TYPE;
        v_org_name         organization.name%TYPE;
        v_push_url         VARCHAR2(1000);
        v_push_body        VARCHAR2(4000);
        v_inbox_type       VARCHAR2(20);
    BEGIN
        SELECT
            m.platform_user_id,
            m.org_id_organization,
            o.name
        INTO
            v_platform_user_id,
            v_org_id,
            v_org_name
        FROM org_member m
        INNER JOIN organization o ON o.id_organization = m.org_id_organization
        WHERE m.id_org_member = pi_org_member_id
          AND m.is_active = 1;

        v_inbox_type := fn_infer_inbox_ntype(pi_ntype, pi_process_name);
        IF NULLIF(TRIM(pi_url), '') IS NOT NULL THEN
            v_push_url := TRIM(pi_url);
        ELSIF v_inbox_type = 'PAYMENT' THEN
            v_push_url := fn_cobros_push_url(pi_org_member_id, pi_appointment_id);
        ELSE
            v_push_url := fn_calendar_push_url(pi_org_member_id);
        END IF;
        v_push_body  := fn_format_push_body(v_org_name, pi_body);

        IF NOT fn_is_digest_process(pi_process_name) THEN
            pkg_aox_inbox_api.pr_enqueue(
                pi_org_id          => v_org_id,
                pi_org_member_id   => pi_org_member_id,
                pi_ntype           => v_inbox_type,
                pi_title           => pi_title,
                pi_body            => pi_body,
                pi_action_type     => NVL(pi_action_type, 'OPEN_URL'),
                pi_action_url      => v_push_url,
                pi_action_payload  => pi_action_payload,
                pi_appointment_id  => pi_appointment_id,
                pi_holiday_id      => pi_holiday_id,
                pi_campaign_id     => pi_campaign_id,
                pi_dedupe_key      => pi_dedupe_key
            );
        END IF;

        FOR device IN (
            SELECT f.fcm_token
              FROM user_fcm_devices f
             WHERE f.platform_user_id = v_platform_user_id
        ) LOOP
            pr_send_push(
                pi_token => device.fcm_token,
                pi_title => pi_title,
                pi_body  => v_push_body,
                pi_url   => v_push_url
            );
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => pi_process_name,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'org_member_id=' || pi_org_member_id
            );
            NULL;
    END pr_notify_org_member;

    PROCEDURE pr_notify_org_member_checked(
        pi_org_member_id    IN NUMBER,
        pi_title            IN VARCHAR2,
        pi_body             IN VARCHAR2,
        pi_url              IN VARCHAR2,
        pi_process_name     IN VARCHAR2,
        pi_ntype            IN VARCHAR2,
        pi_appointment_id   IN NUMBER,
        pi_holiday_id       IN NUMBER,
        pi_campaign_id      IN NUMBER,
        pi_action_type      IN VARCHAR2,
        pi_action_payload   IN CLOB,
        pi_dedupe_key       IN VARCHAR2,
        po_inbox_ok         OUT NUMBER,
        po_push_attempted   OUT NUMBER,
        po_push_succeeded   OUT NUMBER,
        po_push_failed      OUT NUMBER,
        po_error            OUT VARCHAR2
    ) IS
        v_platform_user_id platform_user.id_platform_user%TYPE;
        v_org_id           organization.id_organization%TYPE;
        v_org_name         organization.name%TYPE;
        v_push_url         VARCHAR2(1000);
        v_push_body        VARCHAR2(4000);
        v_inbox_type       VARCHAR2(20);
        v_inbox_count      NUMBER := 0;
        v_push_success     NUMBER := 0;
        v_push_error       VARCHAR2(4000);
    BEGIN
        po_inbox_ok       := 0;
        po_push_attempted := 0;
        po_push_succeeded := 0;
        po_push_failed    := 0;
        po_error          := NULL;

        IF NULLIF(TRIM(pi_dedupe_key), '') IS NULL THEN
            RAISE_APPLICATION_ERROR(-20072, 'La notificacion checked requiere dedupe_key.');
        END IF;

        SELECT m.platform_user_id,
               m.org_id_organization,
               o.name
          INTO v_platform_user_id,
               v_org_id,
               v_org_name
          FROM org_member m
          JOIN organization o ON o.id_organization = m.org_id_organization
         WHERE m.id_org_member = pi_org_member_id
           AND m.is_active = 1;

        v_inbox_type := fn_infer_inbox_ntype(pi_ntype, pi_process_name);
        IF NULLIF(TRIM(pi_url), '') IS NOT NULL THEN
            v_push_url := TRIM(pi_url);
        ELSIF v_inbox_type = 'PAYMENT' THEN
            v_push_url := fn_cobros_push_url(pi_org_member_id, pi_appointment_id);
        ELSE
            v_push_url := fn_calendar_push_url(pi_org_member_id);
        END IF;
        v_push_body := fn_format_push_body(v_org_name, pi_body);

        IF NOT fn_is_digest_process(pi_process_name) THEN
            pkg_aox_inbox_api.pr_enqueue(
                pi_org_id          => v_org_id,
                pi_org_member_id   => pi_org_member_id,
                pi_ntype           => v_inbox_type,
                pi_title           => pi_title,
                pi_body            => pi_body,
                pi_action_type     => NVL(pi_action_type, 'OPEN_URL'),
                pi_action_url      => v_push_url,
                pi_action_payload  => pi_action_payload,
                pi_appointment_id  => pi_appointment_id,
                pi_holiday_id      => pi_holiday_id,
                pi_campaign_id     => pi_campaign_id,
                pi_dedupe_key      => pi_dedupe_key
            );
        END IF;

        SELECT COUNT(*)
          INTO v_inbox_count
          FROM user_notification n
         WHERE n.org_id_organization = v_org_id
           AND n.org_member_id = pi_org_member_id
           AND n.dedupe_key = pi_dedupe_key
           AND n.deleted_at IS NULL;

        IF v_inbox_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20073, 'No se pudo crear la notificacion de campanita.');
        END IF;
        po_inbox_ok := 1;

        FOR device IN (
            SELECT f.fcm_token
              FROM user_fcm_devices f
             WHERE f.platform_user_id = v_platform_user_id
        ) LOOP
            po_push_attempted := po_push_attempted + 1;
            pr_send_push_checked(
                pi_token   => device.fcm_token,
                pi_title   => pi_title,
                pi_body    => v_push_body,
                pi_url     => v_push_url,
                po_success => v_push_success,
                po_error   => v_push_error
            );
            IF v_push_success = 1 THEN
                po_push_succeeded := po_push_succeeded + 1;
            ELSE
                po_push_failed := po_push_failed + 1;
                po_error := SUBSTR(
                    CASE
                        WHEN po_error IS NULL THEN NVL(v_push_error, 'FCM fallo sin detalle')
                        ELSE po_error || ' | ' || NVL(v_push_error, 'FCM fallo sin detalle')
                    END,
                    1,
                    400
                );
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            po_error := SUBSTR(
                NVL(po_error || ' | ', '') || SQLERRM,
                1,
                400
            );
    END pr_notify_org_member_checked;

    PROCEDURE pr_log_digest_sent(
        pi_org_member_id IN NUMBER,
        pi_local_date    IN VARCHAR2,
        pi_role          IN VARCHAR2,
        pi_scenario      IN VARCHAR2
    ) IS
    BEGIN
        pkg_aox_util.pr_log_push_fcm(
            pi_process_name => c_process_digest,
            pi_status       => 'SUCCESS',
            pi_parameters   => 'org_member_id=' || pi_org_member_id ||
                               ';local_date=' || pi_local_date ||
                               ';role=' || pi_role ||
                               ';scenario=' || pi_scenario
        );
    END pr_log_digest_sent;

    PROCEDURE pr_process_daily_morning_digest(
        pi_batch_size IN NUMBER DEFAULT 500
    ) IS
        v_now_local      TIMESTAMP;
        v_today_start    TIMESTAMP;
        v_tomorrow_start TIMESTAMP;
        v_hour           NUMBER;
        v_local_date     VARCHAR2(10);
        v_today_date     DATE;
        v_admin_role_id  NUMBER := pkg_aox_util.fn_rol('ADMIN');
        v_prof_role_id   NUMBER := pkg_aox_util.fn_rol('PROFESIONAL');
    BEGIN
        v_now_local      := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);
        v_hour           := TO_NUMBER(TO_CHAR(v_now_local, 'HH24'));
        v_today_start    := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        v_local_date     := TO_CHAR(v_today_start, 'YYYY-MM-DD');
        v_today_date     := TRUNC(CAST(v_now_local AS DATE));

        IF v_hour < c_digest_start_h OR v_hour >= c_digest_end_h THEN
            RETURN;
        END IF;

        FOR admin_rec IN (
            SELECT
                m.id_org_member,
                m.org_id_organization,
                p.id_professional,
                (
                    SELECT COUNT(*)
                      FROM appointment a
                     WHERE a.org_id_organization = m.org_id_organization
                       AND a.start_time >= v_today_start
                       AND a.start_time < v_tomorrow_start
                       AND a.status IN ('PENDIENTE', 'CONFIRMADO')
                ) AS total_global,
                (
                    SELECT COUNT(*)
                      FROM appointment a
                     WHERE a.org_id_organization = m.org_id_organization
                       AND a.pro_id_professional = p.id_professional
                       AND a.start_time >= v_today_start
                       AND a.start_time < v_tomorrow_start
                       AND a.status IN ('PENDIENTE', 'CONFIRMADO')
                ) AS mis_citas
              FROM org_member m
              LEFT JOIN professional p
                ON p.usr_id_user = m.id_org_member
               AND p.org_id_organization = m.org_id_organization
             WHERE m.is_active = 1
               AND m.rol_id_role = v_admin_role_id
               AND EXISTS (
                    SELECT 1
                      FROM user_fcm_devices f
                     WHERE f.platform_user_id = m.platform_user_id
               )
             FETCH FIRST NVL(pi_batch_size, 500) ROWS ONLY
        ) LOOP
            IF admin_rec.total_global > 0
               AND NOT fn_digest_already_sent(admin_rec.id_org_member, v_local_date) THEN

                IF NVL(admin_rec.mis_citas, 0) > 0
                   AND admin_rec.id_professional IS NOT NULL
                   AND fn_is_professional_working_day(admin_rec.id_professional, v_today_date) THEN
                    pr_notify_org_member(
                        pi_org_member_id => admin_rec.id_org_member,
                        pi_title         => '📊 Resumen de agenda en hasel',
                        pi_body          =>
                            '¡Buen día! Hoy hay un total de ' || admin_rec.total_global ||
                            ' citas en el sistema. Tú tienes ' || admin_rec.mis_citas ||
                            ' bajo tu atención. ¡Buen turno!',
                        pi_url           => fn_dashboard_push_url(admin_rec.id_org_member),
                        pi_process_name  => c_process_digest || '.ADMIN_A'
                    );
                    pr_log_digest_sent(
                        admin_rec.id_org_member, v_local_date, 'ADMIN', 'A'
                    );
                ELSIF NVL(admin_rec.mis_citas, 0) = 0
                  AND fn_is_org_working_day(admin_rec.org_id_organization, v_today_date) THEN
                    pr_notify_org_member(
                        pi_org_member_id => admin_rec.id_org_member,
                        pi_title         => '📈 Actividad de hoy en hasel',
                        pi_body          =>
                            '¡Buen día! El sistema registra un total de ' ||
                            admin_rec.total_global ||
                            ' citas programadas para la jornada de hoy.',
                        pi_url           => fn_dashboard_push_url(admin_rec.id_org_member),
                        pi_process_name  => c_process_digest || '.ADMIN_B'
                    );
                    pr_log_digest_sent(
                        admin_rec.id_org_member, v_local_date, 'ADMIN', 'B'
                    );
                END IF;
            END IF;
        END LOOP;

        FOR prof_rec IN (
            SELECT
                m.id_org_member,
                p.id_professional,
                TRIM(pu.first_name) AS nombre_profesional,
                (
                    SELECT COUNT(*)
                      FROM appointment a
                     WHERE a.org_id_organization = m.org_id_organization
                       AND a.pro_id_professional = p.id_professional
                       AND a.start_time >= v_today_start
                       AND a.start_time < v_tomorrow_start
                       AND a.status IN ('PENDIENTE', 'CONFIRMADO')
                ) AS mis_citas
              FROM org_member m
              INNER JOIN professional p
                ON p.usr_id_user = m.id_org_member
               AND p.org_id_organization = m.org_id_organization
              INNER JOIN platform_user pu
                ON pu.id_platform_user = m.platform_user_id
             WHERE m.is_active = 1
               AND m.rol_id_role = v_prof_role_id
               AND EXISTS (
                    SELECT 1
                      FROM user_fcm_devices f
                     WHERE f.platform_user_id = m.platform_user_id
               )
             FETCH FIRST NVL(pi_batch_size, 500) ROWS ONLY
        ) LOOP
            IF prof_rec.mis_citas > 0
               AND fn_is_professional_working_day(prof_rec.id_professional, v_today_date)
               AND NOT fn_digest_already_sent(prof_rec.id_org_member, v_local_date) THEN

                IF prof_rec.mis_citas = 1 THEN
                    pr_notify_org_member(
                        pi_org_member_id => prof_rec.id_org_member,
                        pi_title         => '📅 Tienes una cita hoy',
                        pi_body          =>
                            '¡Hola, ' || prof_rec.nombre_profesional ||
                            '! Hoy tienes 1 cita programada. Toca aquí para ver el horario y los detalles.',
                        pi_url           => fn_calendar_push_url(prof_rec.id_org_member),
                        pi_process_name  => c_process_digest || '.PROF_1'
                    );
                    pr_log_digest_sent(
                        prof_rec.id_org_member, v_local_date, 'PROFESIONAL', '1'
                    );
                ELSE
                    pr_notify_org_member(
                        pi_org_member_id => prof_rec.id_org_member,
                        pi_title         => '📅 Tu agenda para hoy',
                        pi_body          =>
                            '¡Hola, ' || prof_rec.nombre_profesional ||
                            '! Tienes ' || prof_rec.mis_citas ||
                            ' citas programadas para hoy. Toca aquí para revisar tu calendario.',
                        pi_url           => fn_calendar_push_url(prof_rec.id_org_member),
                        pi_process_name  => c_process_digest || '.PROF_N'
                    );
                    pr_log_digest_sent(
                        prof_rec.id_org_member, v_local_date, 'PROFESIONAL', 'N'
                    );
                END IF;
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => c_process_digest,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            RAISE;
    END pr_process_daily_morning_digest;

END pkg_aox_fcm_api;
/


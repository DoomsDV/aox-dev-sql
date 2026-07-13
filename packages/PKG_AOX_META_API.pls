PROMPT CREATE OR REPLACE PACKAGE pkg_aox_meta_api
CREATE OR REPLACE PACKAGE pkg_aox_meta_api IS

    /**
     * Paquete de integración con los servicios de Meta (Facebook/WhatsApp).
     * Centraliza las llamadas a la Graph API.
     */

    -- Envía notificación de cita confirmada vía WhatsApp Cloud API
    PROCEDURE pr_send_whatsapp_notification (
        pi_phone_number  IN VARCHAR2,
        pi_customer_name IN VARCHAR2,
        pi_date_time     IN VARCHAR2,
        pi_professional  IN VARCHAR2
    );

    -- Encola el envío de confirmación de reserva por WhatsApp sin bloquear la API pública.
    PROCEDURE pr_enqueue_booking_confirmation_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Envía la plantilla confirmacion_reserva_hasel para una cita confirmada.
    PROCEDURE pr_send_booking_confirmation_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Envía la plantilla modificacion_reserva_hasel cuando staff reprograma o cambia la reserva.
    PROCEDURE pr_send_booking_modified_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Envía la plantilla cancelacion_reserva_manual_hasel_v2 cuando staff cancela/elimina la reserva.
    PROCEDURE pr_send_booking_cancelled_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Fase C2: cancelacion negocio con seña — pide alias SIPAP (cancelacion_y_reembolso_v1).
    PROCEDURE pr_send_refund_alias_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Envía la plantilla confirmar_asistencia_reserva_v2 para reservas próximas.
    PROCEDURE pr_send_attendance_request_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    );

    -- Job: envía recordatorios inteligentes de asistencia.
    PROCEDURE pr_process_attendance_reminders (
        pi_batch_size IN NUMBER DEFAULT 100
    );

    -- Job: cancela automáticamente reservas sin respuesta cuando la organización usa CANCEL.
    PROCEDURE pr_process_attendance_timeouts (
        pi_batch_size IN NUMBER DEFAULT 100
    );

    -- Punto de entrada para webhook/quick reply de WhatsApp.
    PROCEDURE pr_apply_attendance_reply (
        pi_appointment_id IN appointment.id_appointment%TYPE,
        pi_action         IN VARCHAR2
    );

    -- Procesa payloads de quick reply: CONFIRMAR_RESERVA_ID_12345 / CANCELAR_RESERVA_ID_12345.
    PROCEDURE pr_apply_attendance_payload (
        pi_payload IN VARCHAR2
    );

END pkg_aox_meta_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_meta_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_meta_api IS

    FUNCTION fn_clean_whatsapp_phone (
        pi_phone_number IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_clean_phone  VARCHAR2(30);
        v_country_code VARCHAR2(10) := NVL(fn_get_parameter('WHATSAPP_DEFAULT_COUNTRY_CODE'), '595');
    BEGIN
        v_clean_phone := REGEXP_REPLACE(NVL(pi_phone_number, ''), '[^0-9]', '');

        IF v_clean_phone LIKE '09%' THEN
            v_clean_phone := v_country_code || SUBSTR(v_clean_phone, 2);
        ELSIF LENGTH(v_clean_phone) = 9 AND v_clean_phone LIKE '9%' THEN
            v_clean_phone := v_country_code || v_clean_phone;
        END IF;

        RETURN v_clean_phone;
    END fn_clean_whatsapp_phone;

    FUNCTION fn_format_coordinate (
        pi_coordinate IN NUMBER
    ) RETURN VARCHAR2 IS
        v_coordinate VARCHAR2(50);
    BEGIN
        IF pi_coordinate IS NULL THEN
            RETURN NULL;
        END IF;

        v_coordinate := TO_CHAR(
            pi_coordinate,
            'FM999999990D99999999',
            'NLS_NUMERIC_CHARACTERS=.,'
        );

        RETURN RTRIM(RTRIM(v_coordinate, '0'), '.');
    END fn_format_coordinate;

    FUNCTION fn_maps_button_suffix (
        pi_latitude      IN NUMBER,
        pi_longitude     IN NUMBER,
        pi_location_name IN VARCHAR2
    ) RETURN VARCHAR2 IS
    BEGIN
        IF pi_latitude IS NOT NULL AND pi_longitude IS NOT NULL THEN
            RETURN fn_format_coordinate(pi_latitude) ||
                   '%2C' ||
                   fn_format_coordinate(pi_longitude);
        END IF;

        RETURN REPLACE(REPLACE(TRIM(NVL(pi_location_name, 'Hasel')), ' ', '+'), ',', '%2C');
    END fn_maps_button_suffix;

    FUNCTION fn_reservation_suffix (
        pi_public_token IN VARCHAR2
    ) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(pi_public_token);
    END fn_reservation_suffix;

    FUNCTION fn_profile_suffix (
        pi_profile_slug IN VARCHAR2
    ) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(pi_profile_slug);
    END fn_profile_suffix;

    FUNCTION fn_public_booking_path_suffix (
        pi_org_slug  IN VARCHAR2,
        pi_prof_slug IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_org_slug  VARCHAR2(100) := TRIM(pi_org_slug);
        v_prof_slug VARCHAR2(100) := TRIM(pi_prof_slug);
    BEGIN
        IF v_org_slug IS NULL OR v_prof_slug IS NULL THEN
            RETURN NULL;
        END IF;

        RETURN LOWER(v_org_slug) || '/p/' || LOWER(v_prof_slug);
    END fn_public_booking_path_suffix;

    FUNCTION fn_new_public_token RETURN VARCHAR2 IS
    BEGIN
        RETURN LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID()));
    END fn_new_public_token;

    FUNCTION fn_ensure_public_token (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) RETURN appointment.public_manage_token%TYPE IS
        v_token appointment.public_manage_token%TYPE;
    BEGIN
        SELECT public_manage_token
          INTO v_token
          FROM appointment
         WHERE id_appointment = pi_appointment_id
         FOR UPDATE;

        IF v_token IS NULL THEN
            v_token := fn_new_public_token();
            UPDATE appointment
               SET public_manage_token = v_token,
                   updated_at          = CURRENT_TIMESTAMP
             WHERE id_appointment = pi_appointment_id;
        END IF;

        RETURN v_token;
    END fn_ensure_public_token;

    FUNCTION fn_get_meta_phone_number_id RETURN VARCHAR2 IS
        v_phone_number_id app_parameter.param_value%TYPE;
    BEGIN
        v_phone_number_id := fn_get_parameter('META_PHONE_NUMBER_ID');

        IF v_phone_number_id IS NULL THEN
            v_phone_number_id := fn_get_parameter('META_PHONE_ID');
        END IF;

        RETURN v_phone_number_id;
    END fn_get_meta_phone_number_id;

    PROCEDURE pr_post_whatsapp_message (
        pi_payload IN CLOB
    ) IS
        v_url             VARCHAR2(4000);
        v_auth_token      app_parameter.param_value%TYPE;
        v_phone_number_id app_parameter.param_value%TYPE;
        v_response        CLOB;
        v_status_code     NUMBER;
        v_payload_json    json_object_t;
        v_template_json   json_object_t;
        v_phone_number    VARCHAR2(50);
        v_template_name   VARCHAR2(120);
    BEGIN
        v_auth_token      := fn_get_parameter('META_API_KEY');
        v_phone_number_id := fn_get_meta_phone_number_id();

        IF v_auth_token IS NULL THEN
            RAISE_APPLICATION_ERROR(-20050, 'No existe el parámetro META_API_KEY.');
        END IF;

        IF v_phone_number_id IS NULL THEN
            RAISE_APPLICATION_ERROR(-20051, 'No existe el parámetro META_PHONE_NUMBER_ID.');
        END IF;

        v_url := 'https://graph.facebook.com/' || NVL(fn_get_parameter('META_GRAPH_API_VERSION'), 'v25.0') || '/' || v_phone_number_id || '/messages';

        BEGIN
            v_payload_json := json_object_t.parse(pi_payload);
            IF v_payload_json.has('to') THEN
                v_phone_number := v_payload_json.get_string('to');
            END IF;
            IF v_payload_json.has('template') THEN
                v_template_json := v_payload_json.get_object('template');
                IF v_template_json.has('name') THEN
                    v_template_name := v_template_json.get_string('name');
                END IF;
            ELSIF v_payload_json.has('type') THEN
                v_template_name := UPPER(v_payload_json.get_string('type'));
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        apex_web_service.g_request_headers.delete();
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'Authorization';
        apex_web_service.g_request_headers(2).value := 'Bearer ' || v_auth_token;

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => pi_payload
        );

        v_status_code := apex_web_service.g_status_code;

        IF v_status_code NOT BETWEEN 200 AND 299 THEN
            RAISE_APPLICATION_ERROR(
                -20052,
                'Meta API respondió HTTP ' || v_status_code || ': ' || DBMS_LOB.SUBSTR(v_response, 1000, 1)
            );
        END IF;
        pkg_aox_util.pr_log_whatsapp_template(
            pi_process_name    => 'PKG_AOX_META_API.PR_POST_WHATSAPP_MESSAGE',
            pi_template_name   => v_template_name,
            pi_phone_number    => v_phone_number,
            pi_status          => 'SUCCESS',
            pi_status_code     => v_status_code,
            pi_request_payload => pi_payload,
            pi_response_body   => v_response
        );
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_whatsapp_template(
                pi_process_name    => 'PKG_AOX_META_API.PR_POST_WHATSAPP_MESSAGE',
                pi_template_name   => v_template_name,
                pi_phone_number    => v_phone_number,
                pi_status          => 'ERROR',
                pi_status_code     => v_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_payload => pi_payload,
                pi_response_body   => v_response
            );
            RAISE;
    END pr_post_whatsapp_message;

    PROCEDURE pr_send_whatsapp_text (
        pi_phone_number IN VARCHAR2,
        pi_message      IN VARCHAR2
    ) IS
        v_clean_phone      VARCHAR2(30);
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        v_clean_phone := fn_clean_whatsapp_phone(pi_phone_number);

        IF v_clean_phone IS NULL OR TRIM(pi_message) IS NULL THEN
            RETURN;
        END IF;

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('recipient_type', 'individual');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'text');
            APEX_JSON.open_object('text');
                APEX_JSON.write('preview_url', FALSE);
                APEX_JSON.write('body', pi_message);
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_whatsapp_text;

    PROCEDURE pr_send_whatsapp_notification (
        pi_phone_number  IN VARCHAR2,
        pi_customer_name IN VARCHAR2,
        pi_date_time     IN VARCHAR2,
        pi_professional  IN VARCHAR2
    ) IS
        v_url           VARCHAR2(4000);
        v_auth_token    VARCHAR2(4000);
        v_body_json     json_object_t := json_object_t();
        v_template      json_object_t := json_object_t();
        v_language      json_object_t := json_object_t();

        -- Variables para inyectar los datos en la plantilla ({{1}}, {{2}}, {{3}})
        v_components    json_array_t  := json_array_t();
        v_body_comp     json_object_t := json_object_t();
        v_parameters    json_array_t  := json_array_t();
        v_param1        json_object_t := json_object_t();
        v_param2        json_object_t := json_object_t();
        v_param3        json_object_t := json_object_t();

        v_response      CLOB;
        v_clean_phone   VARCHAR2(20);
        v_phone_id      VARCHAR2(100);
        v_status_code   NUMBER;
        v_payload       CLOB;
    BEGIN
        -- 1. Limpiar el teléfono (solo números)
        v_clean_phone := REGEXP_REPLACE(pi_phone_number, '[^0-9]', '');

        IF v_clean_phone LIKE '09%' THEN
            v_clean_phone := NVL(fn_get_parameter('WHATSAPP_DEFAULT_COUNTRY_CODE'), '595') || SUBSTR(v_clean_phone, 2);
        END IF;

        v_phone_id   := fn_get_meta_phone_number_id();
        v_auth_token := fn_get_parameter('META_API_KEY');
        v_url        := 'https://graph.facebook.com/' || NVL(fn_get_parameter('META_GRAPH_API_VERSION'), 'v18.0') || '/' || v_phone_id || '/messages';

        IF v_phone_id IS NULL OR v_auth_token IS NULL THEN
            RETURN;
        END IF;

        -- 2. Armar el JSON base de la API de Meta
        v_body_json.put('messaging_product', 'whatsapp');
        v_body_json.put('to', v_clean_phone);
        v_body_json.put('type', 'template');

        v_template.put('name', NVL(fn_get_parameter('META_WA_TEMPLATE_LEGACY'), 'cita_confirmada'));
        v_language.put('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
        v_template.put('language', v_language);

        -- 3. Inyectar las variables dinámicas a la plantilla
        -- Asumiendo una plantilla: "Hola {{1}}, tu cita para el {{2}} con {{3}} está confirmada."
        v_param1.put('type', 'text'); v_param1.put('text', pi_customer_name);
        v_param2.put('type', 'text'); v_param2.put('text', pi_date_time);
        v_param3.put('type', 'text'); v_param3.put('text', pi_professional);

        v_parameters.append(v_param1);
        v_parameters.append(v_param2);
        v_parameters.append(v_param3);

        v_body_comp.put('type', 'body');
        v_body_comp.put('parameters', v_parameters);

        v_components.append(v_body_comp);
        v_template.put('components', v_components);

        -- Adjuntar el template completo al cuerpo del mensaje
        v_body_json.put('template', v_template);

        -- 4. Configurar las cabeceras HTTP
        apex_web_service.g_request_headers.delete();
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';
        apex_web_service.g_request_headers(2).name  := 'Authorization';
        apex_web_service.g_request_headers(2).value := 'Bearer ' || v_auth_token;

        -- 5. Hacer la petición POST a los servidores de WhatsApp
        v_payload := v_body_json.to_clob();
        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => v_payload
        );
        v_status_code := apex_web_service.g_status_code;

        pkg_aox_util.pr_log_whatsapp_template(
            pi_process_name    => 'PKG_AOX_META_API.PR_SEND_WHATSAPP_NOTIFICATION',
            pi_template_name   => NVL(fn_get_parameter('META_WA_TEMPLATE_LEGACY'), 'cita_confirmada'),
            pi_phone_number    => v_clean_phone,
            pi_status          => CASE WHEN v_status_code BETWEEN 200 AND 299 THEN 'SUCCESS' ELSE 'ERROR' END,
            pi_status_code     => v_status_code,
            pi_request_payload => v_payload,
            pi_response_body   => v_response
        );

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_whatsapp_template(
                pi_process_name    => 'PKG_AOX_META_API.PR_SEND_WHATSAPP_NOTIFICATION',
                pi_template_name   => NVL(fn_get_parameter('META_WA_TEMPLATE_LEGACY'), 'cita_confirmada'),
                pi_phone_number    => v_clean_phone,
                pi_status          => 'ERROR',
                pi_status_code     => v_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_payload => v_payload,
                pi_response_body   => v_response
            );
            NULL;
    END pr_send_whatsapp_notification;

    PROCEDURE pr_enqueue_booking_confirmation_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_job_name VARCHAR2(30);
    BEGIN
        IF pi_appointment_id IS NULL THEN
            RETURN;
        END IF;

        v_job_name := 'WA_CONF_' ||
                      SUBSTR(TO_CHAR(ABS(pi_appointment_id)), 1, 10) ||
                      '_' ||
                      TO_CHAR(SYSTIMESTAMP, 'FF6');

        DBMS_SCHEDULER.create_job(
            job_name   => v_job_name,
            job_type   => 'PLSQL_BLOCK',
            job_action => 'BEGIN pkg_aox_meta_api.pr_send_booking_confirmation_wa(pi_appointment_id => ' ||
                          TO_CHAR(pi_appointment_id) ||
                          '); END;',
            start_date => SYSTIMESTAMP,
            enabled    => TRUE,
            auto_drop  => TRUE,
            comments   => 'Envio async WhatsApp confirmacion reserva'
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Si DBMS_SCHEDULER no está disponible, intentamos el envío directo sin afectar la reserva.
            BEGIN
                pr_send_booking_confirmation_wa(pi_appointment_id => pi_appointment_id);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
    END pr_enqueue_booking_confirmation_wa;

    PROCEDURE pr_send_booking_confirmation_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_customer_name    customer.full_name%TYPE;
        v_phone_number     customer.phone_number%TYPE;
        v_start_time       appointment.start_time%TYPE;
        v_status           appointment.status%TYPE;
        v_organization_name organization.name%TYPE;
        v_location_name    location.name%TYPE;
        v_latitude         location.latitude%TYPE;
        v_longitude        location.longitude%TYPE;
        v_clean_phone      VARCHAR2(30);
        v_booking_date     VARCHAR2(10);
        v_booking_time     VARCHAR2(5);
        v_maps_suffix      VARCHAR2(500);
        v_public_token     appointment.public_manage_token%TYPE;
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        SELECT
            c.full_name,
            c.phone_number,
            a.start_time,
            a.status,
            o.name,
            l.name,
            l.latitude,
            l.longitude
        INTO
            v_customer_name,
            v_phone_number,
            v_start_time,
            v_status,
            v_organization_name,
            v_location_name,
            v_latitude,
            v_longitude
        FROM appointment a
        JOIN customer c
          ON c.id_customer = a.cus_id_customer
        JOIN organization o
          ON o.id_organization = a.org_id_organization
        JOIN location l
          ON l.id_location = a.loc_id_location
        WHERE a.id_appointment = pi_appointment_id;

        IF v_status <> 'CONFIRMADO' THEN
            RETURN;
        END IF;

        v_clean_phone  := fn_clean_whatsapp_phone(v_phone_number);
        v_booking_date := TO_CHAR(v_start_time, 'DD-MM-YYYY');
        v_booking_time := TO_CHAR(v_start_time, 'HH24:MI');
        v_maps_suffix  := fn_maps_button_suffix(v_latitude, v_longitude, v_location_name);
        v_public_token := fn_ensure_public_token(pi_appointment_id);

        IF v_clean_phone IS NULL THEN
            RETURN;
        END IF;

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'template');
            APEX_JSON.open_object('template');
                APEX_JSON.write('name', fn_get_parameter('META_WA_TEMPLATE_BOOKING'));
                APEX_JSON.open_object('language');
                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                APEX_JSON.close_object;
                APEX_JSON.open_array('components');
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'body');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', v_customer_name);
                            APEX_JSON.close_object;
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', v_organization_name);
                            APEX_JSON.close_object;
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', v_booking_date);
                            APEX_JSON.close_object;
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', v_booking_time);
                            APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'url');
                        APEX_JSON.write('index', '0');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', v_maps_suffix);
                            APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'url');
                        APEX_JSON.write('index', '1');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object;
                                APEX_JSON.write('type', 'text');
                                APEX_JSON.write('text', fn_reservation_suffix(v_public_token));
                            APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                APEX_JSON.close_array;
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_booking_confirmation_wa;

    PROCEDURE pr_send_booking_modified_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_customer_name    customer.full_name%TYPE;
        v_phone_number     customer.phone_number%TYPE;
        v_start_time       appointment.start_time%TYPE;
        v_organization_name organization.name%TYPE;
        v_public_token     appointment.public_manage_token%TYPE;
        v_clean_phone      VARCHAR2(30);
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        SELECT c.full_name, c.phone_number, a.start_time, o.name
          INTO v_customer_name, v_phone_number, v_start_time, v_organization_name
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
          JOIN organization o ON o.id_organization = a.org_id_organization
         WHERE a.id_appointment = pi_appointment_id;

        v_clean_phone  := fn_clean_whatsapp_phone(v_phone_number);
        v_public_token := fn_ensure_public_token(pi_appointment_id);

        IF v_clean_phone IS NULL THEN
            RETURN;
        END IF;

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'template');
            APEX_JSON.open_object('template');
                APEX_JSON.write('name', fn_get_parameter('META_WA_TEMPLATE_MODIFIED'));
                APEX_JSON.open_object('language');
                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                APEX_JSON.close_object;
                APEX_JSON.open_array('components');
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'body');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_customer_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_organization_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', TO_CHAR(v_start_time, 'DD-MM-YYYY HH24:MI')); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'url');
                        APEX_JSON.write('index', '0');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', fn_reservation_suffix(v_public_token)); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                APEX_JSON.close_array;
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_booking_modified_wa;

    PROCEDURE pr_send_booking_cancelled_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_customer_name    customer.full_name%TYPE;
        v_phone_number     customer.phone_number%TYPE;
        v_start_time       appointment.start_time%TYPE;
        v_organization_name organization.name%TYPE;
        v_org_slug         workspace_setting.profile_slug%TYPE;
        v_profile_slug     professional.profile_slug%TYPE;
        v_clean_phone      VARCHAR2(30);
        v_booking_path     VARCHAR2(250);
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        SELECT
            c.full_name,
            c.phone_number,
            a.start_time,
            o.name,
            ws.profile_slug,
            p.profile_slug
          INTO
            v_customer_name,
            v_phone_number,
            v_start_time,
            v_organization_name,
            v_org_slug,
            v_profile_slug
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
          JOIN organization o ON o.id_organization = a.org_id_organization
          JOIN workspace_setting ws ON ws.org_id_organization = a.org_id_organization
          JOIN professional p ON p.id_professional = a.pro_id_professional
         WHERE a.id_appointment = pi_appointment_id;

        v_clean_phone  := fn_clean_whatsapp_phone(v_phone_number);
        v_booking_path := fn_public_booking_path_suffix(v_org_slug, v_profile_slug);

        IF v_start_time <= CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP) THEN
            RETURN;
        END IF;

        IF v_clean_phone IS NULL OR v_booking_path IS NULL THEN
            RETURN;
        END IF;

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'template');
            APEX_JSON.open_object('template');
                APEX_JSON.write('name', fn_get_parameter('META_WA_TEMPLATE_CANCEL'));
                APEX_JSON.open_object('language');
                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                APEX_JSON.close_object;
                APEX_JSON.open_array('components');
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'body');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_customer_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_organization_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', TO_CHAR(v_start_time, 'DD-MM-YYYY HH24:MI')); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'url');
                        APEX_JSON.write('index', '0');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_booking_path); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                APEX_JSON.close_array;
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_booking_cancelled_wa;

    PROCEDURE pr_send_refund_alias_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_customer_name     customer.full_name%TYPE;
        v_phone_number      customer.phone_number%TYPE;
        v_start_time        appointment.start_time%TYPE;
        v_organization_name organization.name%TYPE;
        v_refund_amount     appointment.refund_amount%TYPE;
        v_public_token      appointment.public_manage_token%TYPE;
        v_clean_phone       VARCHAR2(30);
        v_amount_text       VARCHAR2(80);
        v_payload           CLOB;
        v_json_initialized  BOOLEAN := FALSE;
        v_template_name     VARCHAR2(100);
    BEGIN
        SELECT
            c.full_name,
            c.phone_number,
            a.start_time,
            o.name,
            a.refund_amount,
            a.public_manage_token
          INTO
            v_customer_name,
            v_phone_number,
            v_start_time,
            v_organization_name,
            v_refund_amount,
            v_public_token
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
          JOIN organization o ON o.id_organization = a.org_id_organization
         WHERE a.id_appointment = pi_appointment_id;

        v_clean_phone := fn_clean_whatsapp_phone(v_phone_number);
        v_public_token := fn_ensure_public_token(pi_appointment_id);
        v_template_name := NVL(
            fn_get_parameter('META_WA_TEMPLATE_REFUND_ALIAS'),
            'cancelacion_y_reembolso_v1'
        );

        IF v_clean_phone IS NULL OR v_public_token IS NULL THEN
            RETURN;
        END IF;

        v_amount_text := 'Gs. ' || TRIM(TO_CHAR(NVL(v_refund_amount, 0), 'FM999G999G999'));

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'template');
            APEX_JSON.open_object('template');
                APEX_JSON.write('name', v_template_name);
                APEX_JSON.open_object('language');
                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                APEX_JSON.close_object;
                APEX_JSON.open_array('components');
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'body');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_customer_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_organization_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', TO_CHAR(v_start_time, 'DD-MM-YYYY HH24:MI')); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_amount_text); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'url');
                        APEX_JSON.write('index', '0');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', fn_reservation_suffix(v_public_token)); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                APEX_JSON.close_array;
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_refund_alias_wa;

    PROCEDURE pr_send_attendance_request_wa (
        pi_appointment_id IN appointment.id_appointment%TYPE
    ) IS
        v_customer_name    customer.full_name%TYPE;
        v_phone_number     customer.phone_number%TYPE;
        v_start_time       appointment.start_time%TYPE;
        v_status           appointment.status%TYPE;
        v_organization_name organization.name%TYPE;
        v_service_name     service.name%TYPE;
        v_clean_phone      VARCHAR2(30);
        v_booking_date     VARCHAR2(10);
        v_booking_time     VARCHAR2(5);
        v_org_id           NUMBER;
        v_cancel_wait_h    NUMBER;
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        SELECT c.full_name, c.phone_number, a.start_time, a.status, o.name, s.name, a.org_id_organization
          INTO v_customer_name, v_phone_number, v_start_time, v_status, v_organization_name, v_service_name, v_org_id
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
          JOIN organization o ON o.id_organization = a.org_id_organization
          JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.id_appointment = pi_appointment_id
         FOR UPDATE OF a.attendance_status;

        IF v_status <> 'CONFIRMADO' THEN
            RETURN;
        END IF;

        v_clean_phone := fn_clean_whatsapp_phone(v_phone_number);
        IF v_clean_phone IS NULL THEN
            RETURN;
        END IF;

        v_booking_date := TO_CHAR(v_start_time, 'DD-MM-YYYY');
        v_booking_time := TO_CHAR(v_start_time, 'HH24:MI');

        APEX_JSON.initialize_clob_output;
        v_json_initialized := TRUE;
        APEX_JSON.open_object;
            APEX_JSON.write('messaging_product', 'whatsapp');
            APEX_JSON.write('to', v_clean_phone);
            APEX_JSON.write('type', 'template');
            APEX_JSON.open_object('template');
                APEX_JSON.write('name', fn_get_parameter('META_WA_TEMPLATE_ATTENDANCE'));
                APEX_JSON.open_object('language');
                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                APEX_JSON.close_object;
                APEX_JSON.open_array('components');
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'body');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_customer_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_organization_name); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_booking_date); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_booking_time); APEX_JSON.close_object;
                            APEX_JSON.open_object; APEX_JSON.write('type', 'text'); APEX_JSON.write('text', v_service_name); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'quick_reply');
                        APEX_JSON.write('index', '0');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'payload'); APEX_JSON.write('payload', 'CONFIRMAR_RESERVA_ID_' || pi_appointment_id); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                    APEX_JSON.open_object;
                        APEX_JSON.write('type', 'button');
                        APEX_JSON.write('sub_type', 'quick_reply');
                        APEX_JSON.write('index', '1');
                        APEX_JSON.open_array('parameters');
                            APEX_JSON.open_object; APEX_JSON.write('type', 'payload'); APEX_JSON.write('payload', 'CANCELAR_RESERVA_ID_' || pi_appointment_id); APEX_JSON.close_object;
                        APEX_JSON.close_array;
                    APEX_JSON.close_object;
                APEX_JSON.close_array;
            APEX_JSON.close_object;
        APEX_JSON.close_object;

        v_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;
        v_json_initialized := FALSE;

        pr_post_whatsapp_message(pi_payload => v_payload);

        v_cancel_wait_h := pkg_aox_util.fn_get_org_cancel_wait_hours(v_org_id);

        UPDATE appointment
           SET attendance_status  = 'SENT',
               attendance_sent_at = CURRENT_TIMESTAMP,
               attendance_due_at  = CURRENT_TIMESTAMP + NUMTODSINTERVAL(v_cancel_wait_h, 'HOUR'),
               updated_at         = CURRENT_TIMESTAMP
         WHERE id_appointment = pi_appointment_id;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_json_initialized THEN
                APEX_JSON.free_output;
            END IF;
            RAISE;
    END pr_send_attendance_request_wa;

    PROCEDURE pr_apply_attendance_reply (
        pi_appointment_id IN appointment.id_appointment%TYPE,
        pi_action         IN VARCHAR2
    ) IS
        v_action          VARCHAR2(30) := UPPER(TRIM(pi_action));
        v_customer_name   customer.full_name%TYPE;
        v_phone_number    customer.phone_number%TYPE;
        v_profile_slug    professional.profile_slug%TYPE;
        v_rows_updated    NUMBER := 0;
        v_message         VARCHAR2(500);
    BEGIN
        IF v_action IN ('CONFIRMAR', 'CONFIRMADO', 'CONFIRMAR_RESERVA') THEN
            UPDATE appointment
               SET attendance_status   = 'CONFIRMED',
                   attendance_reply_at = CURRENT_TIMESTAMP,
                   status              = 'CONFIRMADO',
                   updated_at          = CURRENT_TIMESTAMP
             WHERE id_appointment = pi_appointment_id
               AND status <> 'CANCELADO';
            v_rows_updated := SQL%ROWCOUNT;

            IF v_rows_updated > 0 THEN
                BEGIN
                    SELECT c.full_name, c.phone_number
                      INTO v_customer_name, v_phone_number
                      FROM appointment a
                      JOIN customer c ON c.id_customer = a.cus_id_customer
                     WHERE a.id_appointment = pi_appointment_id;

                    v_message := 'Gracias ' || NVL(v_customer_name, '') ||
                        ', confirmamos tu asistencia. ¡Te esperamos!' || CHR(10) || CHR(10) ||
                        'El tiempo de espera puede variar. El profesional podría retrasarse en la atención según la dinámica del día.' || CHR(10) || CHR(10) ||
                        '¡Gracias por tu comprensión!';
                    pr_send_whatsapp_text(v_phone_number, TRIM(v_message));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END IF;
        ELSIF v_action IN ('CANCELAR', 'NO', 'DECLINED', 'CANCELAR_RESERVA') THEN
            UPDATE appointment
               SET attendance_status   = 'DECLINED',
                   attendance_reply_at = CURRENT_TIMESTAMP,
                   status              = 'CANCELADO',
                   cancel_reason       = 'CUSTOMER_DECLINED_ATTENDANCE',
                   updated_at          = CURRENT_TIMESTAMP
             WHERE id_appointment = pi_appointment_id
               AND status <> 'CANCELADO';
            v_rows_updated := SQL%ROWCOUNT;

            IF v_rows_updated > 0 THEN
                BEGIN
                    SELECT c.full_name, c.phone_number, p.profile_slug
                      INTO v_customer_name, v_phone_number, v_profile_slug
                      FROM appointment a
                      JOIN customer c ON c.id_customer = a.cus_id_customer
                      JOIN professional p ON p.id_professional = a.pro_id_professional
                     WHERE a.id_appointment = pi_appointment_id;

                    v_message := 'Lamentamos que no puedas asistir, ' || NVL(v_customer_name, '') ||
                                 '. Si deseas, puedes volver a reservar en el perfil del profesional.';
                    pr_send_whatsapp_text(v_phone_number, TRIM(v_message));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END IF;
        END IF;

        COMMIT;
    END pr_apply_attendance_reply;

    PROCEDURE pr_apply_attendance_payload (
        pi_payload IN VARCHAR2
    ) IS
        v_payload        VARCHAR2(200) := UPPER(TRIM(pi_payload));
        v_appointment_id appointment.id_appointment%TYPE;
        v_action         VARCHAR2(30);
    BEGIN
        v_appointment_id := TO_NUMBER(REGEXP_SUBSTR(v_payload, '[0-9]+$'));

        IF v_payload LIKE 'CONFIRMAR_RESERVA_ID_%' THEN
            v_action := 'CONFIRMAR_RESERVA';
        ELSIF v_payload LIKE 'CANCELAR_RESERVA_ID_%' THEN
            v_action := 'CANCELAR_RESERVA';
        ELSE
            RAISE_APPLICATION_ERROR(-20060, 'Payload de asistencia no reconocido.');
        END IF;

        pr_apply_attendance_reply(
            pi_appointment_id => v_appointment_id,
            pi_action         => v_action
        );
    END pr_apply_attendance_payload;

    PROCEDURE pr_process_attendance_reminders (
        pi_batch_size IN NUMBER DEFAULT 100
    ) IS
        v_current_hour NUMBER;
        v_current_time TIMESTAMP;
    BEGIN 
        -- Asignamos la hora con la zona horaria correcta                                       
        v_current_time := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);

        -- Usamos la variable para sacar la hora actual                                                                    
        v_current_hour := TO_NUMBER(TO_CHAR(v_current_time, 'HH24'));

        IF v_current_hour < pkg_aox_util.fn_param_number('META_REMINDER_START_HOUR', 6)
          OR v_current_hour >= pkg_aox_util.fn_param_number('META_REMINDER_END_HOUR', 22) THEN
            RETURN;
        END IF;

        FOR rec IN (
            SELECT a.id_appointment
              FROM appointment a
              LEFT JOIN workspace_setting ws
                ON ws.org_id_organization = a.org_id_organization
              LEFT JOIN ref_reminder_hours rh
                ON rh.id_reminder_hours   = ws.rh_id_reminder_hours
              AND rh.is_active            = 1
            WHERE a.status                = 'CONFIRMADO'
              AND a.attendance_status     = 'NOT_REQUESTED'
              AND a.start_time            > v_current_time
              AND v_current_time          >= a.start_time - NUMTODSINTERVAL(NVL(rh.hours_value, 24), 'HOUR')
              AND a.created_at            <= v_current_time - NUMTODSINTERVAL(30, 'MINUTE')
            ORDER BY a.start_time
            FETCH FIRST NVL(pi_batch_size, 100) ROWS ONLY
        ) LOOP
            BEGIN
                pr_send_attendance_request_wa(rec.id_appointment);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;
    END pr_process_attendance_reminders;

    PROCEDURE pr_process_attendance_timeouts (
        pi_batch_size IN NUMBER DEFAULT 100
    ) IS
        v_current_hour     NUMBER;
        v_current_time     TIMESTAMP;
        v_clean_phone      VARCHAR2(30);
        v_payload          CLOB;
        v_json_initialized BOOLEAN := FALSE;
    BEGIN
        -- Asignamos la hora con la zona horaria correcta
        v_current_time := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);

        -- Usamos la variable para sacar la hora actual
        v_current_hour := TO_NUMBER(TO_CHAR(v_current_time, 'HH24'));

        IF v_current_hour < pkg_aox_util.fn_param_number('META_REMINDER_START_HOUR', 6)
          OR v_current_hour >= pkg_aox_util.fn_param_number('META_REMINDER_END_HOUR', 22) THEN
            RETURN;
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                c.full_name,
                c.phone_number,
                o.name AS organization_name,
                ws.profile_slug AS org_slug,
                p.profile_slug
              FROM appointment a
              JOIN workspace_setting ws 
                ON ws.org_id_organization     = a.org_id_organization
              JOIN customer c 
                ON c.id_customer              = a.cus_id_customer
              JOIN organization o 
                ON o.id_organization          = a.org_id_organization
              JOIN professional p 
                ON p.id_professional          = a.pro_id_professional
            WHERE a.status                    = 'CONFIRMADO'
              AND a.attendance_status         = 'SENT'
              AND a.attendance_due_at         <= v_current_time
              AND ws.unanswered_alert_action  = 'CANCEL'
            ORDER BY a.attendance_due_at
            FETCH FIRST NVL(pi_batch_size, 100) ROWS ONLY
        ) LOOP
            UPDATE appointment
              SET status            = 'CANCELADO',
                  attendance_status = 'EXPIRED',
                  cancel_reason     = 'NO_ATTENDANCE_CONFIRMATION',
                  updated_at        = v_current_time
            WHERE id_appointment    = rec.id_appointment
              AND status = 'CONFIRMADO';

            IF SQL%ROWCOUNT > 0 THEN
                v_clean_phone := fn_clean_whatsapp_phone(rec.phone_number);

                IF v_clean_phone IS NOT NULL
                  AND fn_public_booking_path_suffix(rec.org_slug, rec.profile_slug) IS NOT NULL THEN
                    BEGIN
                        APEX_JSON.initialize_clob_output;
                        v_json_initialized := TRUE;
                        APEX_JSON.open_object;
                            APEX_JSON.write('messaging_product', 'whatsapp');
                            APEX_JSON.write('to', v_clean_phone);
                            APEX_JSON.write('type', 'template');
                            APEX_JSON.open_object('template');
                                APEX_JSON.write(
                                    'name',
                                    NVL(
                                        fn_get_parameter('META_WA_TEMPLATE_AUTO_CANCEL'),
                                        'cancelacion_auto_hasel_v2'
                                    )
                                );
                                APEX_JSON.open_object('language');
                                    APEX_JSON.write('code', NVL(fn_get_parameter('META_WA_TEMPLATE_LANG'), 'es'));
                                APEX_JSON.close_object;
                                APEX_JSON.open_array('components');
                                    -- Variables del cuerpo (Body)
                                    APEX_JSON.open_object;
                                        APEX_JSON.write('type', 'body');
                                        APEX_JSON.open_array('parameters');
                                            APEX_JSON.open_object;
                                            APEX_JSON.write('type', 'text');
                                            APEX_JSON.write('text', rec.full_name);
                                            APEX_JSON.close_object; -- {{1}} Nombre
                                            APEX_JSON.open_object;
                                            APEX_JSON.write('type', 'text');
                                            APEX_JSON.write('text', TO_CHAR(rec.start_time, 'HH24:MI'));
                                            APEX_JSON.close_object; -- {{2}} Hora
                                            APEX_JSON.open_object;
                                            APEX_JSON.write('type', 'text');
                                            APEX_JSON.write('text', rec.organization_name);
                                            APEX_JSON.close_object; -- {{3}} Organización
                                        APEX_JSON.close_array;
                                    APEX_JSON.close_object;
                                    -- Variable del botón (URL)
                                    APEX_JSON.open_object;
                                        APEX_JSON.write('type', 'button');
                                        APEX_JSON.write('sub_type', 'url');
                                        APEX_JSON.write('index', '0');
                                        APEX_JSON.open_array('parameters');
                                            APEX_JSON.open_object; APEX_JSON.write('type', 'text');
                                            APEX_JSON.write(
                                                'text',
                                                fn_public_booking_path_suffix(rec.org_slug, rec.profile_slug)
                                            );
                                            APEX_JSON.close_object;
                                        APEX_JSON.close_array;
                                    APEX_JSON.close_object;
                                APEX_JSON.close_array;
                            APEX_JSON.close_object;
                        APEX_JSON.close_object;

                        v_payload := APEX_JSON.get_clob_output;
                        APEX_JSON.free_output;
                        v_json_initialized := FALSE;

                        -- Enviamos el payload armando a la API de Meta
                        pr_post_whatsapp_message(pi_payload => v_payload);

                    EXCEPTION
                        WHEN OTHERS THEN
                            IF v_json_initialized THEN
                                APEX_JSON.free_output;
                                v_json_initialized := FALSE;
                            END IF;
                            -- Se captura el error para que el ciclo LOOP no se rompa y siga cancelando el resto de las citas
                    END;
                END IF;
            END IF;
        END LOOP;

        COMMIT;
    END pr_process_attendance_timeouts;

END pkg_aox_meta_api;
/


PROMPT CREATE OR REPLACE PACKAGE pkg_aox_appointment_api
CREATE OR REPLACE PACKAGE pkg_aox_appointment_api IS

    -- Listar citas formateadas para FullCalendar (Con JOIN a Customer)
    PROCEDURE pr_list_for_calendar(
        pi_auth_header   IN  VARCHAR2,
        pi_start_date    IN  VARCHAR2,
        pi_end_date      IN  VARCHAR2,
        pi_prof_id       IN  NUMBER DEFAULT NULL,
        pi_loc_id        IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener el detalle de una reserva específica (Con JOIN a Customer)
    PROCEDURE pr_get_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Crear una nueva reserva (Gestionando la tabla Customer)
    PROCEDURE pr_create_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualizar una reserva existente (Reprogramar o cambiar datos del cliente)
    PROCEDURE pr_update_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar una reserva
    PROCEDURE pr_delete_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase 4: subir un adjunto al historial de una cita (Premium: APPOINTMENT_HISTORY).
    -- El body es JSON: { "file_base64": "...", "filename": "...", "mime_type": "..." }
    PROCEDURE pr_upload_attachment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase 4: eliminar un adjunto del historial de una cita.
    PROCEDURE pr_delete_attachment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_attachment_id IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    FUNCTION fn_parse_iso_date(pi_iso_str IN VARCHAR2) RETURN TIMESTAMP WITH TIME ZONE;
END pkg_aox_appointment_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_appointment_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_appointment_api IS


    -- Procedimiento: Listar Citas para Calendario
    PROCEDURE pr_list_for_calendar(
        pi_auth_header   IN  VARCHAR2,
        pi_start_date    IN  VARCHAR2,
        pi_end_date      IN  VARCHAR2,
        pi_prof_id       IN  NUMBER DEFAULT NULL,
        pi_loc_id        IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id          NUMBER;
        v_user_id         NUMBER;
        v_role_id         NUMBER;
        v_actual_pro_id   NUMBER := pi_prof_id;

        v_response_json   json_object_t := json_object_t();
        v_events_arr     json_array_t  := json_array_t();
        v_event_obj       json_object_t;
        v_extended_props  json_object_t;
        v_api_code        VARCHAR2(30);
        v_error_message   VARCHAR2(4000);
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            BEGIN
                SELECT id_professional INTO v_actual_pro_id
                FROM professional WHERE usr_id_user = v_user_id AND org_id_organization = v_org_id;
            EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20001, 'Perfil no asignado.'); END;
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment, c.full_name, c.phone_number, a.start_time, a.end_time,
                a.status, a.attendance_status, a.attendance_reply_at, a.pro_id_professional,
                a.loc_id_location,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                s.name AS service_name, l.name AS location_name
            FROM appointment a
            JOIN customer c     ON a.cus_id_customer = c.id_customer -- JOIN A CUSTOMER
            JOIN professional p ON a.pro_id_professional = p.id_professional
            JOIN app_user u     ON p.usr_id_user         = u.id_user
            JOIN service s      ON a.ser_id_service      = s.id_service
            JOIN location l     ON a.loc_id_location     = l.id_location
            WHERE a.org_id_organization = v_org_id
              AND a.start_time < fn_parse_iso_date(pi_end_date)
              AND a.end_time   > fn_parse_iso_date(pi_start_date)
              AND (v_actual_pro_id IS NULL OR a.pro_id_professional = v_actual_pro_id)
              AND (pi_loc_id IS NULL OR a.loc_id_location = pi_loc_id)
        ) LOOP
            v_event_obj := json_object_t();
            v_event_obj.put('id'    , rec.id_appointment);
            v_event_obj.put('title' , rec.full_name || ' - ' || rec.service_name);
            v_event_obj.put('start' , TO_CHAR(rec.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_event_obj.put('end'   , TO_CHAR(rec.end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_event_obj.put('resourceId', rec.pro_id_professional);

            IF rec.status = 'PENDIENTE' THEN v_event_obj.put('backgroundColor', '#f59e0b');
            ELSIF rec.status = 'CONFIRMADO' THEN v_event_obj.put('backgroundColor', '#10b981');
            ELSIF rec.status = 'COMPLETADO' THEN v_event_obj.put('backgroundColor', '#3b82f6');
            ELSIF rec.status = 'CANCELADO' THEN v_event_obj.put('backgroundColor', '#ef4444');
            END IF;

            v_extended_props := json_object_t();
            v_extended_props.put('customer_phone'   , rec.phone_number);
            v_extended_props.put('status'           , rec.status);
            v_extended_props.put('attendance_status', rec.attendance_status);
            v_extended_props.put(
                'attendance_confirmed',
                CASE WHEN rec.attendance_status = 'CONFIRMED' THEN TRUE ELSE FALSE END
            );
            IF rec.attendance_reply_at IS NOT NULL THEN
                v_extended_props.put(
                    'attendance_reply_at',
                    TO_CHAR(rec.attendance_reply_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                );
            END IF;
            v_extended_props.put('professional_name', rec.professional_name);
            v_extended_props.put('service_name'     , rec.service_name);
            v_extended_props.put('location_name'    , rec.location_name);

            IF rec.status IN ('PENDIENTE', 'CONFIRMADO')
               AND TRUNC(rec.start_time) >= TRUNC(SYSDATE) THEN
                DECLARE
                    v_misaligned_reason VARCHAR2(40);
                BEGIN
                    v_misaligned_reason := pkg_aox_util.fn_get_appointment_schedule_misaligned_reason(
                        rec.pro_id_professional,
                        rec.start_time,
                        rec.end_time,
                        rec.loc_id_location
                    );
                    IF v_misaligned_reason IS NOT NULL THEN
                        v_extended_props.put('schedule_misaligned', TRUE);
                        v_extended_props.put('schedule_misaligned_reason', v_misaligned_reason);
                    ELSE
                        v_extended_props.put('schedule_misaligned', FALSE);
                    END IF;
                END;
            ELSE
                v_extended_props.put('schedule_misaligned', FALSE);
            END IF;

            v_event_obj.put('extendedProps', v_extended_props);
            v_events_arr.append(v_event_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_events_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION WHEN OTHERS THEN
        pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
        pkg_aox_util.pr_log_api(
            pi_api_name        => 'APPOINTMENTS_CALENDAR',
            pi_process_name    => 'PKG_AOX_APPOINTMENT_API.PR_LIST_FOR_CALENDAR',
            pi_http_method     => 'GET',
            pi_endpoint        => '/appointments/calendar',
            pi_org_id          => v_org_id,
            pi_user_id         => v_user_id,
            pi_status          => 'ERROR',
            pi_status_code     => po_status_code,
            pi_error_code      => SQLCODE,
            pi_error_message   => SQLERRM,
            pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
            pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            pi_request_params  => 'start=' || pi_start_date || ';end=' || pi_end_date || ';prof_id=' || pi_prof_id || ';loc_id=' || pi_loc_id
        );
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => po_status_code,
            pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
            pi_message       => v_error_message,
            po_response_body => po_response_body
        );
    END pr_list_for_calendar;

    -- Obtener Cita por ID
    PROCEDURE pr_get_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_user_id       NUMBER;
        v_actual_pro_id NUMBER;
        v_response_json json_object_t := json_object_t();
        v_app_obj       json_object_t;
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            SELECT
                id_professional
            INTO
                v_actual_pro_id
            FROM professional
            WHERE usr_id_user           = v_user_id
                AND org_id_organization = v_org_id;
        END IF;


        FOR rec IN (
            SELECT
                a.id_appointment,
                a.loc_id_location,
                a.pro_id_professional,
                a.ser_id_service,
                c.id_customer,
                c.full_name,
                c.phone_number,
                a.status,
                a.attendance_status,
                a.attendance_reply_at,
                a.start_time,
                a.end_time,
                a.payment_status,
                a.deposit_amount,
                a.refund_status,
                a.refund_amount,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                s.name AS service_name,
                l.name AS location_name
            FROM appointment a
            JOIN customer c     ON a.cus_id_customer     = c.id_customer
            JOIN professional p ON a.pro_id_professional = p.id_professional
            JOIN app_user u     ON p.usr_id_user         = u.id_user
            JOIN service s      ON a.ser_id_service      = s.id_service
            JOIN location l     ON a.loc_id_location     = l.id_location
            WHERE a.id_appointment = pi_app_id
              AND a.org_id_organization = v_org_id
              AND (v_role_id != pkg_aox_util.fn_rol('PROFESIONAL') OR a.pro_id_professional = v_actual_pro_id)
        ) LOOP
            v_app_obj := json_object_t();

            v_app_obj.put('id_appointment'      , rec.id_appointment);
            v_app_obj.put('loc_id_location'     , rec.loc_id_location);
            v_app_obj.put('location_name'       , rec.location_name);
            v_app_obj.put('pro_id_professional' , rec.pro_id_professional);
            v_app_obj.put('professional_name'   , rec.professional_name);
            v_app_obj.put('ser_id_service'      , rec.ser_id_service);
            v_app_obj.put('service_name'        , NVL(rec.service_name, 'Servicio'));
            v_app_obj.put('id_customer'         , rec.id_customer);
            v_app_obj.put('customer_name'       , rec.full_name);
            v_app_obj.put('customer_phone'      , rec.phone_number);
            v_app_obj.put('status'              , rec.status);
            v_app_obj.put('attendance_status'   , rec.attendance_status);
            v_app_obj.put('payment_status'      , rec.payment_status);
            IF rec.deposit_amount IS NOT NULL THEN
                v_app_obj.put('deposit_amount', rec.deposit_amount);
            END IF;
            v_app_obj.put('refund_status', NVL(rec.refund_status, 'NONE'));
            IF rec.refund_amount IS NOT NULL THEN
                v_app_obj.put('refund_amount', rec.refund_amount);
            END IF;
            v_app_obj.put(
                'attendance_confirmed',
                CASE WHEN rec.attendance_status = 'CONFIRMED' THEN TRUE ELSE FALSE END
            );
            IF rec.attendance_reply_at IS NOT NULL THEN
                v_app_obj.put(
                    'attendance_reply_at',
                    TO_CHAR(rec.attendance_reply_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                );
            END IF;
            v_app_obj.put('start_time'          , TO_CHAR(rec.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_app_obj.put('end_time'            , TO_CHAR(rec.end_time,   'YYYY-MM-DD"T"HH24:MI:SS'));

            IF rec.status IN ('PENDIENTE', 'CONFIRMADO')
               AND TRUNC(rec.start_time) >= TRUNC(SYSDATE) THEN
                DECLARE
                    v_misaligned_reason VARCHAR2(40);
                BEGIN
                    v_misaligned_reason := pkg_aox_util.fn_get_appointment_schedule_misaligned_reason(
                        rec.pro_id_professional,
                        rec.start_time,
                        rec.end_time,
                        rec.loc_id_location
                    );
                    IF v_misaligned_reason IS NOT NULL THEN
                        v_app_obj.put('schedule_misaligned', TRUE);
                        v_app_obj.put('schedule_misaligned_reason', v_misaligned_reason);
                    ELSE
                        v_app_obj.put('schedule_misaligned', FALSE);
                    END IF;
                END;
            ELSE
                v_app_obj.put('schedule_misaligned', FALSE);
            END IF;

            -- Historial (Fase 4): notas y adjuntos de la cita si el plan lo incluye.
            IF pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'APPOINTMENT_HISTORY') = 1 THEN
                DECLARE
                    v_history_obj  json_object_t := json_object_t();
                    v_attach_arr   json_array_t  := json_array_t();
                    v_attach_obj   json_object_t;
                    v_notes        CLOB;
                BEGIN
                    BEGIN
                        SELECT notes INTO v_notes
                          FROM appointment_session_record
                         WHERE app_id_appointment = rec.id_appointment;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN v_notes := NULL;
                    END;

                    IF v_notes IS NOT NULL THEN
                        v_history_obj.put('notes', v_notes);
                    ELSE
                        v_history_obj.put_null('notes');
                    END IF;

                    FOR att IN (
                        SELECT id_attachment, file_name, mime_type, size_bytes, storage_url, created_at
                          FROM appointment_attachment
                         WHERE app_id_appointment  = rec.id_appointment
                           AND org_id_organization = v_org_id
                         ORDER BY id_attachment
                    ) LOOP
                        v_attach_obj := json_object_t();
                        v_attach_obj.put('id_attachment', att.id_attachment);
                        v_attach_obj.put('file_name'    , att.file_name);
                        v_attach_obj.put('mime_type'    , att.mime_type);
                        v_attach_obj.put('size_bytes'   , att.size_bytes);
                        v_attach_obj.put('url'          , att.storage_url);
                        v_attach_obj.put('created_at'   , TO_CHAR(att.created_at, 'YYYY-MM-DD"T"HH24:MI:SS'));
                        v_attach_arr.append(v_attach_obj);
                    END LOOP;

                    v_history_obj.put('attachments', v_attach_arr);
                    v_app_obj.put('history', v_history_obj);
                    v_app_obj.put('history_enabled', TRUE);
                END;
            ELSE
                v_app_obj.put('history_enabled', FALSE);
            END IF;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_app_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status', 'error');
        v_response_json.put('message', 'Cita no encontrada.');
        po_response_body := v_response_json.to_clob();
    END pr_get_appointment;

    PROCEDURE pr_create_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_role_id       NUMBER;
        v_user_id       NUMBER;
        v_actual_pro_id NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();

        v_loc_id        NUMBER;
        v_pro_id        NUMBER;
        v_ser_id        NUMBER;
        v_cus_id        NUMBER;
        v_requested_cus_id NUMBER;

        v_cust_name     VARCHAR2(150);
        v_cust_phone    VARCHAR2(20);

        v_start_time_tz TIMESTAMP WITH TIME ZONE;
        v_end_time_tz   TIMESTAMP WITH TIME ZONE;
        v_start_time    TIMESTAMP;
        v_end_time      TIMESTAMP;

        v_overlap_count NUMBER := 0;
        v_customer_access_count NUMBER := 0;
        v_new_id        NUMBER;
        v_lock_dummy    NUMBER;
        v_payment_status appointment.payment_status%TYPE;
        v_deposit_amount appointment.deposit_amount%TYPE;
        v_requires_deposit service.requires_deposit%TYPE := 0;
        v_acknowledge   BOOLEAN := FALSE;
        v_ack_raw       VARCHAR2(20);
        v_notify_customer BOOLEAN := TRUE;
        v_notify_raw    VARCHAR2(20);
        v_misaligned_reason VARCHAR2(40);
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Gate de suscripción: bloquea escritura en READ_ONLY / vencido.
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            BEGIN
                SELECT id_professional
                  INTO v_actual_pro_id
                  FROM professional
                WHERE usr_id_user         = v_user_id
                  AND org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20001, 'Perfil profesional no asignado.');
            END;
        END IF;

        v_json_req := json_object_t.parse(pi_body);

        v_loc_id     := v_json_req.get_number('loc_id_location');
        v_pro_id     := v_json_req.get_number('pro_id_professional');
        v_ser_id     := v_json_req.get_number('ser_id_service');
        IF v_json_req.has('id_customer') THEN
            v_requested_cus_id := v_json_req.get_number('id_customer');
        END IF;
        v_cust_name  := TRIM(v_json_req.get_string('customer_name'));
        v_cust_phone := TRIM(v_json_req.get_string('customer_phone'));

        IF v_json_req.has('acknowledge_schedule_misalignment') THEN
            BEGIN
                v_acknowledge := v_json_req.get_boolean('acknowledge_schedule_misalignment');
            EXCEPTION
                WHEN OTHERS THEN
                    v_ack_raw := LOWER(TRIM(NVL(v_json_req.get_string('acknowledge_schedule_misalignment'), 'false')));
                    v_acknowledge := v_ack_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        IF v_json_req.has('notify_customer') THEN
            BEGIN
                v_notify_customer := v_json_req.get_boolean('notify_customer');
            EXCEPTION
                WHEN OTHERS THEN
                    v_notify_raw := LOWER(TRIM(NVL(v_json_req.get_string('notify_customer'), 'true')));
                    v_notify_customer := v_notify_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            v_pro_id := v_actual_pro_id;
        END IF;

        -- El profesional debe tener el servicio asignado
        DECLARE
            v_ps_count NUMBER := 0;
        BEGIN
            SELECT COUNT(*)
              INTO v_ps_count
              FROM professional_service ps
             WHERE ps.pro_id_professional = v_pro_id
               AND ps.ser_id_service      = v_ser_id
               AND ps.org_id_organization = v_org_id;

            IF v_ps_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20004, 'El profesional no realiza ese servicio.');
            END IF;
        END;

        v_start_time_tz := fn_parse_iso_date(v_json_req.get_string('start_time'));
        v_end_time_tz   := fn_parse_iso_date(v_json_req.get_string('end_time'));

        -- La tabla appointment guarda TIMESTAMP sin zona horaria
        v_start_time := CAST(v_start_time_tz AS TIMESTAMP);
        v_end_time   := CAST(v_end_time_tz   AS TIMESTAMP);

        -- Validación básica de rango horario
        IF v_start_time >= v_end_time THEN
            RAISE_APPLICATION_ERROR(-20003, 'La fecha/hora de inicio debe ser menor a la de fin.');
        END IF;

        -- Gestión de Customer: si viene id_customer, usarlo; si no, crear/actualizar por teléfono.
        IF NVL(v_requested_cus_id, 0) > 0 THEN
            BEGIN
                SELECT
                    id_customer,
                    full_name,
                    phone_number
                INTO
                    v_cus_id,
                    v_cust_name,
                    v_cust_phone
                FROM customer
                WHERE id_customer         = v_requested_cus_id
                  AND org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
            END;

            IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
                SELECT COUNT(*)
                  INTO v_customer_access_count
                  FROM appointment a
                WHERE a.cus_id_customer     = v_cus_id
                  AND a.pro_id_professional = v_pro_id
                  AND a.org_id_organization = v_org_id;

                IF v_customer_access_count = 0 THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No tienes permisos para usar este cliente.');
                END IF;
            END IF;
        ELSE
            IF NVL(v_cust_name, '') = '' THEN
                RAISE_APPLICATION_ERROR(-20006, 'El nombre del cliente es obligatorio.');
            END IF;

            IF NVL(v_cust_phone, '') = '' THEN
                RAISE_APPLICATION_ERROR(-20006, 'El teléfono del cliente es obligatorio.');
            END IF;

            BEGIN
                SELECT id_customer
                  INTO v_cus_id
                  FROM customer
                WHERE phone_number        = v_cust_phone
                  AND org_id_organization = v_org_id;

                UPDATE customer
                  SET full_name   = v_cust_name
                WHERE id_customer = v_cus_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    INSERT INTO customer (
                        org_id_organization,
                        full_name,
                        phone_number
                    )
                    VALUES (
                        v_org_id,
                        v_cust_name,
                        v_cust_phone
                    )
                    RETURNING id_customer INTO v_cus_id;
            END;
        END IF;

        -- Lock del profesional para evitar doble booking concurrente
        SELECT 1
          INTO v_lock_dummy
          FROM professional
        WHERE id_professional     = v_pro_id
          AND org_id_organization = v_org_id
        FOR UPDATE;

        -- Soft-check: fuera de agenda del profesional (requiere confirmación del cliente).
        v_misaligned_reason := pkg_aox_util.fn_get_appointment_schedule_misaligned_reason(
            v_pro_id,
            v_start_time,
            v_end_time,
            v_loc_id
        );

        IF v_misaligned_reason IS NOT NULL AND NOT v_acknowledge THEN
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json.put('status', 'error');
            v_response_json.put('code', 'SCHEDULE_MISALIGNED');
            v_response_json.put('schedule_misaligned_reason', v_misaligned_reason);
            v_response_json.put(
                'message',
                CASE v_misaligned_reason
                    WHEN 'DAY_BLOCKED' THEN
                        'El profesional tiene ese día bloqueado en excepciones de horario.'
                    WHEN 'WRONG_LOCATION' THEN
                        'El profesional no atiende en esa sucursal en el horario elegido.'
                    ELSE
                        'El horario elegido no coincide con los turnos del profesional ese día.'
                END
            );
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Validación de solapamiento
        SELECT COUNT(*)
          INTO v_overlap_count
          FROM appointment a
        WHERE a.org_id_organization = v_org_id
          AND a.pro_id_professional = v_pro_id
          AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
          AND a.start_time < v_end_time
          AND a.end_time   > v_start_time;

        IF v_overlap_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El profesional ya tiene una cita en ese horario.');
        END IF;

        -- Determinar seña del servicio (para turnos internos / contabilidad)
        BEGIN
            SELECT NVL(requires_deposit, 0)
              INTO v_requires_deposit
              FROM service
             WHERE id_service = v_ser_id
               AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20005, 'Servicio no encontrado.');
        END;

        IF v_requires_deposit = 1 THEN
            v_deposit_amount := pkg_aox_payment_settings_api.fn_calculate_deposit(v_ser_id, v_org_id);
        ELSE
            v_deposit_amount := NULL;
        END IF;

        -- Estado de pago manual (solo panel). Si no viene, default seguro:
        -- - Servicio sin seña: NONE
        -- - Servicio con seña: PENDING (reserva telefónica / pendiente de cobro)
        IF v_json_req.has('payment_status') THEN
            v_payment_status := UPPER(TRIM(v_json_req.get_string('payment_status')));
        ELSE
            v_payment_status := CASE WHEN v_requires_deposit = 1 THEN 'PENDING' ELSE 'NONE' END;
        END IF;

        IF v_payment_status NOT IN ('NONE', 'PENDING', 'PAID', 'PAID_TRANSFER', 'PAID_CASH', 'EXEMPT') THEN
            RAISE_APPLICATION_ERROR(-20006, 'payment_status inválido.');
        END IF;

        -- Insertar Cita
        INSERT INTO appointment (
            org_id_organization,
            loc_id_location,
            pro_id_professional,
            ser_id_service,
            cus_id_customer,
            start_time,
            end_time,
            status,
            payment_status,
            deposit_amount,
            public_manage_token
        ) VALUES (
            v_org_id,
            v_loc_id,
            v_pro_id,
            v_ser_id,
            v_cus_id,
            v_start_time,
            v_end_time,
            CASE WHEN v_payment_status = 'PENDING' THEN 'PENDIENTE' ELSE 'CONFIRMADO' END,
            v_payment_status,
            v_deposit_amount,
            LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID()))
        )
        RETURNING id_appointment INTO v_new_id;

        COMMIT;

        -- Auditoría de pago manual (panel). No llama a Pagopar.
        IF v_payment_status <> 'NONE' THEN
            BEGIN
                INSERT INTO payment_transaction (
                    org_id_organization,
                    app_id_appointment,
                    provider,
                    external_reference,
                    id_pedido_comercio,
                    idempotency_key,
                    amount,
                    currency,
                    payment_status,
                    payment_channel,
                    source,
                    processed_at
                ) VALUES (
                    v_org_id,
                    v_new_id,
                    'manual',
                    NULL,
                    'MANUAL-' || v_new_id,
                    'MANUAL:' || v_new_id || ':' || v_payment_status,
                    CASE
                        WHEN v_payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH') THEN NVL(v_deposit_amount, 0)
                        ELSE 0
                    END,
                    'PYG',
                    v_payment_status,
                    'MANUAL',
                    'MANUAL',
                    CURRENT_TIMESTAMP
                );
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;

        -- Plantilla confirmacion_reserva_hasel (mismo flujo que reserva pública).
        IF v_notify_customer THEN
            BEGIN
                pkg_aox_meta_api.pr_enqueue_booking_confirmation_wa(
                    pi_appointment_id => v_new_id
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_response_json.put('id_appointment', v_new_id);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20003, -20006, -20007) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20004 THEN pkg_aox_util.c_not_found_code
                WHEN SQLCODE = -20002 THEN pkg_aox_util.c_conflict_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'APPOINTMENTS_CREATE',
                pi_process_name    => 'PKG_AOX_APPOINTMENT_API.PR_CREATE_APPOINTMENT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/appointments',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_create_appointment;

    PROCEDURE pr_update_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id           NUMBER;
        v_role_id          NUMBER;
        v_user_id          NUMBER;
        v_actual_pro_id    NUMBER := NULL;

        v_json_req         json_object_t;
        v_response_json    json_object_t := json_object_t();

        v_loc_id           NUMBER;
        v_pro_id           NUMBER;
        v_ser_id           NUMBER;
        v_requested_cus_id NUMBER;
        v_cust_name        VARCHAR2(150);
        v_cust_phone       VARCHAR2(20);
        v_cus_id           NUMBER;
        v_current_cus_id   NUMBER;

        v_status           VARCHAR2(20);
        v_old_status       appointment.status%TYPE;
        v_old_start_time   appointment.start_time%TYPE;
        v_old_end_time     appointment.end_time%TYPE;
        v_old_loc_id       appointment.loc_id_location%TYPE;
        v_old_pro_id       appointment.pro_id_professional%TYPE;
        v_old_ser_id       appointment.ser_id_service%TYPE;
        v_start_time_tz    TIMESTAMP WITH TIME ZONE;
        v_end_time_tz      TIMESTAMP WITH TIME ZONE;
        v_start_time       TIMESTAMP;
        v_end_time         TIMESTAMP;

        v_exists           NUMBER := 0;
        v_overlap_count    NUMBER := 0;
        v_customer_access_count NUMBER := 0;
        v_lock_dummy       NUMBER;
        v_session_notes    CLOB;
        v_has_notes_key    BOOLEAN := FALSE;
        v_old_pay_status   appointment.payment_status%TYPE;
        v_old_deposit      appointment.deposit_amount%TYPE;
        v_refund_status    VARCHAR2(20) := 'NONE';
        v_refund_amount    NUMBER := 0;
        v_send_refund_wa   BOOLEAN := FALSE;
        v_acknowledge      BOOLEAN := FALSE;
        v_ack_raw          VARCHAR2(20);
        v_notify_customer  BOOLEAN := TRUE;
        v_notify_raw       VARCHAR2(20);
        v_misaligned_reason VARCHAR2(40);
    BEGIN
        -- Identidad / autorización
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Gate de suscripción: bloquea escritura en READ_ONLY / vencido.
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            BEGIN
                SELECT id_professional
                  INTO v_actual_pro_id
                  FROM professional
                WHERE usr_id_user         = v_user_id
                  AND org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20001, 'Perfil no asignado.');
            END;
        END IF;

        -- 2) Parse body
        v_json_req      := json_object_t.parse(pi_body);
        v_loc_id        := v_json_req.get_number('loc_id_location');
        v_pro_id        := v_json_req.get_number('pro_id_professional');
        v_ser_id        := v_json_req.get_number('ser_id_service');
        IF v_json_req.has('id_customer') THEN
            v_requested_cus_id := v_json_req.get_number('id_customer');
        END IF;
        v_cust_name     := TRIM(v_json_req.get_string('customer_name'));
        v_cust_phone    := TRIM(v_json_req.get_string('customer_phone'));
        v_status        := UPPER(TRIM(v_json_req.get_string('status')));
        -- Historial (Fase 4): notas de la sesion enviadas en el mismo PUT al completar la cita.
        IF v_json_req.has('session_notes') THEN
            v_has_notes_key := TRUE;
            v_session_notes := v_json_req.get_clob('session_notes');
        END IF;

        IF v_json_req.has('acknowledge_schedule_misalignment') THEN
            BEGIN
                v_acknowledge := v_json_req.get_boolean('acknowledge_schedule_misalignment');
            EXCEPTION
                WHEN OTHERS THEN
                    v_ack_raw := LOWER(TRIM(NVL(v_json_req.get_string('acknowledge_schedule_misalignment'), 'false')));
                    v_acknowledge := v_ack_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        IF v_json_req.has('notify_customer') THEN
            BEGIN
                v_notify_customer := v_json_req.get_boolean('notify_customer');
            EXCEPTION
                WHEN OTHERS THEN
                    v_notify_raw := LOWER(TRIM(NVL(v_json_req.get_string('notify_customer'), 'true')));
                    v_notify_customer := v_notify_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        v_start_time_tz := fn_parse_iso_date(v_json_req.get_string('start_time'));
        v_end_time_tz   := fn_parse_iso_date(v_json_req.get_string('end_time'));

        -- Normalizar a TIMESTAMP (tabla appointment usa TIMESTAMP)
        v_start_time := CAST(v_start_time_tz AS TIMESTAMP);
        v_end_time   := CAST(v_end_time_tz   AS TIMESTAMP);

        -- Si es profesional, no puede reasignar a otro profesional
        IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            v_pro_id := v_actual_pro_id;
        END IF;

        -- El profesional debe tener el servicio asignado
        DECLARE
            v_ps_count NUMBER := 0;
        BEGIN
            SELECT COUNT(*)
              INTO v_ps_count
              FROM professional_service ps
             WHERE ps.pro_id_professional = v_pro_id
               AND ps.ser_id_service      = v_ser_id
               AND ps.org_id_organization = v_org_id;

            IF v_ps_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20004, 'El profesional no realiza ese servicio.');
            END IF;
        END;

        -- Validaciones básicas
        IF v_start_time >= v_end_time THEN
            RAISE_APPLICATION_ERROR(-20003, 'La fecha/hora de inicio debe ser menor a la de fin.');
        END IF;

        IF v_status NOT IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO', 'CANCELADO') THEN
            RAISE_APPLICATION_ERROR(-20005, 'Estado inválido.');
        END IF;

        -- Cita existente y dentro del alcance del usuario
        SELECT COUNT(*)
          INTO v_exists
          FROM appointment a
        WHERE a.id_appointment                          = pi_app_id
          AND a.org_id_organization                     = v_org_id
          AND (v_role_id != pkg_aox_util.fn_rol('PROFESIONAL') OR a.pro_id_professional  = v_actual_pro_id);

        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cita no encontrada.');
        END IF;

        -- Lock del profesional para prevenir doble booking concurrente
        SELECT 1
          INTO v_lock_dummy
          FROM professional
        WHERE id_professional     = v_pro_id
          AND org_id_organization = v_org_id
        FOR UPDATE;

        -- Obtener customer actual de la cita (fallback si teléfono vacío)
        SELECT
            cus_id_customer,
            status,
            start_time,
            end_time,
            loc_id_location,
            pro_id_professional,
            ser_id_service,
            payment_status,
            deposit_amount
          INTO
            v_current_cus_id,
            v_old_status,
            v_old_start_time,
            v_old_end_time,
            v_old_loc_id,
            v_old_pro_id,
            v_old_ser_id,
            v_old_pay_status,
            v_old_deposit
          FROM appointment
        WHERE id_appointment      = pi_app_id
          AND org_id_organization = v_org_id;

        IF NVL(v_old_status, '-') = 'CANCELADO' THEN
            RAISE_APPLICATION_ERROR(-20008, 'Las citas canceladas no se pueden modificar.');
        ELSIF NVL(v_old_status, '-') = 'COMPLETADO' THEN
            RAISE_APPLICATION_ERROR(-20008, 'Las citas completadas no se pueden modificar.');
        END IF;

        -- Gestión de customer: si viene id_customer, usarlo; si no, upsert por teléfono.
        IF NVL(v_requested_cus_id, 0) > 0 THEN
            BEGIN
                SELECT
                    id_customer,
                    full_name,
                    phone_number
                INTO
                    v_cus_id,
                    v_cust_name,
                    v_cust_phone
                FROM customer
                WHERE id_customer         = v_requested_cus_id
                  AND org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
            END;

            IF v_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
                SELECT COUNT(*)
                  INTO v_customer_access_count
                  FROM appointment a
                WHERE a.cus_id_customer     = v_cus_id
                  AND a.pro_id_professional = v_pro_id
                  AND a.org_id_organization = v_org_id;

                IF v_customer_access_count = 0 THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No tienes permisos para usar este cliente.');
                END IF;
            END IF;
        ELSE
            IF NVL(v_cust_name, '') = '' THEN
                RAISE_APPLICATION_ERROR(-20006, 'El nombre del cliente es obligatorio.');
            END IF;

            IF NVL(v_cust_phone, '') = '' THEN
                v_cus_id := v_current_cus_id;
                UPDATE customer
                  SET full_name   = v_cust_name
                WHERE id_customer = v_cus_id;
            ELSE
            BEGIN
                SELECT id_customer
                  INTO v_cus_id
                  FROM customer
                WHERE phone_number        = v_cust_phone
                  AND org_id_organization = v_org_id;

                UPDATE customer
                  SET full_name   = v_cust_name
                WHERE id_customer = v_cus_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    INSERT INTO customer (
                        org_id_organization,
                        full_name,
                        phone_number
                    )
                    VALUES (
                        v_org_id,
                        v_cust_name,
                        v_cust_phone
                    )
                    RETURNING id_customer INTO v_cus_id;
            END;
            END IF;
        END IF;

        IF v_status <> 'CANCELADO' THEN
            v_misaligned_reason := pkg_aox_util.fn_get_appointment_schedule_misaligned_reason(
                v_pro_id,
                v_start_time,
                v_end_time,
                v_loc_id
            );

            IF v_misaligned_reason IS NOT NULL AND NOT v_acknowledge THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');
                v_response_json.put('code', 'SCHEDULE_MISALIGNED');
                v_response_json.put('schedule_misaligned_reason', v_misaligned_reason);
                v_response_json.put(
                    'message',
                    CASE v_misaligned_reason
                        WHEN 'DAY_BLOCKED' THEN
                            'El profesional tiene ese día bloqueado en excepciones de horario.'
                        WHEN 'WRONG_LOCATION' THEN
                            'El profesional no atiende en esa sucursal en el horario elegido.'
                        ELSE
                            'El horario elegido no coincide con los turnos del profesional ese día.'
                    END
                );
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        -- Validar solapamiento (excluyendo la misma cita)
        SELECT COUNT(*)
          INTO v_overlap_count
          FROM appointment
        WHERE id_appointment <> pi_app_id
          AND org_id_organization = v_org_id
          AND pro_id_professional = v_pro_id
          AND status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
          AND start_time < v_end_time
          AND end_time   > v_start_time;

        IF v_overlap_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El profesional ya tiene una cita en ese horario.');
        END IF;

        -- Fase C2: cancelacion del negocio + seña.
        IF v_status = 'CANCELADO' AND NVL(v_old_status, '-') <> 'CANCELADO' THEN
            IF NVL(v_old_pay_status, 'NONE') IN ('PAID', 'PAID_TRANSFER')
               AND NVL(v_old_deposit, 0) > 0 THEN
                v_refund_amount := ROUND(v_old_deposit);
                v_refund_status := 'AWAITING_ALIAS';
                v_send_refund_wa := TRUE;
            ELSIF NVL(v_old_pay_status, 'NONE') = 'PENDING' AND NVL(v_old_deposit, 0) > 0 THEN
                UPDATE payment_transaction
                   SET payment_status = 'EXPIRED',
                       processed_at   = CURRENT_TIMESTAMP
                 WHERE app_id_appointment = pi_app_id
                   AND payment_status = 'PENDING';
                v_refund_status := 'NOT_APPLICABLE';
                v_refund_amount := 0;
            ELSE
                v_refund_status := CASE
                    WHEN NVL(v_old_deposit, 0) > 0 THEN 'NOT_APPLICABLE'
                    ELSE 'NONE'
                END;
                v_refund_amount := 0;
            END IF;
        END IF;

        -- Actualizar cita
        UPDATE appointment
          SET loc_id_location     = v_loc_id,
              pro_id_professional = v_pro_id,
              ser_id_service      = v_ser_id,
              cus_id_customer     = v_cus_id,
              start_time          = v_start_time,
              end_time            = v_end_time,
              status              = v_status,
              updated_at          = CURRENT_TIMESTAMP,
              cancel_reason       = CASE
                                      WHEN v_status = 'CANCELADO' THEN 'BUSINESS_CANCELLED'
                                      ELSE cancel_reason
                                    END,
              payment_status      = CASE
                                      WHEN v_status = 'CANCELADO'
                                       AND NVL(v_old_pay_status, 'NONE') = 'PENDING'
                                       AND NVL(v_old_deposit, 0) > 0
                                      THEN 'EXPIRED'
                                      ELSE payment_status
                                    END,
              refund_status       = CASE
                                      WHEN v_status = 'CANCELADO' AND NVL(v_old_status, '-') <> 'CANCELADO'
                                      THEN v_refund_status
                                      ELSE refund_status
                                    END,
              refund_amount       = CASE
                                      WHEN v_status = 'CANCELADO'
                                       AND NVL(v_old_status, '-') <> 'CANCELADO'
                                       AND v_refund_amount > 0
                                      THEN v_refund_amount
                                      WHEN v_status = 'CANCELADO' AND NVL(v_old_status, '-') <> 'CANCELADO'
                                      THEN NULL
                                      ELSE refund_amount
                                    END,
              refund_requested_at = CASE
                                      WHEN v_status = 'CANCELADO'
                                       AND NVL(v_old_status, '-') <> 'CANCELADO'
                                       AND v_refund_status = 'AWAITING_ALIAS'
                                      THEN CURRENT_TIMESTAMP
                                      ELSE refund_requested_at
                                    END
        WHERE id_appointment      = pi_app_id
          AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cita no encontrada.');
        END IF;

        -- Historial de la cita (Fase 4): al pasar a COMPLETADO se guarda el registro
        -- de sesion en la MISMA transaccion (la cita completada es inmutable).
        -- Solo si el plan incluye APPOINTMENT_HISTORY y llegaron notas en el PUT.
        IF v_status = 'COMPLETADO'
           AND v_has_notes_key
           AND pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'APPOINTMENT_HISTORY') = 1 THEN
            MERGE INTO appointment_session_record t
            USING (SELECT pi_app_id AS app_id FROM dual) s
               ON (t.app_id_appointment = s.app_id)
            WHEN MATCHED THEN UPDATE SET
                t.notes          = v_session_notes,
                t.created_by_user = NVL(t.created_by_user, v_user_id),
                t.updated_at     = CURRENT_TIMESTAMP
            WHEN NOT MATCHED THEN
                INSERT (app_id_appointment, org_id_organization, notes, created_by_user)
                VALUES (pi_app_id, v_org_id, v_session_notes, v_user_id);
        END IF;

        COMMIT;

        BEGIN
            IF v_status = 'CANCELADO' AND NVL(v_old_status, '-') <> 'CANCELADO' THEN
                IF v_send_refund_wa THEN
                    pkg_aox_meta_api.pr_send_refund_alias_wa(pi_appointment_id => pi_app_id);
                ELSE
                    pkg_aox_meta_api.pr_send_booking_cancelled_wa(pi_appointment_id => pi_app_id);
                END IF;
            ELSIF v_notify_customer
               AND v_status <> 'CANCELADO'
               AND (
                    v_old_start_time != v_start_time OR
                    v_old_end_time   != v_end_time   OR
                    v_old_loc_id     != v_loc_id     OR
                    v_old_pro_id     != v_pro_id     OR
                    v_old_ser_id     != v_ser_id
               ) THEN
                pkg_aox_meta_api.pr_send_booking_modified_wa(pi_appointment_id => pi_app_id);
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        IF v_send_refund_wa THEN
            v_response_json.put(
                'message',
                'Cita cancelada. Se pidio al cliente su alias SIPAP para el reembolso.'
            );
            v_response_json.put('refund_status', 'AWAITING_ALIAS');
            v_response_json.put('refund_amount', v_refund_amount);
        ELSE
            v_response_json.put('message', 'Cita actualizada correctamente.');
        END IF;
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE = -20004 THEN pkg_aox_util.c_not_found_code
                WHEN SQLCODE IN (-20003, -20005, -20006, -20007, -20008) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20002 THEN pkg_aox_util.c_conflict_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'APPOINTMENTS_UPDATE',
                pi_process_name    => 'PKG_AOX_APPOINTMENT_API.PR_UPDATE_APPOINTMENT',
                pi_http_method     => 'PUT',
                pi_endpoint        => '/appointments/:id',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body,
                pi_request_params  => 'appointment_id=' || pi_app_id
            );

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_update_appointment;

    -- Eliminar Cita
    PROCEDURE pr_delete_appointment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_start_time    appointment.start_time%TYPE;
        v_old_status    appointment.status%TYPE;
        v_old_pay_status appointment.payment_status%TYPE;
        v_old_deposit   appointment.deposit_amount%TYPE;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Gate de suscripción: bloquea eliminación en READ_ONLY / vencido.
        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        SELECT
            start_time,
            status,
            payment_status,
            deposit_amount
          INTO
            v_start_time,
            v_old_status,
            v_old_pay_status,
            v_old_deposit
          FROM appointment
         WHERE id_appointment      = pi_app_id
           AND org_id_organization = v_org_id;

        IF NVL(v_old_status, '-') IN ('CANCELADO', 'COMPLETADO') THEN
            RAISE_APPLICATION_ERROR(-20008, 'Las citas canceladas o completadas no se pueden eliminar.');
        END IF;

        -- Con seña pagada: cancelar (reembolso) en lugar de borrar, para no perder trazabilidad.
        IF NVL(v_old_pay_status, 'NONE') IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH')
           AND NVL(v_old_deposit, 0) > 0 THEN
            RAISE_APPLICATION_ERROR(
                -20008,
                'Esta cita tiene seña pagada. Cancela la cita para gestionar el reembolso; no la elimines.'
            );
        END IF;

        IF NVL(v_old_status, '-') <> 'CANCELADO'
           AND v_start_time > CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP) THEN
            BEGIN
                pkg_aox_meta_api.pr_send_booking_cancelled_wa(pi_appointment_id => pi_app_id);
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;

        -- Seña no pagada: limpiar hijos antes del DELETE (FK_PAYTX_APP / reclamos).
        DELETE FROM org_refund_claim
         WHERE app_id_appointment = pi_app_id;

        DELETE FROM payment_transaction
         WHERE app_id_appointment = pi_app_id
           AND org_id_organization = v_org_id
           AND NVL(payment_status, 'NONE') NOT IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH');

        DELETE FROM appointment
        WHERE id_appointment        = pi_app_id
            AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cita no encontrada.');
        END IF;

        COMMIT;
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'APPOINTMENTS_DELETE',
                pi_process_name    => 'PKG_AOX_APPOINTMENT_API.PR_DELETE_APPOINTMENT',
                pi_http_method     => 'DELETE',
                pi_endpoint        => '/appointments/:id',
                pi_org_id          => v_org_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'appointment_id=' || pi_app_id
            );
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Cita no encontrada.');
            po_response_body := v_response_json.to_clob();
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE = -20004 THEN pkg_aox_util.c_not_found_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'APPOINTMENTS_DELETE',
                pi_process_name    => 'PKG_AOX_APPOINTMENT_API.PR_DELETE_APPOINTMENT',
                pi_http_method     => 'DELETE',
                pi_endpoint        => '/appointments/:id',
                pi_org_id          => v_org_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'appointment_id=' || pi_app_id
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_delete_appointment;

    -- Función de Soporte: Parseo ISO a TIMESTAMP WITH TIME ZONE
    FUNCTION fn_parse_iso_date(pi_iso_str IN VARCHAR2) RETURN TIMESTAMP WITH TIME ZONE IS
        v_clean_str VARCHAR2(100);
    BEGIN
        v_clean_str := REPLACE(REPLACE(pi_iso_str, 'T', ' '), 'Z', '+00:00');
        RETURN TO_TIMESTAMP_TZ(v_clean_str, 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM');
    EXCEPTION WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(-20003, 'Formato de fecha inválido.');
    END fn_parse_iso_date;

    -- Fase 4: subir un adjunto al historial de una cita.
    -- Todo el gateo (feature APPOINTMENT_HISTORY, estado con escritura, paywall de
    -- storage y pertenencia de la cita) lo resuelve pkg_aox_bucket; aquí sólo
    -- resolvemos identidad, parseamos el JSON y decodificamos el base64.
    PROCEDURE pr_upload_attachment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_json          json_object_t;
        v_base64        CLOB;
        v_filename      VARCHAR2(255);
        v_mime          VARCHAR2(150);
        v_blob          BLOB;
        v_att_id        NUMBER;
        v_url           VARCHAR2(1000);
        v_size          NUMBER := 0;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Debes enviar un archivo adjunto.');
        END IF;

        v_json     := json_object_t.parse(pi_body);
        v_base64   := v_json.get_clob('file_base64');
        v_filename := TRIM(v_json.get_string('filename'));
        v_mime     := TRIM(v_json.get_string('mime_type'));

        IF v_base64 IS NULL OR DBMS_LOB.GETLENGTH(v_base64) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El archivo adjunto esta vacio.');
        END IF;

        v_blob := apex_web_service.clobbase642blob(v_base64);

        pkg_aox_bucket.pr_upload_appointment_attachment(
            pi_blob          => v_blob,
            pi_filename      => NVL(v_filename, 'archivo'),
            pi_mime_type     => NVL(v_mime, 'application/octet-stream'),
            pi_org_id        => v_org_id,
            pi_app_id        => pi_app_id,
            pi_user_id       => v_user_id,
            po_attachment_id => v_att_id,
            po_url           => v_url
        );

        BEGIN
            SELECT NVL(size_bytes, 0) INTO v_size
              FROM appointment_attachment
             WHERE id_attachment = v_att_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_size := 0;
        END;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_data_obj.put('id_attachment', v_att_id);
        v_data_obj.put('file_name', NVL(v_filename, 'archivo'));
        v_data_obj.put('mime_type', v_mime);
        v_data_obj.put('size_bytes', v_size);
        v_data_obj.put('url', v_url);
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_upload_attachment;

    -- Fase 4: eliminar un adjunto del historial de una cita.
    PROCEDURE pr_delete_attachment(
        pi_auth_header   IN  VARCHAR2,
        pi_app_id        IN  NUMBER,
        pi_attachment_id IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_cnt           NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- El adjunto debe pertenecer a la cita indicada y a la organización.
        SELECT COUNT(*)
          INTO v_cnt
          FROM appointment_attachment
         WHERE id_attachment       = pi_attachment_id
           AND app_id_appointment  = pi_app_id
           AND org_id_organization = v_org_id;

        IF v_cnt = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Adjunto no encontrado.');
        END IF;

        pkg_aox_bucket.pr_delete_appointment_attachment(
            pi_org_id        => v_org_id,
            pi_attachment_id => pi_attachment_id
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Adjunto eliminado.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_attachment;

END pkg_aox_appointment_api;
/


PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ai_tools
CREATE OR REPLACE PACKAGE pkg_aox_ai_tools IS
    FUNCTION fn_list_appointments(
        pi_start_date      IN VARCHAR2,
        pi_end_date        IN VARCHAR2 DEFAULT NULL,
        pi_professional_id IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_list_next_appointments(
        pi_days            IN NUMBER DEFAULT 7,
        pi_professional_id IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_list_professionals(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_list_services(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_list_locations(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_find_availability(
        pi_target_date     IN VARCHAR2,
        pi_service_id      IN NUMBER,
        pi_location_id     IN NUMBER,
        pi_professional_id IN NUMBER DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_create_appointment(
        pi_customer_name    IN VARCHAR2,
        pi_customer_phone   IN VARCHAR2,
        pi_service_id       IN NUMBER,
        pi_location_id      IN NUMBER,
        pi_start_time       IN VARCHAR2,
        pi_professional_id  IN NUMBER DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_cancel_appointment(
        pi_appointment_id  IN NUMBER,
        pi_confirm_cancel  IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB;

    FUNCTION fn_org_id RETURN NUMBER;
END pkg_aox_ai_tools;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_tools
CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_tools IS

    FUNCTION fn_ctx_number(pi_name IN VARCHAR2) RETURN NUMBER IS
        v_value VARCHAR2(4000);
    BEGIN
        v_value := SYS_CONTEXT('AOX_AI_CTX', pi_name);
        IF v_value IS NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'Contexto de IA no inicializado.');
        END IF;
        RETURN TO_NUMBER(v_value);
    END fn_ctx_number;

    FUNCTION fn_org_id RETURN NUMBER IS
    BEGIN
        RETURN fn_ctx_number('ORG_ID');
    END fn_org_id;

    FUNCTION fn_user_id RETURN NUMBER IS
    BEGIN
        RETURN fn_ctx_number('USER_ID');
    END fn_user_id;

    FUNCTION fn_role_id RETURN NUMBER IS
    BEGIN
        RETURN fn_ctx_number('ROLE_ID');
    END fn_role_id;

    FUNCTION fn_pro_id RETURN NUMBER IS
    BEGIN
        RETURN fn_ctx_number('PRO_ID');
    END fn_pro_id;

    FUNCTION fn_json_response(
        pi_status  IN VARCHAR2,
        pi_message IN VARCHAR2 DEFAULT NULL,
        pi_data    IN json_array_t DEFAULT NULL
    ) RETURN CLOB IS
        v_obj json_object_t := json_object_t();
    BEGIN
        v_obj.put('status', pi_status);
        IF pi_message IS NOT NULL THEN
            v_obj.put('message', pi_message);
        END IF;
        IF pi_data IS NOT NULL THEN
            v_obj.put('data', pi_data);
        END IF;
        RETURN v_obj.to_clob();
    END fn_json_response;

    FUNCTION fn_parse_date(pi_date IN VARCHAR2) RETURN DATE IS
    BEGIN
        RETURN TO_DATE(pi_date, 'YYYY-MM-DD');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20003, 'Formato de fecha invalido. Usa YYYY-MM-DD.');
    END fn_parse_date;

    FUNCTION fn_parse_datetime(pi_value IN VARCHAR2) RETURN TIMESTAMP IS
        v_clean VARCHAR2(100);
    BEGIN
        v_clean := REPLACE(REPLACE(pi_value, 'T', ' '), 'Z', '');
        IF REGEXP_LIKE(v_clean, '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$') THEN
            RETURN TO_TIMESTAMP(v_clean, 'YYYY-MM-DD HH24:MI');
        END IF;
        IF REGEXP_LIKE(v_clean, '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') THEN
            RETURN TO_TIMESTAMP(v_clean, 'YYYY-MM-DD HH24:MI:SS');
        END IF;
        RETURN CAST(TO_TIMESTAMP_TZ(REPLACE(REPLACE(pi_value, 'T', ' '), 'Z', '+00:00'), 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM') AS TIMESTAMP);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20003, 'Formato de fecha y hora invalido. Usa YYYY-MM-DDTHH24:MI:SS.');
    END fn_parse_datetime;

    FUNCTION fn_is_professional RETURN BOOLEAN IS
    BEGIN
        RETURN fn_role_id = pkg_aox_util.fn_rol('PROFESIONAL');
    END fn_is_professional;

    FUNCTION fn_effective_professional(pi_professional_id IN NUMBER) RETURN NUMBER IS
        v_org_id NUMBER := fn_org_id;
        v_pro_id NUMBER := pi_professional_id;
        v_count  NUMBER;
    BEGIN
        IF fn_is_professional THEN
            v_pro_id := fn_pro_id;
            IF NVL(v_pro_id, -1) <= 0 THEN
                RAISE_APPLICATION_ERROR(-20001, 'Perfil profesional no asignado.');
            END IF;
            RETURN v_pro_id;
        END IF;

        IF NVL(v_pro_id, 0) <= 0 THEN
            RETURN NULL;
        END IF;

        SELECT COUNT(*)
        INTO v_count
        FROM professional
        WHERE id_professional     = v_pro_id
          AND org_id_organization = v_org_id
          AND is_active           = 1;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Profesional no encontrado.');
        END IF;

        RETURN v_pro_id;
    END fn_effective_professional;

    PROCEDURE pr_validate_service(
        pi_service_id IN NUMBER,
        po_duration   OUT NUMBER
    ) IS
    BEGIN
        SELECT duration_minutes
        INTO po_duration
        FROM service
        WHERE id_service          = pi_service_id
          AND org_id_organization = fn_org_id
          AND is_active           = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20004, 'Servicio no encontrado o inactivo.');
    END pr_validate_service;

    PROCEDURE pr_validate_location(pi_location_id IN NUMBER) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO v_count
        FROM location
        WHERE id_location         = pi_location_id
          AND org_id_organization = fn_org_id
          AND is_active           = 1;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Local no encontrado o inactivo.');
        END IF;
    END pr_validate_location;

    PROCEDURE pr_validate_professional_service(
        pi_professional_id IN NUMBER,
        pi_service_id      IN NUMBER
    ) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO v_count
        FROM professional_service ps
        JOIN professional p
          ON p.id_professional = ps.pro_id_professional
        WHERE ps.pro_id_professional = pi_professional_id
          AND ps.ser_id_service      = pi_service_id
          AND ps.org_id_organization = fn_org_id
          AND p.is_active            = 1;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'El profesional no realiza ese servicio.');
        END IF;
    END pr_validate_professional_service;

    FUNCTION fn_list_appointments(
        pi_start_date      IN VARCHAR2,
        pi_end_date        IN VARCHAR2 DEFAULT NULL,
        pi_professional_id IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id      NUMBER := fn_org_id;
        v_prof_id     NUMBER;
        v_start_date  DATE;
        v_end_date    DATE;
        v_status      VARCHAR2(20);
        v_arr         json_array_t := json_array_t();
        v_obj         json_object_t;
    BEGIN
        v_prof_id := fn_effective_professional(pi_professional_id);
        v_start_date := fn_parse_date(pi_start_date);
        v_end_date := CASE
            WHEN pi_end_date IS NULL THEN v_start_date + 1
            ELSE fn_parse_date(pi_end_date) + 1
        END;

        v_status := UPPER(TRIM(pi_status));
        IF v_status IN ('', 'TODOS', 'TODAS', 'ALL') THEN
            v_status := NULL;
        END IF;
        IF v_status IS NOT NULL AND v_status NOT IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO', 'CANCELADO') THEN
            RAISE_APPLICATION_ERROR(-20003, 'Estado invalido.');
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                a.status,
                c.full_name AS customer_name,
                c.phone_number AS customer_phone,
                s.id_service,
                s.name AS service_name,
                a.pro_id_professional,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                l.id_location,
                l.name AS location_name
            FROM appointment a
            JOIN customer c
              ON c.id_customer = a.cus_id_customer
            JOIN service s
              ON s.id_service = a.ser_id_service
            JOIN professional p
              ON p.id_professional = a.pro_id_professional
            JOIN app_user u
              ON u.id_user = p.usr_id_user
            JOIN location l
              ON l.id_location = a.loc_id_location
            WHERE a.org_id_organization = v_org_id
              AND a.start_time >= CAST(v_start_date AS TIMESTAMP)
              AND a.start_time <  CAST(v_end_date AS TIMESTAMP)
              AND (v_prof_id IS NULL OR a.pro_id_professional = v_prof_id)
              AND (v_status IS NULL OR a.status = v_status)
            ORDER BY a.start_time ASC
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_appointment', rec.id_appointment);
            v_obj.put('start_time', TO_CHAR(rec.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_obj.put('end_time', TO_CHAR(rec.end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_obj.put('status', rec.status);
            v_obj.put('customer_name', rec.customer_name);
            v_obj.put('customer_phone', rec.customer_phone);
            v_obj.put('id_service', rec.id_service);
            v_obj.put('service_name', rec.service_name);
            v_obj.put('id_professional', rec.pro_id_professional);
            v_obj.put('professional_name', rec.professional_name);
            v_obj.put('id_location', rec.id_location);
            v_obj.put('location_name', rec.location_name);
            v_arr.append(v_obj);
        END LOOP;

        RETURN fn_json_response('success', NULL, v_arr);
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_AI_TOOLS.FN_LIST_APPOINTMENTS',
                pi_org_id          => v_org_id,
                pi_pro_id          => v_prof_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'start_date=' || pi_start_date || ';end_date=' || pi_end_date || ';professional_id=' || pi_professional_id || ';status=' || pi_status
            );
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_list_appointments;

    FUNCTION fn_list_next_appointments(
        pi_days            IN NUMBER DEFAULT 7,
        pi_professional_id IN NUMBER DEFAULT NULL,
        pi_status          IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_days       NUMBER := LEAST(GREATEST(NVL(pi_days, 7), 1), 31);
        v_start_date DATE;
        v_end_date   DATE;
    BEGIN
        v_start_date := TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS DATE));
        v_end_date   := v_start_date + v_days - 1;

        RETURN fn_list_appointments(
            pi_start_date      => TO_CHAR(v_start_date, 'YYYY-MM-DD'),
            pi_end_date        => TO_CHAR(v_end_date, 'YYYY-MM-DD'),
            pi_professional_id => pi_professional_id,
            pi_status          => pi_status
        );
    EXCEPTION
        WHEN OTHERS THEN
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_list_next_appointments;

    FUNCTION fn_list_professionals(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id NUMBER := fn_org_id;
        v_pro_id NUMBER;
        v_query  VARCHAR2(200) := LOWER(TRIM(pi_query));
        v_arr    json_array_t := json_array_t();
        v_obj    json_object_t;
    BEGIN
        v_pro_id := fn_effective_professional(NULL);

        FOR rec IN (
            SELECT
                p.id_professional,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS full_name,
                p.phone_number,
                p.profile_slug
            FROM professional p
            JOIN app_user u
              ON u.id_user = p.usr_id_user
            WHERE p.org_id_organization = v_org_id
              AND p.is_active = 1
              AND (v_pro_id IS NULL OR p.id_professional = v_pro_id)
              AND (
                    v_query IS NULL
                 OR LOWER(NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))) LIKE '%' || v_query || '%'
                 OR LOWER(p.phone_number) LIKE '%' || v_query || '%'
              )
            ORDER BY full_name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_professional', rec.id_professional);
            v_obj.put('full_name', rec.full_name);
            v_obj.put('phone_number', rec.phone_number);
            v_obj.put('profile_slug', rec.profile_slug);
            v_arr.append(v_obj);
        END LOOP;

        RETURN fn_json_response('success', NULL, v_arr);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_list_professionals;

    FUNCTION fn_list_services(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id NUMBER := fn_org_id;
        v_query  VARCHAR2(200) := LOWER(TRIM(pi_query));
        v_arr    json_array_t := json_array_t();
        v_obj    json_object_t;
    BEGIN
        FOR rec IN (
            SELECT id_service, name, duration_minutes, price
            FROM service
            WHERE org_id_organization = v_org_id
              AND is_active = 1
              AND (v_query IS NULL OR LOWER(name) LIKE '%' || v_query || '%')
            ORDER BY name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_service', rec.id_service);
            v_obj.put('name', rec.name);
            v_obj.put('duration_minutes', rec.duration_minutes);
            v_obj.put('price', rec.price);
            v_arr.append(v_obj);
        END LOOP;

        RETURN fn_json_response('success', NULL, v_arr);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_list_services;

    FUNCTION fn_list_locations(
        pi_query IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id NUMBER := fn_org_id;
        v_query  VARCHAR2(200) := LOWER(TRIM(pi_query));
        v_arr    json_array_t := json_array_t();
        v_obj    json_object_t;
    BEGIN
        FOR rec IN (
            SELECT id_location, name, address
            FROM location
            WHERE org_id_organization = v_org_id
              AND is_active = 1
              AND (
                    v_query IS NULL
                 OR LOWER(name) LIKE '%' || v_query || '%'
                 OR LOWER(address) LIKE '%' || v_query || '%'
              )
            ORDER BY name
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('id_location', rec.id_location);
            v_obj.put('name', rec.name);
            v_obj.put('address', rec.address);
            v_arr.append(v_obj);
        END LOOP;

        RETURN fn_json_response('success', NULL, v_arr);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_list_locations;

    FUNCTION fn_find_availability(
        pi_target_date     IN VARCHAR2,
        pi_service_id      IN NUMBER,
        pi_location_id     IN NUMBER,
        pi_professional_id IN NUMBER DEFAULT NULL
    ) RETURN CLOB IS
        v_prof_id  NUMBER;
        v_date     DATE;
        v_duration NUMBER;
        v_arr      json_array_t := json_array_t();
        v_obj      json_object_t;
    BEGIN
        IF pi_location_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_location para buscar disponibilidad.');
        END IF;

        v_prof_id := fn_effective_professional(pi_professional_id);
        IF v_prof_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_professional para buscar disponibilidad.');
        END IF;

        v_date := fn_parse_date(pi_target_date);
        pr_validate_service(pi_service_id, v_duration);
        pr_validate_location(pi_location_id);
        pr_validate_professional_service(v_prof_id, pi_service_id);

        FOR rec IN (
            SELECT slot_time
            FROM TABLE(pkg_aox_util.fn_get_available_slots(v_prof_id, pi_location_id, pi_service_id, v_date))
            ORDER BY slot_time
        ) LOOP
            v_obj := json_object_t();
            v_obj.put('date', TO_CHAR(v_date, 'YYYY-MM-DD'));
            v_obj.put('start_time', rec.slot_time);
            v_obj.put('id_professional', v_prof_id);
            v_obj.put('id_service', pi_service_id);
            v_obj.put('id_location', pi_location_id);
            v_arr.append(v_obj);
        END LOOP;

        RETURN fn_json_response('success', NULL, v_arr);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_find_availability;

    FUNCTION fn_create_appointment(
        pi_customer_name    IN VARCHAR2,
        pi_customer_phone   IN VARCHAR2,
        pi_service_id       IN NUMBER,
        pi_location_id      IN NUMBER,
        pi_start_time       IN VARCHAR2,
        pi_professional_id  IN NUMBER DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id        NUMBER := fn_org_id;
        v_prof_id       NUMBER;
        v_duration      NUMBER;
        v_start_time    TIMESTAMP;
        v_end_time      TIMESTAMP;
        v_customer_id   NUMBER;
        v_overlap_count NUMBER;
        v_new_id        NUMBER;
        v_lock_dummy    NUMBER;
        v_response      json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
        v_prof_name     VARCHAR2(200);
    BEGIN
        IF TRIM(pi_customer_name) IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el nombre del cliente.');
        END IF;
        IF TRIM(pi_customer_phone) IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el telefono del cliente.');
        END IF;
        IF pi_service_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_service.');
        END IF;
        IF pi_location_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_location.');
        END IF;
        IF pi_start_time IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito fecha y hora de inicio.');
        END IF;

        v_prof_id := fn_effective_professional(pi_professional_id);
        IF v_prof_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_professional para crear la cita.');
        END IF;

        pr_validate_service(pi_service_id, v_duration);
        pr_validate_location(pi_location_id);
        pr_validate_professional_service(v_prof_id, pi_service_id);

        v_start_time := fn_parse_datetime(pi_start_time);
        v_end_time := v_start_time + NUMTODSINTERVAL(v_duration, 'MINUTE');

        SELECT 1
        INTO v_lock_dummy
        FROM professional
        WHERE id_professional     = v_prof_id
          AND org_id_organization = v_org_id
        FOR UPDATE;

        SELECT COUNT(*)
        INTO v_overlap_count
        FROM appointment
        WHERE org_id_organization = v_org_id
          AND pro_id_professional = v_prof_id
          AND status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
          AND start_time < v_end_time
          AND end_time > v_start_time;

        IF v_overlap_count > 0 THEN
            RETURN fn_json_response('conflict', 'El profesional ya tiene una cita en ese horario.');
        END IF;

        BEGIN
            SELECT id_customer
            INTO v_customer_id
            FROM customer
            WHERE org_id_organization = v_org_id
              AND phone_number = TRIM(pi_customer_phone);

            UPDATE customer
            SET full_name = TRIM(pi_customer_name)
            WHERE id_customer = v_customer_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                INSERT INTO customer (
                    org_id_organization,
                    full_name,
                    phone_number
                ) VALUES (
                    v_org_id,
                    TRIM(pi_customer_name),
                    TRIM(pi_customer_phone)
                )
                RETURNING id_customer INTO v_customer_id;
        END;

        INSERT INTO appointment (
            org_id_organization,
            loc_id_location,
            pro_id_professional,
            ser_id_service,
            cus_id_customer,
            start_time,
            end_time,
            status,
            public_manage_token
        ) VALUES (
            v_org_id,
            pi_location_id,
            v_prof_id,
            pi_service_id,
            v_customer_id,
            v_start_time,
            v_end_time,
            'CONFIRMADO',
            LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID()))
        )
        RETURNING id_appointment INTO v_new_id;

        BEGIN
            SELECT NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
            INTO v_prof_name
            FROM professional p
            JOIN app_user u
              ON u.id_user = p.usr_id_user
            WHERE p.id_professional = v_prof_id;

            pkg_aox_meta_api.pr_send_whatsapp_notification(
                pi_phone_number  => TRIM(pi_customer_phone),
                pi_customer_name => TRIM(pi_customer_name),
                pi_date_time     => TO_CHAR(v_start_time, 'DD/MM/YYYY HH24:MI'),
                pi_professional  => v_prof_name
            );
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        COMMIT;

        v_response.put('status', 'success');
        v_response.put('message', 'Cita creada correctamente.');
        v_data.put('id_appointment', v_new_id);
        v_data.put('start_time', TO_CHAR(v_start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
        v_data.put('end_time', TO_CHAR(v_end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
        v_data.put('id_customer', v_customer_id);
        v_data.put('id_professional', v_prof_id);
        v_response.put('data', v_data);
        RETURN v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_AI_TOOLS.FN_CREATE_APPOINTMENT',
                pi_org_id          => v_org_id,
                pi_pro_id          => v_prof_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'customer_name=' || pi_customer_name || ';customer_phone=' || pi_customer_phone || ';service_id=' || pi_service_id || ';location_id=' || pi_location_id || ';start_time=' || pi_start_time || ';professional_id=' || pi_professional_id
            );
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_create_appointment;

    FUNCTION fn_cancel_appointment(
        pi_appointment_id  IN NUMBER,
        pi_confirm_cancel  IN VARCHAR2 DEFAULT NULL
    ) RETURN CLOB IS
        v_org_id      NUMBER := fn_org_id;
        v_prof_id     NUMBER;
        v_exists      NUMBER;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        IF pi_appointment_id IS NULL THEN
            RETURN fn_json_response('needs_input', 'Necesito el id_appointment para cancelar.');
        END IF;

        IF UPPER(TRIM(pi_confirm_cancel)) NOT IN ('SI', 'CONFIRMADO', 'CONFIRMAR', 'YES') THEN
            RETURN fn_json_response('confirmation_required', 'Confirma la cancelacion enviando pi_confirm_cancel = SI.');
        END IF;

        v_prof_id := fn_effective_professional(NULL);

        SELECT COUNT(*)
        INTO v_exists
        FROM appointment
        WHERE id_appointment = pi_appointment_id
          AND org_id_organization = v_org_id
          AND (v_prof_id IS NULL OR pro_id_professional = v_prof_id)
          AND status <> 'CANCELADO';

        IF v_exists = 0 THEN
            RETURN fn_json_response('not_found', 'Cita no encontrada o ya cancelada.');
        END IF;

        UPDATE appointment
        SET status = 'CANCELADO'
        WHERE id_appointment = pi_appointment_id
          AND org_id_organization = v_org_id
          AND (v_prof_id IS NULL OR pro_id_professional = v_prof_id);

        COMMIT;

        v_response.put('status', 'success');
        v_response.put('message', 'Cita cancelada correctamente.');
        v_data.put('id_appointment', pi_appointment_id);
        v_response.put('data', v_data);
        RETURN v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_ai(
                pi_process_name    => 'PKG_AOX_AI_TOOLS.FN_CANCEL_APPOINTMENT',
                pi_org_id          => v_org_id,
                pi_pro_id          => v_prof_id,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'appointment_id=' || pi_appointment_id || ';confirm_cancel=' || pi_confirm_cancel
            );
            RETURN fn_json_response('error', REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''));
    END fn_cancel_appointment;
END pkg_aox_ai_tools;
/


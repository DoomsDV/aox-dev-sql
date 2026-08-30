PROMPT CREATE OR REPLACE PACKAGE pkg_aox_public_booking_api
CREATE OR REPLACE PACKAGE pkg_aox_public_booking_api IS
    FUNCTION fn_get_available_slots_pipe (
        pi_pro_id           IN NUMBER,
        pi_loc_id           IN NUMBER,
        pi_ser_id           IN NUMBER,
        pi_target_date      IN DATE,
        pi_exclude_app_id   IN NUMBER DEFAULT NULL
    ) RETURN t_slot_tab PIPELINED;

    -- Obtener perfil público por slug de organización + slug de profesional
    PROCEDURE pr_get_profile(
        pi_org_slug      IN  VARCHAR2,
        pi_prof_slug     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Hub publico del negocio: logo, about, sucursales y equipo (/:org_slug)
    PROCEDURE pr_get_org_hub(
        pi_org_slug      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Perfil público global por platform_user.public_slug (/u/:slug)
    PROCEDURE pr_get_user_public_profile(
        pi_public_slug   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Resolver slug legacy /p/{prof} cuando hay una sola coincidencia activa
    PROCEDURE pr_resolve_professional_slug(
        pi_prof_slug     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener los horarios libres en JSON (Usa tu función PIPELINED por dentro)
    PROCEDURE pr_get_available_slots(
        pi_pro_id           IN  NUMBER,
        pi_loc_id           IN  NUMBER,
        pi_ser_id           IN  NUMBER,
        pi_target_date      IN  VARCHAR2, -- Formato YYYY-MM-DD
        pi_exclude_app_id   IN  NUMBER DEFAULT NULL, -- Edición: ignorar bloqueo de esta cita
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    );

    -- Fechas con al menos 1 slot libre en un rango (plantilla + excepciones + citas)
    PROCEDURE pr_get_available_dates(
        pi_pro_id           IN  NUMBER,
        pi_loc_id           IN  NUMBER,
        pi_ser_id           IN  NUMBER,
        pi_from_date        IN  VARCHAR2, -- YYYY-MM-DD
        pi_to_date          IN  VARCHAR2, -- YYYY-MM-DD
        pi_exclude_app_id   IN  NUMBER DEFAULT NULL,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    );

    -- Crear cita pública (Sin JWT)
    -- pi_idempotency_key (header Idempotency-Key, opcional): si el cliente reintenta el POST
    -- (timeout de red) con la misma key, se devuelve la cita ya creada (REPLAY) en vez de
    -- fallar por solape (ver PKG_AOX_UTIL.pr_idempotency_begin).
    PROCEDURE pr_create_public_app(
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    );

    -- Validar si un cliente existe por su número de teléfono (API Pública)
    PROCEDURE pr_validate_customer(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener resumen de reserva pública por hash /r/:hash
    PROCEDURE pr_get_public_reservation(
        pi_public_token  IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Reprogramar reserva pública por hash /r/:hash
    PROCEDURE pr_update_public_reservation(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Cancelar reserva pública por hash /r/:hash (body opcional: refund_alias)
    PROCEDURE pr_cancel_public_reservation(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase C/C2: cliente carga alias SIPAP cuando refund_status = AWAITING_ALIAS
    PROCEDURE pr_submit_refund_alias(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase B2: subir comprobante SIPAP + OCR (token de gestion publica)
    -- pi_idempotency_key (header Idempotency-Key, opcional): evita re-subir/re-correr OCR si
    -- el cliente reintenta el POST por timeout de red (ver PKG_AOX_UTIL.pr_idempotency_begin).
    PROCEDURE pr_upload_public_receipt(
        pi_public_token     IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    );

END pkg_aox_public_booking_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_public_booking_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_public_booking_api IS

    FUNCTION fn_policy_label(pi_policy IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE UPPER(TRIM(pi_policy))
            WHEN 'FLEXIBLE' THEN 'Flexible'
            WHEN 'MODERATE' THEN 'Moderada'
            WHEN 'STRICT'   THEN 'Estricta (no reembolsable)'
            ELSE NULL
        END;
    END fn_policy_label;

    FUNCTION fn_policy_summary(pi_policy IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE UPPER(TRIM(pi_policy))
            WHEN 'FLEXIBLE' THEN
                'Reembolso total cancelando hasta 24 hs antes del turno.'
            WHEN 'MODERATE' THEN
                'Reembolso del 50% cancelando hasta 24 hs antes. Las cancelaciones posteriores no tienen devolución.'
            WHEN 'STRICT' THEN
                'Las cancelaciones no tienen reembolso de la seña en ningún caso.'
            ELSE NULL
        END;
    END fn_policy_summary;

    -- Monto de reembolso si cancela el CLIENTE (politica snapshot + ventana 24h).
    FUNCTION fn_calc_customer_refund(
        pi_policy         IN VARCHAR2,
        pi_deposit_amount IN NUMBER,
        pi_start_time     IN TIMESTAMP
    ) RETURN NUMBER IS
        v_deposit NUMBER := NVL(pi_deposit_amount, 0);
        v_hours   NUMBER;
    BEGIN
        IF v_deposit <= 0 THEN
            RETURN 0;
        END IF;

        -- Horas hasta el inicio del turno (zona app via CURRENT_TIMESTAMP).
        v_hours := (CAST(pi_start_time AS DATE) - CAST(CURRENT_TIMESTAMP AS DATE)) * 24;

        IF v_hours <= 24 THEN
            RETURN 0;
        END IF;

        RETURN CASE UPPER(TRIM(NVL(pi_policy, 'STRICT')))
            WHEN 'FLEXIBLE' THEN ROUND(v_deposit)
            WHEN 'MODERATE' THEN ROUND(v_deposit * 0.5)
            ELSE 0
        END;
    END fn_calc_customer_refund;

    -- Motivo cuando hay seña pagada pero el preview de reembolso es 0.
    FUNCTION fn_no_refund_reason(
        pi_policy         IN VARCHAR2,
        pi_deposit_amount IN NUMBER,
        pi_start_time     IN TIMESTAMP,
        pi_refund_amount  IN NUMBER
    ) RETURN VARCHAR2 IS
        v_hours NUMBER;
    BEGIN
        IF NVL(pi_refund_amount, 0) > 0 OR NVL(pi_deposit_amount, 0) <= 0 THEN
            RETURN NULL;
        END IF;

        v_hours := (CAST(pi_start_time AS DATE) - CAST(CURRENT_TIMESTAMP AS DATE)) * 24;

        IF v_hours <= 24 THEN
            RETURN 'WITHIN_24H';
        END IF;

        IF UPPER(TRIM(NVL(pi_policy, 'STRICT'))) = 'STRICT' THEN
            RETURN 'POLICY_STRICT';
        END IF;

        RETURN NULL;
    END fn_no_refund_reason;

    FUNCTION fn_sipap_digits(pi_raw IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_REPLACE(NVL(pi_raw, ''), '[^0-9]', '');
    END fn_sipap_digits;

    -- DV oficial SET (Pa_Calcular_Dv_11_A): pesos 2..11 ciclicos.
    FUNCTION fn_sipap_ruc_dv(pi_base IN VARCHAR2) RETURN NUMBER IS
        v_digits VARCHAR2(40);
        v_total  PLS_INTEGER := 0;
        v_peso   PLS_INTEGER := 2;
        v_resto  PLS_INTEGER;
    BEGIN
        v_digits := fn_sipap_digits(pi_base);
        IF v_digits IS NULL OR LENGTH(v_digits) NOT BETWEEN 5 AND 8 THEN
            RETURN NULL;
        END IF;

        FOR i IN REVERSE 1 .. LENGTH(v_digits) LOOP
            v_total := v_total + TO_NUMBER(SUBSTR(v_digits, i, 1)) * v_peso;
            v_peso  := CASE WHEN v_peso >= 11 THEN 2 ELSE v_peso + 1 END;
        END LOOP;

        v_resto := MOD(v_total, 11);
        RETURN CASE WHEN v_resto > 1 THEN 11 - v_resto ELSE 0 END;
    END fn_sipap_ruc_dv;

    -- Normaliza alias SIPAP (celular PY / CI / RUC / email) o -20002.
    FUNCTION fn_normalize_sipap_alias(pi_raw IN VARCHAR2) RETURN VARCHAR2 IS
        v_raw     VARCHAR2(200) := TRIM(pi_raw);
        v_email   VARCHAR2(200);
        v_digits  VARCHAR2(40);
        v_local   VARCHAR2(40);
        v_base    VARCHAR2(40);
        v_dv      NUMBER;
        v_expected NUMBER;
    BEGIN
        IF v_raw IS NULL OR LENGTH(v_raw) = 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Ingresa un alias SIPAP valido: celular paraguayo, CI, RUC o email.'
            );
        END IF;

        IF INSTR(v_raw, '@') > 0 THEN
            v_email := LOWER(REGEXP_REPLACE(v_raw, '\s+', ''));
            IF LENGTH(v_email) BETWEEN 6 AND 100
               AND REGEXP_LIKE(v_email, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$')
            THEN
                RETURN v_email;
            END IF;
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Ingresa un email valido. Ej: nombre@correo.com'
            );
        END IF;

        v_digits := fn_sipap_digits(v_raw);
        IF v_digits IS NULL OR LENGTH(v_digits) = 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Ingresa un alias SIPAP valido: celular paraguayo, CI, RUC o email.'
            );
        END IF;

        -- Misma normalizacion que parseParaguayMobilePhone (TS).
        IF v_digits LIKE '00595%' THEN
            v_digits := SUBSTR(v_digits, 3);
        END IF;
        IF v_digits LIKE '5950%' THEN
            v_digits := '595' || SUBSTR(v_digits, 5);
        END IF;

        IF REGEXP_LIKE(v_digits, '^5959[0-9]{8}$') THEN
            RETURN '0' || SUBSTR(v_digits, 4);
        END IF;
        IF REGEXP_LIKE(v_digits, '^09[0-9]{8}$') THEN
            RETURN v_digits;
        END IF;
        IF REGEXP_LIKE(v_digits, '^9[0-9]{8}$') THEN
            RETURN '0' || v_digits;
        END IF;

        v_local := CASE
            WHEN v_digits LIKE '595%' THEN SUBSTR(v_digits, 4)
            ELSE v_digits
        END;
        IF REGEXP_LIKE(v_digits, '^09[0-9]{0,8}$')
           OR REGEXP_LIKE(v_local, '^9[0-9]{8}$')
        THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Ingresa un celular paraguayo valido. Ej: 0981 123 456'
            );
        END IF;

        IF LENGTH(v_digits) BETWEEN 6 AND 9 THEN
            v_base := SUBSTR(v_digits, 1, LENGTH(v_digits) - 1);
            v_dv := TO_NUMBER(SUBSTR(v_digits, -1));
            v_expected := fn_sipap_ruc_dv(v_base);
            IF v_expected IS NOT NULL AND v_expected = v_dv THEN
                RETURN v_base || '-' || TO_CHAR(v_dv);
            END IF;
        END IF;

        IF LENGTH(v_digits) >= 9 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Ingresa un RUC paraguayo valido. Ej: 80012345-6'
            );
        END IF;

        IF REGEXP_LIKE(v_digits, '^[0-9]{5,8}$') AND NOT REGEXP_LIKE(v_digits, '^0+$') THEN
            RETURN v_digits;
        END IF;

        RAISE_APPLICATION_ERROR(
            pkg_aox_util.c_sqlcode_validation,
            'Ingresa un alias SIPAP valido: celular paraguayo, CI, RUC o email.'
        );
    END fn_normalize_sipap_alias;

    FUNCTION fn_new_hasel_reference RETURN VARCHAR2 IS
    BEGIN
        RETURN 'HASEL-' || DBMS_RANDOM.STRING('X', 8);
    END fn_new_hasel_reference;

    /** Datos SIPAP públicos de la org (NULL object si no hay cobros habilitados). */
    FUNCTION fn_public_deposit_settings(pi_org_id IN NUMBER) RETURN json_object_t IS
        v_obj            json_object_t := json_object_t();
        v_sipap          json_object_t := json_object_t();
        v_enabled        NUMBER := 0;
        v_policy         org_payment_settings.refund_policy%TYPE;
        v_bank_name      ref_sipap_bank.name%TYPE;
        v_account_holder org_payment_settings.account_holder%TYPE;
        v_document_id    org_payment_settings.document_id%TYPE;
        v_bank_alias     org_payment_settings.bank_alias%TYPE;
    BEGIN
        IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'DEPOSIT_COLLECTION') = 0 THEN
            v_obj.put('deposits_enabled', 0);
            RETURN v_obj;
        END IF;

        BEGIN
            SELECT /*+ no_parallel */
                   NVL(ops.deposits_enabled, 0),
                   ops.refund_policy,
                   b.name,
                   ops.account_holder,
                   ops.document_id,
                   ops.bank_alias
              INTO v_enabled,
                   v_policy,
                   v_bank_name,
                   v_account_holder,
                   v_document_id,
                   v_bank_alias
              FROM org_payment_settings ops
              LEFT JOIN ref_sipap_bank b
                ON b.id_bank = ops.bank_id
             WHERE ops.org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_obj.put('deposits_enabled', 0);
                RETURN v_obj;
        END;

        v_obj.put('deposits_enabled', v_enabled);
        IF v_enabled = 1 THEN
            v_obj.put('refund_policy', v_policy);
            v_obj.put('refund_policy_label', fn_policy_label(v_policy));
            v_obj.put('refund_policy_summary', fn_policy_summary(v_policy));
            v_sipap.put('bank_name', v_bank_name);
            v_sipap.put('account_holder', v_account_holder);
            v_sipap.put('document_id', v_document_id);
            v_sipap.put('bank_alias', v_bank_alias);
            v_obj.put('sipap', v_sipap);
        END IF;

        RETURN v_obj;
    END fn_public_deposit_settings;

    -- Tu Función Pipelined (Optimizada)
    -- Nota: Asume que tienes un TYPE t_slot_rec AS OBJECT (slot_time VARCHAR2(5))
    -- y TYPE t_slot_tab AS TABLE OF t_slot_rec creados en tu base de datos.
    FUNCTION fn_get_available_slots_pipe (
        pi_pro_id           IN NUMBER,
        pi_loc_id           IN NUMBER,
        pi_ser_id           IN NUMBER,
        pi_target_date      IN DATE,
        pi_exclude_app_id   IN NUMBER DEFAULT NULL
    ) RETURN t_slot_tab PIPELINED IS
        -- Rangos de citas del pro ese día (precargados en memoria, fuera del loop de slots).
        TYPE t_time_range IS RECORD (
            start_time appointment.start_time%TYPE,
            end_time   appointment.end_time%TYPE
        );
        TYPE t_time_range_tab IS TABLE OF t_time_range;

        -- Cierres parciales de la sucursal ese día (formato HH24:MI, igual que location_closure).
        TYPE t_closure_range IS RECORD (
            start_hm location_closure.start_time%TYPE,
            end_hm   location_closure.end_time%TYPE
        );
        TYPE t_closure_range_tab IS TABLE OF t_closure_range;

        v_day_of_week       NUMBER;
        v_service_duration  NUMBER;
        v_work_start        TIMESTAMP;
        v_work_end          TIMESTAMP;
        v_current_slot      TIMESTAMP;
        v_slot_end          TIMESTAMP;
        v_has_overlap       BOOLEAN;
        v_step_minutes      NUMBER;
        v_org_id            NUMBER;
        v_now               TIMESTAMP := CURRENT_TIMESTAMP;
        v_exception_type    VARCHAR2(20);
        v_target_trunc      DATE := TRUNC(pi_target_date);
        v_appointments      t_time_range_tab;
        v_partial_closures  t_closure_range_tab;
    BEGIN
        BEGIN
            SELECT p.org_id_organization
              INTO v_org_id
              FROM professional p
             WHERE p.id_professional = pi_pro_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_org_id := NULL;
        END;

        v_step_minutes := pkg_aox_util.fn_get_org_booking_slot_minutes(v_org_id);

        -- 1. Duración del servicio
        BEGIN
            SELECT
              s.duration_minutes
            INTO
              v_service_duration
            FROM service s
            JOIN professional_service ps ON s.id_service  = ps.ser_id_service
            WHERE ps.pro_id_professional                  = pi_pro_id AND s.id_service = pi_ser_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        -- 0. Cierre de sucursal full-day: corte temprano.
        IF pkg_aox_util.fn_is_location_closed_full_day(pi_loc_id, v_target_trunc) = 1 THEN
            RETURN;
        END IF;

        v_exception_type := pkg_aox_util.fn_get_schedule_exception_type(pi_pro_id, v_target_trunc);

        IF v_exception_type = 'BLOCKED' THEN
            RETURN;
        END IF;

        v_day_of_week := v_target_trunc - TRUNC(v_target_trunc, 'IW') + 1;

        -- Precarga set-based (1 query cada una, no por slot candidato): citas vigentes
        -- del profesional ese día y cierres parciales de la sucursal ese día.
        SELECT start_time, end_time
          BULK COLLECT INTO v_appointments
          FROM appointment
         WHERE pro_id_professional = pi_pro_id
           AND TRUNC(start_time)   = v_target_trunc
           AND status             != 'CANCELADO'
           AND (pi_exclude_app_id IS NULL OR id_appointment <> pi_exclude_app_id);

        SELECT start_time, end_time
          BULK COLLECT INTO v_partial_closures
          FROM location_closure
         WHERE loc_id_location = pi_loc_id
           AND is_full_day     = 0
           AND v_target_trunc BETWEEN start_date AND end_date;

        -- 2. Bloques: excepcion OVERRIDE o plantilla semanal
        FOR rec IN (
            SELECT s.start_time, s.end_time
            FROM professional_schedule_exception_slot s
            JOIN professional_schedule_exception e
              ON e.id_schedule_exception = s.exc_id_schedule_exception
            WHERE e.pro_id_professional = pi_pro_id
              AND e.exception_date = v_target_trunc
              AND e.exception_type = 'OVERRIDE'
              AND s.loc_id_location = pi_loc_id
            UNION ALL
            SELECT ps.start_time, ps.end_time
            FROM professional_schedule ps
            WHERE ps.pro_id_professional = pi_pro_id
              AND ps.loc_id_location = pi_loc_id
              AND ps.day_of_week = v_day_of_week
              AND v_exception_type IS NULL
        ) LOOP
            v_work_start    := TO_TIMESTAMP(TO_CHAR(pi_target_date, 'YYYY-MM-DD') || ' ' || rec.start_time, 'YYYY-MM-DD HH24:MI');
            v_work_end      := TO_TIMESTAMP(TO_CHAR(pi_target_date, 'YYYY-MM-DD') || ' ' || rec.end_time, 'YYYY-MM-DD HH24:MI');
            v_current_slot  := v_work_start;

            -- 3. Iteración de Bloques
            WHILE v_current_slot + NUMTODSINTERVAL(v_service_duration, 'MINUTE') <= v_work_end LOOP
                v_slot_end := v_current_slot + NUMTODSINTERVAL(v_service_duration, 'MINUTE');

                -- AJUSTE DE ORO 2: No ofrecer turnos en el pasado si es hoy
                IF v_current_slot > v_now OR TRUNC(pi_target_date) > TRUNC(v_now) THEN

                    -- AJUSTE DE ORO 1: chequeo de solapamiento en memoria (sin ir a la base por slot)
                    v_has_overlap := FALSE;
                    FOR i IN 1 .. v_appointments.COUNT LOOP
                        IF v_current_slot < v_appointments(i).end_time
                           AND v_slot_end   > v_appointments(i).start_time THEN
                            v_has_overlap := TRUE;
                            EXIT;
                        END IF;
                    END LOOP;

                    -- Filtrar cierres parciales de la sucursal (en memoria).
                    IF NOT v_has_overlap THEN
                        DECLARE
                            v_slot_start_hm VARCHAR2(5) := TO_CHAR(v_current_slot, 'HH24:MI');
                            v_slot_end_hm   VARCHAR2(5) := TO_CHAR(v_slot_end,     'HH24:MI');
                        BEGIN
                            FOR i IN 1 .. v_partial_closures.COUNT LOOP
                                IF v_slot_start_hm < v_partial_closures(i).end_hm
                                   AND v_slot_end_hm > v_partial_closures(i).start_hm THEN
                                    v_has_overlap := TRUE;
                                    EXIT;
                                END IF;
                            END LOOP;
                        END;
                    END IF;

                    IF NOT v_has_overlap THEN
                        PIPE ROW(t_slot_rec(TO_CHAR(v_current_slot, 'HH24:MI')));
                    END IF;

                END IF;

                v_current_slot := v_current_slot + NUMTODSINTERVAL(v_step_minutes, 'MINUTE');
            END LOOP;
        END LOOP;
        RETURN;
    END fn_get_available_slots_pipe;

    -- API 1: Obtener Huecos Libres (Usa la función pipe)
    PROCEDURE pr_get_available_slots(
        pi_pro_id           IN  NUMBER,
        pi_loc_id           IN  NUMBER,
        pi_ser_id           IN  NUMBER,
        pi_target_date      IN  VARCHAR2,
        pi_exclude_app_id   IN  NUMBER DEFAULT NULL,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_slots_arr     json_array_t  := json_array_t();
        v_target_date   DATE;
    BEGIN
        v_target_date := TO_DATE(pi_target_date, 'YYYY-MM-DD');

        -- Llamamos a tu función mágica y armamos el array
        FOR rec IN (
            SELECT
              slot_time
            FROM TABLE(fn_get_available_slots_pipe(
                pi_pro_id,
                pi_loc_id,
                pi_ser_id,
                v_target_date,
                pi_exclude_app_id
            ))
        ) LOOP
            v_slots_arr.append(rec.slot_time);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_slots_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_AVAILABLE_SLOTS',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_GET_AVAILABLE_SLOTS',
                pi_http_method     => 'GET',
                pi_endpoint        => '/public/available-slots',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'pro_id=' || pi_pro_id
                    || ';loc_id=' || pi_loc_id
                    || ';ser_id=' || pi_ser_id
                    || ';target_date=' || pi_target_date
                    || ';exclude_app_id=' || pi_exclude_app_id
            );
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Error al consultar disponibilidad: Verifique el formato de fecha.');
            po_response_body := v_response_json.to_clob();
    END pr_get_available_slots;

    -- API 1b: Fechas del rango con al menos un hueco libre
    PROCEDURE pr_get_available_dates(
        pi_pro_id           IN  NUMBER,
        pi_loc_id           IN  NUMBER,
        pi_ser_id           IN  NUMBER,
        pi_from_date        IN  VARCHAR2,
        pi_to_date          IN  VARCHAR2,
        pi_exclude_app_id   IN  NUMBER DEFAULT NULL,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_dates_arr     json_array_t  := json_array_t();
        v_from_date     DATE;
        v_to_date       DATE;
        v_cursor        DATE;
        v_has_slot      NUMBER;
        v_span_days     NUMBER;
    BEGIN
        IF pi_pro_id IS NULL OR pi_loc_id IS NULL OR pi_ser_id IS NULL
           OR pi_from_date IS NULL OR TRIM(pi_from_date) = ''
           OR pi_to_date IS NULL OR TRIM(pi_to_date) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'pro_id, loc_id, ser_id, from_date y to_date son obligatorios.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        BEGIN
            v_from_date := TRUNC(TO_DATE(TRIM(pi_from_date), 'YYYY-MM-DD'));
            v_to_date   := TRUNC(TO_DATE(TRIM(pi_to_date), 'YYYY-MM-DD'));
        EXCEPTION
            WHEN OTHERS THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'from_date y to_date deben ser YYYY-MM-DD.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        IF v_to_date < v_from_date THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'to_date no puede ser anterior a from_date.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        v_span_days := v_to_date - v_from_date;
        IF v_span_days > 62 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El rango máximo es de 62 días.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        v_cursor := v_from_date;
        WHILE v_cursor <= v_to_date LOOP
            v_has_slot := 0;
            BEGIN
                SELECT /*+ FIRST_ROWS(1) */ 1
                  INTO v_has_slot
                  FROM TABLE(fn_get_available_slots_pipe(
                      pi_pro_id,
                      pi_loc_id,
                      pi_ser_id,
                      v_cursor,
                      pi_exclude_app_id
                  ))
                 WHERE ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_has_slot := 0;
            END;

            IF v_has_slot = 1 THEN
                v_dates_arr.append(TO_CHAR(v_cursor, 'YYYY-MM-DD'));
            END IF;

            v_cursor := v_cursor + 1;
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_dates_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_AVAILABLE_DATES',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_GET_AVAILABLE_DATES',
                pi_http_method     => 'GET',
                pi_endpoint        => '/public/available-dates',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'pro_id=' || pi_pro_id
                    || ';loc_id=' || pi_loc_id
                    || ';ser_id=' || pi_ser_id
                    || ';from_date=' || pi_from_date
                    || ';to_date=' || pi_to_date
                    || ';exclude_app_id=' || pi_exclude_app_id
            );
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Error al consultar fechas disponibles.');
            po_response_body := v_response_json.to_clob();
    END pr_get_available_dates;

    -- API 2: Obtener Perfil por slug de org + profesional
    PROCEDURE pr_get_profile(
        pi_org_slug      IN  VARCHAR2,
        pi_prof_slug     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_profile_obj   json_object_t := json_object_t();
        v_services_arr  json_array_t  := json_array_t();
        v_locations_arr json_array_t  := json_array_t();
        v_srv_obj       json_object_t;
        v_loc_obj       json_object_t;

        v_pro_id            NUMBER;
        v_org_id            NUMBER;
        v_org_slug          VARCHAR2(100);
        v_org_name          VARCHAR2(255);
        v_prof_slug         VARCHAR2(100);
        v_full_name         VARCHAR2(255);
        v_specialty         VARCHAR2(255);
        v_image_url         VARCHAR2(4000);
    BEGIN
        IF pi_org_slug IS NULL OR trim(pi_org_slug) = ''
           OR pi_prof_slug IS NULL OR trim(pi_prof_slug) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'org_slug y profile_slug son obligatorios.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        BEGIN
            SELECT
                p.id_professional,
                p.org_id_organization,
                ws.profile_slug,
                o.name,
                p.profile_slug,
                NVL(p.display_name, TRIM(pu.first_name || ' ' || pu.last_name)),
                s.name,
                NVL(
                    NULLIF(TRIM(p.profile_image_url), ''),
                    NULLIF(TRIM(pu.profile_image_url), '')
                )
            INTO
                v_pro_id,
                v_org_id,
                v_org_slug,
                v_org_name,
                v_prof_slug,
                v_full_name,
                v_specialty,
                v_image_url
            FROM professional p
            JOIN workspace_setting ws ON ws.org_id_organization = p.org_id_organization
            JOIN organization o ON o.id_organization = p.org_id_organization
            JOIN org_member m ON m.id_org_member = p.usr_id_user
            JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
            LEFT JOIN specialty s ON p.spe_id_specialty = s.id_specialty
            WHERE lower(trim(ws.profile_slug)) = lower(trim(pi_org_slug))
              AND lower(trim(p.profile_slug)) = lower(trim(pi_prof_slug))
              AND p.is_active = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Profesional no encontrado.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        v_profile_obj.put('id_professional'     , v_pro_id);
        v_profile_obj.put('org_id_organization' , v_org_id);
        v_profile_obj.put('organization_slug'   , v_org_slug);
        v_profile_obj.put('organization_name'   , v_org_name);
        v_profile_obj.put('profile_slug'        , v_prof_slug);
        v_profile_obj.put('full_name'           , v_full_name);
        v_profile_obj.put('specialty'           , NVL(v_specialty, 'Sin especialidad'));

        IF v_image_url IS NOT NULL THEN
            v_profile_obj.put('image_url', v_image_url);
        ELSE
            v_profile_obj.put('image_url', '');
        END IF;

        -- 3. Obtener servicios de este médico
        FOR rec IN (
            SELECT
                s.id_service,
                s.name,
                s.duration_minutes,
                s.price,
                s.hide_public_price,
                s.hidden_public_price_label,
                s.image_url,
                s.requires_deposit,
                s.deposit_type,
                s.deposit_value,
                NVL(
                    NULLIF(TRIM(s.hidden_public_price_label), ''),
                    NVL(NULLIF(TRIM(ws.hidden_public_price_label), ''), 'A evaluar')
                ) AS resolved_hidden_price_label
            FROM service s
            JOIN professional_service ps ON s.id_service = ps.ser_id_service
            LEFT JOIN workspace_setting ws ON ws.org_id_organization = s.org_id_organization
            WHERE ps.pro_id_professional = v_pro_id AND s.is_active = 1
        ) LOOP
            v_srv_obj := json_object_t();
            v_srv_obj.put('id_service'       , rec.id_service);
            v_srv_obj.put('name'             , rec.name);
            v_srv_obj.put('duration_minutes' , rec.duration_minutes);
            v_srv_obj.put('price'            , rec.price);
            v_srv_obj.put('hide_public_price', NVL(rec.hide_public_price, 0));
            v_srv_obj.put('hidden_price_label', rec.resolved_hidden_price_label);
            IF rec.image_url IS NOT NULL THEN
                v_srv_obj.put('image_url', rec.image_url);
            ELSE
                v_srv_obj.put('image_url', '');
            END IF;
            v_srv_obj.put('requires_deposit' , rec.requires_deposit);
            v_srv_obj.put('deposit_type'     , rec.deposit_type);
            v_srv_obj.put('deposit_value'    , rec.deposit_value);
            IF NVL(rec.requires_deposit, 0) = 1 THEN
                BEGIN
                    v_srv_obj.put(
                        'deposit_amount',
                        pkg_aox_payment_settings_api.fn_calculate_deposit(rec.id_service, v_org_id)
                    );
                EXCEPTION
                    WHEN OTHERS THEN
                        v_srv_obj.put('deposit_amount', 0);
                END;
            ELSE
                v_srv_obj.put('deposit_amount', 0);
            END IF;
            v_services_arr.append(v_srv_obj);
        END LOOP;

        v_profile_obj.put('services', v_services_arr);

        -- 4. Obtener sucursales públicas activas de la organización
        FOR loc_rec IN (
            SELECT
                id_location,
                name,
                address,
                latitude,
                longitude
            FROM location
            WHERE org_id_organization = v_org_id
              AND is_active           = 1
            ORDER BY name
        ) LOOP
            v_loc_obj := json_object_t();
            v_loc_obj.put('id_location', loc_rec.id_location);
            v_loc_obj.put('name'       , loc_rec.name);
            v_loc_obj.put('address'    , loc_rec.address);

            IF loc_rec.latitude IS NOT NULL THEN
                v_loc_obj.put('latitude', loc_rec.latitude);
            END IF;

            IF loc_rec.longitude IS NOT NULL THEN
                v_loc_obj.put('longitude', loc_rec.longitude);
            END IF;

            v_locations_arr.append(v_loc_obj);
        END LOOP;

        v_profile_obj.put('locations', v_locations_arr);
        v_profile_obj.put('deposit_settings', fn_public_deposit_settings(v_org_id));

        -- 5. Responder
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_profile_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_PROFILE',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_GET_PROFILE',
                pi_http_method     => 'GET',
                pi_endpoint        => '/public/profile/:org_slug/:prof_slug',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'org_slug=' || pi_org_slug || ';prof_slug=' || pi_prof_slug
            );
    END pr_get_profile;

    PROCEDURE pr_get_org_hub(
        pi_org_slug      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json   json_object_t := json_object_t();
        v_hub_obj         json_object_t := json_object_t();
        v_locations_arr   json_array_t  := json_array_t();
        v_professionals_arr json_array_t := json_array_t();
        v_categories_arr  json_array_t  := json_array_t();
        v_loc_ids_arr     json_array_t;
        v_loc_obj         json_object_t;
        v_pro_obj         json_object_t;
        v_service_names_arr json_array_t;

        v_org_id          NUMBER;
        v_org_slug        VARCHAR2(100);
        v_org_name        VARCHAR2(255);
        v_logo_url        VARCHAR2(500);
        v_banner_url      VARCHAR2(500);
        v_facebook_url    VARCHAR2(500);
        v_instagram_url   VARCHAR2(500);
        v_business_hours  VARCHAR2(4000);
        v_description     VARCHAR2(1000);
        v_public_whatsapp VARCHAR2(20);
        v_sub_state       VARCHAR2(20);
        v_maintenance     BOOLEAN := FALSE;
        v_booking_path    VARCHAR2(300);
        v_gallery_arr     json_array_t := json_array_t();
        v_gallery_item    json_object_t;
    BEGIN
        IF pi_org_slug IS NULL OR trim(pi_org_slug) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'org_slug es obligatorio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF pkg_aox_util.fn_is_reserved_org_slug(pi_org_slug) = 1 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Negocio no encontrado.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        BEGIN
            SELECT
                o.id_organization,
                ws.profile_slug,
                o.name,
                ws.logo_url,
                ws.banner_url,
                ws.facebook_url,
                ws.instagram_url,
                ws.business_hours,
                ws.description,
                ws.public_whatsapp
            INTO
                v_org_id,
                v_org_slug,
                v_org_name,
                v_logo_url,
                v_banner_url,
                v_facebook_url,
                v_instagram_url,
                v_business_hours,
                v_description,
                v_public_whatsapp
            FROM workspace_setting ws
            JOIN organization o ON o.id_organization = ws.org_id_organization
            WHERE lower(trim(ws.profile_slug)) = lower(trim(pi_org_slug));
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Negocio no encontrado.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        v_sub_state := pkg_aox_subscription_api.fn_get_subscription_state(v_org_id);
        IF v_sub_state IN ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') THEN
            v_maintenance := TRUE;
        END IF;

        v_hub_obj.put('organization_name', v_org_name);
        v_hub_obj.put('organization_slug', v_org_slug);
        v_hub_obj.put('logo_url', NVL(v_logo_url, ''));
        v_hub_obj.put('banner_url', NVL(v_banner_url, ''));
        v_hub_obj.put('facebook_url', NVL(v_facebook_url, ''));
        v_hub_obj.put('instagram_url', NVL(v_instagram_url, ''));
        IF v_business_hours IS NOT NULL AND length(trim(v_business_hours)) > 0 THEN
            BEGIN
                v_hub_obj.put('business_hours', json_object_t.parse(v_business_hours));
            EXCEPTION
                WHEN OTHERS THEN
                    v_hub_obj.put('business_hours', v_business_hours);
            END;
        ELSE
            v_hub_obj.put_null('business_hours');
        END IF;
        v_hub_obj.put('description', NVL(v_description, ''));
        v_hub_obj.put('public_whatsapp', NVL(v_public_whatsapp, ''));
        v_hub_obj.put('maintenance', v_maintenance);

        FOR gal_rec IN (
            SELECT id_gallery_image, image_url, sort_order
              FROM org_gallery_image
             WHERE org_id_organization = v_org_id
             ORDER BY sort_order, id_gallery_image
        ) LOOP
            v_gallery_item := json_object_t();
            v_gallery_item.put('id', gal_rec.id_gallery_image);
            v_gallery_item.put('url', NVL(gal_rec.image_url, ''));
            v_gallery_item.put('sort_order', gal_rec.sort_order);
            v_gallery_arr.append(v_gallery_item);
        END LOOP;
        v_hub_obj.put('gallery_images', v_gallery_arr);

        FOR loc_rec IN (
            SELECT
                id_location,
                name,
                address,
                latitude,
                longitude
            FROM location
            WHERE org_id_organization = v_org_id
              AND is_active = 1
            ORDER BY name
        ) LOOP
            v_loc_obj := json_object_t();
            v_loc_obj.put('id_location', loc_rec.id_location);
            v_loc_obj.put('name', loc_rec.name);
            v_loc_obj.put('address', NVL(loc_rec.address, ''));
            IF loc_rec.latitude IS NOT NULL THEN
                v_loc_obj.put('latitude', loc_rec.latitude);
            END IF;
            IF loc_rec.longitude IS NOT NULL THEN
                v_loc_obj.put('longitude', loc_rec.longitude);
            END IF;
            v_locations_arr.append(v_loc_obj);
        END LOOP;

        -- Categorias / servicios activos del negocio (tags del Overview)
        FOR cat_rec IN (
            SELECT s.name
              FROM service s
             WHERE s.org_id_organization = v_org_id
               AND s.is_active = 1
               AND s.name IS NOT NULL
               AND TRIM(s.name) IS NOT NULL
             ORDER BY LOWER(s.name)
             FETCH FIRST 16 ROWS ONLY
        ) LOOP
            v_categories_arr.append(cat_rec.name);
        END LOOP;

        FOR pro_rec IN (
            SELECT
                p.id_professional,
                p.profile_slug,
                NVL(p.display_name, TRIM(pu.first_name || ' ' || pu.last_name)) AS full_name,
                NVL(s.name, 'Sin especialidad') AS specialty,
                NVL(
                    NULLIF(TRIM(p.profile_image_url), ''),
                    NULLIF(TRIM(pu.profile_image_url), '')
                ) AS image_url
            FROM professional p
            JOIN org_member m ON m.id_org_member = p.usr_id_user
            JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
            LEFT JOIN specialty s ON p.spe_id_specialty = s.id_specialty
            WHERE p.org_id_organization = v_org_id
              AND p.is_active = 1
              AND p.profile_slug IS NOT NULL
              AND TRIM(p.profile_slug) IS NOT NULL
            ORDER BY full_name
        ) LOOP
            v_pro_obj := json_object_t();
            v_pro_obj.put('id_professional', pro_rec.id_professional);
            v_pro_obj.put('full_name', pro_rec.full_name);
            v_pro_obj.put('specialty', pro_rec.specialty);
            v_pro_obj.put('image_url', NVL(pro_rec.image_url, ''));
            v_pro_obj.put('profile_slug', pro_rec.profile_slug);
            v_booking_path :=
                '/' || lower(trim(v_org_slug)) ||
                '/p/' || lower(trim(pro_rec.profile_slug));
            v_pro_obj.put('booking_path', v_booking_path);

            v_loc_ids_arr := json_array_t();
            FOR loc_id_rec IN (
                SELECT DISTINCT ps.loc_id_location AS id_location
                  FROM professional_schedule ps
                  JOIN location l ON l.id_location = ps.loc_id_location
                 WHERE ps.pro_id_professional = pro_rec.id_professional
                   AND l.org_id_organization = v_org_id
                   AND l.is_active = 1
                 ORDER BY ps.loc_id_location
            ) LOOP
                v_loc_ids_arr.append(loc_id_rec.id_location);
            END LOOP;
            v_pro_obj.put('location_ids', v_loc_ids_arr);

            v_service_names_arr := json_array_t();
            FOR srv_rec IN (
                SELECT s.name
                  FROM service s
                  JOIN professional_service ps ON s.id_service = ps.ser_id_service
                 WHERE ps.pro_id_professional = pro_rec.id_professional
                   AND s.org_id_organization = v_org_id
                   AND s.is_active = 1
                   AND s.name IS NOT NULL
                   AND TRIM(s.name) IS NOT NULL
                 ORDER BY LOWER(s.name)
                 FETCH FIRST 3 ROWS ONLY
            ) LOOP
                v_service_names_arr.append(srv_rec.name);
            END LOOP;
            v_pro_obj.put('service_names', v_service_names_arr);

            v_professionals_arr.append(v_pro_obj);
        END LOOP;

        v_hub_obj.put('locations', v_locations_arr);
        v_hub_obj.put('professionals', v_professionals_arr);
        v_hub_obj.put('service_categories', v_categories_arr);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_hub_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_ORG_HUB',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_GET_ORG_HUB',
                pi_http_method     => 'GET',
                pi_endpoint        => '/public/org/:slug',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'org_slug=' || pi_org_slug
            );
    END pr_get_org_hub;

    PROCEDURE pr_get_user_public_profile(
        pi_public_slug   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_profile_obj   json_object_t := json_object_t();
        v_locations_arr json_array_t  := json_array_t();
        v_services_arr  json_array_t;
        v_loc_obj       json_object_t;
        v_srv_obj       json_object_t;

        v_pu_id         NUMBER;
        v_public_slug   VARCHAR2(100);
        v_full_name     VARCHAR2(255);
        v_image_url     VARCHAR2(4000);
    BEGIN
        IF pi_public_slug IS NULL OR trim(pi_public_slug) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'public_slug es obligatorio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        BEGIN
            SELECT
                pu.id_platform_user,
                pu.public_slug,
                pu.first_name || ' ' || pu.last_name,
                pu.profile_image_url
            INTO
                v_pu_id,
                v_public_slug,
                v_full_name,
                v_image_url
            FROM platform_user pu
            WHERE lower(trim(pu.public_slug)) = lower(trim(pi_public_slug))
              AND pu.is_active = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Perfil no encontrado.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        v_profile_obj.put('public_slug', v_public_slug);
        v_profile_obj.put('full_name'  , v_full_name);
        v_profile_obj.put('image_url'  , NVL(v_image_url, ''));

        FOR loc_rec IN (
            SELECT DISTINCT
                l.id_location,
                l.name,
                l.address,
                l.latitude,
                l.longitude,
                p.id_professional,
                p.org_id_organization,
                o.name AS organization_name,
                ws.profile_slug AS organization_slug,
                ws.logo_url AS organization_logo_url
            FROM org_member m
            JOIN professional p ON p.usr_id_user = m.id_org_member
                               AND p.is_active = 1
            JOIN organization o ON o.id_organization = p.org_id_organization
            JOIN workspace_setting ws ON ws.org_id_organization = p.org_id_organization
            JOIN professional_schedule sch ON sch.pro_id_professional = p.id_professional
                                          AND sch.org_id_organization = p.org_id_organization
            JOIN location l ON l.id_location = sch.loc_id_location
                           AND l.org_id_organization = p.org_id_organization
                           AND l.is_active = 1
            WHERE m.platform_user_id = v_pu_id
              AND m.is_active = 1
            ORDER BY organization_name, l.name
        ) LOOP
            v_loc_obj := json_object_t();
            v_services_arr := json_array_t();

            v_loc_obj.put('id_location'       , loc_rec.id_location);
            v_loc_obj.put('name'              , loc_rec.name);
            v_loc_obj.put('address'           , loc_rec.address);

            IF loc_rec.latitude IS NOT NULL THEN
                v_loc_obj.put('latitude', loc_rec.latitude);
            END IF;

            IF loc_rec.longitude IS NOT NULL THEN
                v_loc_obj.put('longitude', loc_rec.longitude);
            END IF;

            v_loc_obj.put('org_id_organization', loc_rec.org_id_organization);
            v_loc_obj.put('organization_name'  , loc_rec.organization_name);
            v_loc_obj.put('organization_slug'  , loc_rec.organization_slug);
            v_loc_obj.put('organization_logo_url', NVL(loc_rec.organization_logo_url, ''));
            v_loc_obj.put('id_professional'    , loc_rec.id_professional);

            FOR srv_rec IN (
                SELECT
                    s.id_service,
                    s.name,
                    s.duration_minutes,
                    s.price,
                    s.hide_public_price,
                    s.hidden_public_price_label,
                    s.image_url,
                    s.requires_deposit,
                    s.deposit_type,
                    s.deposit_value,
                    NVL(
                        NULLIF(TRIM(s.hidden_public_price_label), ''),
                        NVL(NULLIF(TRIM(ws.hidden_public_price_label), ''), 'A evaluar')
                    ) AS resolved_hidden_price_label
                FROM service s
                JOIN professional_service ps ON s.id_service = ps.ser_id_service
                LEFT JOIN workspace_setting ws
                    ON ws.org_id_organization = s.org_id_organization
                WHERE ps.pro_id_professional = loc_rec.id_professional
                  AND s.is_active = 1
                ORDER BY s.name
            ) LOOP
                v_srv_obj := json_object_t();
                v_srv_obj.put('id_service'       , srv_rec.id_service);
                v_srv_obj.put('name'             , srv_rec.name);
                v_srv_obj.put('duration_minutes' , srv_rec.duration_minutes);
                v_srv_obj.put('price'            , srv_rec.price);
                v_srv_obj.put('hide_public_price', NVL(srv_rec.hide_public_price, 0));
                v_srv_obj.put('hidden_price_label', srv_rec.resolved_hidden_price_label);
                IF srv_rec.image_url IS NOT NULL THEN
                    v_srv_obj.put('image_url', srv_rec.image_url);
                ELSE
                    v_srv_obj.put('image_url', '');
                END IF;
                v_srv_obj.put('requires_deposit' , srv_rec.requires_deposit);
                v_srv_obj.put('deposit_type'     , srv_rec.deposit_type);
                v_srv_obj.put('deposit_value'    , srv_rec.deposit_value);
                IF NVL(srv_rec.requires_deposit, 0) = 1 THEN
                    BEGIN
                        v_srv_obj.put(
                            'deposit_amount',
                            pkg_aox_payment_settings_api.fn_calculate_deposit(
                                srv_rec.id_service,
                                loc_rec.org_id_organization
                            )
                        );
                    EXCEPTION
                        WHEN OTHERS THEN
                            v_srv_obj.put('deposit_amount', 0);
                    END;
                ELSE
                    v_srv_obj.put('deposit_amount', 0);
                END IF;
                v_services_arr.append(v_srv_obj);
            END LOOP;

            v_loc_obj.put('services', v_services_arr);
            v_loc_obj.put('deposit_settings', fn_public_deposit_settings(loc_rec.org_id_organization));
            v_locations_arr.append(v_loc_obj);
        END LOOP;

        v_profile_obj.put('locations', v_locations_arr);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_profile_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_USER_PROFILE',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_GET_USER_PUBLIC_PROFILE',
                pi_http_method     => 'GET',
                pi_endpoint        => '/public/user/:public_slug',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'public_slug=' || pi_public_slug
            );
    END pr_get_user_public_profile;

    PROCEDURE pr_resolve_professional_slug(
        pi_prof_slug     IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
        v_match_count   NUMBER := 0;
        v_org_slug      VARCHAR2(100);
        v_prof_slug     VARCHAR2(100);
    BEGIN
        IF pi_prof_slug IS NULL OR trim(pi_prof_slug) = '' THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'profile_slug es obligatorio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        FOR rec IN (
            SELECT
                ws.profile_slug AS organization_slug,
                p.profile_slug AS profile_slug
            FROM professional p
            JOIN workspace_setting ws ON ws.org_id_organization = p.org_id_organization
            WHERE lower(trim(p.profile_slug)) = lower(trim(pi_prof_slug))
              AND p.is_active = 1
              AND p.profile_slug IS NOT NULL
        ) LOOP
            v_match_count  := v_match_count + 1;
            v_org_slug     := rec.organization_slug;
            v_prof_slug    := rec.profile_slug;

            IF v_match_count > 1 THEN
                EXIT;
            END IF;
        END LOOP;

        IF v_match_count = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Profesional no encontrado.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_match_count > 1 THEN
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Este enlace pertenece a varias organizaciones. Usá el enlace completo con el nombre del negocio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        v_data_obj.put('organization_slug', v_org_slug);
        v_data_obj.put('profile_slug', v_prof_slug);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    END pr_resolve_professional_slug;

    -- API 3: Crear Cita Pública
    PROCEDURE pr_create_public_app(
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        c_idem_scope        CONSTANT VARCHAR2(64) := 'PUBLIC_BOOKING_CREATE';
        v_idem_key          VARCHAR2(255) := TRIM(pi_idempotency_key);
        v_idem_request_hash VARCHAR2(64);
        v_idem_outcome      VARCHAR2(20);
        v_idem_resp_status  NUMBER;
        v_idem_resp_payload CLOB;

        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_org_id        NUMBER;
        v_loc_id        NUMBER;
        v_pro_id        NUMBER;
        v_ser_id        NUMBER;
        v_start_time    TIMESTAMP WITH TIME ZONE;
        v_end_time      TIMESTAMP WITH TIME ZONE;
        v_overlap_count NUMBER;
        v_available_count NUMBER;
        v_lock_dummy    NUMBER;
        v_loc_count     NUMBER;
        v_service_duration_minutes service.duration_minutes%TYPE;

        -- Nuevas variables para cliente
        v_cus_phone            VARCHAR2(20);
        v_cus_name             VARCHAR2(150);
        v_cus_id               NUMBER;
        v_new_app_id           appointment.id_appointment%TYPE;
        v_reserve_for_deposit  BOOLEAN := FALSE;
        v_requires_deposit     service.requires_deposit%TYPE := 0;
        v_deposit_amount       NUMBER;
        v_deposit_type         service.deposit_type%TYPE;
        v_deposit_value        service.deposit_value%TYPE;
        v_pending_minutes      NUMBER := NVL(TO_NUMBER(fn_get_parameter('SIPAP_PAYMENT_PENDING_MINUTES')), 60);
        v_expires_at           TIMESTAMP WITH TIME ZONE;
        v_policy_accepted      BOOLEAN := FALSE;
        v_policy_code          org_payment_settings.refund_policy%TYPE;
        v_bank_name            ref_sipap_bank.name%TYPE;
        v_account_holder       org_payment_settings.account_holder%TYPE;
        v_document_id          org_payment_settings.document_id%TYPE;
        v_bank_alias           org_payment_settings.bank_alias%TYPE;
        v_payment_reference    VARCHAR2(32);
        v_sipap_obj            json_object_t;
        v_public_token         VARCHAR2(128);
    BEGIN
        v_json_req   := json_object_t.parse(pi_body);
        v_org_id     := v_json_req.get_number('org_id_organization'); -- Viene oculto desde el frontend
        v_pro_id     := v_json_req.get_number('pro_id_professional');
        v_loc_id     := v_json_req.get_number('loc_id_location');
        v_ser_id     := v_json_req.get_number('ser_id_service');

        -- Extraer los datos del cliente desde el JSON
        v_cus_phone  := TRIM(v_json_req.get_string('customer_phone'));
        v_cus_name   := TRIM(v_json_req.get_string('customer_name'));

        IF v_idem_key IS NOT NULL THEN
            v_idem_request_hash := RAWTOHEX(DBMS_CRYPTO.HASH(
                UTL_I18N.STRING_TO_RAW(
                    TO_CHAR(v_org_id) || '|' || TO_CHAR(v_pro_id) || '|' || TO_CHAR(v_loc_id) || '|' ||
                    TO_CHAR(v_ser_id) || '|' || NVL(v_cus_phone, '') || '|' ||
                    NVL(v_json_req.get_string('start_time'), ''),
                    'AL32UTF8'
                ),
                DBMS_CRYPTO.HASH_SH256
            ));

            pkg_aox_util.pr_idempotency_begin(
                pi_scope             => c_idem_scope,
                pi_key               => v_idem_key,
                pi_request_hash      => v_idem_request_hash,
                po_outcome           => v_idem_outcome,
                po_response_status   => v_idem_resp_status,
                po_response_payload  => v_idem_resp_payload
            );

            IF v_idem_outcome = 'REPLAY' THEN
                -- Reintento del mismo pedido: devolver la cita ya creada en vez de fallar por
                -- solape/duplicado.
                po_status_code    := v_idem_resp_status;
                po_response_body  := v_idem_resp_payload;
                RETURN;
            ELSIF v_idem_outcome = 'IN_PROGRESS' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_progress,
                    pi_message       => 'Ya hay una reserva en curso para esta operacion. Espera unos segundos e intenta de nuevo.',
                    po_response_body => po_response_body
                );
                RETURN;
            ELSIF v_idem_outcome = 'CONFLICT' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_conflict,
                    pi_message       => 'La clave de idempotencia ya fue usada con una reserva distinta.',
                    po_response_body => po_response_body
                );
                RETURN;
            END IF;
            -- outcome = 'NEW': continua el flujo normal abajo
        END IF;

        BEGIN
            pkg_aox_util.pr_assert_rate_limit(
                pi_scope        => 'PUBLIC_BOOKING',
                pi_key          => NVL(NULLIF(REGEXP_REPLACE(NVL(v_cus_phone, ''), '[^0-9]', ''), ''), pkg_aox_util.fn_client_ip),
                pi_max_attempts => pkg_aox_util.fn_param_number('RATE_LIMIT_PUBLIC_BOOKING_MAX', 20),
                pi_window_sec   => pkg_aox_util.fn_param_number('RATE_LIMIT_PUBLIC_BOOKING_WINDOW_SEC', 900)
            );
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE = pkg_aox_util.c_sqlcode_rate_limit THEN
                    po_status_code := pkg_aox_util.c_too_many_requests_code;
                    pkg_aox_util.pr_build_api_error_response(
                        pi_status_code   => po_status_code,
                        pi_api_code      => pkg_aox_util.c_api_code_rate_limited,
                        pi_message       => REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: ', ''),
                        po_response_body => po_response_body
                    );
                    RETURN;
                END IF;
                RAISE;
        END;

        -- Gate de suscripción: reserva pública en mantenimiento si la org está en READ_ONLY / vencido.
        pkg_aox_subscription_api.pr_assert_public_booking_open(v_org_id);

        -- Validar que el cliente haya enviado sus datos
        IF v_cus_phone IS NULL OR v_cus_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20003, 'El nombre y el teléfono son obligatorios para agendar.');
        END IF;

        IF v_json_req.has('reserve_for_deposit') THEN
            BEGIN
                v_reserve_for_deposit := CASE
                    WHEN v_json_req.get_boolean('reserve_for_deposit') THEN TRUE
                    ELSE FALSE
                END;
            EXCEPTION
                WHEN OTHERS THEN
                    v_reserve_for_deposit := NVL(TO_NUMBER(v_json_req.get_string('reserve_for_deposit')), 0) = 1;
            END;
        END IF;

        IF v_json_req.has('policy_accepted') THEN
            BEGIN
                v_policy_accepted := CASE
                    WHEN v_json_req.get_boolean('policy_accepted') THEN TRUE
                    ELSE FALSE
                END;
            EXCEPTION
                WHEN OTHERS THEN
                    v_policy_accepted := NVL(TO_NUMBER(v_json_req.get_string('policy_accepted')), 0) = 1;
            END;
        END IF;

        -- Fase 6: la sucursal debe pertenecer a la misma organización.
        SELECT COUNT(*) INTO v_loc_count
          FROM location
         WHERE id_location = v_loc_id AND org_id_organization = v_org_id;

        IF v_loc_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20025, 'Sucursal no encontrada.');
        END IF;

        SELECT NVL(requires_deposit, 0), deposit_type, deposit_value, duration_minutes
          INTO v_requires_deposit, v_deposit_type, v_deposit_value, v_service_duration_minutes
          FROM service
         WHERE id_service = v_ser_id
           AND org_id_organization = v_org_id;

        IF v_reserve_for_deposit AND NVL(v_requires_deposit, 0) = 0 THEN
            RAISE_APPLICATION_ERROR(-20020, 'Este servicio no requiere seña.');
        END IF;

        -- Fase 2: si el servicio exige seña, forzar el hold SIPAP sin depender
        -- del flag reserve_for_deposit enviado por el cliente (bypass de seña obligatoria).
        IF NVL(v_requires_deposit, 0) = 1 AND NOT v_reserve_for_deposit THEN
            v_reserve_for_deposit := TRUE;
        END IF;

        IF v_reserve_for_deposit THEN
            IF pkg_aox_payment_settings_api.fn_org_deposits_enabled(v_org_id) = 0 THEN
                RAISE_APPLICATION_ERROR(
                    -20022,
                    'Este negocio aún no tiene habilitado el cobro de señas por transferencia.'
                );
            END IF;

            SELECT /*+ no_parallel */
                   ops.refund_policy,
                   b.name,
                   ops.account_holder,
                   ops.document_id,
                   ops.bank_alias
              INTO v_policy_code, v_bank_name, v_account_holder, v_document_id, v_bank_alias
              FROM org_payment_settings ops
              LEFT JOIN ref_sipap_bank b
                ON b.id_bank = ops.bank_id
             WHERE ops.org_id_organization = v_org_id
               AND NVL(ops.deposits_enabled, 0) = 1;

            IF v_policy_code IS NULL OR v_bank_alias IS NULL OR v_bank_name IS NULL THEN
                RAISE_APPLICATION_ERROR(
                    -20023,
                    'Faltan la política o los datos SIPAP del comercio. Contactá al negocio.'
                );
            END IF;

            IF NOT v_policy_accepted THEN
                RAISE_APPLICATION_ERROR(
                    -20024,
                    'Debés aceptar la política de cancelación para continuar con la seña.'
                );
            END IF;

            v_deposit_amount := pkg_aox_payment_settings_api.fn_calculate_deposit(v_ser_id, v_org_id);
            IF v_deposit_amount <= 0 THEN
                RAISE_APPLICATION_ERROR(-20021, 'El monto de la seña no es válido.');
            END IF;
        END IF;

        -- Parsear la Z y la T
        -- Parsear ignorando el TimeZone del cliente para forzar la hora local exacta
        v_start_time := TO_TIMESTAMP(SUBSTR(REPLACE(v_json_req.get_string('start_time'), 'T', ' '), 1, 19), 'YYYY-MM-DD HH24:MI:SS');

        -- Fase 3: end_time siempre se recalcula server-side desde la duración del
        -- servicio; nunca se confía en el end_time enviado por el cliente.
        v_end_time := v_start_time + NUMTODSINTERVAL(v_service_duration_minutes, 'MINUTE');

        -- Fase 1: lock del profesional para evitar doble booking concurrente
        -- (mismo patrón que ya usa el panel en pr_create_appointment_row).
        SELECT 1
          INTO v_lock_dummy
          FROM professional
        WHERE id_professional     = v_pro_id
          AND org_id_organization = v_org_id
        FOR UPDATE;

        SELECT
            COUNT(*)
        INTO
            v_available_count
        FROM TABLE(fn_get_available_slots_pipe(v_pro_id, v_loc_id, v_ser_id, CAST(v_start_time AS DATE)))
        WHERE slot_time = TO_CHAR(v_start_time, 'HH24:MI');

        IF v_available_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'El horario seleccionado ya no está disponible.');
        END IF;

        -- Validación de solapamiento (esto ahora funcionará perfectamente)
        SELECT
            COUNT(*)
        INTO
            v_overlap_count
        FROM appointment
        WHERE pro_id_professional   = v_pro_id
            AND org_id_organization = v_org_id
            AND status              != 'CANCELADO'
            AND (
                v_reserve_for_deposit = FALSE
                OR payment_status NOT IN ('EXPIRED', 'FAILED')
            )
            AND (start_time < v_end_time AND end_time > v_start_time);

        IF v_overlap_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Este horario acaba de ser reservado por alguien más.');
        END IF;

        -- GESTIÓN DEL CLIENTE (Upsert: Buscar o Crear)
        BEGIN
            -- Intentamos encontrar el cliente por su teléfono y organización
            SELECT
                id_customer
            INTO
                v_cus_id
            FROM customer
            WHERE phone_number          = v_cus_phone
                AND org_id_organization = v_org_id;

            -- Actualizamos el nombre por si el cliente lo cambió o puso su apellido esta vez
            UPDATE customer
            SET full_name     = v_cus_name
            WHERE id_customer = v_cus_id;

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Si es la primera vez que agenda con este teléfono, lo creamos
                INSERT INTO customer (
                    org_id_organization,
                    full_name,
                    phone_number
                )
                VALUES (
                    v_org_id,
                    v_cus_name,
                    v_cus_phone
                )
                RETURNING id_customer INTO v_cus_id;
        END;

        -- CREACIÓN DE LA CITA
        IF v_reserve_for_deposit THEN
            v_expires_at := CURRENT_TIMESTAMP + NUMTODSINTERVAL(v_pending_minutes, 'MINUTE');
            v_payment_reference := fn_new_hasel_reference();
            v_public_token := LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID()));

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
                payment_expires_at,
                public_manage_token,
                policy_code_snapshot,
                policy_accepted_at
            ) VALUES (
                v_org_id,
                v_loc_id,
                v_pro_id,
                v_ser_id,
                v_cus_id,
                v_start_time,
                v_end_time,
                'PENDIENTE',
                'PENDING',
                v_deposit_amount,
                v_expires_at,
                v_public_token,
                v_policy_code,
                CURRENT_TIMESTAMP
            )
            RETURNING id_appointment INTO v_new_app_id;

            INSERT INTO payment_transaction (
                org_id_organization,
                app_id_appointment,
                provider,
                id_pedido_comercio,
                payment_reference,
                idempotency_key,
                amount,
                payment_status,
                payment_channel,
                source
            ) VALUES (
                v_org_id,
                v_new_app_id,
                'sipap',
                v_payment_reference,
                v_payment_reference,
                'HOLD-SIPAP:' || v_new_app_id || ':' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISSFF3'),
                v_deposit_amount,
                'PENDING',
                'TRANSFER',
                'WEB'
            );

            COMMIT;

            v_sipap_obj := json_object_t();
            v_sipap_obj.put('bank_name', v_bank_name);
            v_sipap_obj.put('account_holder', v_account_holder);
            v_sipap_obj.put('document_id', v_document_id);
            v_sipap_obj.put('bank_alias', v_bank_alias);

            po_status_code := pkg_aox_util.c_success_create_code;
            v_response_json.put('status', 'success');
            v_response_json.put('message', 'Turno reservado. Transferí la seña con el código indicado.');
            v_response_json.put('appointment_id', v_new_app_id);
            v_response_json.put('payment_status', 'PENDING');
            v_response_json.put('deposit_amount', v_deposit_amount);
            v_response_json.put('payment_expires_at', TO_CHAR(v_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_response_json.put('payment_reference', v_payment_reference);
            v_response_json.put('public_manage_token', v_public_token);
            v_response_json.put('provider', 'sipap');
            v_response_json.put('sipap', v_sipap_obj);
            v_response_json.put('refund_policy', v_policy_code);
            v_response_json.put('refund_policy_label', fn_policy_label(v_policy_code));
            v_response_json.put('refund_policy_summary', fn_policy_summary(v_policy_code));
            po_response_body := v_response_json.to_clob();
            IF v_idem_key IS NOT NULL THEN
                pkg_aox_util.pr_idempotency_complete(c_idem_scope, v_idem_key, po_status_code, po_response_body);
            END IF;
            RETURN;
        END IF;

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
            v_loc_id,
            v_pro_id,
            v_ser_id,
            v_cus_id,
            v_start_time,
            v_end_time,
            'CONFIRMADO',
            LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID()))
        )
        RETURNING id_appointment INTO v_new_app_id;

        COMMIT;

        -- Disparar WhatsApp al cliente en background para no demorar la respuesta pública.
        BEGIN
            pkg_aox_meta_api.pr_enqueue_booking_confirmation_wa(
                pi_appointment_id => v_new_app_id
            );
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;

        pkg_aox_fcm_api.pr_notify_professional_appointment(
            pi_pro_id         => v_pro_id,
            pi_appointment_id => v_new_app_id,
            pi_title          => '¡Nueva Cita Agendada!',
            pi_body           => v_cus_name || ' ha reservado para el '
                || TO_CHAR(v_start_time, 'DD/MM/YYYY') || ' a las '
                || TO_CHAR(v_start_time, 'HH24:MI'),
            pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_CREATE_PUBLIC_APP.FCM_NOTIFY'
        );

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , '¡Cita confirmada exitosamente!');
        v_response_json.put('appointment_id', v_new_app_id);
        po_response_body := v_response_json.to_clob();
        IF v_idem_key IS NOT NULL THEN
            pkg_aox_util.pr_idempotency_complete(c_idem_scope, v_idem_key, po_status_code, po_response_body);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = -20002 THEN pkg_aox_util.c_conflict_code
                WHEN SQLCODE = -20003 THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20004 THEN pkg_aox_util.c_conflict_code
                WHEN SQLCODE IN (-20020, -20021, -20022, -20023, -20024) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20025 THEN pkg_aox_util.c_not_found_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            -- Libera la key ante fallas tecnicas/transitorias (sin cita confirmada) para no
            -- bloquear un retry legitimo; los rechazos de negocio dejan la key IN_PROGRESS.
            IF v_idem_key IS NOT NULL AND SQLCODE NOT IN (
                -20002, -20003, -20004, -20020, -20021, -20022, -20023, -20024, -20025
            ) THEN
                pkg_aox_util.pr_idempotency_release(c_idem_scope, v_idem_key);
            END IF;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_APPOINTMENTS_CREATE',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_CREATE_PUBLIC_APP',
                pi_http_method     => 'POST',
                pi_endpoint        => '/public/appointments',
                pi_org_id          => v_org_id,
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
    END pr_create_public_app;

    -- API Validar Cliente Público por Teléfono
    PROCEDURE pr_validate_customer(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();

        v_org_id        NUMBER;
        v_phone_number  VARCHAR2(20);
        v_full_name     customer.full_name%TYPE;
        v_id_customer   customer.id_customer%TYPE;
    BEGIN
        -- Parsear el body igual que en pr_create_public_app
        BEGIN
            v_json_req     := json_object_t.parse(pi_body);
            v_org_id       := v_json_req.get_number('org_id_organization');
            v_phone_number := TRIM(v_json_req.get_string('customer_phone'));
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        IF v_org_id IS NULL OR v_phone_number IS NULL THEN
             RAISE_APPLICATION_ERROR(-20002, 'org_id_organization y customer_phone son obligatorios.');
        END IF;

        -- Buscar al cliente
        BEGIN
            SELECT
                id_customer,
                full_name
            INTO
                v_id_customer,
                v_full_name
            FROM customer
            WHERE phone_number          = v_phone_number
                AND org_id_organization = v_org_id;

            -- Si lo encuentra (Cliente Existente)
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('exists', true);

            v_data_obj.put('id_customer', v_id_customer);
            v_data_obj.put('full_name'  , v_full_name);
            v_response_json.put('data'  , v_data_obj);

            po_response_body := v_response_json.to_clob();

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Si no lo encuentra (Cliente Nuevo)
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                v_response_json.put('exists', false);
                v_response_json.put('message', 'Cliente nuevo, se requiere nombre.');
                po_response_body := v_response_json.to_clob();
        END;

    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := CASE
                WHEN SQLCODE = -20002 THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_VALIDATE_CUSTOMER',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_VALIDATE_CUSTOMER',
                pi_http_method     => 'POST',
                pi_endpoint        => '/public/validate-customer',
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
    END pr_validate_customer;

    PROCEDURE pr_get_public_reservation(
        pi_public_token  IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json   json_object_t := json_object_t();
        v_data_obj        json_object_t := json_object_t();
        v_preview         json_object_t;
        v_refund_preview  NUMBER;
        v_requires_alias  NUMBER;
        v_locations_arr   json_array_t;
        v_loc_obj         json_object_t;
        v_includes_arr    json_array_t;
        v_history_arr     json_array_t;
        v_hist_obj        json_object_t;
        v_history_count   NUMBER;
        v_include_src     VARCHAR2(2000);
        v_include_pos     PLS_INTEGER;
        v_include_line    VARCHAR2(2000);
        v_last_rec        VARCHAR2(4000);
        v_tx_ocr_status   payment_transaction.ocr_status%TYPE;
        v_tx_reject_reason payment_transaction.reject_reason%TYPE;
        v_tx_reference    payment_transaction.payment_reference%TYPE;
        v_tx_reviewed_at  payment_transaction.reviewed_at%TYPE;
    BEGIN
        FOR rec IN (
            SELECT
                a.id_appointment,
                a.org_id_organization,
                a.cus_id_customer,
                a.loc_id_location,
                a.pro_id_professional,
                a.ser_id_service,
                a.start_time,
                a.end_time,
                a.status,
                a.payment_status,
                a.payment_expires_at,
                a.deposit_amount,
                a.policy_code_snapshot,
                a.refund_status,
                a.refund_amount,
                a.refund_alias,
                c.full_name AS customer_name,
                c.phone_number AS customer_phone,
                l.name AS location_name,
                l.address AS location_address,
                s.name AS service_name,
                s.duration_minutes,
                s.image_url AS service_image_url,
                s.public_includes,
                NVL(p.display_name, TRIM(pu.first_name || ' ' || pu.last_name)) AS professional_name,
                p.profile_slug AS professional_slug,
                NVL(NULLIF(TRIM(p.profile_image_url), ''), NULLIF(TRIM(pu.profile_image_url), '')) AS professional_image_url,
                ws.profile_slug AS organization_slug,
                o.name AS organization_name
            FROM appointment a
            JOIN customer c ON c.id_customer = a.cus_id_customer
            JOIN location l ON l.id_location = a.loc_id_location
            JOIN service s ON s.id_service = a.ser_id_service
            JOIN professional p ON p.id_professional = a.pro_id_professional
            JOIN org_member m ON m.id_org_member = p.usr_id_user
            JOIN platform_user pu ON pu.id_platform_user = m.platform_user_id
            JOIN workspace_setting ws ON ws.org_id_organization = a.org_id_organization
            JOIN organization o ON o.id_organization = a.org_id_organization
            WHERE a.public_manage_token = TRIM(pi_public_token)
        ) LOOP
            v_data_obj.put('id_appointment'      , rec.id_appointment);
            v_data_obj.put('org_id_organization' , rec.org_id_organization);
            v_data_obj.put('loc_id_location'     , rec.loc_id_location);
            v_data_obj.put('location_name'       , rec.location_name);
            v_data_obj.put('location_address'    , rec.location_address);
            v_data_obj.put('pro_id_professional' , rec.pro_id_professional);
            v_data_obj.put('professional_name'   , rec.professional_name);
            v_data_obj.put('professional_slug'   , rec.professional_slug);
            v_data_obj.put('professional_image_url', NVL(rec.professional_image_url, ''));
            v_data_obj.put('organization_slug'   , rec.organization_slug);
            v_data_obj.put('organization_name'   , rec.organization_name);
            v_data_obj.put('ser_id_service'      , rec.ser_id_service);
            v_data_obj.put('service_name'        , rec.service_name);
            v_data_obj.put('service_image_url'   , NVL(rec.service_image_url, ''));
            v_data_obj.put('duration_minutes'    , rec.duration_minutes);
            v_data_obj.put('customer_name'       , rec.customer_name);
            v_data_obj.put('customer_phone'      , rec.customer_phone);
            v_data_obj.put('status'              , rec.status);
            v_data_obj.put('start_time'          , TO_CHAR(rec.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_data_obj.put('end_time'            , TO_CHAR(rec.end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
            v_data_obj.put('payment_status'      , rec.payment_status);

            -- Seña pendiente: exponer estado del comprobante (ocr_status/reject_reason/
            -- payment_reference/payment_expires_at) y datos SIPAP para que /r/[token]
            -- pueda ofrecer "subir/resubir comprobante" sin un segundo fetch.
            IF NVL(rec.payment_status, 'NONE') = 'PENDING' AND NVL(rec.deposit_amount, 0) > 0 THEN
                v_tx_ocr_status    := NULL;
                v_tx_reject_reason := NULL;
                v_tx_reference     := NULL;
                v_tx_reviewed_at   := NULL;
                BEGIN
                    SELECT pt.ocr_status, pt.reject_reason, pt.payment_reference, pt.reviewed_at
                      INTO v_tx_ocr_status, v_tx_reject_reason, v_tx_reference, v_tx_reviewed_at
                      FROM (
                            SELECT /*+ no_parallel */
                                   pt.ocr_status, pt.reject_reason, pt.payment_reference, pt.reviewed_at
                              FROM payment_transaction pt
                             WHERE pt.app_id_appointment = rec.id_appointment
                               AND pt.provider = 'sipap'
                             ORDER BY pt.id_transaction DESC
                             FETCH FIRST 1 ROW ONLY
                           ) pt;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        NULL;
                END;

                v_data_obj.put('ocr_status', v_tx_ocr_status);
                v_data_obj.put('payment_reference', v_tx_reference);
                -- Flag independiente del motivo: si el staff rechazó sin texto,
                -- el cliente igual debe poder resubir el comprobante.
                v_data_obj.put(
                    'receipt_rejected',
                    CASE
                        WHEN v_tx_ocr_status = 'MISMATCH' AND v_tx_reviewed_at IS NOT NULL
                        THEN TRUE
                        ELSE FALSE
                    END
                );
                IF v_tx_ocr_status = 'MISMATCH' AND v_tx_reviewed_at IS NOT NULL THEN
                    v_data_obj.put('reject_reason', v_tx_reject_reason);
                END IF;
                IF rec.payment_expires_at IS NOT NULL THEN
                    v_data_obj.put(
                        'payment_expires_at',
                        TO_CHAR(rec.payment_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                    );
                END IF;
                v_data_obj.put('deposit_settings', fn_public_deposit_settings(rec.org_id_organization));
            END IF;

            -- Sucursales activas de la organizacion (evita el 2do fetch a
            -- getPublicProfileWithOrds que hacia el frontend solo para esto).
            v_locations_arr := json_array_t();
            FOR loc_rec IN (
                SELECT id_location, name, address, latitude, longitude
                  FROM location
                 WHERE org_id_organization = rec.org_id_organization
                   AND is_active = 1
                 ORDER BY name
            ) LOOP
                v_loc_obj := json_object_t();
                v_loc_obj.put('id_location', loc_rec.id_location);
                v_loc_obj.put('name'       , loc_rec.name);
                v_loc_obj.put('address'    , loc_rec.address);
                IF loc_rec.latitude IS NOT NULL THEN
                    v_loc_obj.put('latitude', loc_rec.latitude);
                END IF;
                IF loc_rec.longitude IS NOT NULL THEN
                    v_loc_obj.put('longitude', loc_rec.longitude);
                END IF;
                v_locations_arr.append(v_loc_obj);
            END LOOP;
            v_data_obj.put('locations', v_locations_arr);

            v_includes_arr := json_array_t();
            v_include_src := REPLACE(NVL(rec.public_includes, ''), CHR(13), '');
            WHILE v_include_src IS NOT NULL LOOP
                v_include_pos := INSTR(v_include_src, CHR(10));
                IF v_include_pos = 0 THEN
                    v_include_line := TRIM(v_include_src);
                    v_include_src := NULL;
                ELSE
                    v_include_line := TRIM(SUBSTR(v_include_src, 1, v_include_pos - 1));
                    v_include_src := SUBSTR(v_include_src, v_include_pos + 1);
                END IF;
                IF v_include_line IS NOT NULL THEN
                    v_includes_arr.append(v_include_line);
                END IF;
            END LOOP;
            v_data_obj.put('service_includes', v_includes_arr);

            SELECT COUNT(*)
              INTO v_history_count
              FROM appointment a
             WHERE a.cus_id_customer = rec.cus_id_customer
               AND a.pro_id_professional = rec.pro_id_professional
               AND a.org_id_organization = rec.org_id_organization
               AND a.id_appointment <> rec.id_appointment
               AND (
                    a.status = 'COMPLETADO'
                    OR (a.status = 'CONFIRMADO' AND a.start_time < SYSTIMESTAMP)
               );
            v_data_obj.put('visit_history_count', v_history_count);

            v_history_arr := json_array_t();
            FOR hist IN (
                SELECT
                    a.start_time,
                    s.name AS service_name,
                    a.status
                  FROM appointment a
                  JOIN service s ON s.id_service = a.ser_id_service
                 WHERE a.cus_id_customer = rec.cus_id_customer
                   AND a.pro_id_professional = rec.pro_id_professional
                   AND a.org_id_organization = rec.org_id_organization
                   AND a.id_appointment <> rec.id_appointment
                   AND (
                        a.status = 'COMPLETADO'
                        OR (a.status = 'CONFIRMADO' AND a.start_time < SYSTIMESTAMP)
                   )
                 ORDER BY a.start_time DESC
                 FETCH FIRST 50 ROWS ONLY
            ) LOOP
                v_hist_obj := json_object_t();
                v_hist_obj.put('start_time', TO_CHAR(hist.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
                v_hist_obj.put('service_name', hist.service_name);
                v_hist_obj.put('status', hist.status);
                v_history_arr.append(v_hist_obj);
            END LOOP;
            v_data_obj.put('visit_history', v_history_arr);

            v_last_rec := NULL;
            IF pkg_aox_subscription_api.fn_org_has_feature(rec.org_id_organization, 'APPOINTMENT_HISTORY') = 1 THEN
                BEGIN
                    SELECT SUBSTR(TRIM(r.recommendations), 1, 4000)
                      INTO v_last_rec
                      FROM appointment_session_record r
                      JOIN appointment a ON a.id_appointment = r.app_id_appointment
                     WHERE a.cus_id_customer = rec.cus_id_customer
                       AND a.pro_id_professional = rec.pro_id_professional
                       AND a.org_id_organization = rec.org_id_organization
                       AND a.status = 'COMPLETADO'
                       AND TRIM(r.recommendations) IS NOT NULL
                     ORDER BY a.start_time DESC
                     FETCH FIRST 1 ROW ONLY;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_last_rec := NULL;
                END;
            END IF;
            IF v_last_rec IS NOT NULL THEN
                v_data_obj.put('last_recommendations', v_last_rec);
            END IF;

            IF rec.deposit_amount IS NOT NULL THEN
                v_data_obj.put('deposit_amount', rec.deposit_amount);
            END IF;
            v_data_obj.put('policy_code_snapshot', rec.policy_code_snapshot);
            v_data_obj.put('policy_label', fn_policy_label(rec.policy_code_snapshot));
            v_data_obj.put('refund_status', NVL(rec.refund_status, 'NONE'));
            IF rec.refund_amount IS NOT NULL THEN
                v_data_obj.put('refund_amount', rec.refund_amount);
            END IF;
            v_data_obj.put('refund_alias', rec.refund_alias);

            IF NVL(rec.refund_status, 'NONE') = 'PENDING' THEN
                DECLARE
                    v_alias_at   TIMESTAMP WITH TIME ZONE;
                    v_deadline   TIMESTAMP WITH TIME ZONE;
                    v_can_claim  NUMBER := 0;
                    v_open_claim NUMBER := 0;
                BEGIN
                    SELECT refund_alias_submitted_at
                      INTO v_alias_at
                      FROM appointment
                     WHERE id_appointment = rec.id_appointment;

                    v_deadline := pkg_aox_refund_claims_api.fn_refund_sla_deadline(v_alias_at);
                    IF v_deadline IS NOT NULL THEN
                        v_data_obj.put(
                            'refund_sla_deadline',
                            TO_CHAR(v_deadline AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                        );
                    END IF;
                    v_can_claim := pkg_aox_refund_claims_api.fn_is_refund_sla_breached(v_alias_at);

                    SELECT COUNT(*)
                      INTO v_open_claim
                      FROM org_refund_claim
                     WHERE app_id_appointment = rec.id_appointment
                       AND claim_status = 'OPEN';

                    v_data_obj.put('refund_claim_open', CASE WHEN v_open_claim > 0 THEN 1 ELSE 0 END);
                    v_data_obj.put(
                        'can_claim_refund',
                        CASE WHEN v_can_claim = 1 AND v_open_claim = 0 THEN 1 ELSE 0 END
                    );
                END;
            END IF;

            -- Preview solo si la cita sigue activa y hay seña pagada.
            IF rec.status <> 'CANCELADO'
               AND NVL(rec.payment_status, 'NONE') IN ('PAID', 'PAID_TRANSFER')
               AND NVL(rec.deposit_amount, 0) > 0
            THEN
                v_refund_preview := fn_calc_customer_refund(
                    rec.policy_code_snapshot,
                    rec.deposit_amount,
                    rec.start_time
                );
                v_requires_alias := CASE WHEN v_refund_preview > 0 THEN 1 ELSE 0 END;
                v_preview := json_object_t();
                v_preview.put('amount', v_refund_preview);
                v_preview.put('requires_alias', v_requires_alias);
                v_preview.put('policy_code', rec.policy_code_snapshot);
                v_preview.put('policy_label', fn_policy_label(rec.policy_code_snapshot));
                v_preview.put('policy_summary', fn_policy_summary(rec.policy_code_snapshot));
                DECLARE
                    v_no_refund_reason VARCHAR2(30);
                BEGIN
                    v_no_refund_reason := fn_no_refund_reason(
                        rec.policy_code_snapshot,
                        rec.deposit_amount,
                        rec.start_time,
                        v_refund_preview
                    );
                    IF v_no_refund_reason IS NOT NULL THEN
                        v_preview.put('no_refund_reason', v_no_refund_reason);
                    END IF;
                END;
                v_data_obj.put('refund_preview', v_preview);
            END IF;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_data_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status', 'error');
        v_response_json.put('message', 'Reserva no encontrada.');
        po_response_body := v_response_json.to_clob();
    END pr_get_public_reservation;

    PROCEDURE pr_update_public_reservation(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json_req        json_object_t;
        v_response_json   json_object_t := json_object_t();
        v_app_id          appointment.id_appointment%TYPE;
        v_org_id          appointment.org_id_organization%TYPE;
        v_loc_id          appointment.loc_id_location%TYPE;
        v_pro_id          appointment.pro_id_professional%TYPE;
        v_ser_id          appointment.ser_id_service%TYPE;
        v_status          appointment.status%TYPE;
        v_start_time        TIMESTAMP;
        v_end_time          TIMESTAMP;
        v_old_start_time    TIMESTAMP;
        v_old_end_time      TIMESTAMP;
        v_old_loc_id        appointment.loc_id_location%TYPE;
        v_cus_name          customer.full_name%TYPE;
        v_overlap_count     NUMBER;
        v_available_count   NUMBER;
        v_schedule_changed  BOOLEAN;
        v_payment_status    appointment.payment_status%TYPE;
        v_service_duration_minutes service.duration_minutes%TYPE;
        v_loc_count         NUMBER;
    BEGIN
        v_json_req := json_object_t.parse(pi_body);
        v_start_time := TO_TIMESTAMP(SUBSTR(REPLACE(v_json_req.get_string('start_time'), 'T', ' '), 1, 19), 'YYYY-MM-DD HH24:MI:SS');

        SELECT
            a.id_appointment,
            a.org_id_organization,
            a.loc_id_location,
            a.pro_id_professional,
            a.ser_id_service,
            a.status,
            a.start_time,
            a.end_time,
            a.payment_status,
            c.full_name
        INTO
            v_app_id,
            v_org_id,
            v_loc_id,
            v_pro_id,
            v_ser_id,
            v_status,
            v_old_start_time,
            v_old_end_time,
            v_payment_status,
            v_cus_name
        FROM appointment a
        JOIN customer c
          ON c.id_customer = a.cus_id_customer
        WHERE a.public_manage_token = TRIM(pi_public_token)
        FOR UPDATE;

        v_old_loc_id := v_loc_id;

        -- Gate de suscripción: reserva pública en mantenimiento si la org está en READ_ONLY / vencido.
        pkg_aox_subscription_api.pr_assert_public_booking_open(v_org_id);

        IF v_json_req.has('loc_id_location') THEN
            v_loc_id := v_json_req.get_number('loc_id_location');

            -- Fase 6: la sucursal debe pertenecer a la misma organización.
            SELECT COUNT(*) INTO v_loc_count
              FROM location
             WHERE id_location = v_loc_id AND org_id_organization = v_org_id;

            IF v_loc_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20025, 'Sucursal no encontrada.');
            END IF;
        END IF;

        IF v_status = 'CANCELADO' THEN
            RAISE_APPLICATION_ERROR(-20005, 'No se puede modificar una reserva cancelada.');
        END IF;

        -- Fase 3: end_time siempre se recalcula server-side desde la duración del
        -- servicio; nunca se confía en el end_time enviado por el cliente.
        SELECT duration_minutes
          INTO v_service_duration_minutes
          FROM service
         WHERE id_service = v_ser_id
           AND org_id_organization = v_org_id;

        v_end_time := v_start_time + NUMTODSINTERVAL(v_service_duration_minutes, 'MINUTE');

        IF v_start_time >= v_end_time THEN
            RAISE_APPLICATION_ERROR(-20003, 'La fecha/hora de inicio debe ser menor a la de fin.');
        END IF;

        SELECT COUNT(*)
          INTO v_available_count
          FROM TABLE(fn_get_available_slots_pipe(
              v_pro_id,
              v_loc_id,
              v_ser_id,
              CAST(v_start_time AS DATE),
              v_app_id
          ))
         WHERE slot_time = TO_CHAR(v_start_time, 'HH24:MI');

        IF v_available_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'El horario seleccionado ya no está disponible.');
        END IF;

        SELECT COUNT(*)
          INTO v_overlap_count
          FROM appointment
         WHERE id_appointment <> v_app_id
           AND org_id_organization = v_org_id
           AND pro_id_professional = v_pro_id
           AND status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
           AND start_time < v_end_time
           AND end_time   > v_start_time;

        IF v_overlap_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El profesional ya tiene una cita en ese horario.');
        END IF;

        UPDATE appointment
           SET loc_id_location     = v_loc_id,
               start_time          = v_start_time,
               end_time            = v_end_time,
               -- Fase 4: si es un hold SIPAP sin pagar, la reprogramación no debe
               -- "confirmar" la cita sin que se haya completado el pago de la seña.
               status              = CASE WHEN v_payment_status = 'PENDING' THEN 'PENDIENTE' ELSE 'CONFIRMADO' END,
               attendance_status   = 'NOT_REQUESTED',
               attendance_sent_at  = NULL,
               attendance_due_at   = NULL,
               attendance_reply_at = NULL,
               updated_at          = CURRENT_TIMESTAMP
         WHERE id_appointment = v_app_id;

        v_schedule_changed :=
            v_old_start_time <> v_start_time
            OR v_old_end_time <> v_end_time
            OR v_old_loc_id <> v_loc_id;

        COMMIT;

        IF v_schedule_changed THEN
            pkg_aox_fcm_api.pr_notify_professional_appointment(
                pi_pro_id         => v_pro_id,
                pi_appointment_id => v_app_id,
                pi_title          => 'Cita reprogramada',
                pi_body           => NVL(TRIM(v_cus_name), 'Un cliente') || ' modificó su cita para el '
                    || TO_CHAR(v_start_time, 'DD/MM/YYYY') || ' a las '
                    || TO_CHAR(v_start_time, 'HH24:MI'),
                pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPDATE_PUBLIC_RESERVATION.FCM_NOTIFY'
            );
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Reserva actualizada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RESERVATION_UPDATE',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPDATE_PUBLIC_RESERVATION',
                pi_http_method     => 'PUT',
                pi_endpoint        => '/public/reservations/:token',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body,
                pi_request_params  => 'token=' || pi_public_token
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Reserva no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE IN (-20003, -20005) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE IN (-20002, -20004) THEN pkg_aox_util.c_conflict_code
                WHEN SQLCODE = -20025 THEN pkg_aox_util.c_not_found_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RESERVATION_UPDATE',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPDATE_PUBLIC_RESERVATION',
                pi_http_method     => 'PUT',
                pi_endpoint        => '/public/reservations/:token',
                pi_org_id          => v_org_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body,
                pi_request_params  => 'token=' || pi_public_token || ';appointment_id=' || v_app_id
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_update_public_reservation;

    PROCEDURE pr_cancel_public_reservation(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json   json_object_t := json_object_t();
        v_data_obj        json_object_t := json_object_t();
        v_json            json_object_t;
        v_app_id          appointment.id_appointment%TYPE;
        v_pro_id          appointment.pro_id_professional%TYPE;
        v_start_time      appointment.start_time%TYPE;
        v_cus_name        customer.full_name%TYPE;
        v_pay_status      appointment.payment_status%TYPE;
        v_deposit         appointment.deposit_amount%TYPE;
        v_policy          appointment.policy_code_snapshot%TYPE;
        v_refund_amount   NUMBER := 0;
        v_refund_status   VARCHAR2(20) := 'NONE';
        v_refund_alias    VARCHAR2(100);
        v_msg             VARCHAR2(400);
        v_fcm_body        VARCHAR2(500);
    BEGIN
        IF pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN
            BEGIN
                v_json := json_object_t.parse(pi_body);
                v_refund_alias := SUBSTR(TRIM(v_json.get_string('refund_alias')), 1, 100);
            EXCEPTION
                WHEN OTHERS THEN
                    v_refund_alias := NULL;
            END;
        END IF;

        SELECT
            a.id_appointment,
            a.pro_id_professional,
            a.start_time,
            c.full_name,
            a.payment_status,
            a.deposit_amount,
            a.policy_code_snapshot
        INTO
            v_app_id,
            v_pro_id,
            v_start_time,
            v_cus_name,
            v_pay_status,
            v_deposit,
            v_policy
        FROM appointment a
        JOIN customer c
          ON c.id_customer = a.cus_id_customer
        WHERE a.public_manage_token = TRIM(pi_public_token)
          AND a.status <> 'CANCELADO'
        FOR UPDATE;

        -- Seña pagada: calcular reembolso segun politica.
        IF NVL(v_pay_status, 'NONE') IN ('PAID', 'PAID_TRANSFER') AND NVL(v_deposit, 0) > 0 THEN
            v_refund_amount := fn_calc_customer_refund(v_policy, v_deposit, v_start_time);
            IF v_refund_amount > 0 THEN
                v_refund_alias := fn_normalize_sipap_alias(v_refund_alias);
                v_refund_status := 'PENDING';
            ELSE
                v_refund_status := 'NOT_APPLICABLE';
                v_refund_amount := 0;
                v_refund_alias := NULL;
            END IF;
        ELSIF NVL(v_pay_status, 'NONE') = 'PENDING' AND NVL(v_deposit, 0) > 0 THEN
            -- Hold sin pagar: expirar pago, sin reembolso.
            UPDATE payment_transaction
               SET payment_status = 'EXPIRED',
                   processed_at   = CURRENT_TIMESTAMP
             WHERE app_id_appointment = v_app_id
               AND payment_status = 'PENDING';
            v_refund_status := 'NOT_APPLICABLE';
            v_refund_amount := 0;
            UPDATE appointment
               SET payment_status = 'EXPIRED'
             WHERE id_appointment = v_app_id;
        ELSE
            v_refund_status := CASE
                WHEN NVL(v_deposit, 0) > 0 THEN 'NOT_APPLICABLE'
                ELSE 'NONE'
            END;
            v_refund_amount := 0;
        END IF;

        UPDATE appointment
           SET status                     = 'CANCELADO',
               cancel_reason              = 'CUSTOMER_CANCELLED',
               updated_at                 = CURRENT_TIMESTAMP,
               refund_status              = v_refund_status,
               refund_amount              = CASE WHEN v_refund_amount > 0 THEN v_refund_amount ELSE NULL END,
               refund_alias               = CASE WHEN v_refund_status = 'PENDING' THEN v_refund_alias ELSE NULL END,
               refund_requested_at        = CASE WHEN v_refund_status = 'PENDING' THEN CURRENT_TIMESTAMP ELSE NULL END,
               refund_alias_submitted_at  = CASE WHEN v_refund_status = 'PENDING' THEN CURRENT_TIMESTAMP ELSE NULL END
         WHERE id_appointment = v_app_id;

        COMMIT;

        IF v_refund_status = 'PENDING' THEN
            v_msg := 'Reserva cancelada. Tu reembolso quedo pendiente: el comercio te transferira a tu alias.';
            v_fcm_body := NVL(TRIM(v_cus_name), 'Un cliente') || ' cancelo su cita del '
                || TO_CHAR(v_start_time, 'DD/MM/YYYY') || ' a las '
                || TO_CHAR(v_start_time, 'HH24:MI')
                || '. Reembolso pendiente: Gs. ' || TO_CHAR(v_refund_amount, 'FM999G999G999');
        ELSIF v_refund_status = 'NOT_APPLICABLE' AND NVL(v_pay_status, 'NONE') IN ('PAID', 'PAID_TRANSFER') THEN
            v_msg := 'Reserva cancelada. Según la política de seña, no corresponde reembolso.';
            v_fcm_body := NVL(TRIM(v_cus_name), 'Un cliente') || ' cancelo su cita del '
                || TO_CHAR(v_start_time, 'DD/MM/YYYY') || ' a las '
                || TO_CHAR(v_start_time, 'HH24:MI');
        ELSE
            v_msg := 'Reserva cancelada correctamente.';
            v_fcm_body := NVL(TRIM(v_cus_name), 'Un cliente') || ' cancelo su cita del '
                || TO_CHAR(v_start_time, 'DD/MM/YYYY') || ' a las '
                || TO_CHAR(v_start_time, 'HH24:MI');
        END IF;

        pkg_aox_fcm_api.pr_notify_professional_appointment(
            pi_pro_id         => v_pro_id,
            pi_appointment_id => v_app_id,
            pi_title          => CASE WHEN v_refund_status = 'PENDING' THEN 'Reembolso pendiente' ELSE 'Cita cancelada' END,
            pi_body           => v_fcm_body,
            pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_CANCEL_PUBLIC_RESERVATION.FCM_NOTIFY'
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', v_msg);
        v_data_obj.put('refund_status', v_refund_status);
        IF v_refund_amount > 0 THEN
            v_data_obj.put('refund_amount', v_refund_amount);
        END IF;
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RESERVATION_CANCEL',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_CANCEL_PUBLIC_RESERVATION',
                pi_http_method     => 'DELETE',
                pi_endpoint        => '/public/reservations/:token',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'token=' || pi_public_token
            );
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Reserva no encontrada o ya cancelada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RESERVATION_CANCEL',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_CANCEL_PUBLIC_RESERVATION',
                pi_http_method     => 'DELETE',
                pi_endpoint        => '/public/reservations/:token',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'token=' || pi_public_token || ';appointment_id=' || v_app_id
            );
    END pr_cancel_public_reservation;

    PROCEDURE pr_submit_refund_alias(
        pi_public_token  IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
        v_json          json_object_t;
        v_app_id        appointment.id_appointment%TYPE;
        v_pro_id        appointment.pro_id_professional%TYPE;
        v_refund_st     appointment.refund_status%TYPE;
        v_refund_amt    appointment.refund_amount%TYPE;
        v_cus_name      customer.full_name%TYPE;
        v_alias         VARCHAR2(100);
    BEGIN
        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Body requerido.');
        END IF;

        v_json := json_object_t.parse(pi_body);
        v_alias := SUBSTR(TRIM(v_json.get_string('refund_alias')), 1, 100);
        v_alias := fn_normalize_sipap_alias(v_alias);

        SELECT a.id_appointment,
               a.pro_id_professional,
               a.refund_status,
               a.refund_amount,
               c.full_name
          INTO v_app_id, v_pro_id, v_refund_st, v_refund_amt, v_cus_name
          FROM appointment a
          JOIN customer c ON c.id_customer = a.cus_id_customer
         WHERE a.public_manage_token = TRIM(pi_public_token)
         FOR UPDATE;

        IF v_refund_st = 'PENDING' THEN
            -- Idempotente: actualizar alias si ya estaba pendiente.
            UPDATE appointment
               SET refund_alias              = v_alias,
                   refund_alias_submitted_at = NVL(refund_alias_submitted_at, CURRENT_TIMESTAMP),
                   updated_at                = CURRENT_TIMESTAMP
             WHERE id_appointment = v_app_id;
        ELSIF v_refund_st = 'AWAITING_ALIAS' THEN
            UPDATE appointment
               SET refund_status             = 'PENDING',
                   refund_alias              = v_alias,
                   refund_alias_submitted_at = CURRENT_TIMESTAMP,
                   updated_at                = CURRENT_TIMESTAMP
             WHERE id_appointment = v_app_id;
            v_refund_st := 'PENDING';
        ELSE
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Esta reserva no espera datos de reembolso.'
            );
        END IF;

        COMMIT;

        pkg_aox_fcm_api.pr_notify_professional_appointment(
            pi_pro_id         => v_pro_id,
            pi_appointment_id => v_app_id,
            pi_title          => 'Alias de reembolso recibido',
            pi_body           => NVL(TRIM(v_cus_name), 'Un cliente')
                || ' cargo su alias. Reembolso pendiente: Gs. '
                || TO_CHAR(NVL(v_refund_amt, 0), 'FM999G999G999'),
            pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_SUBMIT_REFUND_ALIAS.FCM_NOTIFY'
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Alias recibido. El comercio te transferira el reembolso.');
        v_data_obj.put('refund_status', v_refund_st);
        IF v_refund_amt IS NOT NULL THEN
            v_data_obj.put('refund_amount', v_refund_amt);
        END IF;
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Reserva no encontrada.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_submit_refund_alias;

    -- Fase B2: subir comprobante + OCR sync. Token = public_manage_token del hold SIPAP.
    PROCEDURE pr_upload_public_receipt(
        pi_public_token     IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        c_idem_scope        CONSTANT VARCHAR2(64) := 'PUBLIC_RECEIPT_UPLOAD';
        v_idem_key          VARCHAR2(255) := TRIM(pi_idempotency_key);
        v_idem_request_hash VARCHAR2(64);
        v_idem_outcome      VARCHAR2(20);
        v_idem_resp_status  NUMBER;
        v_idem_resp_payload CLOB;

        v_json            json_object_t;
        v_base64          CLOB;
        v_filename        VARCHAR2(255);
        v_mime            VARCHAR2(150);
        v_blob            BLOB;
        v_app_id          appointment.id_appointment%TYPE;
        v_org_id          organization.id_organization%TYPE;
        v_cus_id          customer.id_customer%TYPE;
        v_cus_name        customer.full_name%TYPE;
        v_pro_id          professional.id_professional%TYPE;
        v_app_status      appointment.status%TYPE;
        v_pay_status      appointment.payment_status%TYPE;
        v_deposit_amount  appointment.deposit_amount%TYPE;
        v_expires_at      appointment.payment_expires_at%TYPE;
        v_tx_id           payment_transaction.id_transaction%TYPE;
        v_expected_ref    payment_transaction.payment_reference%TYPE;
        v_expected_amt    payment_transaction.amount%TYPE;
        v_url             VARCHAR2(1000);
        v_object_key      VARCHAR2(500);
        v_ocr_clob        CLOB;
        v_ocr_obj         json_object_t;
        v_ocr_status      VARCHAR2(20);
        v_ocr_ref         VARCHAR2(64);
        v_ocr_amount      NUMBER;
        v_ocr_conf        NUMBER;
        v_ocr_dt_str      VARCHAR2(64);
        v_ocr_dt          TIMESTAMP WITH TIME ZONE;
        v_ref_ok          BOOLEAN := FALSE;
        v_amt_ok          BOOLEAN := FALSE;
        v_msg             VARCHAR2(400);
        v_response_json   json_object_t := json_object_t();
        v_data_obj        json_object_t := json_object_t();
        v_is_image        BOOLEAN := FALSE;
        v_max_bytes       NUMBER;
        v_max_b64_len     NUMBER;
    BEGIN
        IF pi_public_token IS NULL OR LENGTH(TRIM(pi_public_token)) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Token de reserva requerido.');
        END IF;

        -- Hardening (auditoría ORDS R1): limitar intentos de upload por reserva y por IP
        -- antes de procesar el body, para frenar fuerza bruta / DoS con payloads grandes.
        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'PUBLIC_RECEIPT_UPLOAD',
            pi_key          => TRIM(pi_public_token),
            pi_max_attempts => pkg_aox_util.fn_param_number('RATE_LIMIT_RECEIPT_UPLOAD_MAX', 10),
            pi_window_sec   => pkg_aox_util.fn_param_number('RATE_LIMIT_RECEIPT_UPLOAD_WINDOW_SEC', 900)
        );
        pkg_aox_util.pr_assert_rate_limit(
            pi_scope        => 'PUBLIC_RECEIPT_UPLOAD_IP',
            pi_key          => pkg_aox_util.fn_client_ip,
            pi_max_attempts => pkg_aox_util.fn_param_number('RATE_LIMIT_RECEIPT_UPLOAD_IP_MAX', 30),
            pi_window_sec   => pkg_aox_util.fn_param_number('RATE_LIMIT_RECEIPT_UPLOAD_IP_WINDOW_SEC', 900)
        );

        IF pi_body IS NULL OR DBMS_LOB.GETLENGTH(pi_body) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Debes enviar el comprobante.');
        END IF;

        v_json     := json_object_t.parse(pi_body);
        v_base64   := v_json.get_clob('file_base64');
        v_filename := TRIM(v_json.get_string('filename'));
        v_mime     := LOWER(TRIM(NVL(v_json.get_string('mime_type'), 'application/octet-stream')));

        IF v_base64 IS NULL OR DBMS_LOB.GETLENGTH(v_base64) = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El comprobante esta vacio.');
        END IF;

        -- Hardening (auditoría ORDS R1/R4): tope de tamaño ANTES de clobbase642blob.
        -- El tamaño en base64 es ~4/3 del binario; se calcula el largo máximo permitido
        -- del CLOB codificado y se rechaza sin decodificar si lo supera.
        v_max_bytes   := pkg_aox_util.fn_param_number('RECEIPT_MAX_BYTES', 8388608);
        v_max_b64_len := CEIL(v_max_bytes / 3) * 4 + 4;
        IF DBMS_LOB.GETLENGTH(v_base64) > v_max_b64_len THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El comprobante supera el tamaño máximo permitido (' || TRUNC(v_max_bytes / 1024 / 1024) || ' MB).'
            );
        END IF;

        IF v_idem_key IS NOT NULL THEN
            -- Hash liviano (sin hashear los MB del base64 completo): token + metadata + largo
            -- alcanza para distinguir "mismo intento reintentado" de "otro comprobante".
            v_idem_request_hash := RAWTOHEX(DBMS_CRYPTO.HASH(
                UTL_I18N.STRING_TO_RAW(
                    TRIM(pi_public_token) || '|' || NVL(v_filename, '') || '|' || v_mime || '|' ||
                    TO_CHAR(DBMS_LOB.GETLENGTH(v_base64)),
                    'AL32UTF8'
                ),
                DBMS_CRYPTO.HASH_SH256
            ));

            pkg_aox_util.pr_idempotency_begin(
                pi_scope             => c_idem_scope,
                pi_key               => v_idem_key,
                pi_request_hash      => v_idem_request_hash,
                po_outcome           => v_idem_outcome,
                po_response_status   => v_idem_resp_status,
                po_response_payload  => v_idem_resp_payload
            );

            IF v_idem_outcome = 'REPLAY' THEN
                -- Reintento del mismo upload: devolver el resultado ya procesado sin
                -- re-subir el archivo ni re-correr el OCR.
                po_status_code    := v_idem_resp_status;
                po_response_body  := v_idem_resp_payload;
                RETURN;
            ELSIF v_idem_outcome = 'IN_PROGRESS' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_progress,
                    pi_message       => 'Ya hay una subida en curso para este comprobante. Espera unos segundos e intenta de nuevo.',
                    po_response_body => po_response_body
                );
                RETURN;
            ELSIF v_idem_outcome = 'CONFLICT' THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_idempotency_conflict,
                    pi_message       => 'La clave de idempotencia ya fue usada con un comprobante distinto.',
                    po_response_body => po_response_body
                );
                RETURN;
            END IF;
            -- outcome = 'NEW': continua el flujo normal abajo
        END IF;

        SELECT a.id_appointment,
               a.org_id_organization,
               a.cus_id_customer,
               a.pro_id_professional,
               a.status,
               a.payment_status,
               a.deposit_amount,
               a.payment_expires_at
          INTO v_app_id, v_org_id, v_cus_id, v_pro_id,
               v_app_status, v_pay_status, v_deposit_amount, v_expires_at
          FROM appointment a
         WHERE a.public_manage_token = TRIM(pi_public_token)
         FOR UPDATE;

        IF v_app_status = 'CANCELADO' THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'La reserva ya fue cancelada.');
        END IF;

        IF v_pay_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH', 'EXEMPT') THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Esta seña ya fue confirmada.');
        END IF;

        IF v_pay_status <> 'PENDING' THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No hay una seña pendiente para esta reserva.');
        END IF;

        IF v_expires_at IS NOT NULL AND v_expires_at < CURRENT_TIMESTAMP THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El tiempo para pagar la seña ya expiró.');
        END IF;

        BEGIN
            -- Oracle no permite FETCH FIRST ... FOR UPDATE (ORA-02014):
            -- primero seleccionamos el id y luego bloqueamos la fila por PK.
            SELECT pt.id_transaction
              INTO v_tx_id
              FROM payment_transaction pt
             WHERE pt.app_id_appointment = v_app_id
               AND pt.provider = 'sipap'
               AND pt.payment_status = 'PENDING'
             ORDER BY pt.id_transaction DESC
             FETCH FIRST 1 ROW ONLY;

            SELECT pt.payment_reference, pt.amount
              INTO v_expected_ref, v_expected_amt
              FROM payment_transaction pt
             WHERE pt.id_transaction = v_tx_id
             FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No se encontro la transaccion SIPAP pendiente.');
        END;

        v_blob := apex_web_service.clobbase642blob(v_base64);

        pkg_aox_bucket.pr_upload_payment_receipt(
            pi_blob        => v_blob,
            pi_filename    => NVL(v_filename, 'comprobante'),
            pi_mime_type   => v_mime,
            pi_org_id      => v_org_id,
            pi_customer_id => v_cus_id,
            pi_receipt_id  => v_tx_id,
            po_url         => v_url,
            po_object_key  => v_object_key
        );

        UPDATE payment_transaction
           SET receipt_object_key  = v_object_key,
               receipt_url         = v_url,
               receipt_mime_type   = v_mime,
               receipt_uploaded_at = CURRENT_TIMESTAMP,
               ocr_status          = 'PENDING',
               reject_reason       = NULL,
               reviewed_at         = NULL,
               reviewed_by         = NULL
         WHERE id_transaction = v_tx_id;

        v_is_image := v_mime LIKE 'image/%';

        IF NOT v_is_image THEN
            -- PDF u otros: guardar para revision manual (OCR vision requiere imagen).
            v_ocr_status := 'MANUAL_REVIEW';
            v_msg := 'Comprobante recibido. El comercio lo revisara manualmente.';
            UPDATE payment_transaction
               SET ocr_status     = v_ocr_status,
                   ocr_checked_at = CURRENT_TIMESTAMP,
                   ocr_confidence = 0
             WHERE id_transaction = v_tx_id;
        ELSE
            v_ocr_clob := pkg_aox_ia_manager.fn_extract_transfer_receipt(
                pi_image_url    => v_url,
                pi_expected_ref => v_expected_ref,
                pi_expected_amt => NVL(v_expected_amt, v_deposit_amount),
                pi_org_id       => v_org_id
            );
            v_ocr_obj := json_object_t.parse(v_ocr_clob);

            BEGIN
                v_ocr_ref := UPPER(TRIM(v_ocr_obj.get_string('reference')));
            EXCEPTION WHEN OTHERS THEN v_ocr_ref := NULL;
            END;

            BEGIN
                v_ocr_amount := v_ocr_obj.get_number('amount');
            EXCEPTION WHEN OTHERS THEN v_ocr_amount := NULL;
            END;

            BEGIN
                v_ocr_conf := NVL(v_ocr_obj.get_number('confidence'), 0);
            EXCEPTION WHEN OTHERS THEN v_ocr_conf := 0;
            END;

            BEGIN
                v_ocr_dt_str := TRIM(v_ocr_obj.get_string('transfer_datetime'));
                IF v_ocr_dt_str IS NOT NULL THEN
                    v_ocr_dt := TO_TIMESTAMP_TZ(
                        REGEXP_REPLACE(v_ocr_dt_str, 'T', ' '),
                        'YYYY-MM-DD HH24:MI:SS TZH:TZM'
                    );
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    BEGIN
                        v_ocr_dt := CAST(TO_TIMESTAMP(SUBSTR(v_ocr_dt_str, 1, 19), 'YYYY-MM-DD HH24:MI:SS') AS TIMESTAMP WITH TIME ZONE);
                    EXCEPTION
                        WHEN OTHERS THEN v_ocr_dt := NULL;
                    END;
            END;

            IF NVL(v_ocr_obj.get_string('status'), 'ok') NOT IN ('ok') THEN
                v_ocr_status := 'FAILED';
                v_msg := 'No pudimos leer el comprobante. El comercio lo revisara.';
            ELSE
                -- Match parcial de HASEL- (bancos truncan asunto).
                IF v_expected_ref IS NOT NULL AND v_ocr_ref IS NOT NULL THEN
                    v_ref_ok := (INSTR(v_ocr_ref, UPPER(v_expected_ref)) > 0)
                             OR (INSTR(UPPER(v_expected_ref), v_ocr_ref) > 0 AND LENGTH(v_ocr_ref) >= 8);
                END IF;

                IF v_ocr_amount IS NOT NULL AND NVL(v_expected_amt, v_deposit_amount) IS NOT NULL THEN
                    v_amt_ok := ABS(v_ocr_amount - NVL(v_expected_amt, v_deposit_amount)) <= 1;
                END IF;

                IF v_ocr_conf < 0.55 THEN
                    v_ocr_status := 'MANUAL_REVIEW';
                    v_msg := 'Comprobante recibido. Requiere revision del comercio.';
                ELSIF v_ref_ok AND v_amt_ok THEN
                    v_ocr_status := 'MATCH';
                    v_msg := 'Pago verificado. Tu turno quedo confirmado.';
                ELSIF v_ref_ok OR v_amt_ok THEN
                    v_ocr_status := 'MANUAL_REVIEW';
                    v_msg := 'Comprobante recibido. El comercio confirmara el pago.';
                ELSE
                    v_ocr_status := 'MISMATCH';
                    v_msg := 'Los datos del comprobante no coinciden. El comercio lo revisara.';
                END IF;
            END IF;

            UPDATE payment_transaction
               SET ocr_raw_json       = v_ocr_clob,
                   ocr_reference      = v_ocr_ref,
                   ocr_amount         = v_ocr_amount,
                   ocr_transferred_at = v_ocr_dt,
                   ocr_confidence     = v_ocr_conf,
                   ocr_status         = v_ocr_status,
                   ocr_checked_at     = CURRENT_TIMESTAMP
             WHERE id_transaction = v_tx_id;
        END IF;

        IF v_ocr_status = 'MATCH' THEN
            UPDATE payment_transaction
               SET payment_status = 'PAID',
                   processed_at   = CURRENT_TIMESTAMP
             WHERE id_transaction = v_tx_id;

            UPDATE appointment
               SET payment_status = 'PAID_TRANSFER',
                   status         = 'CONFIRMADO',
                   paid_at        = CURRENT_TIMESTAMP,
                   updated_at     = CURRENT_TIMESTAMP
             WHERE id_appointment = v_app_id;

            BEGIN
                pkg_aox_fcm_api.pr_notify_professional_appointment(
                    pi_pro_id         => v_pro_id,
                    pi_appointment_id => v_app_id,
                    pi_title          => 'Seña confirmada',
                    pi_body           => 'Se verifico el comprobante SIPAP. Turno confirmado.',
                    pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPLOAD_PUBLIC_RECEIPT.FCM_NOTIFY'
                );
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;

            -- Enviar template Meta de confirmacion al cliente (la cita quedo CONFIRMADO al
            -- verificarse la sena). En reservas con sena el WA no se envia al crear el hold,
            -- recien ahora que el pago fue verificado.
            BEGIN
                pkg_aox_meta_api.pr_enqueue_booking_confirmation_wa(
                    pi_appointment_id => v_app_id
                );
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        ELSIF v_ocr_status IN ('MANUAL_REVIEW', 'MISMATCH', 'FAILED', 'PENDING') THEN
            BEGIN
                SELECT c.full_name
                  INTO v_cus_name
                  FROM customer c
                 WHERE c.id_customer = v_cus_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_cus_name := NULL;
            END;

            BEGIN
                pkg_aox_fcm_api.pr_notify_professional_appointment(
                    pi_pro_id         => v_pro_id,
                    pi_appointment_id => v_app_id,
                    pi_title          => 'Comprobante pendiente de revisión',
                    pi_body           => NVL(TRIM(v_cus_name), 'Un cliente')
                                      || ' subió el comprobante SIPAP. Revisalo en Cobros.',
                    pi_process_name   => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPLOAD_PUBLIC_RECEIPT.PAYMENT_REVIEW',
                    pi_ntype          => 'PAYMENT'
                );
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', v_msg);
        v_data_obj.put('appointment_id', v_app_id);
        v_data_obj.put('ocr_status', v_ocr_status);
        v_data_obj.put('payment_status', CASE WHEN v_ocr_status = 'MATCH' THEN 'PAID_TRANSFER' ELSE 'PENDING' END);
        v_data_obj.put('receipt_url', v_url);
        IF v_ocr_ref IS NOT NULL THEN v_data_obj.put('ocr_reference', v_ocr_ref); END IF;
        IF v_ocr_amount IS NOT NULL THEN v_data_obj.put('ocr_amount', v_ocr_amount); END IF;
        IF v_ocr_conf IS NOT NULL THEN v_data_obj.put('ocr_confidence', v_ocr_conf); END IF;
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
        IF v_idem_key IS NOT NULL THEN
            pkg_aox_util.pr_idempotency_complete(c_idem_scope, v_idem_key, po_status_code, po_response_body);
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            ROLLBACK;
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'Reserva no encontrada.',
                po_response_body => po_response_body
            );
            IF v_idem_key IS NOT NULL THEN
                pkg_aox_util.pr_idempotency_release(c_idem_scope, v_idem_key);
            END IF;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RECEIPT_UPLOAD',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPLOAD_PUBLIC_RECEIPT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/public/reservations/:token/receipt',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'token=' || pi_public_token
            );
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            -- Libera la key salvo en el rechazo de validacion mas comun (todas las reglas de
            -- negocio de este endpoint usan c_sqlcode_validation); no bloquea un retry legitimo
            -- tras una falla tecnica/transitoria (bucket, OCR, red).
            IF v_idem_key IS NOT NULL AND SQLCODE != pkg_aox_util.c_sqlcode_validation THEN
                pkg_aox_util.pr_idempotency_release(c_idem_scope, v_idem_key);
            END IF;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'PUBLIC_RECEIPT_UPLOAD',
                pi_process_name    => 'PKG_AOX_PUBLIC_BOOKING_API.PR_UPLOAD_PUBLIC_RECEIPT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/public/reservations/:token/receipt',
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'token=' || pi_public_token
            );
    END pr_upload_public_receipt;

END pkg_aox_public_booking_api;
/


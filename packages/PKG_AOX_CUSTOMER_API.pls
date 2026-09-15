PROMPT CREATE OR REPLACE PACKAGE pkg_aox_customer_api
CREATE OR REPLACE PACKAGE pkg_aox_customer_api IS

    PROCEDURE pr_list_customers(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_pro_id        IN  NUMBER DEFAULT NULL,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        pi_archived      IN  NUMBER DEFAULT 0,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- ORDS: GET /customers/:id  (query: pro_id opcional)
    PROCEDURE pr_get_customer_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_pro_id        IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- ORDS: POST /customers  (body: first_name, last_name, phone_number, document_number?, email?)
    PROCEDURE pr_create_customer(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- ORDS: PUT /customers/:id  (body: first_name, last_name, phone_number, document_number?, email?)
    PROCEDURE pr_update_customer_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- ORDS: POST /customers/:id/archive (pi_is_active=0) y /restore (pi_is_active=1)
    PROCEDURE pr_set_customer_active(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_is_active     IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_customer_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_customer_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_customer_api IS

    c_pending_limit CONSTANT PLS_INTEGER := 10;
    c_history_limit CONSTANT PLS_INTEGER := 20;

    PROCEDURE pr_resolve_customer_access(
        pi_auth_header       IN  VARCHAR2,
        pi_pro_id            IN  NUMBER,
        po_org_id            OUT NUMBER,
        po_user_id           OUT NUMBER,
        po_role_id           OUT NUMBER,
        po_effective_pro_id  OUT NUMBER
    ) IS
        v_actual_pro_id NUMBER;
    BEGIN
        po_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        po_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        po_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        po_effective_pro_id := pi_pro_id;

        IF po_role_id = pkg_aox_util.fn_rol('PROFESIONAL') THEN
            BEGIN
                SELECT id_professional
                  INTO v_actual_pro_id
                  FROM professional
                 WHERE usr_id_user         = po_user_id
                   AND org_id_organization = po_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20001, 'Perfil profesional no asignado.');
            END;

            po_effective_pro_id := v_actual_pro_id;
        ELSIF po_role_id = pkg_aox_util.fn_rol('RECEPCIONISTA') THEN
            po_effective_pro_id := NULL;
        END IF;
    END pr_resolve_customer_access;

    PROCEDURE pr_add_field_error(
        pio_errors  IN OUT NOCOPY json_array_t,
        pi_field    IN VARCHAR2,
        pi_message  IN VARCHAR2
    ) IS
        v_error json_object_t := json_object_t();
    BEGIN
        v_error.put('field'  , pi_field);
        v_error.put('message', pi_message);
        pio_errors.append(v_error);
    END pr_add_field_error;

    PROCEDURE pr_put_optional_str(
        pio_obj    IN OUT NOCOPY json_object_t,
        pi_key     IN VARCHAR2,
        pi_value   IN VARCHAR2
    ) IS
    BEGIN
        IF pi_value IS NULL THEN
            pio_obj.put_null(pi_key);
        ELSE
            pio_obj.put(pi_key, pi_value);
        END IF;
    END pr_put_optional_str;

    FUNCTION fn_json_trim(
        pi_obj IN json_object_t,
        pi_key IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_el  json_element_t;
        v_raw VARCHAR2(4000);
    BEGIN
        IF pi_obj IS NULL OR NOT pi_obj.has(pi_key) THEN
            RETURN NULL;
        END IF;
        v_el := pi_obj.get(pi_key);
        IF v_el IS NULL OR v_el.is_null THEN
            RETURN NULL;
        END IF;
        BEGIN
            v_raw := pi_obj.get_string(pi_key);
        EXCEPTION
            WHEN OTHERS THEN
                v_raw := TRIM('"' FROM v_el.stringify());
        END;
        RETURN NULLIF(TRIM(v_raw), '');
    END fn_json_trim;

    FUNCTION fn_digits_only(pi_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN NULLIF(REGEXP_REPLACE(NVL(pi_value, ''), '[^0-9]', ''), '');
    END fn_digits_only;

    PROCEDURE pr_normalize_customer_contact(
        pi_org_id          IN  NUMBER,
        pi_exclude_cus_id  IN  NUMBER,
        pi_first_name      IN  VARCHAR2,
        pi_last_name       IN  VARCHAR2,
        pi_full_name       IN  VARCHAR2,
        pi_phone           IN  VARCHAR2,
        pi_document        IN  VARCHAR2,
        pi_email           IN  VARCHAR2,
        po_first_name      OUT VARCHAR2,
        po_last_name       OUT VARCHAR2,
        po_full_name       OUT VARCHAR2,
        po_phone           OUT VARCHAR2,
        po_document        OUT VARCHAR2,
        po_email           OUT VARCHAR2,
        po_errors          IN OUT NOCOPY json_array_t
    ) IS
        v_first     VARCHAR2(200);
        v_last      VARCHAR2(200);
        v_full      VARCHAR2(400);
        v_phone     VARCHAR2(50);
        v_document  VARCHAR2(40);
        v_email     VARCHAR2(200);
        v_space     PLS_INTEGER;
        v_dup       NUMBER := 0;
    BEGIN
        v_first := NULLIF(TRIM(pi_first_name), '');
        v_last  := NULLIF(TRIM(pi_last_name), '');
        v_full  := NULLIF(TRIM(pi_full_name), '');

        IF v_first IS NULL AND v_last IS NULL AND v_full IS NOT NULL THEN
            v_space := INSTR(v_full, ' ');
            IF v_space > 0 THEN
                v_first := NULLIF(TRIM(SUBSTR(v_full, 1, v_space - 1)), '');
                v_last  := NULLIF(TRIM(SUBSTR(v_full, v_space + 1)), '');
            ELSE
                v_first := v_full;
            END IF;
        END IF;

        IF v_first IS NULL THEN
            pr_add_field_error(po_errors, 'first_name', 'El nombre es obligatorio.');
        ELSIF LENGTH(v_first) > 80 THEN
            pr_add_field_error(po_errors, 'first_name', 'El nombre no puede superar los 80 caracteres.');
        END IF;

        IF v_last IS NULL THEN
            pr_add_field_error(po_errors, 'last_name', 'El apellido es obligatorio.');
        ELSIF LENGTH(v_last) > 80 THEN
            pr_add_field_error(po_errors, 'last_name', 'El apellido no puede superar los 80 caracteres.');
        END IF;

        IF v_first IS NOT NULL AND v_last IS NOT NULL THEN
            v_full := TRIM(v_first || ' ' || v_last);
            IF LENGTH(v_full) > 150 THEN
                pr_add_field_error(po_errors, 'full_name', 'El nombre completo no puede superar los 150 caracteres.');
            END IF;
        END IF;

        v_phone := NULLIF(TRIM(pi_phone), '');
        IF v_phone IS NULL THEN
            pr_add_field_error(po_errors, 'phone_number', 'El telefono es obligatorio.');
        ELSIF NOT REGEXP_LIKE(v_phone, '^\+5959[0-9]{8}$') THEN
            pr_add_field_error(
                po_errors,
                'phone_number',
                'Ingresa un numero de Paraguay valido. Ej: 0981 123 456.'
            );
        ELSE
            SELECT COUNT(*)
              INTO v_dup
              FROM customer
             WHERE org_id_organization = pi_org_id
               AND phone_number        = v_phone
               AND (pi_exclude_cus_id IS NULL OR id_customer != pi_exclude_cus_id);

            IF v_dup > 0 THEN
                pr_add_field_error(
                    po_errors,
                    'phone_number',
                    'Este numero ya esta registrado con otro cliente.'
                );
            END IF;
        END IF;

        v_document := fn_digits_only(pi_document);
        IF v_document IS NOT NULL THEN
            IF NOT REGEXP_LIKE(v_document, '^[0-9]{5,8}$') OR REGEXP_LIKE(v_document, '^0+$') THEN
                pr_add_field_error(
                    po_errors,
                    'document_number',
                    'Ingresa una CI paraguaya valida. Ej: 4567890.'
                );
            ELSE
                SELECT COUNT(*)
                  INTO v_dup
                  FROM customer
                 WHERE org_id_organization = pi_org_id
                   AND document_number      = v_document
                   AND (pi_exclude_cus_id IS NULL OR id_customer != pi_exclude_cus_id);

                IF v_dup > 0 THEN
                    pr_add_field_error(
                        po_errors,
                        'document_number',
                        'Esta CI ya esta registrada con otro cliente.'
                    );
                END IF;
            END IF;
        END IF;

        v_email := LOWER(TRIM(pi_email));
        IF v_email IS NOT NULL THEN
            IF LENGTH(v_email) < 6
               OR LENGTH(v_email) > 150
               OR NOT REGEXP_LIKE(v_email, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN
                pr_add_field_error(
                    po_errors,
                    'email',
                    'Ingresa un correo valido. Ej: nombre@correo.com'
                );
            ELSE
                SELECT COUNT(*)
                  INTO v_dup
                  FROM customer
                 WHERE org_id_organization = pi_org_id
                   AND email                = v_email
                   AND (pi_exclude_cus_id IS NULL OR id_customer != pi_exclude_cus_id);

                IF v_dup > 0 THEN
                    pr_add_field_error(
                        po_errors,
                        'email',
                        'Este correo ya esta registrado con otro cliente.'
                    );
                END IF;
            END IF;
        END IF;

        po_first_name := v_first;
        po_last_name  := v_last;
        po_full_name  := v_full;
        po_phone      := v_phone;
        po_document   := v_document;
        po_email      := v_email;
    END pr_normalize_customer_contact;

    PROCEDURE pr_put_customer_contact(
        pio_obj           IN OUT NOCOPY json_object_t,
        pi_id_customer    IN NUMBER,
        pi_full_name      IN VARCHAR2,
        pi_first_name     IN VARCHAR2,
        pi_last_name      IN VARCHAR2,
        pi_phone          IN VARCHAR2,
        pi_document       IN VARCHAR2,
        pi_email          IN VARCHAR2
    ) IS
    BEGIN
        pio_obj.put('id_customer' , pi_id_customer);
        pio_obj.put('full_name'   , NVL(pi_full_name, ''));
        pr_put_optional_str(pio_obj, 'first_name', pi_first_name);
        pr_put_optional_str(pio_obj, 'last_name', pi_last_name);
        pr_put_optional_str(pio_obj, 'phone_number', pi_phone);
        pr_put_optional_str(pio_obj, 'document_number', pi_document);
        pr_put_optional_str(pio_obj, 'email', pi_email);
    END pr_put_customer_contact;

    FUNCTION fn_build_appointment_json(
        pi_start_time       IN TIMESTAMP,
        pi_end_time         IN TIMESTAMP,
        pi_service_name     IN VARCHAR2,
        pi_professional_name IN VARCHAR2,
        pi_status           IN VARCHAR2,
        pi_payment_status   IN VARCHAR2,
        pi_app_id           IN NUMBER DEFAULT NULL,
        pi_history_enabled  IN NUMBER DEFAULT 0,
        pi_include_detail   IN NUMBER DEFAULT 0
    ) RETURN json_object_t IS
        v_obj          json_object_t := json_object_t();
        v_has_notes    NUMBER := 0;
        v_attach_count NUMBER := 0;
        v_body_mark_count NUMBER := 0;
        v_notes_legacy CLOB;
        v_consultation_reason CLOB;
        v_procedure_notes CLOB;
        v_recommendations CLOB;
        v_attach_arr   json_array_t := json_array_t();
        v_attach_obj   json_object_t;
        v_survey_status appointment.survey_status%TYPE;
        v_survey_score  appointment.survey_score%TYPE;
    BEGIN
        v_obj.put('start_time', TO_CHAR(pi_start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
        IF pi_end_time IS NOT NULL THEN
            v_obj.put('end_time', TO_CHAR(pi_end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
        END IF;
        v_obj.put('service_name', NVL(pi_service_name, 'Servicio'));
        v_obj.put('professional_name', NVL(pi_professional_name, ''));
        v_obj.put('status', pi_status);
        IF pi_payment_status IS NOT NULL THEN
            v_obj.put('payment_status', pi_payment_status);
        END IF;

        -- Flags de historial (Fase 4): solo si el plan incluye APPOINTMENT_HISTORY.
        IF pi_app_id IS NOT NULL THEN
            v_obj.put('id_appointment', pi_app_id);
            BEGIN
                SELECT NVL(a.survey_status, 'NONE'), a.survey_score
                  INTO v_survey_status, v_survey_score
                  FROM appointment a
                 WHERE a.id_appointment = pi_app_id;

                v_obj.put('survey_status', v_survey_status);
                IF v_survey_score IS NOT NULL THEN
                    v_obj.put('survey_score', v_survey_score);
                END IF;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL;
            END;
            IF NVL(pi_history_enabled, 0) = 1 THEN
                SELECT COUNT(*)
                  INTO v_has_notes
                  FROM appointment_session_record
                 WHERE app_id_appointment = pi_app_id
                   AND (
                        notes IS NOT NULL
                     OR consultation_reason IS NOT NULL
                     OR procedure_notes IS NOT NULL
                     OR recommendations IS NOT NULL
                   );

                SELECT COUNT(*)
                  INTO v_attach_count
                  FROM appointment_attachment
                 WHERE app_id_appointment = pi_app_id;

                BEGIN
                    SELECT pkg_aox_body_map_api.fn_mark_count_from_json(bs.snapshot_json)
                      INTO v_body_mark_count
                      FROM customer_body_snapshot bs
                     WHERE bs.app_id_appointment = pi_app_id
                       AND ROWNUM = 1;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_body_mark_count := 0;
                END;

                v_obj.put('has_history_notes', CASE WHEN v_has_notes > 0 THEN TRUE ELSE FALSE END);
                v_obj.put('attachment_count', v_attach_count);
                v_obj.put('body_mark_count', v_body_mark_count);
                v_obj.put(
                    'has_history',
                    CASE WHEN (v_has_notes + v_attach_count + v_body_mark_count) > 0 THEN TRUE ELSE FALSE END
                );

                -- Detalle completo (notas + adjuntos) para el historial del perfil.
                IF NVL(pi_include_detail, 0) = 1 THEN
                    BEGIN
                        SELECT notes,
                               consultation_reason,
                               procedure_notes,
                               recommendations
                          INTO v_notes_legacy,
                               v_consultation_reason,
                               v_procedure_notes,
                               v_recommendations
                          FROM appointment_session_record
                         WHERE app_id_appointment = pi_app_id;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            v_notes_legacy        := NULL;
                            v_consultation_reason := NULL;
                            v_procedure_notes     := NULL;
                            v_recommendations     := NULL;
                    END;

                    IF v_procedure_notes IS NULL AND v_notes_legacy IS NOT NULL THEN
                        v_procedure_notes := v_notes_legacy;
                    END IF;

                    IF v_consultation_reason IS NOT NULL THEN
                        v_obj.put('consultation_reason', v_consultation_reason);
                    ELSE
                        v_obj.put_null('consultation_reason');
                    END IF;

                    IF v_procedure_notes IS NOT NULL THEN
                        v_obj.put('procedure_notes', v_procedure_notes);
                    ELSE
                        v_obj.put_null('procedure_notes');
                    END IF;

                    IF v_recommendations IS NOT NULL THEN
                        v_obj.put('recommendations', v_recommendations);
                    ELSE
                        v_obj.put_null('recommendations');
                    END IF;

                    IF v_notes_legacy IS NOT NULL THEN
                        v_obj.put('notes', v_notes_legacy);
                    ELSE
                        v_obj.put_null('notes');
                    END IF;

                    FOR att IN (
                        SELECT id_attachment, file_name, mime_type, size_bytes, storage_url
                          FROM appointment_attachment
                         WHERE app_id_appointment = pi_app_id
                         ORDER BY id_attachment
                    ) LOOP
                        v_attach_obj := json_object_t();
                        v_attach_obj.put('id_attachment', att.id_attachment);
                        v_attach_obj.put('file_name'    , att.file_name);
                        v_attach_obj.put('mime_type'    , att.mime_type);
                        v_attach_obj.put('size_bytes'   , att.size_bytes);
                        v_attach_obj.put('url'          , att.storage_url);
                        v_attach_arr.append(v_attach_obj);
                    END LOOP;

                    v_obj.put('attachments', v_attach_arr);
                END IF;
            END IF;
        END IF;
        RETURN v_obj;
    END fn_build_appointment_json;

    PROCEDURE pr_list_customers(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_pro_id        IN  NUMBER DEFAULT NULL,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        pi_archived      IN  NUMBER DEFAULT 0,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_role_id       NUMBER;
        v_effective_pro_id NUMBER;
        v_response_json json_object_t := json_object_t();
        v_customers_arr json_array_t  := json_array_t();
        v_customer_obj  json_object_t;
        v_meta_obj      json_object_t;

        v_page          NUMBER := NVL(pi_page, 1);
        v_limit         NUMBER := NVL(pi_limit, 9);
        v_offset        NUMBER;
        v_total_records NUMBER := 0;
        v_total_pages   NUMBER := 0;
        v_want_active   NUMBER := CASE WHEN NVL(pi_archived, 0) = 1 THEN 0 ELSE 1 END;
        -- Mayúsculas + sin tildes/diacríticos para LIKE accent-insensitive (Maria = María).
        v_search        VARCHAR2(200) := TRANSLATE(
            UPPER(TRIM(pi_search)),
            'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ',
            'AEIOUUNAEIOUAAEIOU'
        );
    BEGIN
        pr_resolve_customer_access(
            pi_auth_header,
            pi_pro_id,
            v_org_id,
            v_user_id,
            v_role_id,
            v_effective_pro_id
        );

        IF v_page < 1 THEN v_page := 1; END IF;
        v_offset := (v_page - 1) * v_limit;
        IF v_search IS NOT NULL AND LENGTH(v_search) = 0 THEN
            v_search := NULL;
        END IF;

        SELECT COUNT(*)
          INTO v_total_records
          FROM customer c
         WHERE c.org_id_organization = v_org_id
           AND NVL(c.is_active, 1) = v_want_active
           AND (v_effective_pro_id IS NULL OR EXISTS (
                 SELECT 1
                   FROM appointment a
                  WHERE a.cus_id_customer = c.id_customer
                    AND a.org_id_organization = c.org_id_organization
                    AND a.pro_id_professional = v_effective_pro_id
               ))
           AND (
                v_search IS NULL
                OR TRANSLATE(UPPER(c.full_name), 'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ', 'AEIOUUNAEIOUAAEIOU')
                   LIKE '%' || v_search || '%'
                OR UPPER(NVL(c.phone_number, '')) LIKE '%' || v_search || '%'
                OR UPPER(NVL(c.document_number, '')) LIKE '%' || v_search || '%'
                OR UPPER(NVL(c.email, '')) LIKE '%' || v_search || '%'
               );

        v_total_pages := CEIL(v_total_records / v_limit);

        FOR rec IN (
            SELECT
                c.id_customer,
                c.full_name,
                c.first_name,
                c.last_name,
                c.document_number,
                c.email,
                c.phone_number,
                c.created_at,
                NVL(c.is_active, 1) AS is_active,
                NVL(agg.appointment_count, 0) AS appointment_count,
                agg.last_appointment_at
            FROM customer c
            LEFT JOIN (
                SELECT a.cus_id_customer,
                       a.org_id_organization,
                       COUNT(*) AS appointment_count,
                       MAX(a.start_time) AS last_appointment_at
                  FROM appointment a
                 WHERE a.org_id_organization = v_org_id
                   AND (
                        a.status = 'COMPLETADO'
                     OR (
                            a.status = 'CONFIRMADO'
                        AND a.start_time < CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP)
                        )
                   )
                   AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
                 GROUP BY a.cus_id_customer, a.org_id_organization
            ) agg
              ON agg.cus_id_customer = c.id_customer
             AND agg.org_id_organization = c.org_id_organization
            WHERE c.org_id_organization = v_org_id
              AND NVL(c.is_active, 1) = v_want_active
              AND (v_effective_pro_id IS NULL OR EXISTS (
                    SELECT 1
                      FROM appointment a
                     WHERE a.cus_id_customer = c.id_customer
                       AND a.org_id_organization = c.org_id_organization
                       AND a.pro_id_professional = v_effective_pro_id
                  ))
              AND (
                    v_search IS NULL
                    OR TRANSLATE(UPPER(c.full_name), 'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ', 'AEIOUUNAEIOUAAEIOU')
                       LIKE '%' || v_search || '%'
                    OR UPPER(NVL(c.phone_number, '')) LIKE '%' || v_search || '%'
                    OR UPPER(NVL(c.document_number, '')) LIKE '%' || v_search || '%'
                    OR UPPER(NVL(c.email, '')) LIKE '%' || v_search || '%'
                  )
            ORDER BY c.id_customer DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_customer_obj := json_object_t();
            pr_put_customer_contact(
                v_customer_obj,
                rec.id_customer,
                rec.full_name,
                rec.first_name,
                rec.last_name,
                rec.phone_number,
                rec.document_number,
                rec.email
            );
            v_customer_obj.put('created_at'        , TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_customer_obj.put('is_active'         , NVL(rec.is_active, 1));
            v_customer_obj.put('appointment_count' , NVL(rec.appointment_count, 0));
            IF rec.last_appointment_at IS NOT NULL THEN
                v_customer_obj.put(
                    'last_appointment_at',
                    TO_CHAR(rec.last_appointment_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                );
            ELSE
                v_customer_obj.put_null('last_appointment_at');
            END IF;

            v_customers_arr.append(v_customer_obj);
        END LOOP;

        v_meta_obj := json_object_t();
        v_meta_obj.put('current_page' , v_page);
        v_meta_obj.put('per_page'     , v_limit);
        v_meta_obj.put('total_records', v_total_records);
        v_meta_obj.put('total_pages'  , v_total_pages);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta'  , v_meta_obj);
        v_response_json.put('data'  , v_customers_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_customers;

    PROCEDURE pr_get_customer_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_pro_id        IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id           NUMBER;
        v_user_id          NUMBER;
        v_role_id          NUMBER;
        v_effective_pro_id NUMBER;
        v_now_local        TIMESTAMP;
        v_response_json    json_object_t := json_object_t();
        v_data_obj         json_object_t := json_object_t();
        v_stats_obj        json_object_t := json_object_t();
        v_pending_arr      json_array_t  := json_array_t();
        v_top_services_arr json_array_t  := json_array_t();
        v_top_service_obj  json_object_t;

        v_full_name        VARCHAR2(200);
        v_first_name       VARCHAR2(80);
        v_last_name        VARCHAR2(80);
        v_document_number  VARCHAR2(20);
        v_email            VARCHAR2(150);
        v_phone_number     VARCHAR2(50);
        v_created_at       TIMESTAMP;
        v_is_active        NUMBER;

        v_attended_count   NUMBER := 0;
        v_cancelled_count  NUMBER := 0;
        v_pending_count    NUMBER := 0;
        v_lifetime_value   NUMBER := 0;
        v_attendance_rate  NUMBER;

        v_last_obj         json_object_t;
        v_next_obj         json_object_t;
        v_has_last         BOOLEAN := FALSE;
        v_has_next         BOOLEAN := FALSE;
        v_history_enabled  NUMBER  := 0;
        v_history_arr      json_array_t := json_array_t();

        -- Fase 6: métricas de rentabilidad (ADMIN + feature PROFITABILITY_ANALYTICS; Base + Premium).
        v_analytics_enabled NUMBER := 0;
        v_profit_obj       json_object_t;
        v_year_value       NUMBER := 0;
        v_year_count       NUMBER := 0;
        v_avg_ticket       NUMBER := 0;
        v_lost_value       NUMBER := 0;
    BEGIN
        IF NVL(pi_cus_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cliente invalido.');
        END IF;

        pr_resolve_customer_access(
            pi_auth_header,
            pi_pro_id,
            v_org_id,
            v_user_id,
            v_role_id,
            v_effective_pro_id
        );

        -- Historial (Fase 4): ¿el plan incluye historial por cita?
        v_history_enabled := pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'APPOINTMENT_HISTORY');

        -- Rentabilidad (Fase 6): ADMIN + PROFITABILITY_ANALYTICS (Base + Premium).
        IF v_role_id = pkg_aox_util.fn_rol('ADMIN')
           AND pkg_aox_subscription_api.fn_org_has_feature(v_org_id, 'PROFITABILITY_ANALYTICS') = 1 THEN
            v_analytics_enabled := 1;
        END IF;

        v_now_local := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);

        BEGIN
            SELECT
                c.full_name,
                c.first_name,
                c.last_name,
                c.document_number,
                c.email,
                c.phone_number,
                c.created_at,
                NVL(c.is_active, 1)
              INTO
                v_full_name,
                v_first_name,
                v_last_name,
                v_document_number,
                v_email,
                v_phone_number,
                v_created_at,
                v_is_active
              FROM customer c
             WHERE c.id_customer         = pi_cus_id
               AND c.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR EXISTS (
                     SELECT 1
                       FROM appointment a
                      WHERE a.cus_id_customer = c.id_customer
                        AND a.org_id_organization = c.org_id_organization
                        AND a.pro_id_professional = v_effective_pro_id
                   ));
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
        END;

        SELECT
            NVL(SUM(CASE
                WHEN a.status = 'COMPLETADO'
                  OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local)
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.status = 'CANCELADO'
                 AND a.start_time < v_now_local
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.status = 'PENDIENTE'
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.status = 'COMPLETADO'
                  OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local)
                THEN NVL(s.price, 0) ELSE 0
            END), 0)
          INTO
            v_attended_count,
            v_cancelled_count,
            v_pending_count,
            v_lifetime_value
          FROM appointment a
          LEFT JOIN service s
            ON s.id_service = a.ser_id_service
         WHERE a.cus_id_customer     = pi_cus_id
           AND a.org_id_organization = v_org_id
           AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id);

        v_stats_obj.put('attended_count'  , v_attended_count);
        v_stats_obj.put('cancelled_count' , v_cancelled_count);
        v_stats_obj.put('pending_count'   , v_pending_count);
        v_stats_obj.put('lifetime_value'  , v_lifetime_value);

        IF (v_attended_count + v_cancelled_count) > 0 THEN
            v_attendance_rate := ROUND(
                100 * v_attended_count / (v_attended_count + v_cancelled_count),
                1
            );
            v_stats_obj.put('attendance_rate', v_attendance_rate);
        ELSE
            v_stats_obj.put_null('attendance_rate');
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                NVL(s.name, 'Servicio') AS service_name,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                a.status,
                a.payment_status
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
              LEFT JOIN service s ON s.id_service      = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
               AND (
                    a.status = 'COMPLETADO'
                 OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local)
               )
             ORDER BY a.start_time DESC
             FETCH FIRST 1 ROW ONLY
        ) LOOP
            v_last_obj := fn_build_appointment_json(
                rec.start_time,
                rec.end_time,
                rec.service_name,
                rec.professional_name,
                rec.status,
                rec.payment_status,
                rec.id_appointment,
                v_history_enabled
            );
            v_has_last := TRUE;
        END LOOP;

        IF v_has_last THEN
            v_stats_obj.put('last_appointment', v_last_obj);
        ELSE
            v_stats_obj.put_null('last_appointment');
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                NVL(s.name, 'Servicio') AS service_name,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                a.status,
                a.payment_status
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
              LEFT JOIN service s ON s.id_service      = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
               AND a.status = 'CONFIRMADO'
               AND a.start_time >= v_now_local
             ORDER BY a.start_time ASC
             FETCH FIRST 1 ROW ONLY
        ) LOOP
            v_next_obj := fn_build_appointment_json(
                rec.start_time,
                rec.end_time,
                rec.service_name,
                rec.professional_name,
                rec.status,
                rec.payment_status,
                rec.id_appointment,
                v_history_enabled
            );
            v_has_next := TRUE;
        END LOOP;

        IF v_has_next THEN
            v_stats_obj.put('next_appointment', v_next_obj);
        ELSE
            v_stats_obj.put_null('next_appointment');
        END IF;

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                NVL(s.name, 'Servicio') AS service_name,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                a.status,
                a.payment_status
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
              LEFT JOIN service s ON s.id_service      = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
               AND a.status = 'PENDIENTE'
             ORDER BY a.start_time ASC
             FETCH FIRST c_pending_limit ROWS ONLY
        ) LOOP
            v_pending_arr.append(
                fn_build_appointment_json(
                    rec.start_time,
                    rec.end_time,
                    rec.service_name,
                    rec.professional_name,
                    rec.status,
                    rec.payment_status,
                    rec.id_appointment,
                    v_history_enabled
                )
            );
        END LOOP;

        v_stats_obj.put('pending_appointments', v_pending_arr);

        -- Historial: COMPLETADO siempre (aunque el horario sea futuro) y CONFIRMADO ya ocurrido.
        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                NVL(s.name, 'Servicio') AS service_name,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                a.status,
                a.payment_status
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
              LEFT JOIN service s ON s.id_service      = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
               AND (
                    a.status = 'COMPLETADO'
                 OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local)
               )
             ORDER BY a.start_time DESC
             FETCH FIRST c_history_limit ROWS ONLY
        ) LOOP
            v_history_arr.append(
                fn_build_appointment_json(
                    rec.start_time,
                    rec.end_time,
                    rec.service_name,
                    rec.professional_name,
                    rec.status,
                    rec.payment_status,
                    rec.id_appointment,
                    v_history_enabled,
                    CASE WHEN v_history_enabled = 1 THEN 1 ELSE 0 END
                )
            );
        END LOOP;

        v_stats_obj.put('appointment_history', v_history_arr);
        v_stats_obj.put(
            'history_enabled',
            CASE WHEN v_history_enabled = 1 THEN TRUE ELSE FALSE END
        );

        FOR rec IN (
            SELECT
                s.id_service,
                s.name,
                COUNT(*) AS service_count
              FROM appointment a
              JOIN service s ON s.id_service = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id
               AND (v_effective_pro_id IS NULL OR a.pro_id_professional = v_effective_pro_id)
               AND (
                    a.status = 'COMPLETADO'
                 OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local)
               )
             GROUP BY s.id_service, s.name
             ORDER BY COUNT(*) DESC, s.name ASC
             FETCH FIRST 5 ROWS ONLY
        ) LOOP
            v_top_service_obj := json_object_t();
            v_top_service_obj.put('id_service', rec.id_service);
            v_top_service_obj.put('name'      , rec.name);
            v_top_service_obj.put('count'     , rec.service_count);
            v_top_services_arr.append(v_top_service_obj);
        END LOOP;

        v_stats_obj.put('top_services', v_top_services_arr);

        -- Rentabilidad (Fase 6): ingresos del año en curso, ticket promedio y valor
        -- perdido por cancelaciones. ADMIN con feature PROFITABILITY_ANALYTICS (Base + Premium).
        IF v_analytics_enabled = 1 THEN
            SELECT
                NVL(SUM(CASE
                    WHEN (a.status = 'COMPLETADO'
                       OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local))
                     AND a.start_time >= TRUNC(v_now_local, 'YYYY')
                    THEN NVL(s.price, 0) ELSE 0
                END), 0),
                NVL(SUM(CASE
                    WHEN (a.status = 'COMPLETADO'
                       OR (a.status = 'CONFIRMADO' AND a.start_time < v_now_local))
                     AND a.start_time >= TRUNC(v_now_local, 'YYYY')
                    THEN 1 ELSE 0
                END), 0),
                NVL(SUM(CASE
                    WHEN a.status = 'CANCELADO'
                     AND a.start_time < v_now_local
                    THEN NVL(s.price, 0) ELSE 0
                END), 0)
              INTO
                v_year_value,
                v_year_count,
                v_lost_value
              FROM appointment a
              LEFT JOIN service s
                ON s.id_service = a.ser_id_service
             WHERE a.cus_id_customer     = pi_cus_id
               AND a.org_id_organization = v_org_id;

            IF v_attended_count > 0 THEN
                v_avg_ticket := ROUND(v_lifetime_value / v_attended_count);
            ELSE
                v_avg_ticket := 0;
            END IF;

            v_profit_obj := json_object_t();
            v_profit_obj.put('currency'          , 'PYG');
            v_profit_obj.put('this_year_revenue' , v_year_value);
            v_profit_obj.put('this_year_count'   , v_year_count);
            v_profit_obj.put('avg_ticket'        , v_avg_ticket);
            v_profit_obj.put('lost_value'        , v_lost_value);
            v_stats_obj.put('profitability', v_profit_obj);
            v_stats_obj.put('profitability_enabled', TRUE);
        ELSE
            v_stats_obj.put('profitability_enabled', FALSE);
        END IF;

        pr_put_customer_contact(
            v_data_obj,
            pi_cus_id,
            v_full_name,
            v_first_name,
            v_last_name,
            v_phone_number,
            v_document_number,
            v_email
        );
        v_data_obj.put('created_at'   , TO_CHAR(v_created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        v_data_obj.put('is_active'    , NVL(v_is_active, 1));
        v_data_obj.put('stats'        , v_stats_obj);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_customer_profile;

    PROCEDURE pr_update_customer_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id             NUMBER;
        v_user_id            NUMBER;
        v_role_id            NUMBER;
        v_json_req           json_object_t;
        v_response_json      json_object_t := json_object_t();
        v_data_obj           json_object_t;
        v_validation_errors json_array_t  := json_array_t();

        v_first_name        customer.first_name%TYPE;
        v_last_name         customer.last_name%TYPE;
        v_full_name         customer.full_name%TYPE;
        v_phone_to_save     customer.phone_number%TYPE;
        v_document          customer.document_number%TYPE;
        v_email             customer.email%TYPE;
        v_exists_count      NUMBER := 0;
    BEGIN
        IF NVL(pi_cus_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cliente invalido.');
        END IF;

        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF v_role_id NOT IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN
            RAISE_APPLICATION_ERROR(-20005, 'No tienes permisos para editar clientes.');
        END IF;

        SELECT COUNT(*)
          INTO v_exists_count
          FROM customer
         WHERE id_customer         = pi_cus_id
           AND org_id_organization = v_org_id;

        IF v_exists_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
        END IF;

        v_json_req := json_object_t.parse(pi_body);

        pr_normalize_customer_contact(
            pi_org_id         => v_org_id,
            pi_exclude_cus_id => pi_cus_id,
            pi_first_name     => fn_json_trim(v_json_req, 'first_name'),
            pi_last_name      => fn_json_trim(v_json_req, 'last_name'),
            pi_full_name      => fn_json_trim(v_json_req, 'full_name'),
            pi_phone          => fn_json_trim(v_json_req, 'phone_number'),
            pi_document       => fn_json_trim(v_json_req, 'document_number'),
            pi_email          => fn_json_trim(v_json_req, 'email'),
            po_first_name     => v_first_name,
            po_last_name      => v_last_name,
            po_full_name      => v_full_name,
            po_phone          => v_phone_to_save,
            po_document       => v_document,
            po_email          => v_email,
            po_errors         => v_validation_errors
        );

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status' , 'error');
            v_response_json.put('message', 'Errores de validacion en los campos enviados.');
            v_response_json.put('errors' , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        UPDATE customer
           SET full_name        = v_full_name,
               first_name       = v_first_name,
               last_name        = v_last_name,
               phone_number     = v_phone_to_save,
               document_number  = v_document,
               email            = v_email
         WHERE id_customer         = pi_cus_id
           AND org_id_organization = v_org_id;

        v_data_obj := json_object_t();
        pr_put_customer_contact(
            v_data_obj,
            pi_cus_id,
            v_full_name,
            v_first_name,
            v_last_name,
            v_phone_to_save,
            v_document,
            v_email
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_update_customer_profile;

    PROCEDURE pr_create_customer(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id             NUMBER;
        v_user_id            NUMBER;
        v_role_id            NUMBER;
        v_json_req           json_object_t;
        v_response_json      json_object_t := json_object_t();
        v_data_obj           json_object_t;
        v_validation_errors json_array_t  := json_array_t();

        v_first_name        customer.first_name%TYPE;
        v_last_name         customer.last_name%TYPE;
        v_full_name         customer.full_name%TYPE;
        v_phone_to_save     customer.phone_number%TYPE;
        v_document          customer.document_number%TYPE;
        v_email             customer.email%TYPE;
        v_cus_id            NUMBER;
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF v_role_id NOT IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN
            RAISE_APPLICATION_ERROR(-20005, 'No tienes permisos para crear clientes.');
        END IF;

        v_json_req := json_object_t.parse(NVL(pi_body, TO_CLOB('{}')));

        pr_normalize_customer_contact(
            pi_org_id         => v_org_id,
            pi_exclude_cus_id => NULL,
            pi_first_name     => fn_json_trim(v_json_req, 'first_name'),
            pi_last_name      => fn_json_trim(v_json_req, 'last_name'),
            pi_full_name      => fn_json_trim(v_json_req, 'full_name'),
            pi_phone          => fn_json_trim(v_json_req, 'phone_number'),
            pi_document       => fn_json_trim(v_json_req, 'document_number'),
            pi_email          => fn_json_trim(v_json_req, 'email'),
            po_first_name     => v_first_name,
            po_last_name      => v_last_name,
            po_full_name      => v_full_name,
            po_phone          => v_phone_to_save,
            po_document       => v_document,
            po_email          => v_email,
            po_errors         => v_validation_errors
        );

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status' , 'error');
            v_response_json.put('message', 'Errores de validacion en los campos enviados.');
            v_response_json.put('errors' , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        INSERT INTO customer (
            org_id_organization,
            full_name,
            first_name,
            last_name,
            phone_number,
            document_number,
            email
        ) VALUES (
            v_org_id,
            v_full_name,
            v_first_name,
            v_last_name,
            v_phone_to_save,
            v_document,
            v_email
        ) RETURNING id_customer INTO v_cus_id;

        v_data_obj := json_object_t();
        pr_put_customer_contact(
            v_data_obj,
            v_cus_id,
            v_full_name,
            v_first_name,
            v_last_name,
            v_phone_to_save,
            v_document,
            v_email
        );

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_customer;

    PROCEDURE pr_set_customer_active(
        pi_auth_header   IN  VARCHAR2,
        pi_cus_id        IN  NUMBER,
        pi_is_active     IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_user_id        NUMBER;
        v_role_id        NUMBER;
        v_response_json  json_object_t := json_object_t();
        v_data_obj       json_object_t;
        v_full_name      customer.full_name%TYPE;
        v_first_name     customer.first_name%TYPE;
        v_last_name      customer.last_name%TYPE;
        v_phone          customer.phone_number%TYPE;
        v_document       customer.document_number%TYPE;
        v_email          customer.email%TYPE;
        v_is_active      NUMBER;
        v_target_active  NUMBER;
    BEGIN
        IF NVL(pi_cus_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Cliente invalido.');
        END IF;

        v_target_active := CASE WHEN NVL(pi_is_active, 0) = 1 THEN 1 ELSE 0 END;

        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

        IF v_role_id NOT IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN
            RAISE_APPLICATION_ERROR(
                -20005,
                CASE
                    WHEN v_target_active = 0 THEN 'No tienes permisos para archivar clientes.'
                    ELSE 'No tienes permisos para restaurar clientes.'
                END
            );
        END IF;

        BEGIN
            SELECT full_name, first_name, last_name, phone_number, document_number, email,
                   NVL(is_active, 1)
              INTO v_full_name, v_first_name, v_last_name, v_phone, v_document, v_email,
                   v_is_active
              FROM customer
             WHERE id_customer         = pi_cus_id
               AND org_id_organization = v_org_id
               FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, 'Cliente no encontrado.');
        END;

        IF v_is_active != v_target_active THEN
            UPDATE /*+ no_parallel */ customer
               SET is_active = v_target_active
             WHERE id_customer         = pi_cus_id
               AND org_id_organization = v_org_id;
            v_is_active := v_target_active;
        END IF;

        v_data_obj := json_object_t();
        pr_put_customer_contact(
            v_data_obj,
            pi_cus_id,
            v_full_name,
            v_first_name,
            v_last_name,
            v_phone,
            v_document,
            v_email
        );
        v_data_obj.put('is_active', v_is_active);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_set_customer_active;

END pkg_aox_customer_api;
/

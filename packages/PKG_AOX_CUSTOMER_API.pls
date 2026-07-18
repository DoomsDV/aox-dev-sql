PROMPT CREATE OR REPLACE PACKAGE pkg_aox_customer_api
CREATE OR REPLACE PACKAGE pkg_aox_customer_api IS

    PROCEDURE pr_list_customers(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_pro_id        IN  NUMBER DEFAULT NULL,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
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
        v_notes        CLOB;
        v_attach_arr   json_array_t := json_array_t();
        v_attach_obj   json_object_t;
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
            IF NVL(pi_history_enabled, 0) = 1 THEN
                SELECT COUNT(*)
                  INTO v_has_notes
                  FROM appointment_session_record
                 WHERE app_id_appointment = pi_app_id
                   AND notes IS NOT NULL;

                SELECT COUNT(*)
                  INTO v_attach_count
                  FROM appointment_attachment
                 WHERE app_id_appointment = pi_app_id;

                v_obj.put('has_history_notes', CASE WHEN v_has_notes > 0 THEN TRUE ELSE FALSE END);
                v_obj.put('attachment_count', v_attach_count);
                v_obj.put('has_history', CASE WHEN (v_has_notes + v_attach_count) > 0 THEN TRUE ELSE FALSE END);

                -- Detalle completo (notas + adjuntos) para el historial del perfil.
                IF NVL(pi_include_detail, 0) = 1 THEN
                    BEGIN
                        SELECT notes
                          INTO v_notes
                          FROM appointment_session_record
                         WHERE app_id_appointment = pi_app_id;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            v_notes := NULL;
                    END;

                    IF v_notes IS NOT NULL THEN
                        v_obj.put('notes', v_notes);
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
               );

        v_total_pages := CEIL(v_total_records / v_limit);

        FOR rec IN (
            SELECT
                c.id_customer,
                c.full_name,
                c.phone_number,
                c.created_at
            FROM customer c
            WHERE c.org_id_organization = v_org_id
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
                  )
            ORDER BY c.id_customer DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_customer_obj := json_object_t();
            v_customer_obj.put('id_customer' , rec.id_customer);
            v_customer_obj.put('full_name'   , rec.full_name);
            v_customer_obj.put('phone_number', rec.phone_number);
            v_customer_obj.put('created_at'  , TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

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
        v_phone_number     VARCHAR2(50);
        v_created_at       TIMESTAMP;

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
                c.phone_number,
                c.created_at
              INTO
                v_full_name,
                v_phone_number,
                v_created_at
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
                WHEN a.status IN ('CONFIRMADO', 'COMPLETADO')
                 AND a.start_time < v_now_local
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
                WHEN a.status IN ('CONFIRMADO', 'COMPLETADO')
                 AND a.start_time < v_now_local
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
               AND a.status IN ('CONFIRMADO', 'COMPLETADO')
               AND a.start_time < v_now_local
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

        -- Historial de citas atendidas (últimas N) para la pestaña del perfil.
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
               AND a.status IN ('CONFIRMADO', 'COMPLETADO')
               AND a.start_time < v_now_local
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
               AND a.status IN ('CONFIRMADO', 'COMPLETADO')
               AND a.start_time < v_now_local
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
                    WHEN a.status IN ('CONFIRMADO', 'COMPLETADO')
                     AND a.start_time < v_now_local
                     AND a.start_time >= TRUNC(v_now_local, 'YYYY')
                    THEN NVL(s.price, 0) ELSE 0
                END), 0),
                NVL(SUM(CASE
                    WHEN a.status IN ('CONFIRMADO', 'COMPLETADO')
                     AND a.start_time < v_now_local
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

        v_data_obj.put('id_customer'  , pi_cus_id);
        v_data_obj.put('full_name'    , v_full_name);
        v_data_obj.put('phone_number' , v_phone_number);
        v_data_obj.put('created_at'   , TO_CHAR(v_created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        v_data_obj.put('stats'        , v_stats_obj);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_customer_profile;

END pkg_aox_customer_api;
/

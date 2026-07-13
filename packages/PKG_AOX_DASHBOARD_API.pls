PROMPT CREATE OR REPLACE PACKAGE pkg_aox_dashboard_api
CREATE OR REPLACE PACKAGE pkg_aox_dashboard_api IS

    PROCEDURE pr_get_main_dashboard(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 5,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase 6: métricas de rentabilidad para el panel Premium.
    -- Solo ADMIN y organizaciones con feature PROFITABILITY_ANALYTICS.
    PROCEDURE pr_get_profitability(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_dashboard_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_dashboard_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_dashboard_api IS

    c_upcoming_days     CONSTANT PLS_INTEGER  := 7;
    c_status_canceled   CONSTANT VARCHAR2(20) := 'CANCELADO';

    PROCEDURE pr_get_main_dashboard(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 5,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id          NUMBER;
        v_org_id           NUMBER;
        v_role_id          NUMBER;
        v_prof_id          NUMBER := -1;

        v_now_local        TIMESTAMP;
        v_today_start      TIMESTAMP;
        v_tomorrow_start   TIMESTAMP;
        v_window_end       TIMESTAMP;

        v_response_json    json_object_t := json_object_t();
        v_data_obj         json_object_t := json_object_t();
        v_kpis_obj         json_object_t := json_object_t();
        v_meta_obj         json_object_t := json_object_t();
        v_pagination_obj   json_object_t := json_object_t();
        v_upcoming_arr     json_array_t  := json_array_t();
        v_appt_obj         json_object_t;
        v_api_code         VARCHAR2(30);
        v_error_message    VARCHAR2(4000);

        v_today_count      NUMBER := 0;
        v_today_completed  NUMBER := 0;
        v_pending_count    NUMBER := 0;
        v_my_customers     NUMBER := 0;
        v_total_org        NUMBER := 0;

        v_page             NUMBER := NVL(pi_page, 1);
        v_limit            NUMBER := NVL(pi_limit, 5);
        v_offset           NUMBER;
        v_total_records    NUMBER := 0;
        v_total_pages      NUMBER := 0;
        v_is_org_viewer    BOOLEAN := FALSE;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        v_is_org_viewer := v_role_id IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        );

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        IF v_page < 1 THEN
            v_page := 1;
        END IF;

        IF v_limit < 1 THEN
            v_limit := 5;
        END IF;

        v_offset := (v_page - 1) * v_limit;

        v_now_local      := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);
        v_today_start    := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        v_window_end     := v_now_local + NUMTODSINTERVAL(c_upcoming_days, 'DAY');

        BEGIN
            SELECT
                id_professional
            INTO
                v_prof_id
            FROM professional
            WHERE usr_id_user           = v_user_id
                AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prof_id := -1;
        END;

        SELECT COUNT(*)
        INTO v_today_count
        FROM appointment
        WHERE org_id_organization = v_org_id
          AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
          AND start_time  >= v_today_start
          AND start_time  < v_tomorrow_start
          AND status      <> c_status_canceled;

        SELECT COUNT(*)
        INTO v_today_completed
        FROM appointment
        WHERE org_id_organization = v_org_id
          AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
          AND start_time  >= v_today_start
          AND start_time  < v_tomorrow_start
          AND status      = 'COMPLETADO';

        SELECT
            COUNT(*)
        INTO
            v_pending_count
        FROM appointment
        WHERE org_id_organization                     = v_org_id
            AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
            AND start_time                            >= v_now_local
            AND status IN ('PENDIENTE', 'CONFIRMADO');

        IF v_is_org_viewer THEN
            SELECT COUNT(*)
              INTO v_total_org
              FROM customer
             WHERE org_id_organization = v_org_id;

            IF v_prof_id > 0 THEN
                SELECT COUNT(DISTINCT cus_id_customer)
                  INTO v_my_customers
                  FROM appointment
                 WHERE org_id_organization = v_org_id
                   AND pro_id_professional = v_prof_id;
            ELSE
                v_my_customers := 0;
            END IF;
        ELSE
            SELECT COUNT(DISTINCT cus_id_customer)
              INTO v_my_customers
              FROM appointment
             WHERE org_id_organization = v_org_id
               AND pro_id_professional = v_prof_id;
        END IF;

        v_kpis_obj.put('today_appointments'           , v_today_count);
        v_kpis_obj.put('today_completed_appointments' , v_today_completed);
        v_kpis_obj.put('pending_appointments'         , v_pending_count);
        v_kpis_obj.put('my_customers'                 , v_my_customers);

        IF v_is_org_viewer THEN
            v_kpis_obj.put('total_customers', v_total_org);
        ELSE
            v_kpis_obj.put_null('total_customers');
        END IF;

        SELECT
            COUNT(*)
        INTO
            v_total_records
        FROM appointment a
        WHERE a.org_id_organization = v_org_id
          AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
          AND a.start_time >= v_now_local
          AND a.start_time < v_window_end
          AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO');

        v_total_pages := CEIL(v_total_records / v_limit);

        FOR rec IN (
            SELECT
                a.id_appointment,
                c.full_name AS customer_name,
                TO_CHAR(a.start_time, 'YYYY-MM-DD') AS appointment_date,
                TO_CHAR(a.start_time, 'HH24:MI')    AS time_start,
                TO_CHAR(a.end_time, 'HH24:MI')      AS time_end,
                s.name                              AS service_name,
                a.status
            FROM appointment a
            JOIN customer c
              ON c.id_customer          = a.cus_id_customer
            LEFT JOIN service s
              ON s.id_service           = a.ser_id_service
            WHERE a.org_id_organization = v_org_id
              AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
              AND a.start_time >= v_now_local
              AND a.start_time < v_window_end
              AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
            ORDER BY a.start_time ASC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_appt_obj := json_object_t();
            v_appt_obj.put('id'               , rec.id_appointment);
            v_appt_obj.put('customer_name'    , rec.customer_name);
            v_appt_obj.put('appointment_date' , rec.appointment_date);
            v_appt_obj.put('time_start'       , rec.time_start);
            v_appt_obj.put('time_end'         , rec.time_end);
            v_appt_obj.put('service_name'     , NVL(rec.service_name, 'Servicio'));
            v_appt_obj.put('status'           , rec.status);
            v_upcoming_arr.append(v_appt_obj);
        END LOOP;

        v_meta_obj.put('timezone'             , pkg_aox_util.fn_app_timezone);
        v_meta_obj.put('upcoming_window_days' , c_upcoming_days);
        v_meta_obj.put('generated_at_local'   , TO_CHAR(v_now_local, 'YYYY-MM-DD"T"HH24:MI:SS'));

        v_pagination_obj.put('current_page'  , v_page);
        v_pagination_obj.put('per_page'      , v_limit);
        v_pagination_obj.put('total_records' , v_total_records);
        v_pagination_obj.put('total_pages'   , v_total_pages);

        v_data_obj.put('kpis'                 , v_kpis_obj);
        v_data_obj.put('upcoming_appointments', v_upcoming_arr);
        v_data_obj.put('meta'                 , v_meta_obj);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta'  , v_pagination_obj);
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'DASHBOARD_MAIN',
                pi_process_name    => 'PKG_AOX_DASHBOARD_API.PR_GET_MAIN_DASHBOARD',
                pi_http_method     => 'GET',
                pi_endpoint        => '/dashboard',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'page=' || pi_page || ';limit=' || pi_limit
            );

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_get_main_dashboard;

    -- Fase 6: rentabilidad de la organización (ingresos, ticket promedio, top
    -- servicios y profesionales). Ingreso "realizado" = citas CONFIRMADO/COMPLETADO
    -- ya ocurridas, valorizadas al precio del servicio.
    PROCEDURE pr_get_profitability(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id          NUMBER;
        v_org_id           NUMBER;
        v_role_id          NUMBER;

        v_now_local        TIMESTAMP;
        v_month_start      TIMESTAMP;
        v_next_month_start TIMESTAMP;
        v_prev_month_start TIMESTAMP;
        v_today_start      TIMESTAMP;
        v_tomorrow_start   TIMESTAMP;

        v_today_rev        NUMBER := 0;
        v_month_rev        NUMBER := 0;
        v_month_count      NUMBER := 0;
        v_prev_month_rev   NUMBER := 0;
        v_avg_ticket       NUMBER := 0;
        v_pending_expected NUMBER := 0;
        v_mom_delta        NUMBER;

        v_response_json    json_object_t := json_object_t();
        v_data_obj         json_object_t := json_object_t();
        v_today_obj        json_object_t := json_object_t();
        v_month_obj        json_object_t := json_object_t();
        v_prev_obj         json_object_t := json_object_t();
        v_top_services_arr json_array_t  := json_array_t();
        v_by_prof_arr      json_array_t  := json_array_t();
        v_row_obj          json_object_t;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        -- Solo administradores pueden ver la rentabilidad de la organización.
        IF v_role_id <> pkg_aox_util.fn_rol('ADMIN') THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden,
                'Solo los administradores pueden ver la rentabilidad.');
        END IF;

        -- Gate de plan: requiere feature PROFITABILITY_ANALYTICS (Premium).
        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'PROFITABILITY_ANALYTICS');

        v_now_local        := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);
        v_today_start      := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start   := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        v_month_start      := CAST(TRUNC(v_now_local, 'MM') AS TIMESTAMP);
        v_next_month_start := ADD_MONTHS(v_month_start, 1);
        v_prev_month_start := ADD_MONTHS(v_month_start, -1);

        -- Ingreso de hoy (citas ya ocurridas hoy).
        SELECT NVL(SUM(NVL(s.price, 0)), 0)
          INTO v_today_rev
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_today_start
           AND a.start_time < v_tomorrow_start;

        -- Ingreso y cantidad del mes en curso (citas ya ocurridas).
        SELECT NVL(SUM(NVL(s.price, 0)), 0), COUNT(*)
          INTO v_month_rev, v_month_count
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_month_start
           AND a.start_time < v_now_local;

        -- Ingreso del mes anterior (mes completo).
        SELECT NVL(SUM(NVL(s.price, 0)), 0)
          INTO v_prev_month_rev
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_prev_month_start
           AND a.start_time < v_month_start;

        -- Ingreso esperado por citas futuras confirmadas/pendientes.
        SELECT NVL(SUM(NVL(s.price, 0)), 0)
          INTO v_pending_expected
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND a.status IN ('PENDIENTE', 'CONFIRMADO')
           AND a.start_time >= v_now_local;

        IF v_month_count > 0 THEN
            v_avg_ticket := ROUND(v_month_rev / v_month_count);
        END IF;

        IF v_prev_month_rev > 0 THEN
            v_mom_delta := ROUND(100 * (v_month_rev - v_prev_month_rev) / v_prev_month_rev, 1);
        END IF;

        -- Top servicios por ingreso del mes en curso.
        FOR rec IN (
            SELECT s.id_service, s.name,
                   NVL(SUM(NVL(s.price, 0)), 0) AS revenue,
                   COUNT(*) AS cnt
              FROM appointment a
              JOIN service s ON s.id_service = a.ser_id_service
             WHERE a.org_id_organization = v_org_id
               AND a.status IN ('CONFIRMADO', 'COMPLETADO')
               AND a.start_time >= v_month_start
               AND a.start_time < v_now_local
             GROUP BY s.id_service, s.name
             ORDER BY revenue DESC, cnt DESC
             FETCH FIRST 5 ROWS ONLY
        ) LOOP
            v_row_obj := json_object_t();
            v_row_obj.put('id_service', rec.id_service);
            v_row_obj.put('name'      , rec.name);
            v_row_obj.put('revenue'   , rec.revenue);
            v_row_obj.put('count'     , rec.cnt);
            v_top_services_arr.append(v_row_obj);
        END LOOP;

        -- Ingreso por profesional del mes en curso.
        FOR rec IN (
            SELECT p.id_professional,
                   NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS prof_name,
                   NVL(SUM(NVL(s.price, 0)), 0) AS revenue,
                   COUNT(*) AS cnt
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
              LEFT JOIN service s  ON s.id_service      = a.ser_id_service
             WHERE a.org_id_organization = v_org_id
               AND a.status IN ('CONFIRMADO', 'COMPLETADO')
               AND a.start_time >= v_month_start
               AND a.start_time < v_now_local
             GROUP BY p.id_professional,
                      NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
             ORDER BY revenue DESC, cnt DESC
             FETCH FIRST 8 ROWS ONLY
        ) LOOP
            v_row_obj := json_object_t();
            v_row_obj.put('id_professional', rec.id_professional);
            v_row_obj.put('name'           , rec.prof_name);
            v_row_obj.put('revenue'        , rec.revenue);
            v_row_obj.put('count'          , rec.cnt);
            v_by_prof_arr.append(v_row_obj);
        END LOOP;

        v_today_obj.put('revenue', v_today_rev);

        v_month_obj.put('revenue'        , v_month_rev);
        v_month_obj.put('completed_count', v_month_count);
        v_month_obj.put('avg_ticket'     , v_avg_ticket);

        v_prev_obj.put('revenue', v_prev_month_rev);

        v_data_obj.put('currency'                , 'PYG');
        v_data_obj.put('today'                   , v_today_obj);
        v_data_obj.put('this_month'              , v_month_obj);
        v_data_obj.put('last_month'              , v_prev_obj);
        IF v_mom_delta IS NULL THEN
            v_data_obj.put_null('mom_delta_pct');
        ELSE
            v_data_obj.put('mom_delta_pct', v_mom_delta);
        END IF;
        v_data_obj.put('pending_expected_revenue', v_pending_expected);
        v_data_obj.put('top_services'            , v_top_services_arr);
        v_data_obj.put('by_professional'         , v_by_prof_arr);
        v_data_obj.put('generated_at_local'      , TO_CHAR(v_now_local, 'YYYY-MM-DD"T"HH24:MI:SS'));

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_profitability;

END pkg_aox_dashboard_api;
/


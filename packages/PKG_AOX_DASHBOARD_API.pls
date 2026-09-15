PROMPT CREATE OR REPLACE PACKAGE pkg_aox_dashboard_api
CREATE OR REPLACE PACKAGE pkg_aox_dashboard_api IS

    PROCEDURE pr_get_main_dashboard(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 5,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Fase 6: métricas de rentabilidad del dashboard (Base + Premium).
    -- ADMIN ve la organización completa; PROFESIONAL ve únicamente su propia
    -- producción (filtrado por pro_id_professional). Requiere feature
    -- PROFITABILITY_ANALYTICS en la organización.
    PROCEDURE pr_get_profitability(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- HAS-50 / HAS-57 / HAS-62: analíticas del tenant (volumen 7/15/30/custom,
    -- estados, inasistencias, sucursal/profesional y totales de señas).
    -- Requiere analytics.view. from/to = YYYY-MM-DD, máximo 90 días.
    PROCEDURE pr_get_analytics(
        pi_auth_header     IN  VARCHAR2,
        pi_days            IN  NUMBER DEFAULT 7,
        pi_location_id     IN  NUMBER DEFAULT NULL,
        pi_professional_id IN  NUMBER DEFAULT NULL,
        pi_from_date       IN  VARCHAR2 DEFAULT NULL,
        pi_to_date         IN  VARCHAR2 DEFAULT NULL,
        po_status_code     OUT NUMBER,
        po_response_body   OUT CLOB
    );

END pkg_aox_dashboard_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_dashboard_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_dashboard_api IS

    c_upcoming_days     CONSTANT PLS_INTEGER  := 7;
    c_chart_days        CONSTANT PLS_INTEGER  := 30;
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
        v_by_day_arr       json_array_t  := json_array_t();
        v_upcoming_day_arr json_array_t  := json_array_t();
        v_appt_obj         json_object_t;
        v_day_obj          json_object_t;
        v_api_code         VARCHAR2(30);
        v_error_message    VARCHAR2(4000);

        TYPE t_day_count_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(10);
        v_day_counts       t_day_count_tab;
        v_day_key          VARCHAR2(10);
        v_day_ts           TIMESTAMP;
        v_day_count        NUMBER;
        v_chart_start      TIMESTAMP;
        v_chart_end        TIMESTAMP;

        v_today_count      NUMBER := 0;
        v_today_completed  NUMBER := 0;
        v_today_confirmed  NUMBER := 0;
        v_today_pending    NUMBER := 0;
        v_week_count       NUMBER := 0;
        v_week_confirmed   NUMBER := 0;
        v_week_pending     NUMBER := 0;
        v_deposit_pending_count  NUMBER := 0;
        v_deposit_pending_amount NUMBER := 0;
        v_week_start       TIMESTAMP;
        v_week_end         TIMESTAMP;
        v_pending_count    NUMBER := 0;
        v_unconfirmed_count NUMBER := 0;
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

        -- Card "Por confirmar": solo PENDIENTE (hoy en adelante). No mezclar CONFIRMADO.
        SELECT COUNT(*)
        INTO v_unconfirmed_count
        FROM appointment
        WHERE org_id_organization = v_org_id
          AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
          AND status = 'PENDIENTE'
          AND start_time >= v_today_start;

        -- HAS-56: confirmadas vs pendientes de hoy (completadas cuentan como confirmadas).
        SELECT
            NVL(SUM(CASE WHEN status IN ('CONFIRMADO', 'COMPLETADO') THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN status = 'PENDIENTE' THEN 1 ELSE 0 END), 0)
          INTO
            v_today_confirmed,
            v_today_pending
          FROM appointment
         WHERE org_id_organization = v_org_id
           AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
           AND start_time >= v_today_start
           AND start_time <  v_tomorrow_start
           AND status     <> c_status_canceled;

        -- HAS-56: esta semana calendario (lunes ISO .. domingo).
        v_week_start := CAST(TRUNC(v_today_start, 'IW') AS TIMESTAMP);
        v_week_end   := v_week_start + NUMTODSINTERVAL(7, 'DAY');

        SELECT
            COUNT(*),
            NVL(SUM(CASE WHEN status IN ('CONFIRMADO', 'COMPLETADO') THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN status = 'PENDIENTE' THEN 1 ELSE 0 END), 0)
          INTO
            v_week_count,
            v_week_confirmed,
            v_week_pending
          FROM appointment
         WHERE org_id_organization = v_org_id
           AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
           AND start_time >= v_week_start
           AND start_time <  v_week_end
           AND status     <> c_status_canceled;

        -- HAS-56: señas por cobrar (citas vigentes de hoy en adelante, seña aún PENDING).
        SELECT
            COUNT(*),
            NVL(SUM(NVL(deposit_amount, 0)), 0)
          INTO
            v_deposit_pending_count,
            v_deposit_pending_amount
          FROM appointment
         WHERE org_id_organization = v_org_id
           AND (v_is_org_viewer OR pro_id_professional = v_prof_id)
           AND start_time >= v_today_start
           AND status IN ('PENDIENTE', 'CONFIRMADO')
           AND NVL(deposit_amount, 0) > 0
           AND NVL(payment_status, 'PENDING') = 'PENDING';

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
        v_kpis_obj.put('today_confirmed_appointments' , v_today_confirmed);
        v_kpis_obj.put('today_pending_appointments'   , v_today_pending);
        v_kpis_obj.put('week_appointments'            , v_week_count);
        v_kpis_obj.put('week_confirmed_appointments'  , v_week_confirmed);
        v_kpis_obj.put('week_pending_appointments'    , v_week_pending);
        v_kpis_obj.put('pending_deposits_count'       , v_deposit_pending_count);
        v_kpis_obj.put('pending_deposits_amount'      , v_deposit_pending_amount);
        v_kpis_obj.put('pending_appointments'         , v_pending_count);
        v_kpis_obj.put('unconfirmed_appointments'     , v_unconfirmed_count);
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

        -- Historial de citas (hoy-(N-1) .. hoy) + serie de próximos 7 para el glance.
        -- Una sola agrupación cubre ambos rangos: past 30 + próximos 7.
        v_chart_start := v_today_start - NUMTODSINTERVAL(c_chart_days - 1, 'DAY');
        v_chart_end   := v_today_start + NUMTODSINTERVAL(c_upcoming_days, 'DAY');

        FOR rec IN (
            SELECT
                TO_CHAR(TRUNC(a.start_time), 'YYYY-MM-DD') AS appointment_date,
                COUNT(*) AS cnt
            FROM appointment a
            WHERE a.org_id_organization = v_org_id
              AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
              AND a.start_time >= v_chart_start
              AND a.start_time <  v_chart_end
              AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
            GROUP BY TRUNC(a.start_time)
        ) LOOP
            v_day_counts(rec.appointment_date) := rec.cnt;
        END LOOP;

        FOR v_day_i IN 0 .. (c_chart_days - 1) LOOP
            v_day_ts    := v_chart_start + NUMTODSINTERVAL(v_day_i, 'DAY');
            v_day_key   := TO_CHAR(v_day_ts, 'YYYY-MM-DD');
            v_day_count := 0;
            IF v_day_counts.EXISTS(v_day_key) THEN
                v_day_count := v_day_counts(v_day_key);
            END IF;

            v_day_obj := json_object_t();
            v_day_obj.put('date' , v_day_key);
            v_day_obj.put('count', v_day_count);
            v_by_day_arr.append(v_day_obj);
        END LOOP;

        FOR v_day_i IN 0 .. (c_upcoming_days - 1) LOOP
            v_day_ts    := v_today_start + NUMTODSINTERVAL(v_day_i, 'DAY');
            v_day_key   := TO_CHAR(v_day_ts, 'YYYY-MM-DD');
            v_day_count := 0;
            IF v_day_counts.EXISTS(v_day_key) THEN
                v_day_count := v_day_counts(v_day_key);
            END IF;

            v_day_obj := json_object_t();
            v_day_obj.put('date' , v_day_key);
            v_day_obj.put('count', v_day_count);
            v_upcoming_day_arr.append(v_day_obj);
        END LOOP;

        v_meta_obj.put('timezone'             , pkg_aox_util.fn_app_timezone);
        v_meta_obj.put('upcoming_window_days' , c_upcoming_days);
        v_meta_obj.put('chart_window_days'    , c_chart_days);
        v_meta_obj.put('generated_at_local'   , TO_CHAR(v_now_local, 'YYYY-MM-DD"T"HH24:MI:SS'));

        v_pagination_obj.put('current_page'  , v_page);
        v_pagination_obj.put('per_page'      , v_limit);
        v_pagination_obj.put('total_records' , v_total_records);
        v_pagination_obj.put('total_pages'   , v_total_pages);

        v_data_obj.put('kpis'                 , v_kpis_obj);
        v_data_obj.put('upcoming_appointments', v_upcoming_arr);
        v_data_obj.put('appointments_by_day'  , v_by_day_arr);
        v_data_obj.put('upcoming_by_day'       , v_upcoming_day_arr);
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
        v_prof_id          NUMBER := -1;
        v_is_admin         BOOLEAN := FALSE;
        v_total_clients    NUMBER := 0;
        v_new_clients      NUMBER := 0;
        v_active_clients   NUMBER := 0;
        v_upcoming_clients NUMBER := 0;

        v_now_local        TIMESTAMP;
        v_month_start      TIMESTAMP;
        v_next_month_start TIMESTAMP;
        v_prev_month_start TIMESTAMP;
        v_prev_mtd_end     TIMESTAMP;
        v_today_start      TIMESTAMP;
        v_tomorrow_start   TIMESTAMP;

        v_today_rev        NUMBER := 0;
        v_month_rev        NUMBER := 0;
        v_month_count      NUMBER := 0;
        v_prev_month_rev   NUMBER := 0;
        v_avg_ticket       NUMBER := 0;
        v_pending_expected NUMBER := 0;
        v_pending_count    NUMBER := 0;
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

        v_is_admin := v_role_id = pkg_aox_util.fn_rol('ADMIN');

        -- ADMIN ve la rentabilidad de toda la organización; PROFESIONAL solo la
        -- propia (RBAC: mismo query, filtrado por su pro_id_professional).
        IF NOT v_is_admin THEN
            IF v_role_id <> pkg_aox_util.fn_rol('PROFESIONAL') THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden,
                    'No autorizado a ver la rentabilidad.');
            END IF;

            BEGIN
                SELECT id_professional
                  INTO v_prof_id
                  FROM professional
                 WHERE usr_id_user           = v_user_id
                   AND org_id_organization   = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden,
                        'No se encontró el perfil de profesional del usuario.');
            END;
        END IF;

        -- Gate de plan: requiere feature PROFITABILITY_ANALYTICS (Base + Premium).
        pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'PROFITABILITY_ANALYTICS');

        v_now_local        := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);
        v_today_start      := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start   := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        v_month_start      := CAST(TRUNC(v_now_local, 'MM') AS TIMESTAMP);
        v_next_month_start := ADD_MONTHS(v_month_start, 1);
        v_prev_month_start := ADD_MONTHS(v_month_start, -1);
        -- Mismo tramo transcurrido del mes anterior (MTD vs MTD).
        v_prev_mtd_end     := v_prev_month_start + (v_now_local - v_month_start);

        -- Ingreso de hoy (citas ya ocurridas hoy).
        SELECT NVL(SUM(NVL(s.price, 0)), 0)
          INTO v_today_rev
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_today_start
           AND a.start_time < v_tomorrow_start;

        -- Ingreso y cantidad del mes en curso (citas ya ocurridas).
        SELECT NVL(SUM(NVL(s.price, 0)), 0), COUNT(*)
          INTO v_month_rev, v_month_count
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_month_start
           AND a.start_time < v_now_local;

        -- Ingreso del mismo tramo del mes anterior (hasta el mismo día/hora).
        SELECT NVL(SUM(NVL(s.price, 0)), 0)
          INTO v_prev_month_rev
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_prev_month_start
           AND a.start_time < v_prev_mtd_end;

        -- Ingreso esperado por citas futuras del mes en curso.
        SELECT NVL(SUM(NVL(s.price, 0)), 0), COUNT(*)
          INTO v_pending_expected, v_pending_count
          FROM appointment a
          LEFT JOIN service s ON s.id_service = a.ser_id_service
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('PENDIENTE', 'CONFIRMADO')
           AND a.start_time >= v_now_local
           AND a.start_time < v_next_month_start;

        -- Total de clientes: base de la organización para ADMIN, cartera propia
        -- (pacientes únicos atendidos) para PROFESIONAL.
        IF v_is_admin THEN
            SELECT COUNT(*)
              INTO v_total_clients
              FROM customer
             WHERE org_id_organization = v_org_id;

            SELECT COUNT(*)
              INTO v_new_clients
              FROM customer
             WHERE org_id_organization = v_org_id
               AND CAST(created_at AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP) >= v_month_start
               AND CAST(created_at AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP) < v_next_month_start;
        ELSE
            SELECT COUNT(DISTINCT a.cus_id_customer)
              INTO v_total_clients
              FROM appointment a
             WHERE a.org_id_organization = v_org_id
               AND a.pro_id_professional = v_prof_id;

            SELECT COUNT(DISTINCT a.cus_id_customer)
              INTO v_new_clients
              FROM appointment a
             WHERE a.org_id_organization = v_org_id
               AND a.pro_id_professional = v_prof_id
               AND a.start_time >= v_month_start
               AND a.start_time < v_next_month_start
               AND NOT EXISTS (
                    SELECT 1
                      FROM appointment prev
                     WHERE prev.org_id_organization = a.org_id_organization
                       AND prev.pro_id_professional = a.pro_id_professional
                       AND prev.cus_id_customer     = a.cus_id_customer
                       AND prev.start_time          < v_month_start
               );
        END IF;

        SELECT COUNT(DISTINCT a.cus_id_customer)
          INTO v_active_clients
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('CONFIRMADO', 'COMPLETADO')
           AND a.start_time >= v_month_start
           AND a.start_time < v_now_local;

        SELECT COUNT(DISTINCT a.cus_id_customer)
          INTO v_upcoming_clients
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_admin OR a.pro_id_professional = v_prof_id)
           AND a.status IN ('PENDIENTE', 'CONFIRMADO')
           AND a.start_time >= v_now_local
           AND a.start_time < v_now_local + NUMTODSINTERVAL(7, 'DAY');

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
               AND (v_is_admin OR a.pro_id_professional = v_prof_id)
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
        v_data_obj.put('pending_expected_revenue' , v_pending_expected);
        v_data_obj.put('pending_appointments_month', v_pending_count);
        v_data_obj.put('total_clients'            , v_total_clients);
        v_data_obj.put('new_clients_month'       , v_new_clients);
        v_data_obj.put('active_clients_month'    , v_active_clients);
        v_data_obj.put('upcoming_clients_7d'     , v_upcoming_clients);
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

    -- HAS-50: un solo agregado para Analíticas (no listar próximas citas).
    -- Inasistencia = cita ya vencida que sigue PENDIENTE o CONFIRMADO
    -- (no se completó ni se canceló). Denominador: esas + COMPLETADO.
    PROCEDURE pr_get_analytics(
        pi_auth_header     IN  VARCHAR2,
        pi_days            IN  NUMBER DEFAULT 7,
        pi_location_id     IN  NUMBER DEFAULT NULL,
        pi_professional_id IN  NUMBER DEFAULT NULL,
        pi_from_date       IN  VARCHAR2 DEFAULT NULL,
        pi_to_date         IN  VARCHAR2 DEFAULT NULL,
        po_status_code     OUT NUMBER,
        po_response_body   OUT CLOB
    ) IS
        v_user_id          NUMBER;
        v_org_id           NUMBER;
        v_role_id          NUMBER;
        v_prof_id          NUMBER := -1;
        v_is_org_viewer    BOOLEAN := FALSE;

        v_days             NUMBER;
        v_loc_id           NUMBER;
        v_filter_pro_id    NUMBER;
        v_custom           BOOLEAN := FALSE;
        v_from_d           DATE;
        v_to_d             DATE;
        v_tmp_d            DATE;
        v_period_kind      VARCHAR2(10) := 'preset';

        v_now_local        TIMESTAMP;
        v_today_start      TIMESTAMP;
        v_tomorrow_start   TIMESTAMP;
        v_period_start     TIMESTAMP;
        v_period_end       TIMESTAMP;
        v_period_last      TIMESTAMP;
        v_prev_start       TIMESTAMP;
        v_prev_end         TIMESTAMP;

        v_pendiente        NUMBER := 0;
        v_confirmada       NUMBER := 0;
        v_completada       NUMBER := 0;
        v_cancelada        NUMBER := 0;
        v_volume_total     NUMBER := 0;

        v_ns_count         NUMBER := 0;
        v_ns_eligible      NUMBER := 0;
        v_ns_pct           NUMBER;
        v_prev_ns_count    NUMBER := 0;
        v_prev_ns_eligible NUMBER := 0;
        v_prev_ns_pct      NUMBER;
        v_ns_delta         NUMBER;

        v_paid_total       NUMBER := 0;
        v_pending_total    NUMBER := 0;
        v_paid_count       NUMBER := 0;
        v_pending_count    NUMBER := 0;
        v_deposit_count    NUMBER := 0;

        v_response_json    json_object_t := json_object_t();
        v_data_obj         json_object_t := json_object_t();
        v_status_obj       json_object_t := json_object_t();
        v_no_show_obj      json_object_t := json_object_t();
        v_payments_obj     json_object_t := json_object_t();
        v_filters_obj      json_object_t := json_object_t();
        v_meta_obj         json_object_t := json_object_t();
        v_by_day_arr       json_array_t  := json_array_t();
        v_by_branch_arr    json_array_t  := json_array_t();
        v_by_prof_arr      json_array_t  := json_array_t();
        v_branch_opts      json_array_t  := json_array_t();
        v_prof_opts        json_array_t  := json_array_t();
        v_row_obj          json_object_t;
        v_day_obj          json_object_t;

        TYPE t_day_count_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(10);
        v_day_counts       t_day_count_tab;
        v_day_key          VARCHAR2(10);
        v_day_ts           TIMESTAMP;
        v_day_count        NUMBER;
        v_api_code         VARCHAR2(30);
        v_error_message    VARCHAR2(4000);
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;

        pkg_aox_permission_api.pr_assert_capability(
            v_org_id,
            v_role_id,
            'analytics.view',
            'No tienes permisos para ver analíticas.'
        );

        v_is_org_viewer := v_role_id IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        );

        BEGIN
            SELECT id_professional
              INTO v_prof_id
              FROM professional
             WHERE usr_id_user           = v_user_id
               AND org_id_organization   = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_prof_id := -1;
        END;

        IF NVL(pi_days, 7) = 15 THEN
            v_days := 15;
        ELSIF NVL(pi_days, 7) = 30 THEN
            v_days := 30;
        ELSE
            v_days := 7;
        END IF;

        BEGIN
            IF TRIM(pi_from_date) IS NOT NULL AND TRIM(pi_to_date) IS NOT NULL THEN
                v_from_d := TRUNC(TO_DATE(TRIM(pi_from_date), 'YYYY-MM-DD'));
                v_to_d   := TRUNC(TO_DATE(TRIM(pi_to_date), 'YYYY-MM-DD'));
                IF v_from_d > v_to_d THEN
                    v_tmp_d := v_from_d;
                    v_from_d := v_to_d;
                    v_to_d := v_tmp_d;
                END IF;
                IF (v_to_d - v_from_d + 1) BETWEEN 1 AND 90 THEN
                    v_custom := TRUE;
                    v_days := v_to_d - v_from_d + 1;
                    v_period_kind := 'custom';
                END IF;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                v_custom := FALSE;
                v_period_kind := 'preset';
        END;

        v_loc_id := CASE WHEN NVL(pi_location_id, 0) > 0 THEN pi_location_id ELSE NULL END;

        IF v_is_org_viewer THEN
            v_filter_pro_id := CASE
                WHEN NVL(pi_professional_id, 0) > 0 THEN pi_professional_id
                ELSE NULL
            END;
        ELSE
            IF v_prof_id <= 0 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
            END IF;
            v_filter_pro_id := v_prof_id;
        END IF;

        IF v_loc_id IS NOT NULL THEN
            DECLARE
                v_loc_ok NUMBER;
            BEGIN
                SELECT COUNT(*)
                  INTO v_loc_ok
                  FROM location
                 WHERE id_location         = v_loc_id
                   AND org_id_organization = v_org_id;
                IF v_loc_ok = 0 THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Sucursal inválida.');
                END IF;
            END;
        END IF;

        IF v_is_org_viewer AND v_filter_pro_id IS NOT NULL THEN
            DECLARE
                v_pro_ok NUMBER;
            BEGIN
                SELECT COUNT(*)
                  INTO v_pro_ok
                  FROM professional
                 WHERE id_professional     = v_filter_pro_id
                   AND org_id_organization = v_org_id;
                IF v_pro_ok = 0 THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Profesional inválido.');
                END IF;
            END;
        END IF;

        v_now_local      := CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP);
        v_today_start    := CAST(TRUNC(v_now_local) AS TIMESTAMP);
        v_tomorrow_start := v_today_start + NUMTODSINTERVAL(1, 'DAY');
        IF v_custom THEN
            v_period_start := CAST(v_from_d AS TIMESTAMP);
            v_period_last  := CAST(v_to_d AS TIMESTAMP);
            v_period_end   := v_period_last + NUMTODSINTERVAL(1, 'DAY');
        ELSE
            v_period_start := v_today_start - NUMTODSINTERVAL(v_days - 1, 'DAY');
            v_period_last  := v_today_start;
            v_period_end   := v_tomorrow_start;
        END IF;
        v_prev_start     := v_period_start - NUMTODSINTERVAL(v_days, 'DAY');
        v_prev_end       := v_period_start;

        SELECT
            NVL(SUM(CASE WHEN a.status = 'PENDIENTE'  THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CONFIRMADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'COMPLETADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CANCELADO'  THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO') THEN 1 ELSE 0 END), 0)
          INTO
            v_pendiente,
            v_confirmada,
            v_completada,
            v_cancelada,
            v_volume_total
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
           AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
           AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
           AND a.start_time >= v_period_start
           AND a.start_time <  v_period_end;

        SELECT
            NVL(SUM(CASE
                WHEN a.status IN ('PENDIENTE', 'CONFIRMADO') THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO') THEN 1 ELSE 0
            END), 0)
          INTO
            v_ns_count,
            v_ns_eligible
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
           AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
           AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
           AND a.start_time >= v_period_start
           AND a.start_time <  LEAST(v_now_local, v_period_end)
           AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO');

        SELECT
            NVL(SUM(CASE
                WHEN a.status IN ('PENDIENTE', 'CONFIRMADO') THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO') THEN 1 ELSE 0
            END), 0)
          INTO
            v_prev_ns_count,
            v_prev_ns_eligible
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
           AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
           AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
           AND a.start_time >= v_prev_start
           AND a.start_time <  v_prev_end
           AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO');

        IF v_ns_eligible > 0 THEN
            v_ns_pct := ROUND(100 * v_ns_count / v_ns_eligible, 1);
        END IF;
        IF v_prev_ns_eligible > 0 THEN
            v_prev_ns_pct := ROUND(100 * v_prev_ns_count / v_prev_ns_eligible, 1);
        END IF;
        IF v_ns_pct IS NOT NULL AND v_prev_ns_pct IS NOT NULL THEN
            v_ns_delta := ROUND(v_ns_pct - v_prev_ns_pct, 1);
        END IF;

        SELECT
            NVL(SUM(CASE
                WHEN a.payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH')
                THEN NVL(a.deposit_amount, 0) ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.payment_status = 'PENDING'
                THEN NVL(a.deposit_amount, 0) ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH')
                 AND NVL(a.deposit_amount, 0) > 0
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.payment_status = 'PENDING'
                 AND NVL(a.deposit_amount, 0) > 0
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN NVL(a.deposit_amount, 0) > 0
                 AND a.payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH', 'PENDING')
                THEN 1 ELSE 0
            END), 0)
          INTO
            v_paid_total,
            v_pending_total,
            v_paid_count,
            v_pending_count,
            v_deposit_count
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
           AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
           AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
           AND a.start_time >= v_period_start
           AND a.start_time <  v_period_end;

        FOR rec IN (
            SELECT
                TO_CHAR(TRUNC(a.start_time), 'YYYY-MM-DD') AS appointment_date,
                COUNT(*) AS cnt
              FROM appointment a
             WHERE a.org_id_organization = v_org_id
               AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
               AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
               AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
               AND a.start_time >= v_period_start
               AND a.start_time <  v_period_end
               AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
             GROUP BY TRUNC(a.start_time)
        ) LOOP
            v_day_counts(rec.appointment_date) := rec.cnt;
        END LOOP;

        FOR v_day_i IN 0 .. (v_days - 1) LOOP
            v_day_ts    := v_period_start + NUMTODSINTERVAL(v_day_i, 'DAY');
            v_day_key   := TO_CHAR(v_day_ts, 'YYYY-MM-DD');
            v_day_count := 0;
            IF v_day_counts.EXISTS(v_day_key) THEN
                v_day_count := v_day_counts(v_day_key);
            END IF;
            v_day_obj := json_object_t();
            v_day_obj.put('date' , v_day_key);
            v_day_obj.put('count', v_day_count);
            v_by_day_arr.append(v_day_obj);
        END LOOP;

        FOR rec IN (
            SELECT
                l.id_location,
                l.name,
                COUNT(*) AS cnt
              FROM appointment a
              JOIN location l ON l.id_location = a.loc_id_location
             WHERE a.org_id_organization = v_org_id
               AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
               AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
               AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
               AND a.start_time >= v_period_start
               AND a.start_time <  v_period_end
               AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO', 'CANCELADO')
             GROUP BY l.id_location, l.name
             ORDER BY cnt DESC, l.name
        ) LOOP
            v_row_obj := json_object_t();
            v_row_obj.put('id'   , rec.id_location);
            v_row_obj.put('name' , rec.name);
            v_row_obj.put('count', rec.cnt);
            v_by_branch_arr.append(v_row_obj);
        END LOOP;

        FOR rec IN (
            SELECT
                p.id_professional,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS prof_name,
                COUNT(*) AS cnt
              FROM appointment a
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user         = p.usr_id_user
             WHERE a.org_id_organization = v_org_id
               AND (v_is_org_viewer OR a.pro_id_professional = v_prof_id)
               AND (v_loc_id IS NULL OR a.loc_id_location = v_loc_id)
               AND (v_filter_pro_id IS NULL OR a.pro_id_professional = v_filter_pro_id)
               AND a.start_time >= v_period_start
               AND a.start_time <  v_period_end
               AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO', 'CANCELADO')
             GROUP BY p.id_professional,
                      NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name))
             ORDER BY cnt DESC, prof_name
        ) LOOP
            v_row_obj := json_object_t();
            v_row_obj.put('id'   , rec.id_professional);
            v_row_obj.put('name' , rec.prof_name);
            v_row_obj.put('count', rec.cnt);
            v_by_prof_arr.append(v_row_obj);
        END LOOP;

        FOR rec IN (
            SELECT l.id_location, l.name
              FROM location l
             WHERE l.org_id_organization = v_org_id
             ORDER BY l.is_active DESC, l.name
        ) LOOP
            v_row_obj := json_object_t();
            v_row_obj.put('id'  , rec.id_location);
            v_row_obj.put('name', rec.name);
            v_branch_opts.append(v_row_obj);
        END LOOP;

        IF v_is_org_viewer THEN
            FOR rec IN (
                SELECT
                    p.id_professional,
                    NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS prof_name
                  FROM professional p
                  JOIN app_user u ON u.id_user = p.usr_id_user
                 WHERE p.org_id_organization = v_org_id
                 ORDER BY prof_name
            ) LOOP
                v_row_obj := json_object_t();
                v_row_obj.put('id'  , rec.id_professional);
                v_row_obj.put('name', rec.prof_name);
                v_prof_opts.append(v_row_obj);
            END LOOP;
        END IF;

        v_status_obj.put('pendiente' , v_pendiente);
        v_status_obj.put('confirmada', v_confirmada);
        v_status_obj.put('completada', v_completada);
        v_status_obj.put('cancelada' , v_cancelada);

        v_no_show_obj.put('count'          , v_ns_count);
        v_no_show_obj.put('eligible_count' , v_ns_eligible);
        IF v_ns_pct IS NULL THEN
            v_no_show_obj.put_null('pct');
        ELSE
            v_no_show_obj.put('pct', v_ns_pct);
        END IF;
        IF v_prev_ns_pct IS NULL THEN
            v_no_show_obj.put_null('prev_pct');
        ELSE
            v_no_show_obj.put('prev_pct', v_prev_ns_pct);
        END IF;
        IF v_ns_delta IS NULL THEN
            v_no_show_obj.put_null('delta_pct');
        ELSE
            v_no_show_obj.put('delta_pct', v_ns_delta);
        END IF;

        v_payments_obj.put('currency'       , 'PYG');
        v_payments_obj.put('paid_total'     , v_paid_total);
        v_payments_obj.put('pending_total'  , v_pending_total);
        v_payments_obj.put('paid_count'     , v_paid_count);
        v_payments_obj.put('pending_count'  , v_pending_count);
        v_payments_obj.put('deposit_count'  , v_deposit_count);

        v_filters_obj.put('period_days', v_days);
        v_filters_obj.put('period_kind', v_period_kind);
        v_filters_obj.put('from_date', TO_CHAR(v_period_start, 'YYYY-MM-DD'));
        v_filters_obj.put('to_date', TO_CHAR(v_period_last, 'YYYY-MM-DD'));
        IF v_loc_id IS NULL THEN
            v_filters_obj.put_null('location_id');
        ELSE
            v_filters_obj.put('location_id', v_loc_id);
        END IF;
        IF v_filter_pro_id IS NULL THEN
            v_filters_obj.put_null('professional_id');
        ELSE
            v_filters_obj.put('professional_id', v_filter_pro_id);
        END IF;
        v_filters_obj.put('can_filter_professional', CASE WHEN v_is_org_viewer THEN 1 ELSE 0 END);
        v_filters_obj.put('branches'     , v_branch_opts);
        v_filters_obj.put('professionals', v_prof_opts);

        v_meta_obj.put('timezone'           , pkg_aox_util.fn_app_timezone);
        v_meta_obj.put('period_start'       , TO_CHAR(v_period_start, 'YYYY-MM-DD'));
        v_meta_obj.put('period_end'         , TO_CHAR(v_period_last, 'YYYY-MM-DD'));
        v_meta_obj.put('period_kind'        , v_period_kind);
        v_meta_obj.put('generated_at_local' , TO_CHAR(v_now_local, 'YYYY-MM-DD"T"HH24:MI:SS'));

        v_data_obj.put('period_days'         , v_days);
        v_data_obj.put('period_kind'        , v_period_kind);
        v_data_obj.put('total_appointments'  , v_volume_total);
        v_data_obj.put('appointments_by_day' , v_by_day_arr);
        v_data_obj.put('by_status'           , v_status_obj);
        v_data_obj.put('no_show'             , v_no_show_obj);
        v_data_obj.put('by_branch'           , v_by_branch_arr);
        v_data_obj.put('by_professional'     , v_by_prof_arr);
        v_data_obj.put('payments'            , v_payments_obj);
        v_data_obj.put('filters'             , v_filters_obj);
        v_data_obj.put('meta'                , v_meta_obj);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_resolve_api_error(SQLCODE, SQLERRM, po_status_code, v_api_code, v_error_message);
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'DASHBOARD_ANALYTICS',
                pi_process_name    => 'PKG_AOX_DASHBOARD_API.PR_GET_ANALYTICS',
                pi_http_method     => 'GET',
                pi_endpoint        => '/dashboard/analytics',
                pi_org_id          => v_org_id,
                pi_user_id         => v_user_id,
                pi_status          => 'ERROR',
                pi_status_code     => po_status_code,
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_params  => 'days=' || pi_days
                    || ';from_date=' || pi_from_date
                    || ';to_date=' || pi_to_date
                    || ';location_id=' || pi_location_id
                    || ';professional_id=' || pi_professional_id
            );

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => v_error_message,
                po_response_body => po_response_body
            );
    END pr_get_analytics;

END pkg_aox_dashboard_api;
/


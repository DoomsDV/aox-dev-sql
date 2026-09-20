PROMPT CREATE OR REPLACE PACKAGE pkg_aox_assistant_api
CREATE OR REPLACE PACKAGE pkg_aox_assistant_api IS

    /**
     * Lecturas acotadas para el asistente operativo. No recibe IDs de tenant,
     * usuario o profesional: el scope se deriva del JWT y de RLS.
     */
    PROCEDURE pr_review_summary(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_list_reviews(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        pi_limit         IN  NUMBER DEFAULT 10,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_list_schedules(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_get_insights(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    /**
     * Agenda operativa para el asistente: rango inclusivo, filtros y
     * agregados (hora, weekday, estado). Sin teléfonos ni notas clínicas.
     */
    PROCEDURE pr_list_appointments(
        pi_auth_header   IN  VARCHAR2,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        pi_status        IN  VARCHAR2 DEFAULT 'active',
        pi_prof_id       IN  NUMBER DEFAULT NULL,
        pi_loc_id        IN  NUMBER DEFAULT NULL,
        pi_service_id    IN  NUMBER DEFAULT NULL,
        pi_weekday       IN  NUMBER DEFAULT NULL,
        pi_hour          IN  NUMBER DEFAULT NULL,
        pi_limit         IN  NUMBER DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_assistant_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_assistant_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_assistant_api IS

    c_max_days         CONSTANT PLS_INTEGER := 90;
    c_max_limit        CONSTANT PLS_INTEGER := 20;
    c_max_schedules    CONSTANT PLS_INTEGER := 50;
    c_max_top_pros     CONSTANT PLS_INTEGER := 5;
    c_max_agenda_days  CONSTANT PLS_INTEGER := 366;
    c_max_agenda_limit CONSTANT PLS_INTEGER := 80;

    PROCEDURE pr_bind_assistant(
        pi_auth_header IN  VARCHAR2,
        pi_capability  IN  VARCHAR2,
        pi_denied_msg  IN  VARCHAR2,
        po_org_id      OUT NUMBER,
        po_user_id     OUT NUMBER,
        po_role_id     OUT NUMBER,
        po_prof_id     OUT NUMBER,
        po_org_viewer  OUT NUMBER
    ) IS
    BEGIN
        pkg_aox_session.pr_bind_tenant_from_jwt(
            pi_auth_header => pi_auth_header,
            po_org_id      => po_org_id,
            po_user_id     => po_user_id,
            po_role_id     => po_role_id
        );

        IF NVL(po_org_id, 0) <= 0 OR NVL(po_role_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inválido o sin organización asociada.');
        END IF;

        pkg_aox_permission_api.pr_assert_capability(
            po_org_id,
            po_role_id,
            'assistant.use',
            'El asistente no está habilitado para esta organización o usuario.'
        );
        pkg_aox_permission_api.pr_assert_capability(
            po_org_id,
            po_role_id,
            pi_capability,
            pi_denied_msg
        );

        po_org_viewer := CASE
            WHEN po_role_id IN (pkg_aox_util.fn_rol('ADMIN'), pkg_aox_util.fn_rol('RECEPCIONISTA')) THEN 1
            ELSE 0
        END;
        po_prof_id := NULL;

        IF po_org_viewer = 0 THEN
            BEGIN
                SELECT p.id_professional
                  INTO po_prof_id
                  FROM professional p
                 WHERE p.usr_id_user = po_user_id
                   AND p.org_id_organization = po_org_id
                   AND p.is_active = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    po_prof_id := -1;
            END;
        END IF;
    END pr_bind_assistant;

    PROCEDURE pr_validate_days(pi_days IN NUMBER, po_days OUT PLS_INTEGER) IS
    BEGIN
        po_days := NVL(TRUNC(pi_days), 30);
        IF po_days < 1 OR po_days > c_max_days THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'days debe estar entre 1 y 90.');
        END IF;
    END pr_validate_days;

    PROCEDURE pr_validate_limit(pi_limit IN NUMBER, po_limit OUT PLS_INTEGER) IS
    BEGIN
        po_limit := NVL(TRUNC(pi_limit), 10);
        IF po_limit < 1 OR po_limit > c_max_limit THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'limit debe estar entre 1 y 20.');
        END IF;
    END pr_validate_limit;

    PROCEDURE pr_review_summary(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_days         PLS_INTEGER;
        v_from         TIMESTAMP WITH TIME ZONE;
        v_total        NUMBER := 0;
        v_average      NUMBER;
        v_response     json_object_t := json_object_t();
        v_data         json_object_t := json_object_t();
        v_score_obj    json_object_t;
        v_by_score     json_array_t := json_array_t();
        v_score_count  NUMBER;
    BEGIN
        pr_bind_assistant(
            pi_auth_header => pi_auth_header,
            pi_capability  => 'analytics.view',
            pi_denied_msg  => 'No tienes permisos para ver analíticas y reseñas.',
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );
        pr_validate_days(pi_days, v_days);
        v_from := SYSTIMESTAMP - NUMTODSINTERVAL(v_days, 'DAY');

        SELECT COUNT(*), ROUND(AVG(a.survey_score), 1)
          INTO v_total, v_average
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND a.survey_status = 'COMPLETED'
           AND a.survey_score BETWEEN 1 AND 5
           AND a.survey_replied_at >= v_from
           AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id);

        FOR i IN 1 .. 5 LOOP
            SELECT COUNT(*)
              INTO v_score_count
              FROM appointment a
             WHERE a.org_id_organization = v_org_id
               AND a.survey_status = 'COMPLETED'
               AND a.survey_score = i
               AND a.survey_replied_at >= v_from
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id);
            v_score_obj := json_object_t();
            v_score_obj.put('score', i);
            v_score_obj.put('count', v_score_count);
            v_by_score.append(v_score_obj);
        END LOOP;

        v_data.put('days', v_days);
        v_data.put('review_count', v_total);
        v_data.put('average_score', NVL(v_average, 0));
        v_data.put('by_score', v_by_score);
        v_data.put('scope', CASE WHEN v_org_viewer = 1 THEN 'organization' ELSE 'professional' END);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_review_summary;

    PROCEDURE pr_list_reviews(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        pi_limit         IN  NUMBER DEFAULT 10,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_days         PLS_INTEGER;
        v_limit        PLS_INTEGER;
        v_from         TIMESTAMP WITH TIME ZONE;
        v_response     json_object_t := json_object_t();
        v_data         json_array_t := json_array_t();
        v_item         json_object_t;
    BEGIN
        pr_bind_assistant(
            pi_auth_header => pi_auth_header,
            pi_capability  => 'analytics.view',
            pi_denied_msg  => 'No tienes permisos para ver analíticas y reseñas.',
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );
        pr_validate_days(pi_days, v_days);
        pr_validate_limit(pi_limit, v_limit);
        v_from := SYSTIMESTAMP - NUMTODSINTERVAL(v_days, 'DAY');

        FOR rec IN (
            SELECT a.id_appointment,
                   a.survey_score,
                   a.survey_comment,
                   a.survey_replied_at,
                   s.name AS service_name,
                   p.display_name AS professional_name
              FROM appointment a
              JOIN service s
                ON s.id_service = a.ser_id_service
              JOIN professional p
                ON p.id_professional = a.pro_id_professional
             WHERE a.org_id_organization = v_org_id
               AND a.survey_status = 'COMPLETED'
               AND a.survey_score BETWEEN 1 AND 5
               AND a.survey_replied_at >= v_from
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id)
             ORDER BY a.survey_replied_at DESC
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            v_item := json_object_t();
            v_item.put('appointment_id', rec.id_appointment);
            v_item.put('score', rec.survey_score);
            v_item.put('submitted_at', TO_CHAR(rec.survey_replied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_item.put('service_name', rec.service_name);
            v_item.put('professional_name', rec.professional_name);
            IF rec.survey_comment IS NULL THEN
                v_item.put_null('comment');
            ELSE
                v_item.put('comment', SUBSTR(rec.survey_comment, 1, 400));
            END IF;
            v_data.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_reviews;

    PROCEDURE pr_list_schedules(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_response     json_object_t := json_object_t();
        v_people       json_array_t := json_array_t();
        v_person       json_object_t;
        v_slots        json_array_t;
        v_slot         json_object_t;
    BEGIN
        pr_bind_assistant(
            pi_auth_header => pi_auth_header,
            pi_capability  => 'schedules.view',
            pi_denied_msg  => 'No tienes permisos para ver horarios.',
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );

        FOR prof IN (
            SELECT p.id_professional, p.display_name
              FROM professional p
             WHERE p.org_id_organization = v_org_id
               AND p.is_active = 1
               AND (v_org_viewer = 1 OR p.id_professional = v_prof_id)
             ORDER BY p.display_name
             FETCH FIRST c_max_schedules ROWS ONLY
        ) LOOP
            v_person := json_object_t();
            v_slots := json_array_t();
            v_person.put('professional_id', prof.id_professional);
            v_person.put('professional_name', NVL(prof.display_name, 'Profesional'));

            FOR rec IN (
                SELECT ps.loc_id_location,
                       l.name AS location_name,
                       ps.day_of_week,
                       ps.start_time,
                       ps.end_time
                  FROM professional_schedule ps
                  JOIN location l
                    ON l.id_location = ps.loc_id_location
                 WHERE ps.pro_id_professional = prof.id_professional
                   AND ps.org_id_organization = v_org_id
                 ORDER BY ps.day_of_week, ps.start_time
            ) LOOP
                v_slot := json_object_t();
                v_slot.put('loc_id_location', rec.loc_id_location);
                v_slot.put('location_name', rec.location_name);
                v_slot.put('day_of_week', rec.day_of_week);
                v_slot.put('start_time', rec.start_time);
                v_slot.put('end_time', rec.end_time);
                v_slots.append(v_slot);
            END LOOP;

            v_person.put('schedule', v_slots);
            v_people.append(v_person);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('professionals', v_people);
        v_response.put('scope', CASE WHEN v_org_viewer = 1 THEN 'organization' ELSE 'professional' END);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_schedules;

    PROCEDURE pr_get_insights(
        pi_auth_header   IN  VARCHAR2,
        pi_days          IN  NUMBER DEFAULT 30,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_days         PLS_INTEGER;
        v_from         TIMESTAMP WITH TIME ZONE;
        v_to           TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
        v_pendiente    NUMBER := 0;
        v_confirmada   NUMBER := 0;
        v_completada   NUMBER := 0;
        v_cancelada    NUMBER := 0;
        v_total        NUMBER := 0;
        v_pending_conf NUMBER := 0;
        v_revenue      NUMBER := 0;
        v_response     json_object_t := json_object_t();
        v_data         json_object_t := json_object_t();
        v_period       json_object_t := json_object_t();
        v_kpis         json_object_t := json_object_t();
        v_top          json_array_t := json_array_t();
        v_alerts       json_array_t := json_array_t();
        v_row          json_object_t;
        v_alert        json_object_t;
    BEGIN
        pr_bind_assistant(
            pi_auth_header => pi_auth_header,
            pi_capability  => 'analytics.view',
            pi_denied_msg  => 'No tienes permisos para ver analíticas.',
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );
        pr_validate_days(pi_days, v_days);
        v_from := v_to - NUMTODSINTERVAL(v_days, 'DAY');

        SELECT
            NVL(SUM(CASE WHEN a.status = 'PENDIENTE'  THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CONFIRMADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'COMPLETADO' THEN 1 ELSE 0 END), 0),
            NVL(SUM(CASE WHEN a.status = 'CANCELADO'  THEN 1 ELSE 0 END), 0),
            COUNT(*),
            NVL(SUM(CASE
                WHEN a.status IN ('PENDIENTE', 'CONFIRMADO')
                 AND NVL(a.attendance_status, 'NOT_REQUESTED') IN ('NOT_REQUESTED', 'SENT', 'EXPIRED')
                THEN 1 ELSE 0
            END), 0),
            NVL(SUM(CASE
                WHEN a.payment_status IN ('PAID', 'PAID_TRANSFER', 'PAID_CASH')
                THEN NVL(a.deposit_amount, 0) ELSE 0
            END), 0)
          INTO
            v_pendiente,
            v_confirmada,
            v_completada,
            v_cancelada,
            v_total,
            v_pending_conf,
            v_revenue
          FROM appointment a
         WHERE a.org_id_organization = v_org_id
           AND a.start_time >= v_from
           AND a.start_time <  v_to
           AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id);

        FOR rec IN (
            SELECT p.id_professional,
                   NVL(p.display_name, 'Profesional') AS professional_name,
                   COUNT(*) AS reservation_count
              FROM appointment a
              JOIN professional p
                ON p.id_professional = a.pro_id_professional
             WHERE a.org_id_organization = v_org_id
               AND a.start_time >= v_from
               AND a.start_time <  v_to
               AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO')
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id)
             GROUP BY p.id_professional, NVL(p.display_name, 'Profesional')
             ORDER BY COUNT(*) DESC, professional_name
             FETCH FIRST c_max_top_pros ROWS ONLY
        ) LOOP
            v_row := json_object_t();
            v_row.put('id', rec.id_professional);
            v_row.put('name', rec.professional_name);
            v_row.put('count', rec.reservation_count);
            v_top.append(v_row);
        END LOOP;

        IF v_pending_conf > 0 THEN
            v_alert := json_object_t();
            v_alert.put('type', 'pending_confirmation');
            v_alert.put('count', v_pending_conf);
            v_alerts.append(v_alert);
        END IF;

        v_period.put('days', v_days);
        v_period.put('from', TO_CHAR(v_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        v_period.put('to', TO_CHAR(v_to AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

        v_kpis.put('total', v_total);
        v_kpis.put('pending', v_pendiente);
        v_kpis.put('confirmed', v_confirmada);
        v_kpis.put('completed', v_completada);
        v_kpis.put('cancelled', v_cancelada);
        v_kpis.put('pending_confirmation', v_pending_conf);
        v_kpis.put('revenue', v_revenue);

        v_data.put('period', v_period);
        v_data.put('kpis', v_kpis);
        v_data.put('top_professionals', v_top);
        v_data.put('alerts', v_alerts);
        v_data.put('scope', CASE WHEN v_org_viewer = 1 THEN 'organization' ELSE 'professional' END);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_insights;

    PROCEDURE pr_list_appointments(
        pi_auth_header   IN  VARCHAR2,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        pi_status        IN  VARCHAR2 DEFAULT 'active',
        pi_prof_id       IN  NUMBER DEFAULT NULL,
        pi_loc_id        IN  NUMBER DEFAULT NULL,
        pi_service_id    IN  NUMBER DEFAULT NULL,
        pi_weekday       IN  NUMBER DEFAULT NULL,
        pi_hour          IN  NUMBER DEFAULT NULL,
        pi_limit         IN  NUMBER DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id       NUMBER;
        v_user_id      NUMBER;
        v_role_id      NUMBER;
        v_prof_id      NUMBER;
        v_org_viewer   NUMBER;
        v_from_d       DATE;
        v_to_d         DATE;
        v_from_ts      TIMESTAMP;
        v_to_excl      TIMESTAMP;
        v_status       VARCHAR2(20);
        v_filter_pro   NUMBER;
        v_filter_loc   NUMBER;
        v_filter_ser   NUMBER;
        v_filter_dow   PLS_INTEGER;
        v_filter_hour  PLS_INTEGER;
        v_limit        PLS_INTEGER;
        v_days         PLS_INTEGER;
        v_matched      PLS_INTEGER := 0;
        v_listed       PLS_INTEGER := 0;
        v_iso          PLS_INTEGER;
        v_hour         PLS_INTEGER;
        v_peak_hour    PLS_INTEGER;
        v_peak_hour_n  PLS_INTEGER := 0;
        v_peak_dow     PLS_INTEGER;
        v_peak_dow_n   PLS_INTEGER := 0;
        v_key          PLS_INTEGER;
        v_response     json_object_t := json_object_t();
        v_meta         json_object_t := json_object_t();
        v_filters      json_object_t := json_object_t();
        v_summary      json_object_t := json_object_t();
        v_data         json_array_t := json_array_t();
        v_item         json_object_t;
        v_row          json_object_t;
        v_by_hour      json_array_t := json_array_t();
        v_by_dow       json_array_t := json_array_t();
        v_by_status    json_object_t := json_object_t();
        v_by_pro       json_array_t := json_array_t();
        v_by_ser       json_array_t := json_array_t();
        v_peak_h_obj   json_object_t;
        v_peak_d_obj   json_object_t;

        TYPE t_num_tab IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
        TYPE t_str_tab IS TABLE OF VARCHAR2(400) INDEX BY PLS_INTEGER;
        v_hour_n       t_num_tab;
        v_dow_n        t_num_tab;
        v_st_n         t_num_tab;
        v_pro_n        t_num_tab;
        v_pro_name     t_str_tab;
        v_ser_n        t_num_tab;
        v_ser_name     t_str_tab;

        FUNCTION iso_weekday(pi_ts TIMESTAMP) RETURN PLS_INTEGER IS
        BEGIN
            RETURN TRUNC(CAST(pi_ts AS DATE)) - TRUNC(CAST(pi_ts AS DATE), 'IW') + 1;
        END iso_weekday;

        FUNCTION weekday_name(pi_iso PLS_INTEGER) RETURN VARCHAR2 IS
        BEGIN
            RETURN CASE pi_iso
                WHEN 1 THEN 'lunes'
                WHEN 2 THEN 'martes'
                WHEN 3 THEN 'miércoles'
                WHEN 4 THEN 'jueves'
                WHEN 5 THEN 'viernes'
                WHEN 6 THEN 'sábado'
                WHEN 7 THEN 'domingo'
                ELSE NULL
            END;
        END weekday_name;

        PROCEDURE bump(pi_tab IN OUT NOCOPY t_num_tab, pi_key PLS_INTEGER) IS
        BEGIN
            IF pi_tab.EXISTS(pi_key) THEN
                pi_tab(pi_key) := pi_tab(pi_key) + 1;
            ELSE
                pi_tab(pi_key) := 1;
            END IF;
        END bump;
    BEGIN
        pr_bind_assistant(
            pi_auth_header => pi_auth_header,
            pi_capability  => 'calendar.view',
            pi_denied_msg  => 'No tienes permisos para ver la agenda.',
            po_org_id      => v_org_id,
            po_user_id     => v_user_id,
            po_role_id     => v_role_id,
            po_prof_id     => v_prof_id,
            po_org_viewer  => v_org_viewer
        );

        IF TRIM(pi_from_date) IS NULL AND TRIM(pi_to_date) IS NULL THEN
            v_to_d := TRUNC(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone());
            v_from_d := v_to_d - 29;
        ELSIF TRIM(pi_from_date) IS NULL OR TRIM(pi_to_date) IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'from y to son obligatorios juntos (YYYY-MM-DD).');
        ELSE
            BEGIN
                v_from_d := TO_DATE(TRIM(pi_from_date), 'YYYY-MM-DD');
                v_to_d := TO_DATE(TRIM(pi_to_date), 'YYYY-MM-DD');
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'from y to deben ser YYYY-MM-DD.');
            END;
        END IF;

        IF v_to_d < v_from_d THEN
            DECLARE
                v_swap DATE := v_from_d;
            BEGIN
                v_from_d := v_to_d;
                v_to_d := v_swap;
            END;
        END IF;

        v_days := v_to_d - v_from_d + 1;
        IF v_days < 1 OR v_days > c_max_agenda_days THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El rango de agenda debe estar entre 1 y 366 días.');
        END IF;

        v_from_ts := CAST(v_from_d AS TIMESTAMP);
        v_to_excl := CAST(v_to_d + 1 AS TIMESTAMP);

        v_status := UPPER(TRIM(NVL(pi_status, 'active')));
        IF v_status IN ('ACTIVE', 'ACTIVAS') THEN
            v_status := 'ACTIVE';
        ELSIF v_status IN ('ALL', 'TODAS', '*') THEN
            v_status := 'ALL';
        ELSIF v_status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO', 'CANCELADO') THEN
            NULL;
        ELSE
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'status debe ser active, all, PENDIENTE, CONFIRMADO, COMPLETADO o CANCELADO.');
        END IF;

        v_filter_pro := CASE WHEN NVL(pi_prof_id, 0) > 0 THEN pi_prof_id ELSE NULL END;
        v_filter_loc := CASE WHEN NVL(pi_loc_id, 0) > 0 THEN pi_loc_id ELSE NULL END;
        v_filter_ser := CASE WHEN NVL(pi_service_id, 0) > 0 THEN pi_service_id ELSE NULL END;
        IF v_org_viewer = 0 THEN
            v_filter_pro := NULL;
        END IF;

        IF pi_weekday IS NOT NULL THEN
            IF pi_weekday < 1 OR pi_weekday > 7 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'weekday debe estar entre 1 (lunes) y 7 (domingo).');
            END IF;
            v_filter_dow := pi_weekday;
        END IF;

        IF pi_hour IS NOT NULL THEN
            IF pi_hour < 0 OR pi_hour > 23 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'hour debe estar entre 0 y 23.');
            END IF;
            v_filter_hour := pi_hour;
        END IF;

        v_limit := NVL(TRUNC(pi_limit), 50);
        IF v_limit < 1 OR v_limit > c_max_agenda_limit THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'limit debe estar entre 1 y 80.');
        END IF;

        v_st_n(1) := 0; -- PENDIENTE
        v_st_n(2) := 0; -- CONFIRMADO
        v_st_n(3) := 0; -- COMPLETADO
        v_st_n(4) := 0; -- CANCELADO

        FOR rec IN (
            SELECT
                a.id_appointment,
                a.start_time,
                a.end_time,
                a.status,
                a.pro_id_professional,
                a.loc_id_location,
                a.ser_id_service,
                c.full_name AS customer_name,
                NVL(p.display_name, TRIM(u.first_name || ' ' || u.last_name)) AS professional_name,
                s.name AS service_name,
                l.name AS location_name
              FROM appointment a
              JOIN customer c     ON c.id_customer = a.cus_id_customer
              JOIN professional p ON p.id_professional = a.pro_id_professional
              JOIN app_user u     ON u.id_user = p.usr_id_user
              JOIN service s      ON s.id_service = a.ser_id_service
              JOIN location l     ON l.id_location = a.loc_id_location
             WHERE a.org_id_organization = v_org_id
               AND a.start_time >= v_from_ts
               AND a.start_time <  v_to_excl
               AND (v_org_viewer = 1 OR a.pro_id_professional = v_prof_id)
               AND (v_filter_pro IS NULL OR a.pro_id_professional = v_filter_pro)
               AND (v_filter_loc IS NULL OR a.loc_id_location = v_filter_loc)
               AND (v_filter_ser IS NULL OR a.ser_id_service = v_filter_ser)
               AND (
                    (v_status = 'ACTIVE' AND a.status IN ('PENDIENTE', 'CONFIRMADO', 'COMPLETADO'))
                    OR v_status = 'ALL'
                    OR a.status = v_status
               )
               AND (v_filter_dow IS NULL OR (TRUNC(a.start_time) - TRUNC(a.start_time, 'IW') + 1) = v_filter_dow)
               AND (v_filter_hour IS NULL OR TO_NUMBER(TO_CHAR(a.start_time, 'HH24')) = v_filter_hour)
             ORDER BY a.start_time
        ) LOOP
            v_matched := v_matched + 1;
            v_iso := iso_weekday(rec.start_time);
            v_hour := TO_NUMBER(TO_CHAR(rec.start_time, 'HH24'));
            bump(v_hour_n, v_hour);
            bump(v_dow_n, v_iso);
            IF rec.status = 'PENDIENTE' THEN
                bump(v_st_n, 1);
            ELSIF rec.status = 'CONFIRMADO' THEN
                bump(v_st_n, 2);
            ELSIF rec.status = 'COMPLETADO' THEN
                bump(v_st_n, 3);
            ELSIF rec.status = 'CANCELADO' THEN
                bump(v_st_n, 4);
            END IF;

            IF rec.pro_id_professional IS NOT NULL THEN
                bump(v_pro_n, rec.pro_id_professional);
                v_pro_name(rec.pro_id_professional) := rec.professional_name;
            END IF;
            IF rec.ser_id_service IS NOT NULL THEN
                bump(v_ser_n, rec.ser_id_service);
                v_ser_name(rec.ser_id_service) := rec.service_name;
            END IF;

            IF v_listed < v_limit THEN
                v_listed := v_listed + 1;
                v_item := json_object_t();
                v_item.put('id', rec.id_appointment);
                v_item.put('start', TO_CHAR(rec.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
                v_item.put('end', TO_CHAR(rec.end_time, 'YYYY-MM-DD"T"HH24:MI:SS'));
                v_item.put('status', rec.status);
                v_item.put('customer_name', rec.customer_name);
                v_item.put('professional_name', rec.professional_name);
                v_item.put('service_name', rec.service_name);
                v_item.put('location_name', rec.location_name);
                v_item.put('pro_id_professional', rec.pro_id_professional);
                v_item.put('loc_id_location', rec.loc_id_location);
                v_item.put('ser_id_service', rec.ser_id_service);
                v_item.put('weekday', v_iso);
                v_item.put('weekday_name', weekday_name(v_iso));
                v_item.put('hour', v_hour);
                v_data.append(v_item);
            END IF;
        END LOOP;

        FOR i IN 0 .. 23 LOOP
            IF v_hour_n.EXISTS(i) THEN
                v_row := json_object_t();
                v_row.put('hour', i);
                v_row.put('count', v_hour_n(i));
                v_by_hour.append(v_row);
                IF v_hour_n(i) > v_peak_hour_n OR (v_hour_n(i) = v_peak_hour_n AND (v_peak_hour IS NULL OR i < v_peak_hour)) THEN
                    v_peak_hour := i;
                    v_peak_hour_n := v_hour_n(i);
                END IF;
            END IF;
        END LOOP;

        FOR i IN 1 .. 7 LOOP
            IF v_dow_n.EXISTS(i) THEN
                v_row := json_object_t();
                v_row.put('weekday', i);
                v_row.put('name', weekday_name(i));
                v_row.put('count', v_dow_n(i));
                v_by_dow.append(v_row);
                IF v_dow_n(i) > v_peak_dow_n OR (v_dow_n(i) = v_peak_dow_n AND (v_peak_dow IS NULL OR i < v_peak_dow)) THEN
                    v_peak_dow := i;
                    v_peak_dow_n := v_dow_n(i);
                END IF;
            END IF;
        END LOOP;

        v_by_status.put('PENDIENTE', NVL(v_st_n(1), 0));
        v_by_status.put('CONFIRMADO', NVL(v_st_n(2), 0));
        v_by_status.put('COMPLETADO', NVL(v_st_n(3), 0));
        v_by_status.put('CANCELADO', NVL(v_st_n(4), 0));

        v_key := v_pro_n.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_row := json_object_t();
            v_row.put('id', v_key);
            v_row.put('name', v_pro_name(v_key));
            v_row.put('count', v_pro_n(v_key));
            v_by_pro.append(v_row);
            v_key := v_pro_n.NEXT(v_key);
        END LOOP;

        v_key := v_ser_n.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_row := json_object_t();
            v_row.put('id', v_key);
            v_row.put('name', v_ser_name(v_key));
            v_row.put('count', v_ser_n(v_key));
            v_by_ser.append(v_row);
            v_key := v_ser_n.NEXT(v_key);
        END LOOP;

        IF v_peak_hour IS NOT NULL THEN
            v_peak_h_obj := json_object_t();
            v_peak_h_obj.put('hour', v_peak_hour);
            v_peak_h_obj.put('count', v_peak_hour_n);
        END IF;
        IF v_peak_dow IS NOT NULL THEN
            v_peak_d_obj := json_object_t();
            v_peak_d_obj.put('weekday', v_peak_dow);
            v_peak_d_obj.put('name', weekday_name(v_peak_dow));
            v_peak_d_obj.put('count', v_peak_dow_n);
        END IF;

        v_filters.put('status', LOWER(v_status));
        IF v_filter_pro IS NOT NULL THEN v_filters.put('pro_id', v_filter_pro); END IF;
        IF v_filter_loc IS NOT NULL THEN v_filters.put('loc_id', v_filter_loc); END IF;
        IF v_filter_ser IS NOT NULL THEN v_filters.put('service_id', v_filter_ser); END IF;
        IF v_filter_dow IS NOT NULL THEN v_filters.put('weekday', v_filter_dow); END IF;
        IF v_filter_hour IS NOT NULL THEN v_filters.put('hour', v_filter_hour); END IF;

        v_meta.put('from', TO_CHAR(v_from_d, 'YYYY-MM-DD'));
        v_meta.put('to', TO_CHAR(v_to_d, 'YYYY-MM-DD'));
        v_meta.put('timezone', pkg_aox_util.fn_app_timezone());
        v_meta.put('matched_count', v_matched);
        v_meta.put('returned_count', v_listed);
        v_meta.put('truncated', CASE WHEN v_matched > v_listed THEN TRUE ELSE FALSE END);
        v_meta.put('filters', v_filters);
        v_meta.put('scope', CASE WHEN v_org_viewer = 1 THEN 'organization' ELSE 'professional' END);

        v_summary.put('by_status', v_by_status);
        v_summary.put('by_hour', v_by_hour);
        v_summary.put('by_weekday', v_by_dow);
        v_summary.put('by_professional', v_by_pro);
        v_summary.put('by_service', v_by_ser);
        IF v_peak_h_obj IS NOT NULL THEN
            v_summary.put('peak_hour', v_peak_h_obj);
        ELSE
            v_summary.put_null('peak_hour');
        END IF;
        IF v_peak_d_obj IS NOT NULL THEN
            v_summary.put('peak_weekday', v_peak_d_obj);
        ELSE
            v_summary.put_null('peak_weekday');
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('meta', v_meta);
        v_response.put('summary', v_summary);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_appointments;

END pkg_aox_assistant_api;
/

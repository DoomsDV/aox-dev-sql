PROMPT CREATE OR REPLACE PACKAGE pkg_aox_inbox_api
CREATE OR REPLACE PACKAGE pkg_aox_inbox_api IS

    -- Inserta una fila de inbox. Idempotente si pi_dedupe_key ya existe.
    -- No exige token FCM: la campanita vive aunque el push este apagado.
    PROCEDURE pr_enqueue(
        pi_org_id          IN NUMBER,
        pi_org_member_id   IN NUMBER,
        pi_ntype           IN VARCHAR2,
        pi_title           IN VARCHAR2,
        pi_body            IN VARCHAR2 DEFAULT NULL,
        pi_action_type     IN VARCHAR2 DEFAULT 'OPEN_URL',
        pi_action_url      IN VARCHAR2 DEFAULT NULL,
        pi_action_payload  IN CLOB     DEFAULT NULL,
        pi_appointment_id  IN NUMBER   DEFAULT NULL,
        pi_holiday_id      IN NUMBER   DEFAULT NULL,
        pi_campaign_id     IN NUMBER   DEFAULT NULL,
        pi_dedupe_key      IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE pr_list(
        pi_auth_header   IN  VARCHAR2,
        pi_limit         IN  NUMBER DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_unread_count(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_mark_read(
        pi_auth_header      IN  VARCHAR2,
        pi_notification_id  IN  NUMBER,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    );

    PROCEDURE pr_mark_all_read(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Proximo feriado del pais de la org (ventana ~15 dias) sin cierre configurado.
    PROCEDURE pr_upcoming_holiday_hint(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Job diario: 14 dias antes del feriado, avisa a ADMIN/RECEPCIONISTA.
    PROCEDURE pr_process_holiday_reminders;

END pkg_aox_inbox_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_inbox_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_inbox_api IS

    c_process_holiday CONSTANT VARCHAR2(100) := 'PKG_AOX_INBOX_API.PR_PROCESS_HOLIDAY_REMINDERS';

    FUNCTION fn_iso_ts(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(pi_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    END fn_iso_ts;

    FUNCTION fn_today_app RETURN DATE IS
    BEGIN
        RETURN TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS TIMESTAMP));
    END fn_today_app;

    FUNCTION fn_lead_days RETURN PLS_INTEGER IS
        v_raw  VARCHAR2(40);
        v_days PLS_INTEGER := 14;
    BEGIN
        v_raw := TRIM(fn_get_parameter('HOLIDAY_NOTIFY_LEAD_DAYS'));
        IF v_raw IS NOT NULL AND REGEXP_LIKE(v_raw, '^[0-9]+$') THEN
            v_days := TO_NUMBER(v_raw);
        END IF;
        IF v_days < 1 THEN
            v_days := 14;
        ELSIF v_days > 30 THEN
            v_days := 30;
        END IF;
        RETURN v_days;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 14;
    END fn_lead_days;

    FUNCTION fn_hint_days RETURN PLS_INTEGER IS
        v_raw  VARCHAR2(40);
        v_days PLS_INTEGER := 15;
    BEGIN
        v_raw := TRIM(fn_get_parameter('HOLIDAY_HINT_DAYS'));
        IF v_raw IS NOT NULL AND REGEXP_LIKE(v_raw, '^[0-9]+$') THEN
            v_days := TO_NUMBER(v_raw);
        END IF;
        IF v_days < 1 THEN
            v_days := 15;
        ELSIF v_days > 45 THEN
            v_days := 45;
        END IF;
        RETURN v_days;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 15;
    END fn_hint_days;

    FUNCTION fn_sanitize_ntype(pi_ntype IN VARCHAR2) RETURN VARCHAR2 IS
        v_type VARCHAR2(20) := UPPER(TRIM(pi_ntype));
    BEGIN
        IF v_type IN ('APPOINTMENT', 'PAYMENT', 'HOLIDAY', 'SYSTEM') THEN
            RETURN v_type;
        END IF;
        RETURN 'SYSTEM';
    END fn_sanitize_ntype;

    FUNCTION fn_sanitize_action(pi_action IN VARCHAR2) RETURN VARCHAR2 IS
        v_action VARCHAR2(30) := UPPER(TRIM(pi_action));
    BEGIN
        IF v_action IN ('OPEN_URL', 'OPEN_CLOSURE') THEN
            RETURN v_action;
        END IF;
        RETURN 'OPEN_URL';
    END fn_sanitize_action;

    PROCEDURE pr_enqueue(
        pi_org_id          IN NUMBER,
        pi_org_member_id   IN NUMBER,
        pi_ntype           IN VARCHAR2,
        pi_title           IN VARCHAR2,
        pi_body            IN VARCHAR2 DEFAULT NULL,
        pi_action_type     IN VARCHAR2 DEFAULT 'OPEN_URL',
        pi_action_url      IN VARCHAR2 DEFAULT NULL,
        pi_action_payload  IN CLOB     DEFAULT NULL,
        pi_appointment_id  IN NUMBER   DEFAULT NULL,
        pi_holiday_id      IN NUMBER   DEFAULT NULL,
        pi_campaign_id     IN NUMBER   DEFAULT NULL,
        pi_dedupe_key      IN VARCHAR2 DEFAULT NULL
    ) IS
        v_title VARCHAR2(500);
        v_key   VARCHAR2(200);
        v_type  VARCHAR2(20);
        v_action VARCHAR2(30);
    BEGIN
        IF pi_org_id IS NULL OR pi_org_id <= 0 OR pi_org_member_id IS NULL OR pi_org_member_id <= 0 THEN
            RETURN;
        END IF;

        v_title := SUBSTR(TRIM(pi_title), 1, 500);
        IF v_title IS NULL THEN
            RETURN;
        END IF;

        v_key := NULLIF(TRIM(pi_dedupe_key), '');
        v_type := fn_sanitize_ntype(pi_ntype);
        v_action := fn_sanitize_action(pi_action_type);

        INSERT INTO user_notification (
            org_id_organization,
            org_member_id,
            ntype,
            title,
            body,
            action_type,
            action_url,
            action_payload,
            appointment_id,
            holiday_id,
            campaign_id,
            dedupe_key
        ) VALUES (
            pi_org_id,
            pi_org_member_id,
            v_type,
            v_title,
            SUBSTR(pi_body, 1, 4000),
            v_action,
            SUBSTR(TRIM(pi_action_url), 1, 1000),
            pi_action_payload,
            pi_appointment_id,
            pi_holiday_id,
            pi_campaign_id,
            v_key
        );
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            NULL;
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => 'PKG_AOX_INBOX_API.PR_ENQUEUE',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_parameters      => 'org_member_id=' || pi_org_member_id || ';ntype=' || pi_ntype
            );
    END pr_enqueue;

    PROCEDURE pr_list(
        pi_auth_header   IN  VARCHAR2,
        pi_limit         IN  NUMBER DEFAULT 50,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_member_id     NUMBER;
        v_limit         PLS_INTEGER;
        v_response      json_object_t := json_object_t();
        v_data          json_array_t  := json_array_t();
        v_item          json_object_t;
        v_payload_obj   json_object_t;
        v_unread        NUMBER := 0;
    BEGIN
        v_org_id    := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        v_limit := NVL(pi_limit, 50);
        IF v_limit < 1 THEN
            v_limit := 50;
        ELSIF v_limit > 100 THEN
            v_limit := 100;
        END IF;

        SELECT COUNT(*)
          INTO v_unread
          FROM user_notification n
         WHERE n.org_member_id = v_member_id
           AND n.org_id_organization = v_org_id
           AND n.read_at IS NULL;

        FOR rec IN (
            SELECT
                n.id_notification,
                n.ntype,
                n.title,
                n.body,
                n.action_type,
                n.action_url,
                n.action_payload,
                n.appointment_id,
                n.holiday_id,
                n.campaign_id,
                n.read_at,
                n.created_at
              FROM user_notification n
             WHERE n.org_member_id = v_member_id
               AND n.org_id_organization = v_org_id
             ORDER BY n.created_at DESC
             FETCH FIRST v_limit ROWS ONLY
        ) LOOP
            v_item := json_object_t();
            v_item.put('id_notification', rec.id_notification);
            v_item.put('ntype', rec.ntype);
            v_item.put('title', rec.title);
            v_item.put('body', rec.body);
            v_item.put('action_type', rec.action_type);
            v_item.put('action_url', rec.action_url);
            v_item.put('appointment_id', rec.appointment_id);
            v_item.put('holiday_id', rec.holiday_id);
            v_item.put('campaign_id', rec.campaign_id);
            IF rec.read_at IS NOT NULL THEN
                v_item.put('read_at', fn_iso_ts(rec.read_at));
            END IF;
            v_item.put('created_at', fn_iso_ts(rec.created_at));
            v_item.put('unread', CASE WHEN rec.read_at IS NULL THEN 1 ELSE 0 END);

            IF rec.action_payload IS NOT NULL THEN
                BEGIN
                    v_payload_obj := json_object_t.parse(rec.action_payload);
                    v_item.put('action_payload', v_payload_obj);
                EXCEPTION
                    WHEN OTHERS THEN
                        BEGIN
                            v_item.put('action_payload', DBMS_LOB.SUBSTR(rec.action_payload, 4000, 1));
                        EXCEPTION
                            WHEN OTHERS THEN
                                NULL;
                        END;
                END;
            END IF;

            v_data.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        v_response.put('unread_count', v_unread);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list;

    PROCEDURE pr_unread_count(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id    NUMBER;
        v_member_id NUMBER;
        v_count     NUMBER := 0;
        v_response  json_object_t := json_object_t();
        v_data      json_object_t := json_object_t();
    BEGIN
        v_org_id    := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        SELECT COUNT(*)
          INTO v_count
          FROM user_notification n
         WHERE n.org_member_id = v_member_id
           AND n.org_id_organization = v_org_id
           AND n.read_at IS NULL;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_data.put('unread_count', v_count);
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_unread_count;

    PROCEDURE pr_mark_read(
        pi_auth_header      IN  VARCHAR2,
        pi_notification_id  IN  NUMBER,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB
    ) IS
        v_org_id    NUMBER;
        v_member_id NUMBER;
        v_updated   NUMBER := 0;
        v_response  json_object_t := json_object_t();
        v_data      json_object_t := json_object_t();
    BEGIN
        v_org_id    := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        IF pi_notification_id IS NULL OR pi_notification_id <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Notificacion invalida.');
        END IF;

        UPDATE user_notification n
           SET n.read_at = NVL(n.read_at, CURRENT_TIMESTAMP)
         WHERE n.id_notification = pi_notification_id
           AND n.org_member_id = v_member_id
           AND n.org_id_organization = v_org_id;

        v_updated := SQL%ROWCOUNT;
        IF v_updated = 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Notificacion no encontrada.');
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_data.put('id_notification', pi_notification_id);
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_mark_read;

    PROCEDURE pr_mark_all_read(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id    NUMBER;
        v_member_id NUMBER;
        v_updated   NUMBER := 0;
        v_response  json_object_t := json_object_t();
        v_data      json_object_t := json_object_t();
    BEGIN
        v_org_id    := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_member_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        UPDATE user_notification n
           SET n.read_at = CURRENT_TIMESTAMP
         WHERE n.org_member_id = v_member_id
           AND n.org_id_organization = v_org_id
           AND n.read_at IS NULL;

        v_updated := SQL%ROWCOUNT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_data.put('updated', v_updated);
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_mark_all_read;

    PROCEDURE pr_upcoming_holiday_hint(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id     NUMBER;
        v_role_id    NUMBER;
        v_country    VARCHAR2(2);
        v_today      DATE;
        v_until      DATE;
        v_response   json_object_t := json_object_t();
        v_data       json_object_t;
        v_id         NUMBER;
        v_name       VARCHAR2(120);
        v_date       DATE;
        v_days       NUMBER;
        v_closure    VARCHAR2(200);
    BEGIN
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');

        IF v_role_id NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        SELECT NVL(o.country_code, 'PY')
          INTO v_country
          FROM organization o
         WHERE o.id_organization = v_org_id;

        v_today := fn_today_app;
        v_until := v_today + fn_hint_days;

        BEGIN
            SELECT
                h.id_holiday,
                h.name,
                h.holiday_date,
                h.holiday_date - v_today
              INTO
                v_id,
                v_name,
                v_date,
                v_days
              FROM ref_holiday h
             WHERE h.is_active = 1
               AND h.country_code = v_country
               AND h.holiday_date BETWEEN v_today AND v_until
               AND NOT EXISTS (
                    SELECT 1
                      FROM location_closure c
                     WHERE c.org_id_organization = v_org_id
                       AND c.start_date <= h.holiday_date
                       AND c.end_date   >= h.holiday_date
               )
             ORDER BY h.holiday_date ASC
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_response_body := v_response.to_clob();
                RETURN;
        END;

        v_closure := 'Feriado Nacional: ' || v_name;
        v_data := json_object_t();
        v_data.put('id_holiday', v_id);
        v_data.put('name', v_name);
        v_data.put('holiday_date', TO_CHAR(v_date, 'YYYY-MM-DD'));
        v_data.put('days_until', v_days);
        v_data.put('closure_name', v_closure);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_upcoming_holiday_hint;

    PROCEDURE pr_process_holiday_reminders IS
        v_today      DATE := fn_today_app;
        v_lead       PLS_INTEGER := fn_lead_days;
        v_target     DATE;
        v_admin      NUMBER := pkg_aox_util.fn_rol('ADMIN');
        v_recep      NUMBER := pkg_aox_util.fn_rol('RECEPCIONISTA');
        v_base       VARCHAR2(500);
        v_title      VARCHAR2(500);
        v_body       VARCHAR2(4000);
        v_url        VARCHAR2(1000);
        v_payload    CLOB;
        v_closure    VARCHAR2(200);
        v_date_label VARCHAR2(20);
    BEGIN
        v_target := v_today + v_lead;
        v_base := RTRIM(NVL(fn_get_parameter('APP_PUBLIC_BASE_URL'), 'https://hasel.app'), '/');

        FOR h IN (
            SELECT id_holiday, country_code, holiday_date, name
              FROM ref_holiday
             WHERE is_active = 1
               AND holiday_date = v_target
        ) LOOP
            v_closure := 'Feriado Nacional: ' || h.name;
            v_date_label := TO_CHAR(h.holiday_date, 'DD/MM');
            v_title := 'Se acerca un feriado nacional';
            v_body := 'Se acerca un feriado nacional: ' || h.name || ' el ' || v_date_label
                   || '. ¿Tu negocio estará abierto?';

            SELECT json_object(
                       'name'        VALUE v_closure,
                       'start_date'  VALUE TO_CHAR(h.holiday_date, 'YYYY-MM-DD'),
                       'end_date'    VALUE TO_CHAR(h.holiday_date, 'YYYY-MM-DD'),
                       'is_full_day' VALUE 1,
                       'apply_all'   VALUE 1
                       RETURNING CLOB
                   )
              INTO v_payload
              FROM dual;

            FOR org_rec IN (
                SELECT o.id_organization
                  FROM organization o
                 WHERE NVL(o.country_code, 'PY') = h.country_code
                   AND NOT EXISTS (
                        SELECT 1
                          FROM location_closure c
                         WHERE c.org_id_organization = o.id_organization
                           AND c.start_date <= h.holiday_date
                           AND c.end_date   >= h.holiday_date
                   )
            ) LOOP
                FOR mem IN (
                    SELECT m.id_org_member
                      FROM org_member m
                     WHERE m.org_id_organization = org_rec.id_organization
                       AND m.is_active = 1
                       AND m.rol_id_role IN (v_admin, v_recep)
                ) LOOP
                    v_url := v_base || '/panel/locations?org_member_id=' || mem.id_org_member
                          || '&open_org_closure=1'
                          || '&name=' || REPLACE(REPLACE(REPLACE(v_closure, '%', '%25'), '&', '%26'), ' ', '%20')
                          || '&start=' || TO_CHAR(h.holiday_date, 'YYYY-MM-DD')
                          || '&end=' || TO_CHAR(h.holiday_date, 'YYYY-MM-DD')
                          || '&full_day=1&apply_all=1';

                    pkg_aox_fcm_api.pr_notify_org_member(
                        pi_org_member_id  => mem.id_org_member,
                        pi_title          => v_title,
                        pi_body           => v_body,
                        pi_url            => v_url,
                        pi_process_name   => c_process_holiday,
                        pi_ntype          => 'HOLIDAY',
                        pi_holiday_id     => h.id_holiday,
                        pi_action_type    => 'OPEN_CLOSURE',
                        pi_action_payload => v_payload,
                        pi_dedupe_key     => 'HOLIDAY:' || org_rec.id_organization || ':'
                                          || h.id_holiday || ':' || mem.id_org_member
                    );
                END LOOP;
                COMMIT;
            END LOOP;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_push_fcm(
                pi_process_name    => c_process_holiday,
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
            );
            ROLLBACK;
    END pr_process_holiday_reminders;

END pkg_aox_inbox_api;
/
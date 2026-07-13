PROMPT CREATE OR REPLACE PACKAGE pkg_aox_schedule_exception_api
CREATE OR REPLACE PACKAGE pkg_aox_schedule_exception_api IS

    -- Listar excepciones de un profesional en un rango de fechas (calendario mensual)
    PROCEDURE pr_list_schedule_exceptions(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_from_date     IN  VARCHAR2,
        pi_to_date       IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Detalle de una excepcion por fecha (YYYY-MM-DD)
    PROCEDURE pr_get_schedule_exception(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_exception_date IN VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Crear o reemplazar excepcion de un dia (reemplazo total de slots en OVERRIDE)
    PROCEDURE pr_upsert_schedule_exception(
        pi_auth_header    IN  VARCHAR2,
        pi_prof_id        IN  NUMBER,
        pi_exception_date IN  VARCHAR2,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

    -- Eliminar excepcion: el dia vuelve a heredar la plantilla semanal
    PROCEDURE pr_delete_schedule_exception(
        pi_auth_header    IN  VARCHAR2,
        pi_prof_id        IN  NUMBER,
        pi_exception_date IN  VARCHAR2,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    );

END pkg_aox_schedule_exception_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_schedule_exception_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_schedule_exception_api IS

    c_type_blocked  CONSTANT VARCHAR2(20) := 'BLOCKED';
    c_type_override CONSTANT VARCHAR2(20) := 'OVERRIDE';

    FUNCTION fn_today_app RETURN DATE IS
    BEGIN
        RETURN TRUNC(CAST(CURRENT_TIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS DATE));
    END fn_today_app;

    PROCEDURE pr_assert_schedule_manager(
        pi_auth_header IN VARCHAR2
    ) IS
        v_role_id NUMBER;
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF v_role_id NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No tienes permisos para gestionar horarios o excepciones.');
        END IF;
    END pr_assert_schedule_manager;

    FUNCTION fn_parse_exception_date(
        pi_exception_date IN VARCHAR2
    ) RETURN DATE IS
    BEGIN
        IF pi_exception_date IS NULL OR TRIM(pi_exception_date) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 'La fecha de excepcion es obligatoria.');
        END IF;

        RETURN TO_DATE(TRIM(pi_exception_date), 'YYYY-MM-DD');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002, 'Formato de fecha invalido. Use YYYY-MM-DD.');
    END fn_parse_exception_date;

    PROCEDURE pr_assert_future_or_today_editable(
        pi_exception_date IN DATE
    ) IS
    BEGIN
        IF TRUNC(pi_exception_date) < fn_today_app THEN
            RAISE_APPLICATION_ERROR(-20003, 'No se pueden crear ni modificar excepciones en fechas pasadas.');
        END IF;
    END pr_assert_future_or_today_editable;

    PROCEDURE pr_assert_professional_in_org(
        pi_prof_id IN NUMBER,
        pi_org_id  IN NUMBER
    ) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO v_count
        FROM professional p
        WHERE p.id_professional = pi_prof_id
          AND p.org_id_organization = pi_org_id;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Profesional no encontrado en la organizacion.');
        END IF;
    END pr_assert_professional_in_org;

    FUNCTION fn_validate_slots_overlap(
        pi_slots IN json_array_t
    ) RETURN VARCHAR2 IS
        v_size   NUMBER;
        v_item   json_object_t;
        v_start  VARCHAR2(5);
        v_end    VARCHAR2(5);
        v_day_name VARCHAR2(20) := 'la excepcion';
    BEGIN
        IF pi_slots IS NULL THEN
            RETURN NULL;
        END IF;

        v_size := pi_slots.get_size();
        IF v_size <= 1 THEN
            RETURN NULL;
        END IF;

        FOR i IN 0 .. v_size - 1 LOOP
            v_item := json_object_t(pi_slots.get(i));
            v_start := v_item.get_string('start_time');
            v_end   := v_item.get_string('end_time');

            IF v_start >= v_end THEN
                RETURN 'La hora de inicio (' || v_start || ') debe ser menor que la de fin (' || v_end || ').';
            END IF;

            FOR j IN 0 .. v_size - 1 LOOP
                IF j = i THEN
                    CONTINUE;
                END IF;

                DECLARE
                    v_other json_object_t := json_object_t(pi_slots.get(j));
                    v_o_start VARCHAR2(5) := v_other.get_string('start_time');
                    v_o_end   VARCHAR2(5) := v_other.get_string('end_time');
                BEGIN
                    IF v_start < v_o_end AND v_end > v_o_start THEN
                        RETURN 'Conflicto en ' || v_day_name || '. El turno de ' || v_start || ' a ' || v_end
                            || ' se cruza con otro turno del mismo dia.';
                    END IF;
                END;
            END LOOP;
        END LOOP;

        RETURN NULL;
    END fn_validate_slots_overlap;

    PROCEDURE pr_list_schedule_exceptions(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_from_date     IN  VARCHAR2,
        pi_to_date       IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_from_date     DATE;
        v_to_date       DATE;
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item          json_object_t;
        v_slot_count    NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        pr_assert_professional_in_org(pi_prof_id, v_org_id);

        v_from_date := fn_parse_exception_date(pi_from_date);
        v_to_date   := fn_parse_exception_date(pi_to_date);

        IF v_from_date > v_to_date THEN
            RAISE_APPLICATION_ERROR(-20002, 'La fecha inicial no puede ser posterior a la fecha final.');
        END IF;

        FOR rec IN (
            SELECT
                e.id_schedule_exception,
                e.exception_date,
                e.exception_type,
                e.note,
                (SELECT COUNT(*)
                 FROM professional_schedule_exception_slot s
                 WHERE s.exc_id_schedule_exception = e.id_schedule_exception) AS slot_count
            FROM professional_schedule_exception e
            WHERE e.pro_id_professional = pi_prof_id
              AND e.org_id_organization = v_org_id
              AND e.exception_date BETWEEN v_from_date AND v_to_date
            ORDER BY e.exception_date ASC
        ) LOOP
            v_item := json_object_t();
            v_item.put('id_schedule_exception', rec.id_schedule_exception);
            v_item.put('exception_date', TO_CHAR(rec.exception_date, 'YYYY-MM-DD'));
            v_item.put('exception_type', rec.exception_type);
            v_item.put('note', rec.note);
            v_item.put('slot_count', rec.slot_count);
            v_item.put('is_past', CASE WHEN rec.exception_date < fn_today_app THEN 1 ELSE 0 END);
            v_data_arr.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20003, -20004) THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_list_schedule_exceptions;

    PROCEDURE pr_get_schedule_exception(
        pi_auth_header    IN  VARCHAR2,
        pi_prof_id        IN  NUMBER,
        pi_exception_date IN  VARCHAR2,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id          NUMBER;
        v_exception_date  DATE;
        v_response_json   json_object_t := json_object_t();
        v_data_obj        json_object_t := json_object_t();
        v_slots_arr       json_array_t  := json_array_t();
        v_slot_obj        json_object_t;
        v_exc_id          NUMBER;
        v_exc_type        VARCHAR2(20);
        v_note            VARCHAR2(500);
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        pr_assert_professional_in_org(pi_prof_id, v_org_id);
        v_exception_date := fn_parse_exception_date(pi_exception_date);

        BEGIN
            SELECT
                e.id_schedule_exception,
                e.exception_type,
                e.note
            INTO
                v_exc_id,
                v_exc_type,
                v_note
            FROM professional_schedule_exception e
            WHERE e.pro_id_professional = pi_prof_id
              AND e.org_id_organization = v_org_id
              AND e.exception_date = v_exception_date;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                v_data_obj.put('exception_date', TO_CHAR(v_exception_date, 'YYYY-MM-DD'));
                v_data_obj.put_null('exception_type');
                v_data_obj.put_null('note');
                v_data_obj.put('slots', json_array_t());
                v_data_obj.put('is_past', CASE WHEN v_exception_date < fn_today_app THEN 1 ELSE 0 END);
                v_data_obj.put('inherits_template', 1);
                v_response_json.put('data', v_data_obj);
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        IF v_exc_type = c_type_override THEN
            FOR rec IN (
                SELECT
                    s.id_exception_slot,
                    s.loc_id_location,
                    l.name AS location_name,
                    s.start_time,
                    s.end_time
                FROM professional_schedule_exception_slot s
                JOIN location l ON l.id_location = s.loc_id_location
                WHERE s.exc_id_schedule_exception = v_exc_id
                ORDER BY s.start_time ASC
            ) LOOP
                v_slot_obj := json_object_t();
                v_slot_obj.put('id_exception_slot', rec.id_exception_slot);
                v_slot_obj.put('loc_id_location', rec.loc_id_location);
                v_slot_obj.put('location_name', rec.location_name);
                v_slot_obj.put('start_time', rec.start_time);
                v_slot_obj.put('end_time', rec.end_time);
                v_slots_arr.append(v_slot_obj);
            END LOOP;
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_data_obj.put('id_schedule_exception', v_exc_id);
        v_data_obj.put('exception_date', TO_CHAR(v_exception_date, 'YYYY-MM-DD'));
        v_data_obj.put('exception_type', v_exc_type);
        v_data_obj.put('note', v_note);
        v_data_obj.put('slots', v_slots_arr);
        v_data_obj.put('is_past', CASE WHEN v_exception_date < fn_today_app THEN 1 ELSE 0 END);
        v_data_obj.put('inherits_template', 0);
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20004) THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_get_schedule_exception;

    PROCEDURE pr_upsert_schedule_exception(
        pi_auth_header    IN  VARCHAR2,
        pi_prof_id        IN  NUMBER,
        pi_exception_date IN  VARCHAR2,
        pi_body           IN  CLOB,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id          NUMBER;
        v_exception_date  DATE;
        v_json_req        json_object_t;
        v_exception_type  VARCHAR2(20);
        v_note            VARCHAR2(500);
        v_slots_arr       json_array_t;
        v_slot_item       json_object_t;
        v_loc_id          NUMBER;
        v_start           VARCHAR2(5);
        v_end             VARCHAR2(5);
        v_exc_id          NUMBER;
        v_overlap_msg     VARCHAR2(4000);
        v_appt_count      NUMBER := 0;
        v_acknowledge     BOOLEAN := FALSE;
        v_ack_raw         VARCHAR2(20);
        v_response_json   json_object_t := json_object_t();
    BEGIN
        pr_assert_schedule_manager(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        pr_assert_professional_in_org(pi_prof_id, v_org_id);
        v_exception_date := fn_parse_exception_date(pi_exception_date);
        pr_assert_future_or_today_editable(v_exception_date);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON invalido.');
        END;

        v_exception_type := UPPER(TRIM(v_json_req.get_string('exception_type')));
        v_note := v_json_req.get_string('note');

        IF v_exception_type NOT IN (c_type_blocked, c_type_override) THEN
            RAISE_APPLICATION_ERROR(-20002, 'exception_type debe ser BLOCKED u OVERRIDE.');
        END IF;

        IF v_exception_type = c_type_override THEN
            v_slots_arr := v_json_req.get_array('slots');
            v_overlap_msg := fn_validate_slots_overlap(v_slots_arr);
            IF v_overlap_msg IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20005, v_overlap_msg);
            END IF;
        END IF;

        IF v_json_req.has('acknowledge_existing_appointments') THEN
            BEGIN
                v_acknowledge := v_json_req.get_boolean('acknowledge_existing_appointments');
            EXCEPTION
                WHEN OTHERS THEN
                    v_ack_raw := LOWER(TRIM(NVL(v_json_req.get_string('acknowledge_existing_appointments'), 'false')));
                    v_acknowledge := v_ack_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        IF v_exception_type = c_type_blocked THEN
            SELECT COUNT(*)
              INTO v_appt_count
              FROM appointment a
             WHERE a.pro_id_professional = pi_prof_id
               AND a.org_id_organization = v_org_id
               AND TRUNC(a.start_time) = v_exception_date
               AND a.status IN ('PENDIENTE', 'CONFIRMADO');

            IF v_appt_count > 0 AND NOT v_acknowledge THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                v_response_json.put('status', 'error');
                v_response_json.put('code', 'EXISTING_APPOINTMENTS');
                v_response_json.put('appointment_count', v_appt_count);
                v_response_json.put(
                    'message',
                    'Hay citas agendadas para este dia. Confirma para continuar con el bloqueo.'
                );
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        BEGIN
            SELECT e.id_schedule_exception
            INTO v_exc_id
            FROM professional_schedule_exception e
            WHERE e.pro_id_professional = pi_prof_id
              AND e.org_id_organization = v_org_id
              AND e.exception_date = v_exception_date;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_exc_id := NULL;
        END;

        IF v_exc_id IS NOT NULL THEN
            DELETE FROM professional_schedule_exception_slot
            WHERE exc_id_schedule_exception = v_exc_id;

            UPDATE professional_schedule_exception
            SET exception_type = v_exception_type,
                note           = v_note,
                updated_at     = CURRENT_TIMESTAMP
            WHERE id_schedule_exception = v_exc_id;
        ELSE
            INSERT INTO professional_schedule_exception (
                org_id_organization,
                pro_id_professional,
                exception_date,
                exception_type,
                note
            ) VALUES (
                v_org_id,
                pi_prof_id,
                v_exception_date,
                v_exception_type,
                v_note
            ) RETURNING id_schedule_exception INTO v_exc_id;
        END IF;

        IF v_exception_type = c_type_override AND v_slots_arr IS NOT NULL AND v_slots_arr.get_size() > 0 THEN
            FOR i IN 0 .. v_slots_arr.get_size() - 1 LOOP
                v_slot_item := json_object_t(v_slots_arr.get(i));
                v_loc_id := v_slot_item.get_number('loc_id_location');
                v_start  := v_slot_item.get_string('start_time');
                v_end    := v_slot_item.get_string('end_time');

                IF v_loc_id IS NULL OR v_loc_id <= 0 THEN
                    RAISE_APPLICATION_ERROR(-20002, 'loc_id_location es obligatorio en cada turno.');
                END IF;

                IF v_start IS NULL OR v_end IS NULL OR v_start >= v_end THEN
                    RAISE_APPLICATION_ERROR(-20002, 'Horario de turno invalido en la excepcion.');
                END IF;

                INSERT INTO professional_schedule_exception_slot (
                    exc_id_schedule_exception,
                    loc_id_location,
                    start_time,
                    end_time
                ) VALUES (
                    v_exc_id,
                    v_loc_id,
                    v_start,
                    v_end
                );
            END LOOP;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Excepción guardada correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20003, -20004) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE = -20005 THEN pkg_aox_util.c_conflict_code
                WHEN SQLCODE = -2290 THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => CASE
                    WHEN SQLCODE = -2290 THEN 'Formato de hora invalido. Debe ser HH:MM.'
                    ELSE pkg_aox_util.fn_clean_sqlerrm(SQLERRM)
                END,
                po_response_body => po_response_body
            );
    END pr_upsert_schedule_exception;

    PROCEDURE pr_delete_schedule_exception(
        pi_auth_header    IN  VARCHAR2,
        pi_prof_id        IN  NUMBER,
        pi_exception_date IN  VARCHAR2,
        po_status_code    OUT NUMBER,
        po_response_body  OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_exception_date DATE;
        v_deleted        NUMBER;
        v_response_json  json_object_t := json_object_t();
    BEGIN
        pr_assert_schedule_manager(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        pr_assert_professional_in_org(pi_prof_id, v_org_id);
        v_exception_date := fn_parse_exception_date(pi_exception_date);
        pr_assert_future_or_today_editable(v_exception_date);

        DELETE FROM professional_schedule_exception
        WHERE pro_id_professional = pi_prof_id
          AND org_id_organization = v_org_id
          AND exception_date = v_exception_date;

        v_deleted := SQL%ROWCOUNT;
        COMMIT;

        IF v_deleted = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'No existe una excepción para esa fecha.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Excepción eliminada. El día vuelve a usar la plantilla semanal.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20003, -20004) THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_delete_schedule_exception;

END pkg_aox_schedule_exception_api;
/


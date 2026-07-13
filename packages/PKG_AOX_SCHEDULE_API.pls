PROMPT CREATE OR REPLACE PACKAGE pkg_aox_schedule_api
CREATE OR REPLACE PACKAGE pkg_aox_schedule_api IS

    -- Obtener la semana completa de un profesional
    PROCEDURE pr_get_schedule(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualización masiva (Wipe y Replace) de la semana
    PROCEDURE pr_bulk_update_schedule(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_schedule_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_schedule_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_schedule_api IS

    -- Procedimiento: Obtener Horarios (GET)
    PROCEDURE pr_get_schedule(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_schedules_arr json_array_t  := json_array_t();
        v_cross_org_arr json_array_t  := json_array_t();
        v_sch_obj       json_object_t;
        v_platform_user_id NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            SELECT om.platform_user_id
              INTO v_platform_user_id
              FROM professional p
              JOIN org_member om ON om.id_org_member = p.usr_id_user
             WHERE p.id_professional = pi_prof_id
               AND p.org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'Profesional no encontrado.');
        END;

        -- Recuperamos los turnos ordenados por día y hora de inicio
        FOR rec IN (
            SELECT ps.id_professional_schedule, ps.loc_id_location, l.name AS location_name,
                   ps.day_of_week, ps.start_time, ps.end_time
            FROM professional_schedule ps
            JOIN location l ON ps.loc_id_location = l.id_location
            WHERE ps.pro_id_professional = pi_prof_id AND ps.org_id_organization = v_org_id
            ORDER BY ps.day_of_week ASC, ps.start_time ASC
        ) LOOP
            v_sch_obj := json_object_t();
            v_sch_obj.put('id_professional_schedule'  , rec.id_professional_schedule);
            v_sch_obj.put('loc_id_location'           , rec.loc_id_location);
            v_sch_obj.put('location_name'             , rec.location_name);
            v_sch_obj.put('day_of_week'               , rec.day_of_week);
            v_sch_obj.put('start_time'                , rec.start_time);
            v_sch_obj.put('end_time'                  , rec.end_time);
            v_schedules_arr.append(v_sch_obj);
        END LOOP;

        IF v_platform_user_id IS NOT NULL THEN
            FOR rec IN (
                SELECT
                    p_other.org_id_organization,
                    o.name AS organization_name,
                    ps.day_of_week,
                    ps.start_time,
                    ps.end_time,
                    l.name AS location_name
                FROM org_member om_other
                JOIN professional p_other
                  ON p_other.usr_id_user = om_other.id_org_member
                 AND p_other.is_active = 1
                JOIN professional_schedule ps
                  ON ps.pro_id_professional = p_other.id_professional
                 AND ps.org_id_organization = p_other.org_id_organization
                JOIN organization o
                  ON o.id_organization = p_other.org_id_organization
                JOIN location l
                  ON l.id_location = ps.loc_id_location
                WHERE om_other.platform_user_id = v_platform_user_id
                  AND om_other.is_active = 1
                  AND NOT (
                      p_other.id_professional = pi_prof_id
                      AND p_other.org_id_organization = v_org_id
                  )
                ORDER BY ps.day_of_week ASC, ps.start_time ASC
            ) LOOP
                v_sch_obj := json_object_t();
                v_sch_obj.put('org_id_organization', rec.org_id_organization);
                v_sch_obj.put('organization_name'  , rec.organization_name);
                v_sch_obj.put('day_of_week'        , rec.day_of_week);
                v_sch_obj.put('start_time'         , rec.start_time);
                v_sch_obj.put('end_time'           , rec.end_time);
                v_sch_obj.put('location_name'      , rec.location_name);
                v_cross_org_arr.append(v_sch_obj);
            END LOOP;
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_schedules_arr);
        v_response_json.put('cross_org_schedules', v_cross_org_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_schedule;

    -- Procedimiento: Actualización Masiva (PUT)
    PROCEDURE pr_bulk_update_schedule(
        pi_auth_header   IN  VARCHAR2,
        pi_prof_id       IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_json_req      json_object_t;
        v_schedules_arr json_array_t;
        v_sch_item      json_object_t;
        v_response_json json_object_t := json_object_t();

        v_loc_id        NUMBER;
        v_day           NUMBER;
        v_start         VARCHAR2(5);
        v_end           VARCHAR2(5);

        -- Nuevas variables para controles
        v_overlap_count NUMBER;
        v_day_name      VARCHAR2(20);
        v_impact_count  NUMBER := 0;
        v_acknowledge   BOOLEAN := FALSE;
        v_ack_raw       VARCHAR2(20);
        v_platform_user_id NUMBER;
        v_other_org_name   VARCHAR2(255);
        v_other_start      VARCHAR2(5);
        v_other_end        VARCHAR2(5);
        v_other_location   VARCHAR2(255);
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        IF pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header) NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No tienes permisos para modificar horarios.');
        END IF;

        BEGIN
            SELECT om.platform_user_id
              INTO v_platform_user_id
              FROM professional p
              JOIN org_member om ON om.id_org_member = p.usr_id_user
             WHERE p.id_professional = pi_prof_id
               AND p.org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'Profesional no encontrado.');
        END;

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_schedules_arr := v_json_req.get_array('schedules');
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o estructura de array incorrecta.');
        END;

        IF v_json_req.has('acknowledge_schedule_impact') THEN
            BEGIN
                v_acknowledge := v_json_req.get_boolean('acknowledge_schedule_impact');
            EXCEPTION
                WHEN OTHERS THEN
                    v_ack_raw := LOWER(TRIM(NVL(v_json_req.get_string('acknowledge_schedule_impact'), 'false')));
                    v_acknowledge := v_ack_raw IN ('true', '1', 'yes', 'si', 'sí');
            END;
        END IF;

        v_impact_count := pkg_aox_util.fn_count_template_impact_appointments(
            pi_prof_id,
            v_org_id,
            v_schedules_arr
        );

        IF v_impact_count > 0 AND NOT v_acknowledge THEN
            po_status_code := pkg_aox_util.c_conflict_code;
            v_response_json.put('status', 'error');
            v_response_json.put('code', 'SCHEDULE_IMPACT_APPOINTMENTS');
            v_response_json.put('appointment_count', v_impact_count);
            v_response_json.put(
                'message',
                'Hay citas futuras que no coinciden con la nueva plantilla. Las citas no se mueven solas: revisa el calendario y reprograma manualmente.'
            );
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Validar solapamiento con horarios de otras organizaciones del mismo usuario
        IF v_schedules_arr IS NOT NULL
           AND v_schedules_arr.get_size() > 0
           AND v_platform_user_id IS NOT NULL THEN
            FOR i IN 0 .. v_schedules_arr.get_size() - 1 LOOP
                v_sch_item := json_object_t(v_schedules_arr.get(i));
                v_day   := v_sch_item.get_number('day_of_week');
                v_start := v_sch_item.get_string('start_time');
                v_end   := v_sch_item.get_string('end_time');

                IF v_start >= v_end THEN
                    RAISE_APPLICATION_ERROR(-20003, 'En uno de los turnos, la hora de inicio ('||v_start||') es mayor o igual a la de fin ('||v_end||').');
                END IF;

                v_other_org_name := NULL;
                v_other_start    := NULL;
                v_other_end      := NULL;
                v_other_location := NULL;

                BEGIN
                    SELECT o.name, ps.start_time, ps.end_time, l.name
                      INTO v_other_org_name, v_other_start, v_other_end, v_other_location
                      FROM org_member om_other
                      JOIN professional p_other
                        ON p_other.usr_id_user = om_other.id_org_member
                       AND p_other.is_active = 1
                      JOIN professional_schedule ps
                        ON ps.pro_id_professional = p_other.id_professional
                       AND ps.org_id_organization = p_other.org_id_organization
                      JOIN organization o
                        ON o.id_organization = p_other.org_id_organization
                      JOIN location l
                        ON l.id_location = ps.loc_id_location
                     WHERE om_other.platform_user_id = v_platform_user_id
                       AND om_other.is_active = 1
                       AND NOT (
                           p_other.id_professional = pi_prof_id
                           AND p_other.org_id_organization = v_org_id
                       )
                       AND ps.day_of_week = v_day
                       AND v_start < ps.end_time
                       AND v_end > ps.start_time
                       AND ROWNUM = 1;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        NULL;
                END;

                IF v_other_org_name IS NOT NULL THEN
                    v_day_name := CASE v_day
                        WHEN 1 THEN 'Lunes'
                        WHEN 2 THEN 'Martes'
                        WHEN 3 THEN 'Miércoles'
                        WHEN 4 THEN 'Jueves'
                        WHEN 5 THEN 'Viernes'
                        WHEN 6 THEN 'Sábado'
                        WHEN 7 THEN 'Domingo'
                        ELSE 'Día ' || v_day
                    END;

                    RAISE_APPLICATION_ERROR(
                        -20005,
                        'No se puede guardar el turno del ' || v_day_name || ' de ' || v_start || ' a ' || v_end
                        || ': ya existe un horario de ' || v_other_start || ' a ' || v_other_end
                        || ' en la organizacion "' || v_other_org_name || '"'
                        || CASE
                            WHEN v_other_location IS NOT NULL THEN ' (' || v_other_location || ')'
                            ELSE ''
                           END
                        || '. Ajusta las horas aqui o modificalas en la otra sucursal.'
                    );
                END IF;
            END LOOP;
        END IF;

        -- INICIO TRANSACCIÓN
        -- 1. Estrategia Wipe: Borramos todo el horario actual del profesional
        DELETE FROM professional_schedule
        WHERE pro_id_professional = pi_prof_id AND org_id_organization = v_org_id;

        -- 2. Estrategia Replace: Validamos e Insertamos los turnos enviados
        IF v_schedules_arr IS NOT NULL AND v_schedules_arr.get_size() > 0 THEN
            FOR i IN 0 .. v_schedules_arr.get_size() - 1 LOOP
                v_sch_item := json_object_t(v_schedules_arr.get(i));

                v_loc_id := v_sch_item.get_number('loc_id_location');
                v_day    := v_sch_item.get_number('day_of_week');
                v_start  := v_sch_item.get_string('start_time');
                v_end    := v_sch_item.get_string('end_time');

                -- CONTROL 1: Lógica básica de horas
                IF v_start >= v_end THEN
                    RAISE_APPLICATION_ERROR(-20003, 'En uno de los turnos, la hora de inicio ('||v_start||') es mayor o igual a la de fin ('||v_end||').');
                END IF;

                -- CONTROL 2: Evitar solapamiento (Overlapping)
                -- Buscamos si el turno que queremos insertar choca con algún turno
                -- que ya hayamos insertado en las iteraciones anteriores de este mismo FOR LOOP.
                SELECT COUNT(*)
                INTO v_overlap_count
                FROM professional_schedule
                WHERE pro_id_professional = pi_prof_id
                  AND day_of_week         = v_day
                  AND (v_start < end_time AND v_end > start_time);

                IF v_overlap_count > 0 THEN
                    -- Convertimos el número a texto para que el error sea amigable en Astro
                    v_day_name := CASE v_day WHEN 1 THEN 'Lunes' WHEN 2 THEN 'Martes' WHEN 3 THEN 'Miércoles' WHEN 4 THEN 'Jueves' WHEN 5 THEN 'Viernes' WHEN 6 THEN 'Sábado' WHEN 7 THEN 'Domingo' ELSE 'Día ' || v_day END;

                    RAISE_APPLICATION_ERROR(-20004, 'Conflicto el día ' || v_day_name || '. El turno de ' || v_start || ' a ' || v_end || ' se cruza o se repite con otro turno en la misma jornada.');
                END IF;

                -- Si pasa los controles, insertamos
                INSERT INTO professional_schedule (
                    org_id_organization, pro_id_professional, loc_id_location,
                    day_of_week, start_time, end_time
                ) VALUES (
                    v_org_id, pi_prof_id, v_loc_id, v_day, v_start, v_end
                );
            END LOOP;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Horarios guardados correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            -- Si cualquier validación falla (ej. Overlap), se hace Rollback de TODO
            -- y el profesional recupera sus horarios viejos intactos.
            ROLLBACK;

            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20003) THEN pkg_aox_util.c_bad_request_code
                WHEN SQLCODE IN (-20004, -20005) THEN pkg_aox_util.c_conflict_code
                ELSE pkg_aox_util.c_internal_error_code
            END;

            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => CASE
                    WHEN SQLCODE = -2290 THEN 'Formato de hora inválido. Debe ser HH:MM.'
                    ELSE pkg_aox_util.fn_clean_sqlerrm(SQLERRM)
                END,
                po_response_body => po_response_body
            );
    END pr_bulk_update_schedule;

END pkg_aox_schedule_api;
/


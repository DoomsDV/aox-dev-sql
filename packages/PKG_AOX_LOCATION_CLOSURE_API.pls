PROMPT CREATE OR REPLACE PACKAGE pkg_aox_location_closure_api
CREATE OR REPLACE PACKAGE pkg_aox_location_closure_api IS

    -- Listar cierres futuros/actuales de una sucursal (o rango de fechas).
    PROCEDURE pr_list_closures(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar cierres org-wide (con closure_group_id que cubre todas las sucursales activas).
    PROCEDURE pr_list_org_closures(
        pi_auth_header   IN  VARCHAR2,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Crear cierre: una sucursal, location_ids[], o apply_all_locations=1 (todas activas).
    -- Si pi_location_id es NULL sin location_ids, se exige apply_all_locations = 1.
    PROCEDURE pr_create_closure(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar un cierre. Si pi_delete_group=1, borra todo el closure_group_id.
    PROCEDURE pr_delete_closure(
        pi_auth_header   IN  VARCHAR2,
        pi_closure_id    IN  NUMBER,
        pi_delete_group  IN  NUMBER DEFAULT 0,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_location_closure_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_location_closure_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_location_closure_api IS

    FUNCTION fn_today_app RETURN DATE IS
    BEGIN
        RETURN TRUNC(CAST(CURRENT_TIMESTAMP AT TIME ZONE pkg_aox_util.fn_app_timezone AS DATE));
    END fn_today_app;

    PROCEDURE pr_assert_manager(pi_auth_header IN VARCHAR2) IS
        v_role_id NUMBER;
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF v_role_id NOT IN (
            pkg_aox_util.fn_rol('ADMIN'),
            pkg_aox_util.fn_rol('RECEPCIONISTA')
        ) THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No tenés permisos para gestionar cierres de sucursal.');
        END IF;
    END pr_assert_manager;

    FUNCTION fn_parse_date_opt(pi_date IN VARCHAR2) RETURN DATE IS
    BEGIN
        IF pi_date IS NULL OR TRIM(pi_date) IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_DATE(TRIM(pi_date), 'YYYY-MM-DD');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20002, 'Formato de fecha inválido. Use YYYY-MM-DD.');
    END fn_parse_date_opt;

    FUNCTION fn_parse_date_req(pi_date IN VARCHAR2) RETURN DATE IS
        v_date DATE;
    BEGIN
        v_date := fn_parse_date_opt(pi_date);
        IF v_date IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 'La fecha es obligatoria (YYYY-MM-DD).');
        END IF;
        RETURN v_date;
    END fn_parse_date_req;

    PROCEDURE pr_assert_location_in_org(
        pi_location_id IN NUMBER,
        pi_org_id      IN NUMBER
    ) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_count
          FROM location l
         WHERE l.id_location = pi_location_id
           AND l.org_id_organization = pi_org_id;

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Sucursal no encontrada en la organización.');
        END IF;
    END pr_assert_location_in_org;

    PROCEDURE pr_list_closures(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_from_date      DATE;
        v_to_date        DATE;
        v_response_json  json_object_t := json_object_t();
        v_data_arr       json_array_t  := json_array_t();
        v_item           json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        pr_assert_location_in_org(pi_location_id, v_org_id);

        v_from_date := fn_parse_date_opt(pi_from_date);
        v_to_date   := fn_parse_date_opt(pi_to_date);

        IF v_from_date IS NULL THEN
            v_from_date := fn_today_app;
        END IF;

        FOR rec IN (
            SELECT
                c.id_location_closure,
                c.loc_id_location,
                c.name,
                c.start_date,
                c.end_date,
                c.is_full_day,
                c.start_time,
                c.end_time,
                c.closure_group_id,
                CASE
                    WHEN c.closure_group_id IS NULL THEN 1
                    ELSE (
                        SELECT COUNT(*)
                          FROM location_closure g
                         WHERE g.org_id_organization = c.org_id_organization
                           AND g.closure_group_id = c.closure_group_id
                    )
                END AS location_count
            FROM location_closure c
            WHERE c.org_id_organization = v_org_id
              AND c.loc_id_location     = pi_location_id
              AND c.end_date >= v_from_date
              AND (v_to_date IS NULL OR c.start_date <= v_to_date)
            ORDER BY c.start_date ASC, c.id_location_closure ASC
        ) LOOP
            v_item := json_object_t();
            v_item.put('id_location_closure', rec.id_location_closure);
            v_item.put('loc_id_location', rec.loc_id_location);
            v_item.put('name', rec.name);
            v_item.put('start_date', TO_CHAR(rec.start_date, 'YYYY-MM-DD'));
            v_item.put('end_date',   TO_CHAR(rec.end_date,   'YYYY-MM-DD'));
            v_item.put('is_full_day', rec.is_full_day);
            v_item.put('start_time', rec.start_time);
            v_item.put('end_time',   rec.end_time);
            v_item.put('location_count', rec.location_count);
            IF rec.closure_group_id IS NULL THEN
                v_item.put_null('closure_group_id');
                v_item.put('scope', 'LOCATION');
            ELSE
                v_item.put('closure_group_id', RAWTOHEX(rec.closure_group_id));
                v_item.put('scope', 'ORG');
            END IF;
            v_data_arr.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session   THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20004)                THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_list_closures;

    PROCEDURE pr_list_org_closures(
        pi_auth_header   IN  VARCHAR2,
        pi_from_date     IN  VARCHAR2 DEFAULT NULL,
        pi_to_date       IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_from_date      DATE;
        v_to_date        DATE;
        v_response_json  json_object_t := json_object_t();
        v_data_arr       json_array_t  := json_array_t();
        v_item           json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_from_date := fn_parse_date_opt(pi_from_date);
        v_to_date   := fn_parse_date_opt(pi_to_date);
        IF v_from_date IS NULL THEN
            v_from_date := fn_today_app;
        END IF;

        -- Un cierre grupal se representa por su primer registro (mismo name/fechas).
        FOR rec IN (
            SELECT
                MIN(c.id_location_closure) AS id_location_closure,
                MIN(c.loc_id_location)     AS loc_id_location,
                c.closure_group_id,
                MIN(c.name)                AS name,
                MIN(c.start_date)          AS start_date,
                MIN(c.end_date)            AS end_date,
                MIN(c.is_full_day)         AS is_full_day,
                MIN(c.start_time)          AS start_time,
                MIN(c.end_time)            AS end_time,
                COUNT(*)                   AS location_count
            FROM location_closure c
            WHERE c.org_id_organization = v_org_id
              AND c.closure_group_id IS NOT NULL
              AND c.end_date >= v_from_date
              AND (v_to_date IS NULL OR c.start_date <= v_to_date)
            GROUP BY c.closure_group_id
            ORDER BY MIN(c.start_date) ASC
        ) LOOP
            v_item := json_object_t();
            v_item.put('id_location_closure', rec.id_location_closure);
            v_item.put('loc_id_location', rec.loc_id_location);
            v_item.put('closure_group_id', RAWTOHEX(rec.closure_group_id));
            v_item.put('name', rec.name);
            v_item.put('start_date', TO_CHAR(rec.start_date, 'YYYY-MM-DD'));
            v_item.put('end_date',   TO_CHAR(rec.end_date,   'YYYY-MM-DD'));
            v_item.put('is_full_day', rec.is_full_day);
            v_item.put('start_time', rec.start_time);
            v_item.put('end_time',   rec.end_time);
            v_item.put('location_count', rec.location_count);
            v_item.put('scope', 'ORG');
            v_data_arr.append(v_item);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session   THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE = -20002                           THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_list_org_closures;

    PROCEDURE pr_create_closure(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_user_id        NUMBER;
        v_json_req       json_object_t;
        v_response_json  json_object_t := json_object_t();
        v_name           VARCHAR2(120);
        v_start_date     DATE;
        v_end_date       DATE;
        v_is_full_day    NUMBER := 1;
        v_start_time     VARCHAR2(5);
        v_end_time       VARCHAR2(5);
        v_apply_all      NUMBER := 0;
        v_group_id       RAW(16);
        v_inserted_ids   json_array_t := json_array_t();
        v_new_id         NUMBER;
        v_loc_ids_arr    json_array_t;
        v_loc_id         NUMBER;
        v_loc_count      NUMBER := 0;
        v_seen           json_object_t := json_object_t();
        v_key            VARCHAR2(40);
        v_active_count   NUMBER;
    BEGIN
        pr_assert_manager(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_name := TRIM(v_json_req.get_string('name'));
        IF v_name IS NULL THEN
            RAISE_APPLICATION_ERROR(-20002, 'El nombre del cierre es obligatorio.');
        END IF;
        IF LENGTH(v_name) > 120 THEN
            RAISE_APPLICATION_ERROR(-20002, 'El nombre excede 120 caracteres.');
        END IF;

        v_start_date := fn_parse_date_req(v_json_req.get_string('start_date'));
        v_end_date   := fn_parse_date_req(v_json_req.get_string('end_date'));

        IF v_end_date < v_start_date THEN
            RAISE_APPLICATION_ERROR(-20002, 'La fecha de fin no puede ser anterior a la de inicio.');
        END IF;

        IF v_json_req.has('is_full_day') THEN
            v_is_full_day := v_json_req.get_number('is_full_day');
        END IF;
        IF v_is_full_day NOT IN (0, 1) THEN
            RAISE_APPLICATION_ERROR(-20002, 'is_full_day debe ser 0 o 1.');
        END IF;

        IF v_is_full_day = 0 THEN
            v_start_time := v_json_req.get_string('start_time');
            v_end_time   := v_json_req.get_string('end_time');
            IF v_start_time IS NULL OR v_end_time IS NULL THEN
                RAISE_APPLICATION_ERROR(-20002, 'Para cierre parcial, start_time y end_time son obligatorios (HH:MM).');
            END IF;
            IF NOT REGEXP_LIKE(v_start_time, '^([01][0-9]|2[0-3]):[0-5][0-9]$')
               OR NOT REGEXP_LIKE(v_end_time, '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
                RAISE_APPLICATION_ERROR(-20002, 'Formato de hora inválido. Use HH:MM (24h).');
            END IF;
            IF v_start_time >= v_end_time THEN
                RAISE_APPLICATION_ERROR(-20002, 'start_time debe ser menor a end_time.');
            END IF;
        ELSE
            v_start_time := NULL;
            v_end_time   := NULL;
        END IF;

        IF v_json_req.has('apply_all_locations') THEN
            v_apply_all := v_json_req.get_number('apply_all_locations');
        END IF;
        IF v_apply_all NOT IN (0, 1) THEN
            RAISE_APPLICATION_ERROR(-20002, 'apply_all_locations debe ser 0 o 1.');
        END IF;

        -- location_ids[] opcional (subset de sucursales)
        IF v_apply_all = 0 AND v_json_req.has('location_ids') AND v_json_req.get('location_ids').is_array THEN
            v_loc_ids_arr := TREAT(v_json_req.get('location_ids') AS json_array_t);
            FOR i IN 0 .. v_loc_ids_arr.get_size() - 1 LOOP
                BEGIN
                    v_loc_id := v_loc_ids_arr.get_number(i);
                EXCEPTION
                    WHEN OTHERS THEN
                        RAISE_APPLICATION_ERROR(-20002, 'location_ids contiene un valor inválido.');
                END;
                IF v_loc_id IS NULL OR v_loc_id <= 0 THEN
                    CONTINUE;
                END IF;
                v_key := TO_CHAR(v_loc_id);
                IF v_seen.has(v_key) THEN
                    CONTINUE;
                END IF;
                v_seen.put(v_key, 1);

                pr_assert_location_in_org(v_loc_id, v_org_id);
                SELECT COUNT(*)
                  INTO v_active_count
                  FROM location
                 WHERE id_location = v_loc_id
                   AND org_id_organization = v_org_id
                   AND is_active = 1;
                IF v_active_count = 0 THEN
                    RAISE_APPLICATION_ERROR(-20002, 'La sucursal ' || v_loc_id || ' no está activa.');
                END IF;

                v_loc_count := v_loc_count + 1;
            END LOOP;

            IF v_loc_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20002, 'Seleccioná al menos una sucursal.');
            END IF;

            IF v_loc_count > 1 THEN
                v_group_id := SYS_GUID();
            END IF;

            FOR i IN 0 .. v_loc_ids_arr.get_size() - 1 LOOP
                BEGIN
                    v_loc_id := v_loc_ids_arr.get_number(i);
                EXCEPTION
                    WHEN OTHERS THEN CONTINUE;
                END;
                IF v_loc_id IS NULL OR v_loc_id <= 0 THEN
                    CONTINUE;
                END IF;
                -- Insertar una sola vez por id (ya dedupeado en v_seen; re-validamos con flag)
                v_key := TO_CHAR(v_loc_id);
                IF NOT v_seen.has(v_key) THEN
                    CONTINUE;
                END IF;
                -- Marcar como insertado para no duplicar
                IF v_seen.get_number(v_key) = 2 THEN
                    CONTINUE;
                END IF;
                v_seen.put(v_key, 2);

                INSERT INTO location_closure (
                    org_id_organization, loc_id_location, name,
                    start_date, end_date, is_full_day, start_time, end_time,
                    closure_group_id, created_by
                ) VALUES (
                    v_org_id, v_loc_id, v_name,
                    v_start_date, v_end_date, v_is_full_day, v_start_time, v_end_time,
                    v_group_id, v_user_id
                ) RETURNING id_location_closure INTO v_new_id;

                v_inserted_ids.append(v_new_id);
            END LOOP;

        ELSIF v_apply_all = 0 THEN
            IF pi_location_id IS NULL THEN
                RAISE_APPLICATION_ERROR(-20002, 'Debés indicar una sucursal, location_ids o marcar "Aplicar a todas".');
            END IF;
            pr_assert_location_in_org(pi_location_id, v_org_id);
            INSERT INTO location_closure (
                org_id_organization, loc_id_location, name,
                start_date, end_date, is_full_day, start_time, end_time,
                closure_group_id, created_by
            ) VALUES (
                v_org_id, pi_location_id, v_name,
                v_start_date, v_end_date, v_is_full_day, v_start_time, v_end_time,
                NULL, v_user_id
            ) RETURNING id_location_closure INTO v_new_id;

            v_inserted_ids.append(v_new_id);
        ELSE
            v_group_id := SYS_GUID();

            FOR rec IN (
                SELECT id_location
                  FROM location
                 WHERE org_id_organization = v_org_id
                   AND is_active = 1
                 ORDER BY id_location ASC
            ) LOOP
                INSERT INTO location_closure (
                    org_id_organization, loc_id_location, name,
                    start_date, end_date, is_full_day, start_time, end_time,
                    closure_group_id, created_by
                ) VALUES (
                    v_org_id, rec.id_location, v_name,
                    v_start_date, v_end_date, v_is_full_day, v_start_time, v_end_time,
                    v_group_id, v_user_id
                ) RETURNING id_location_closure INTO v_new_id;

                v_inserted_ids.append(v_new_id);
            END LOOP;

            IF v_inserted_ids.get_size() = 0 THEN
                ROLLBACK;
                RAISE_APPLICATION_ERROR(-20002, 'No hay sucursales activas para aplicar el cierre.');
            END IF;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Cierre creado correctamente.');
        v_response_json.put('inserted_ids', v_inserted_ids);
        IF v_group_id IS NOT NULL THEN
            v_response_json.put('closure_group_id', RAWTOHEX(v_group_id));
        END IF;
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session   THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                WHEN SQLCODE IN (-20002, -20004)                THEN pkg_aox_util.c_bad_request_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_create_closure;

    PROCEDURE pr_delete_closure(
        pi_auth_header   IN  VARCHAR2,
        pi_closure_id    IN  NUMBER,
        pi_delete_group  IN  NUMBER DEFAULT 0,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_group_id       RAW(16);
        v_deleted        NUMBER := 0;
        v_response_json  json_object_t := json_object_t();
    BEGIN
        pr_assert_manager(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            SELECT closure_group_id
              INTO v_group_id
              FROM location_closure
             WHERE id_location_closure = pi_closure_id
               AND org_id_organization = v_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                po_status_code := pkg_aox_util.c_not_found_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Cierre no encontrado.');
                po_response_body := v_response_json.to_clob();
                RETURN;
        END;

        IF NVL(pi_delete_group, 0) = 1 AND v_group_id IS NOT NULL THEN
            DELETE FROM location_closure
             WHERE org_id_organization = v_org_id
               AND closure_group_id    = v_group_id;
        ELSE
            DELETE FROM location_closure
             WHERE id_location_closure = pi_closure_id
               AND org_id_organization = v_org_id;
        END IF;

        v_deleted := SQL%ROWCOUNT;
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Cierre eliminado.');
        v_response_json.put('deleted_count', v_deleted);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            po_status_code := CASE
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_session   THEN pkg_aox_util.c_unauthorized_code
                WHEN SQLCODE = pkg_aox_util.c_sqlcode_forbidden THEN pkg_aox_util.c_forbidden_code
                ELSE pkg_aox_util.c_internal_error_code
            END;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.fn_resolve_api_code(po_status_code, SQLCODE, SQLERRM),
                pi_message       => pkg_aox_util.fn_clean_sqlerrm(SQLERRM),
                po_response_body => po_response_body
            );
    END pr_delete_closure;

END pkg_aox_location_closure_api;
/


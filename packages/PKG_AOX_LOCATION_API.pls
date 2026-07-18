PROMPT CREATE OR REPLACE PACKAGE pkg_aox_location_api
CREATE OR REPLACE PACKAGE pkg_aox_location_api IS

    -- Listar sucursales con paginación
    PROCEDURE pr_list_locations(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener una sucursal por ID
    PROCEDURE pr_get_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Crear una sucursal
    PROCEDURE pr_create_location(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualizar una sucursal
    PROCEDURE pr_update_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar una sucursal
    PROCEDURE pr_delete_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar sucursales activas (LOV)
    PROCEDURE pr_list_locations_lov(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_location_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_location_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_location_api IS

    -- Función Privada: Validar inputs de Sucursal
    FUNCTION fn_validate_loc_inputs(
        pi_name     IN VARCHAR2,
        pi_address  IN VARCHAR2,
        pi_city_id  IN NUMBER,
        pi_dept_id  IN NUMBER,
        pi_active   IN NUMBER
    ) RETURN json_array_t IS
        v_errors             json_array_t := json_array_t();
        v_error              json_object_t;
        v_name_max_length    NUMBER;
        v_address_max_length NUMBER;
    BEGIN
        -- Longitudes dinámicas
        BEGIN SELECT data_length INTO v_name_max_length FROM user_tab_columns WHERE table_name = 'LOCATION' AND column_name = 'NAME'; EXCEPTION WHEN NO_DATA_FOUND THEN v_name_max_length := 100; END;
        BEGIN SELECT data_length INTO v_address_max_length FROM user_tab_columns WHERE table_name = 'LOCATION' AND column_name = 'ADDRESS'; EXCEPTION WHEN NO_DATA_FOUND THEN v_address_max_length := 255; END;

        IF pi_name IS NULL OR TRIM(pi_name) = '' THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'El nombre es obligatorio.'); v_errors.append(v_error);
        ELSIF LENGTH(pi_name) > v_name_max_length THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'Excede ' || v_name_max_length || ' caracteres.'); v_errors.append(v_error);
        END IF;

        IF pi_address IS NULL OR TRIM(pi_address) = '' THEN
            v_error := json_object_t(); v_error.put('field', 'address'); v_error.put('message', 'La dirección es obligatoria.'); v_errors.append(v_error);
        ELSIF LENGTH(pi_address) > v_address_max_length THEN
            v_error := json_object_t(); v_error.put('field', 'address'); v_error.put('message', 'Excede ' || v_address_max_length || ' caracteres.'); v_errors.append(v_error);
        END IF;

        IF pi_city_id IS NULL THEN
            v_error := json_object_t(); v_error.put('field', 'cit_id_city'); v_error.put('message', 'La ciudad es obligatoria.'); v_errors.append(v_error);
        END IF;

        IF pi_dept_id IS NULL THEN
            v_error := json_object_t(); v_error.put('field', 'dep_id_department'); v_error.put('message', 'El departamento es obligatorio.'); v_errors.append(v_error);
        END IF;

        IF pi_active IS NOT NULL AND pi_active NOT IN (0, 1) THEN
            v_error := json_object_t(); v_error.put('field', 'is_active'); v_error.put('message', 'El estado debe ser 0 o 1.'); v_errors.append(v_error);
        END IF;

        RETURN v_errors;
    END fn_validate_loc_inputs;

    -- Procedimiento: Listar (GET)
    PROCEDURE pr_list_locations(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_locs_arr      json_array_t  := json_array_t();
        v_loc_obj       json_object_t;
        v_meta_obj      json_object_t;
        v_city_obj      json_object_t;
        v_dept_obj      json_object_t;

        v_page          NUMBER := NVL(pi_page, 1);
        v_limit         NUMBER := NVL(pi_limit, 9);
        v_offset        NUMBER;
        v_total_records NUMBER := 0;
        v_total_pages   NUMBER := 0;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF v_page < 1 THEN v_page := 1; END IF;
        v_offset := (v_page - 1) * v_limit;

        SELECT COUNT(*)
        INTO v_total_records
        FROM location
        WHERE org_id_organization = v_org_id
          AND (pi_is_active IS NULL OR is_active = pi_is_active);
        v_total_pages := CEIL(v_total_records / v_limit);

        FOR rec IN (
            SELECT
                l.id_location,
                l.name,
                l.address,
                l.cit_id_city,
                c.description AS city_name,          -- Obtenemos el nombre de la ciudad
                l.dep_id_department,
                d.description AS department_name,    -- Obtenemos el nombre del departamento
                l.latitude,
                l.longitude,
                l.is_active,
                l.created_at
            FROM location l
            JOIN cities c ON l.cit_id_city = c.id_city
            JOIN departments d ON l.dep_id_department = d.id_department
            WHERE l.org_id_organization = v_org_id
              AND (pi_is_active IS NULL OR l.is_active = pi_is_active)
            ORDER BY l.id_location DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_loc_obj := json_object_t();
            v_loc_obj.put('id_location', rec.id_location);
            v_loc_obj.put('name'    , rec.name);
            v_loc_obj.put('address' , rec.address);

            -- Construimos el objeto City
            v_city_obj := json_object_t();
            v_city_obj.put('id_city', rec.cit_id_city);
            v_city_obj.put('name', rec.city_name);
            v_loc_obj.put('city', v_city_obj);

            -- Construimos el objeto Department
            v_dept_obj := json_object_t();
            v_dept_obj.put('id_department', rec.dep_id_department);
            v_dept_obj.put('name', rec.department_name);
            v_loc_obj.put('department', v_dept_obj);

            v_loc_obj.put('latitude', rec.latitude);
            v_loc_obj.put('longitude', rec.longitude);
            v_loc_obj.put('is_active', rec.is_active);
            v_loc_obj.put('created_at', TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            v_locs_arr.append(v_loc_obj);
        END LOOP;

        v_meta_obj := json_object_t();
        v_meta_obj.put('current_page', v_page);
        v_meta_obj.put('per_page', v_limit);
        v_meta_obj.put('total_records', v_total_records);
        v_meta_obj.put('total_pages', v_total_pages);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta', v_meta_obj);
        v_response_json.put('data', v_locs_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_locations;

    -- Procedimiento: Obtener por ID (GET)
    PROCEDURE pr_get_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_loc_obj       json_object_t;
        v_city_obj      json_object_t;
        v_dept_obj      json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT
                l.id_location,
                l.name,
                l.address,
                l.cit_id_city,
                c.description AS city_name,
                l.dep_id_department,
                d.description AS department_name,
                l.latitude,
                l.longitude,
                l.is_active,
                l.created_at
            FROM location l
            JOIN cities c ON l.cit_id_city = c.id_city
            JOIN departments d ON l.dep_id_department = d.id_department
            WHERE l.id_location = pi_location_id AND l.org_id_organization = v_org_id
        ) LOOP
            v_loc_obj := json_object_t();
            v_loc_obj.put('id_location', rec.id_location);
            v_loc_obj.put('name', rec.name);
            v_loc_obj.put('address', rec.address);

            v_city_obj := json_object_t();
            v_city_obj.put('id_city', rec.cit_id_city);
            v_city_obj.put('name', rec.city_name);
            v_loc_obj.put('city', v_city_obj);

            v_dept_obj := json_object_t();
            v_dept_obj.put('id_department', rec.dep_id_department);
            v_dept_obj.put('name', rec.department_name);
            v_loc_obj.put('department', v_dept_obj);

            v_loc_obj.put('latitude', rec.latitude);
            v_loc_obj.put('longitude', rec.longitude);
            v_loc_obj.put('is_active', rec.is_active);
            v_loc_obj.put('created_at', TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_loc_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status', 'error');
        v_response_json.put('message', 'Sucursal no encontrada.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_location;

    -- Procedimiento: Crear (POST)
    PROCEDURE pr_create_location(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t;
        v_new_id            NUMBER;

        v_name              location.name%TYPE;
        v_address           location.address%TYPE;
        v_city_id           location.cit_id_city%TYPE;
        v_dept_id           location.dep_id_department%TYPE;
        v_lat               location.latitude%TYPE;
        v_lon               location.longitude%TYPE;
        v_is_active         location.is_active%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            v_address  := v_json_req.get_string('address');
            v_city_id  := v_json_req.get_number('cit_id_city');
            v_dept_id  := v_json_req.get_number('dep_id_department');
            IF v_json_req.has('latitude') THEN v_lat := v_json_req.get_number('latitude'); END IF;
            IF v_json_req.has('longitude') THEN v_lon := v_json_req.get_number('longitude'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); ELSE v_is_active := 1; END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_validation_errors := fn_validate_loc_inputs(v_name, v_address, v_city_id, v_dept_id, v_is_active);

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Errores de validación en los campos enviados.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        INSERT INTO location (org_id_organization, name, address, cit_id_city, dep_id_department, latitude, longitude, is_active)
        VALUES (v_org_id, TRIM(v_name), TRIM(v_address), v_city_id, v_dept_id, v_lat, v_lon, v_is_active)
        RETURNING id_location INTO v_new_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Sucursal creada correctamente.');
        v_response_json.put('id_location', v_new_id);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_location;

    -- Procedimiento: Actualizar (PUT)
    PROCEDURE pr_update_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t;

        v_name              location.name%TYPE;
        v_address           location.address%TYPE;
        v_city_id           location.cit_id_city%TYPE;
        v_dept_id           location.dep_id_department%TYPE;
        v_lat               location.latitude%TYPE;
        v_lon               location.longitude%TYPE;
        v_is_active         location.is_active%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            v_address  := v_json_req.get_string('address');
            v_city_id  := v_json_req.get_number('cit_id_city');
            v_dept_id  := v_json_req.get_number('dep_id_department');
            IF v_json_req.has('latitude') THEN v_lat := v_json_req.get_number('latitude'); END IF;
            IF v_json_req.has('longitude') THEN v_lon := v_json_req.get_number('longitude'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_validation_errors := fn_validate_loc_inputs(v_name, v_address, v_city_id, v_dept_id, NVL(v_is_active, 1));

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Errores de validación en los campos enviados.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        UPDATE location
        SET name              = TRIM(v_name),
            address           = TRIM(v_address),
            cit_id_city       = v_city_id,
            dep_id_department = v_dept_id,
            latitude          = v_lat,
            longitude         = v_lon,
            is_active         = NVL(v_is_active, is_active)
        WHERE id_location = pi_location_id AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Sucursal no encontrada o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Sucursal actualizada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_update_location;

    -- Procedimiento: Eliminar (DELETE)
    PROCEDURE pr_delete_location(
        pi_auth_header   IN  VARCHAR2,
        pi_location_id   IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        DELETE FROM location
        WHERE id_location = pi_location_id AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Sucursal no encontrada o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Sucursal eliminada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            IF SQLCODE = -2292 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_conflict,
                    pi_message       => 'No se puede eliminar la sucursal porque está en uso.',
                    po_response_body => po_response_body
                );
            ELSE
                pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            END IF;
    END pr_delete_location;

    PROCEDURE pr_list_locations_lov(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_loc_obj       json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT id_location, name, address
            FROM location
            WHERE org_id_organization = v_org_id AND is_active = 1
            ORDER BY name ASC
        ) LOOP
            v_loc_obj := json_object_t();
            v_loc_obj.put('id_location' , rec.id_location);
            v_loc_obj.put('name'        , rec.name);
            v_loc_obj.put('address'     , rec.address);
            v_data_arr.append(v_loc_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_locations_lov;

END pkg_aox_location_api;
/


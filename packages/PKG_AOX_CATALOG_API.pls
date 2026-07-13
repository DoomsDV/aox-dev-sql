PROMPT CREATE OR REPLACE PACKAGE pkg_aox_catalog_api
CREATE OR REPLACE PACKAGE pkg_aox_catalog_api IS

    -- Listar todos los departamentos (Sin paginación)
    PROCEDURE pr_list_departments(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar ciudades filtradas por departamento (Sin paginación)
    PROCEDURE pr_list_cities(
        pi_department_id IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar todos los roles del sistema (Sin paginación)
    PROCEDURE pr_list_roles(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar días de la semana
    PROCEDURE pr_list_days(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Listar especialidades de organización activas
    PROCEDURE pr_list_org_specialties(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_get_location(
        pi_id            IN location.id_location%TYPE,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_catalog_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_catalog_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_catalog_api IS

    -- Procedimiento: Listar Departamentos
    PROCEDURE pr_list_departments(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item_obj      json_object_t;
    BEGIN
        -- Consulta sin paginación, ordenada alfabéticamente
        FOR rec IN (
            SELECT
              id_department,
              dnit_code,
              description
            FROM departments
            ORDER BY description ASC
        ) LOOP
            v_item_obj := json_object_t();
            v_item_obj.put('id_department', rec.id_department);
            v_item_obj.put('description'  , rec.description);
            v_data_arr.append(v_item_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_departments;

    -- Procedimiento: Listar Ciudades por Departamento
    PROCEDURE pr_list_cities(
        pi_department_id IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item_obj      json_object_t;
    BEGIN
        -- Validar que nos envíen el departamento
        IF pi_department_id IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'El ID del departamento es obligatorio para buscar ciudades.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Consulta filtrada por el FK y ordenada alfabéticamente
        FOR rec IN (
            SELECT
              id_city,
              dep_id_department,
              dnit_code,
              description
            FROM cities
            WHERE dep_id_department = pi_department_id
            ORDER BY description ASC
        ) LOOP
            v_item_obj := json_object_t();
            v_item_obj.put('id_city'    , rec.id_city);
            v_item_obj.put('description', rec.description);
            v_data_arr.append(v_item_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_cities;

    -- Procedimiento: Listar Roles (Catálogo)
    PROCEDURE pr_list_roles(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item_obj      json_object_t;
    BEGIN
        -- Consulta directa sin filtros de organización
        FOR rec IN (
            SELECT id_role, name, description, is_active, created_at
            FROM role
            -- Opcional: Si solo quieres mostrar los roles activos en los formularios
            WHERE is_active = 1
            ORDER BY name ASC
        ) LOOP
            v_item_obj := json_object_t();
            v_item_obj.put('id_role'    , rec.id_role);
            v_item_obj.put('name'       , rec.name);
            v_item_obj.put('description', rec.description);
            v_item_obj.put('is_active'  , rec.is_active);
            v_item_obj.put('created_at' , TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            v_data_arr.append(v_item_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_roles;

    -- Procedimiento: Listar Días
    PROCEDURE pr_list_days(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_day_obj       json_object_t;

        -- Definimos el diccionario en memoria
        TYPE t_days IS VARRAY(7) OF VARCHAR2(20);
        v_days t_days := t_days('Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo');
    BEGIN
        FOR i IN 1..7 LOOP
            v_day_obj := json_object_t();
            v_day_obj.put('id_day', i);
            v_day_obj.put('name'  , v_days(i));
            v_data_arr.append(v_day_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_days;

    -- Procedimiento: Listar Especialidades de Organización
    PROCEDURE pr_list_org_specialties(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item_obj      json_object_t;
    BEGIN
        -- Consulta de especialidades activas ordenadas alfabéticamente
        FOR rec IN (
            SELECT
                id_org_specialty,
                name,
                description
            FROM org_specialty
            WHERE is_active = 1
            ORDER BY created_at ASC
        ) LOOP
            v_item_obj := json_object_t();
            v_item_obj.put('id_org_specialty', rec.id_org_specialty);
            v_item_obj.put('name'            , rec.name);
            v_item_obj.put('description'     , rec.description);

            v_data_arr.append(v_item_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_org_specialties;

    PROCEDURE pr_get_location(
        pi_id            IN location.id_location%TYPE,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
        v_data_arr      json_array_t  := json_array_t();
        v_item_obj      json_object_t;
    BEGIN
        -- Consulta sin paginación, ordenada alfabéticamente
        FOR rec IN (
            SELECT
              id_location,
              address,
              latitude,
              longitude
            FROM location
            WHERE id_location = pi_id
            ORDER BY id_location ASC
        ) LOOP
            v_item_obj := json_object_t();
            v_item_obj.put('id_location', rec.id_location);
            v_item_obj.put('address'  , rec.address);
            v_item_obj.put('latitude'  , rec.latitude);
            v_item_obj.put('longitude'  , rec.longitude);
            v_data_arr.append(v_item_obj);
        END LOOP;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_location;

END pkg_aox_catalog_api;
/


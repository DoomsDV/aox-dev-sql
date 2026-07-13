PROMPT CREATE OR REPLACE PACKAGE pkg_aox_service_api
CREATE OR REPLACE PACKAGE pkg_aox_service_api IS

    -- Procedimiento para listar los servicios de la organización
    PROCEDURE pr_list_services(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL, -- Nuevo parámetro opcional
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Procedimiento para crear un nuevo servicio
    PROCEDURE pr_create_service(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Procedimiento para obtener un servicio específico por su ID
    PROCEDURE pr_get_service(
        pi_auth_header   IN  VARCHAR2,
        pi_service_id    IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    FUNCTION fn_validate_service_inputs(
        pi_name     IN VARCHAR2,
        pi_duration IN NUMBER,
        pi_price    IN NUMBER,
        pi_active   IN NUMBER
    ) RETURN json_array_t;

    procedure pr_update_service(
        pi_auth_header   in  varchar2,
        pi_service_id    in  number,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    );

    procedure pr_delete_service(
        pi_auth_header   in  varchar2,
        pi_service_id    in  number,
        po_status_code   out number,
        po_response_body out clob
    );

    -- Listar servicios activos para listas desplegables (Sin paginación)
    PROCEDURE pr_list_services_lov(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );
END pkg_aox_service_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_service_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_service_api IS

    -- Procedimiento: Listar Servicios (GET)
    PROCEDURE pr_list_services(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL, -- Nuevo parámetro
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_services_arr  json_array_t  := json_array_t();
        v_service_obj   json_object_t;
        v_meta_obj      json_object_t;

        -- Variables para la paginación
        v_page          NUMBER := NVL(pi_page, 1);
        v_limit         NUMBER := NVL(pi_limit, 9);
        v_offset        NUMBER;
        v_total_records NUMBER := 0;
        v_total_pages   NUMBER := 0;
    BEGIN
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Calcular el Offset
        IF v_page < 1 THEN v_page := 1; END IF;
        v_offset := (v_page - 1) * v_limit;

        -- 3. Obtener el total de registros (Aplicando el filtro)
        SELECT COUNT(*)
        INTO v_total_records
        FROM service
        WHERE org_id_organization = v_org_id
          AND (pi_is_active IS NULL OR is_active = pi_is_active);

        v_total_pages := CEIL(v_total_records / v_limit);

        -- 4. Consultar servicios (Aplicando el filtro)
        FOR rec IN (
            SELECT
                id_service,
                name,
                duration_minutes,
                price,
                is_active,
                created_at,
                requires_deposit,
                deposit_type,
                deposit_value
            FROM service
            WHERE org_id_organization = v_org_id
              AND (pi_is_active IS NULL OR is_active = pi_is_active)
            ORDER BY id_service DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_service_obj := json_object_t();
            v_service_obj.put('id_service'      , rec.id_service);
            v_service_obj.put('name'            , rec.name);
            v_service_obj.put('duration_minutes', rec.duration_minutes);
            v_service_obj.put('price'           , rec.price);
            v_service_obj.put('is_active'       , rec.is_active);
            v_service_obj.put('requires_deposit', rec.requires_deposit);
            v_service_obj.put('deposit_type'    , rec.deposit_type);
            v_service_obj.put('deposit_value'   , rec.deposit_value);
            v_service_obj.put('created_at'      , TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_services_arr.append(v_service_obj);
        END LOOP;

        -- 5. Construir objeto Meta para el Frontend
        v_meta_obj := json_object_t();
        v_meta_obj.put('current_page', v_page);
        v_meta_obj.put('per_page', v_limit);
        v_meta_obj.put('total_records', v_total_records);
        v_meta_obj.put('total_pages', v_total_pages);

        -- 6. Responder
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta', v_meta_obj);
        v_response_json.put('data', v_services_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_services;

    -- Procedimiento: Crear Servicio (POST)
    PROCEDURE pr_create_service(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t  := json_array_t();
        v_error             json_object_t;
        v_new_id            NUMBER;

        -- Campos del payload
        v_name              service.name%TYPE;
        v_duration          service.duration_minutes%TYPE;
        v_price             service.price%TYPE;
        v_is_active         service.is_active%TYPE;
        v_requires_deposit  service.requires_deposit%TYPE := 0;
        v_deposit_type      service.deposit_type%TYPE;
        v_deposit_value     service.deposit_value%TYPE;
    BEGIN
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Parsear el Body
        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            v_duration := v_json_req.get_number('duration_minutes');
            -- Intentamos leer price y active (si no vienen, serán nulos)
            IF v_json_req.has('price') THEN v_price := v_json_req.get_number('price'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); ELSE v_is_active := 1; END IF;
            IF v_json_req.has('requires_deposit') THEN v_requires_deposit := v_json_req.get_number('requires_deposit'); END IF;
            IF v_json_req.has('deposit_type') THEN v_deposit_type := UPPER(TRIM(v_json_req.get_string('deposit_type'))); END IF;
            IF v_json_req.has('deposit_value') THEN v_deposit_value := v_json_req.get_number('deposit_value'); END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        -- 3. Validaciones manuales basadas en las constraints de tu tabla
        -- 3. Validar entradas dinámicamente
        v_validation_errors := fn_validate_service_inputs(
            pi_name     => v_name,
            pi_duration => v_duration,
            pi_price    => v_price,
            pi_active   => v_is_active
        );

        -- Si hay errores, retornar 400 Bad Request
        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación en los campos enviados.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- Gate: senas requieren plan Premium + Ajustes → Pagos habilitado (SIPAP).
        IF NVL(v_requires_deposit, 0) = 1 THEN
            pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'DEPOSIT_COLLECTION');
            IF pkg_aox_payment_settings_api.fn_org_deposits_enabled(v_org_id) = 0 THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_forbidden,
                    'Habilita el cobro de senas en Ajustes → Pagos (politica y datos SIPAP) antes de exigir seña en un servicio.'
                );
            END IF;
        END IF;

        -- 3.1 Validaciones de Seña (si aplica)
        IF v_requires_deposit IS NOT NULL AND v_requires_deposit NOT IN (0, 1) THEN
            v_error := json_object_t(); v_error.put('field', 'requires_deposit'); v_error.put('message', 'requires_deposit debe ser 0 o 1.'); v_validation_errors.append(v_error);
        END IF;

        IF NVL(v_requires_deposit, 0) = 0 THEN
            v_deposit_type  := NULL;
            v_deposit_value := NULL;
        ELSE
            IF v_deposit_type NOT IN ('PERCENT', 'FIXED') THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_type'); v_error.put('message', 'deposit_type debe ser PERCENT o FIXED.'); v_validation_errors.append(v_error);
            END IF;
            IF v_deposit_value IS NULL OR v_deposit_value <= 0 THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_value'); v_error.put('message', 'deposit_value es obligatorio y debe ser mayor a 0.'); v_validation_errors.append(v_error);
            ELSIF v_deposit_type = 'PERCENT' AND (v_deposit_value < 1 OR v_deposit_value > 100) THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_value'); v_error.put('message', 'deposit_value debe estar entre 1 y 100 para porcentaje.'); v_validation_errors.append(v_error);
            END IF;
        END IF;

        IF v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación en los campos enviados.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- 4. Insertar en la tabla
        insert into service (
          org_id_organization,
          name,
          duration_minutes,
          price,
          is_active,
          requires_deposit,
          deposit_type,
          deposit_value
        )
        values (
          v_org_id,
          trim(v_name),
          v_duration,
          v_price,
          v_is_active,
          NVL(v_requires_deposit, 0),
          v_deposit_type,
          v_deposit_value
        )
        returning id_service into v_new_id;

        commit;

        -- 5. Respuesta exitosa 201 Created
        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status'    , 'success');
        v_response_json.put('message'   , 'Servicio creado correctamente.');
        v_response_json.put('id_service', v_new_id);
        po_response_body := v_response_json.to_clob();

    exception
        when others then
            rollback;
            if sqlcode = -20001 then po_status_code := pkg_aox_util.c_unauthorized_code; -- Unauthorized JWT
            elsif sqlcode = -20002 then po_status_code := pkg_aox_util.c_bad_request_code; -- Bad JSON
            else po_status_code := pkg_aox_util.c_internal_error_code; end if;

            v_response_json.put('status', 'error');
            v_response_json.put('message', regexp_replace(sqlerrm, '^ORA-[0-9]+: ', ''));
            po_response_body := v_response_json.to_clob();
    end pr_create_service;

    -- Procedimiento: Obtener Servicio por ID (GET)
    procedure pr_get_service(
        pi_auth_header   in  varchar2,
        pi_service_id    in  number,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id           number;
        v_response_json    json_object_t := json_object_t();
        v_service_obj      json_object_t;

        -- Variables para recibir los datos de la tabla
        v_id_service       service.id_service%TYPE;
        v_name             service.name%TYPE;
        v_duration         service.duration_minutes%TYPE;
        v_price            service.price%TYPE;
        v_is_active        service.is_active%TYPE;
        v_requires_deposit service.requires_deposit%TYPE;
        v_deposit_type     service.deposit_type%TYPE;
        v_deposit_value    service.deposit_value%TYPE;
        v_created_at       service.created_at%TYPE;
    begin
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Consultar el servicio específico
        begin
            select
              id_service,
              name,
              duration_minutes,
              price,
              is_active,
              requires_deposit,
              deposit_type,
              deposit_value,
              created_at
            into
              v_id_service,
              v_name,
              v_duration,
              v_price,
              v_is_active,
              v_requires_deposit,
              v_deposit_type,
              v_deposit_value,
              v_created_at
            from service
            where id_service          = pi_service_id
              and org_id_organization = v_org_id; -- ¡Seguridad anti-IDOR!

            -- 3. Construir la respuesta JSON exitosa
            v_service_obj := json_object_t();
            v_service_obj.put('id_service'      , v_id_service);
            v_service_obj.put('name'            , v_name);
            v_service_obj.put('duration_minutes', v_duration);
            v_service_obj.put('price'           , v_price);
            v_service_obj.put('is_active'       , v_is_active);
            v_service_obj.put('requires_deposit', v_requires_deposit);
            v_service_obj.put('deposit_type'    , v_deposit_type);
            v_service_obj.put('deposit_value'   , v_deposit_value);
            v_service_obj.put('created_at'      , TO_CHAR(v_created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            po_status_code := pkg_aox_util.c_success_ok_code; -- OK
            v_response_json.put('status', 'success');
            v_response_json.put('data'  , v_service_obj);
            po_response_body := v_response_json.to_clob();

        exception
            when no_data_found then
                -- 4. Si no existe o no le pertenece a esta organización
                po_status_code := pkg_aox_util.c_not_found_code; -- Not Found
                v_response_json.put('status'  , 'error');
                v_response_json.put('message' , 'Servicio no encontrado.');
                po_response_body := v_response_json.to_clob();
        end;

    exception
        when others then
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    end pr_get_service;

    -- Procedimiento: Actualizar Servicio (PUT)
    procedure pr_update_service(
        pi_auth_header   in  varchar2,
        pi_service_id    in  number,
        pi_body          in  clob,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id            number;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t  := json_array_t();
        v_error             json_object_t;

        -- campos del payload
        v_name              service.name%type;
        v_duration          service.duration_minutes%type;
        v_price             service.price%type;
        v_is_active         service.is_active%type;
        v_requires_deposit  service.requires_deposit%TYPE;
        v_deposit_type      service.deposit_type%TYPE;
        v_deposit_value     service.deposit_value%TYPE;
    begin
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Parsear el Body
        begin
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            v_duration := v_json_req.get_number('duration_minutes');
            IF v_json_req.has('price') THEN v_price := v_json_req.get_number('price'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); END IF;
            IF v_json_req.has('requires_deposit') THEN v_requires_deposit := v_json_req.get_number('requires_deposit'); END IF;
            IF v_json_req.has('deposit_type') THEN v_deposit_type := UPPER(TRIM(v_json_req.get_string('deposit_type'))); END IF;
            IF v_json_req.has('deposit_value') THEN v_deposit_value := v_json_req.get_number('deposit_value'); END IF;
        exception
            when others then
                raise_application_error(-20002, 'JSON inválido o malformado.');
        end;

        -- 3. Validaciones de negocio
        -- 3. Validar entradas dinámicamente
        v_validation_errors := fn_validate_service_inputs(
            pi_name     => v_name,
            pi_duration => v_duration,
            pi_price    => v_price,
            pi_active   => v_is_active
        );

        if v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación en los campos enviados.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- Gate: senas requieren plan Premium + Ajustes → Pagos habilitado (SIPAP).
        IF NVL(v_requires_deposit, 0) = 1 THEN
            pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'DEPOSIT_COLLECTION');
            IF pkg_aox_payment_settings_api.fn_org_deposits_enabled(v_org_id) = 0 THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_forbidden,
                    'Habilita el cobro de senas en Ajustes → Pagos (politica y datos SIPAP) antes de exigir seña en un servicio.'
                );
            END IF;
        END IF;

        -- Validaciones de Seña (si aplica)
        IF v_requires_deposit IS NOT NULL AND v_requires_deposit NOT IN (0, 1) THEN
            v_error := json_object_t(); v_error.put('field', 'requires_deposit'); v_error.put('message', 'requires_deposit debe ser 0 o 1.'); v_validation_errors.append(v_error);
        END IF;

        IF NVL(v_requires_deposit, 0) = 0 THEN
            v_deposit_type  := NULL;
            v_deposit_value := NULL;
        ELSE
            IF v_deposit_type NOT IN ('PERCENT', 'FIXED') THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_type'); v_error.put('message', 'deposit_type debe ser PERCENT o FIXED.'); v_validation_errors.append(v_error);
            END IF;
            IF v_deposit_value IS NULL OR v_deposit_value <= 0 THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_value'); v_error.put('message', 'deposit_value es obligatorio y debe ser mayor a 0.'); v_validation_errors.append(v_error);
            ELSIF v_deposit_type = 'PERCENT' AND (v_deposit_value < 1 OR v_deposit_value > 100) THEN
                v_error := json_object_t(); v_error.put('field', 'deposit_value'); v_error.put('message', 'deposit_value debe estar entre 1 y 100 para porcentaje.'); v_validation_errors.append(v_error);
            END IF;
        END IF;

        IF v_validation_errors.get_size() > 0 then
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Errores de validación en los campos enviados.');
            v_response_json.put('errors'  , v_validation_errors);
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        -- 4. Ejecutar el UPDATE
        update service
        set name             = trim(v_name),
            duration_minutes = v_duration,
            price            = v_price,
            is_active        = nvl(v_is_active, is_active), -- si no envían is_active, conserva el actual
            requires_deposit = NVL(v_requires_deposit, requires_deposit),
            deposit_type     = v_deposit_type,
            deposit_value    = v_deposit_value
        where id_service = pi_service_id
          and org_id_organization = v_org_id; -- ¡Seguridad!

        -- 5. Verificar si realmente se actualizó algo
        if sql%rowcount = 0 then
            po_status_code := pkg_aox_util.c_not_found_code; -- Not Found
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Servicio no encontrado o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            return;
        end if;

        commit;

        -- 6. Respuesta exitosa
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Servicio actualizado correctamente.');
        po_response_body := v_response_json.to_clob();

    exception
        when others then
            rollback;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    end pr_update_service;

    -- Procedimiento: Eliminar Servicio (DELETE)
    procedure pr_delete_service(
        pi_auth_header   in  varchar2,
        pi_service_id    in  number,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id        number;
        v_response_json json_object_t := json_object_t();
    begin
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Ejecutar el DELETE
        delete from service
        where id_service          = pi_service_id
          and org_id_organization = v_org_id; -- ¡Seguridad!

        -- 3. Verificar si realmente se eliminó algo
        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code; -- Not Found
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Servicio no encontrado o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        -- 4. Respuesta exitosa
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Servicio eliminado correctamente.');
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            IF SQLCODE = -2292 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_conflict,
                    pi_message       => 'No se puede eliminar el servicio porque ya está siendo utilizado en otros registros.',
                    po_response_body => po_response_body
                );
            ELSE
                pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            END IF;
    END pr_delete_service;

    -- Función Privada: Validar inputs del Servicio
    FUNCTION fn_validate_service_inputs(
        pi_name     IN VARCHAR2,
        pi_duration IN NUMBER,
        pi_price    IN NUMBER,
        pi_active   IN NUMBER
    ) RETURN json_array_t IS
        v_errors          json_array_t := json_array_t();
        v_error           json_object_t;
        v_name_max_length NUMBER;
    BEGIN
        -- Obtener la longitud máxima del campo dinámicamente
        BEGIN
            SELECT data_length INTO v_name_max_length
            FROM user_tab_columns
            WHERE table_name = 'SERVICE' AND column_name = 'NAME';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_name_max_length := 100; -- Fallback de seguridad
        END;

        -- Validaciones del Nombre
        IF pi_name IS NULL OR TRIM(pi_name) = '' THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'El nombre es obligatorio.'); v_errors.append(v_error);
        ELSIF LENGTH(pi_name) > v_name_max_length THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'El nombre no puede exceder los ' || v_name_max_length || ' caracteres.'); v_errors.append(v_error);
        END IF;

        -- Validaciones de Duración
        IF pi_duration IS NULL OR pi_duration <= 0 THEN
            v_error := json_object_t(); v_error.put('field', 'duration_minutes'); v_error.put('message', 'La duración es obligatoria y debe ser mayor a 0.'); v_errors.append(v_error);
        END IF;

        -- Validaciones de Precio
        IF pi_price IS NOT NULL AND pi_price < 0 THEN
            v_error := json_object_t(); v_error.put('field', 'price'); v_error.put('message', 'El precio no puede ser negativo.'); v_errors.append(v_error);
        END IF;

        -- Validaciones de Estado
        IF pi_active IS NOT NULL AND pi_active NOT IN (0, 1) THEN
            v_error := json_object_t(); v_error.put('field', 'is_active'); v_error.put('message', 'El estado debe ser 0 (inactivo) o 1 (activo).'); v_errors.append(v_error);
        END IF;

        RETURN v_errors;
    END fn_validate_service_inputs;

    -- Procedimiento: Listar Servicios (LOV - Sin Paginación)
    PROCEDURE pr_list_services_lov(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_services_arr  json_array_t  := json_array_t();
        v_service_obj   json_object_t;
    BEGIN
        -- 1. Validar Token y obtener Organización
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        -- 2. Consultar SOLO los servicios activos de la organización
        FOR rec IN (
            SELECT id_service, name, duration_minutes, price, requires_deposit, deposit_type, deposit_value
            FROM service
            WHERE org_id_organization = v_org_id
              AND is_active = 1
            ORDER BY name ASC
        ) LOOP
            v_service_obj := json_object_t();
            v_service_obj.put('id_service'      , rec.id_service);
            v_service_obj.put('name'            , rec.name);
            v_service_obj.put('duration_minutes', rec.duration_minutes);
            v_service_obj.put('price'           , rec.price);
            v_service_obj.put('requires_deposit', rec.requires_deposit);
            v_service_obj.put('deposit_type'    , rec.deposit_type);
            v_service_obj.put('deposit_value'   , rec.deposit_value);

            v_services_arr.append(v_service_obj);
        END LOOP;

        -- 3. Responder (Sin objeto "meta" porque no hay paginación)
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_services_arr);
        po_response_body := v_response_json.to_clob();

    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_services_lov;
END pkg_aox_service_api;
/


PROMPT CREATE OR REPLACE PACKAGE pkg_aox_specialty_api
CREATE OR REPLACE PACKAGE pkg_aox_specialty_api IS

    -- Listar especialidades con paginación
    PROCEDURE pr_list_specialties(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener especialidad por ID
    PROCEDURE pr_get_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Crear especialidad
    PROCEDURE pr_create_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Actualizar especialidad
    PROCEDURE pr_update_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar especialidad
    PROCEDURE pr_delete_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_specialty_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_specialty_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_specialty_api IS

    -- Función Privada: Validar inputs de Especialidad
    FUNCTION fn_validate_spec_inputs(
        pi_name        IN VARCHAR2,
        pi_description IN VARCHAR2,
        pi_active      IN NUMBER
    ) RETURN json_array_t IS
        v_errors              json_array_t := json_array_t();
        v_error               json_object_t;
        v_name_max_length     NUMBER;
        v_desc_max_length     NUMBER;
    BEGIN
        -- Longitudes dinámicas
        BEGIN SELECT data_length INTO v_name_max_length FROM user_tab_columns WHERE table_name = 'SPECIALTY' AND column_name = 'NAME'; EXCEPTION WHEN NO_DATA_FOUND THEN v_name_max_length := 100; END;
        BEGIN SELECT data_length INTO v_desc_max_length FROM user_tab_columns WHERE table_name = 'SPECIALTY' AND column_name = 'DESCRIPTION'; EXCEPTION WHEN NO_DATA_FOUND THEN v_desc_max_length := 255; END;

        IF pi_name IS NULL OR TRIM(pi_name) = '' THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'El nombre es obligatorio.'); v_errors.append(v_error);
        ELSIF LENGTH(pi_name) > v_name_max_length THEN
            v_error := json_object_t(); v_error.put('field', 'name'); v_error.put('message', 'Excede ' || v_name_max_length || ' caracteres.'); v_errors.append(v_error);
        END IF;

        IF pi_description IS NOT NULL AND LENGTH(pi_description) > v_desc_max_length THEN
            v_error := json_object_t(); v_error.put('field', 'description'); v_error.put('message', 'Excede ' || v_desc_max_length || ' caracteres.'); v_errors.append(v_error);
        END IF;

        IF pi_active IS NOT NULL AND pi_active NOT IN (0, 1) THEN
            v_error := json_object_t(); v_error.put('field', 'is_active'); v_error.put('message', 'El estado debe ser 0 o 1.'); v_errors.append(v_error);
        END IF;

        RETURN v_errors;
    END fn_validate_spec_inputs;

    -- Procedimiento: Listar (GET)
    PROCEDURE pr_list_specialties(
        pi_auth_header   IN  VARCHAR2,
        pi_page          IN  NUMBER DEFAULT 1,
        pi_limit         IN  NUMBER DEFAULT 9,
        pi_is_active     IN  NUMBER DEFAULT NULL,
        pi_search        IN  VARCHAR2 DEFAULT NULL,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_specs_arr     json_array_t  := json_array_t();
        v_spec_obj      json_object_t;
        v_meta_obj      json_object_t;

        v_page          NUMBER := NVL(pi_page, 1);
        v_limit         NUMBER := NVL(pi_limit, 9);
        v_offset        NUMBER;
        v_total_records NUMBER := 0;
        v_total_pages   NUMBER := 0;
        v_search        VARCHAR2(200) := TRANSLATE(
            UPPER(TRIM(pi_search)),
            'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ',
            'AEIOUUNAEIOUAAEIOU'
        );
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF v_page < 1 THEN v_page := 1; END IF;
        v_offset := (v_page - 1) * v_limit;

        IF v_search IS NOT NULL AND LENGTH(v_search) = 0 THEN
            v_search := NULL;
        END IF;

        SELECT COUNT(*)
        INTO v_total_records
        FROM specialty
        WHERE org_id_organization = v_org_id
          AND (pi_is_active IS NULL OR is_active = pi_is_active)
          AND (
                v_search IS NULL
                OR TRANSLATE(UPPER(name), 'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ', 'AEIOUUNAEIOUAAEIOU')
                   LIKE '%' || v_search || '%'
              );
        v_total_pages := CEIL(v_total_records / v_limit);

        FOR rec IN (
            SELECT id_specialty, name, description, is_active, created_at
            FROM specialty
            WHERE org_id_organization = v_org_id
              AND (pi_is_active IS NULL OR is_active = pi_is_active)
              AND (
                    v_search IS NULL
                    OR TRANSLATE(UPPER(name), 'ÁÉÍÓÚÜÑÀÈÌÒÙÄËÏÖÜ', 'AEIOUUNAEIOUAAEIOU')
                       LIKE '%' || v_search || '%'
                  )
            ORDER BY id_specialty DESC
            OFFSET v_offset ROWS FETCH NEXT v_limit ROWS ONLY
        ) LOOP
            v_spec_obj := json_object_t();
            v_spec_obj.put('id_specialty', rec.id_specialty);
            v_spec_obj.put('name', rec.name);
            v_spec_obj.put('description', rec.description);
            v_spec_obj.put('is_active', rec.is_active);
            v_spec_obj.put('created_at', TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
            v_specs_arr.append(v_spec_obj);
        END LOOP;

        v_meta_obj := json_object_t();
        v_meta_obj.put('current_page', v_page);
        v_meta_obj.put('per_page', v_limit);
        v_meta_obj.put('total_records', v_total_records);
        v_meta_obj.put('total_pages', v_total_pages);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('meta', v_meta_obj);
        v_response_json.put('data', v_specs_arr);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_specialties;

    -- Procedimiento: Obtener por ID (GET)
    PROCEDURE pr_get_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_spec_obj      json_object_t;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT id_specialty, name, description, is_active, created_at
            FROM specialty
            WHERE id_specialty = pi_specialty_id AND org_id_organization = v_org_id
        ) LOOP
            v_spec_obj := json_object_t();
            v_spec_obj.put('id_specialty', rec.id_specialty);
            v_spec_obj.put('name', rec.name);
            v_spec_obj.put('description', rec.description);
            v_spec_obj.put('is_active', rec.is_active);
            v_spec_obj.put('created_at', TO_CHAR(rec.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data', v_spec_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status', 'error');
        v_response_json.put('message', 'Especialidad no encontrada.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_specialty;

    -- Procedimiento: Crear (POST)
    PROCEDURE pr_create_specialty(
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

        v_name              specialty.name%TYPE;
        v_desc              specialty.description%TYPE;
        v_is_active         specialty.is_active%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            IF v_json_req.has('description') THEN v_desc := v_json_req.get_string('description'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); ELSE v_is_active := 1; END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_validation_errors := fn_validate_spec_inputs(v_name, v_desc, v_is_active);

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Errores de validación en los campos enviados.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        INSERT INTO specialty (org_id_organization, name, description, is_active)
        VALUES (v_org_id, TRIM(v_name), TRIM(v_desc), v_is_active)
        RETURNING id_specialty INTO v_new_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Especialidad creada correctamente.');
        v_response_json.put('id_specialty', v_new_id);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_specialty;

    -- Procedimiento: Actualizar (PUT)
    PROCEDURE pr_update_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id            NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();
        v_validation_errors json_array_t;

        v_name              specialty.name%TYPE;
        v_desc              specialty.description%TYPE;
        v_is_active         specialty.is_active%TYPE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);
            v_name     := v_json_req.get_string('name');
            IF v_json_req.has('description') THEN v_desc := v_json_req.get_string('description'); END IF;
            IF v_json_req.has('is_active') THEN v_is_active := v_json_req.get_number('is_active'); END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        v_validation_errors := fn_validate_spec_inputs(v_name, v_desc, NVL(v_is_active, 1));

        IF v_validation_errors.get_size() > 0 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Errores de validación en los campos enviados.');
            v_response_json.put('errors', v_validation_errors);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        UPDATE specialty
        SET name        = TRIM(v_name),
            description = TRIM(v_desc),
            is_active   = NVL(v_is_active, is_active)
        WHERE id_specialty = pi_specialty_id AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Especialidad no encontrada o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Especialidad actualizada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_update_specialty;

    -- Procedimiento: Eliminar (DELETE)
    PROCEDURE pr_delete_specialty(
        pi_auth_header   IN  VARCHAR2,
        pi_specialty_id  IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        DELETE FROM specialty
        WHERE id_specialty = pi_specialty_id AND org_id_organization = v_org_id;

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Especialidad no encontrada o no pertenece a su organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Especialidad eliminada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            IF SQLCODE = -2292 THEN
                po_status_code := pkg_aox_util.c_conflict_code;
                pkg_aox_util.pr_build_api_error_response(
                    pi_status_code   => po_status_code,
                    pi_api_code      => pkg_aox_util.c_api_code_conflict,
                    pi_message       => 'No se puede eliminar la especialidad porque está en uso.',
                    po_response_body => po_response_body
                );
            ELSE
                pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
            END IF;
    END pr_delete_specialty;

END pkg_aox_specialty_api;
/


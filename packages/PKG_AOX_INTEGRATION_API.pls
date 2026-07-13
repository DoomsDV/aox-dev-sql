PROMPT CREATE OR REPLACE PACKAGE pkg_aox_integration_api
CREATE OR REPLACE PACKAGE pkg_aox_integration_api IS

    -- Guardar o actualizar los tokens de una integración (UPSERT)
    PROCEDURE pr_save_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Obtener los tokens de una integración específica (ej. 'google_calendar')
    PROCEDURE pr_get_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Eliminar una integración (Desconectar cuenta)
    PROCEDURE pr_delete_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_integration_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_integration_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_integration_api IS

    -- Procedimiento: Guardar o Actualizar Integración (POST/PUT)
    PROCEDURE pr_save_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id           NUMBER;
        v_json_req          json_object_t;
        v_response_json     json_object_t := json_object_t();

        v_provider          user_integration.provider%TYPE;
        v_access_token      user_integration.access_token%TYPE;
        v_refresh_token     user_integration.refresh_token%TYPE;
    BEGIN
        -- Obtenemos el ID del usuario directamente del token JWT
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        -- Parseamos el Body enviado por Astro
        BEGIN
            v_json_req      := json_object_t.parse(pi_body);
            v_provider      := v_json_req.get_string('provider');
            v_access_token  := v_json_req.get_string('access_token');

            IF v_json_req.has('refresh_token') THEN
                v_refresh_token := v_json_req.get_string('refresh_token');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        -- Validaciones básicas
        IF v_provider IS NULL OR v_access_token IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Proveedor y Access Token son obligatorios.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        -- Logica de UPSERT (Insertar o Actualizar) usando MERGE
        MERGE INTO user_integration ui
        USING (
            SELECT
                v_user_id AS usr_id_user,
                LOWER(v_provider) AS provider,
                -- ENCRIPTAMOS ANTES DE GUARDAR
                pkg_aox_util.fn_encrypt_data(v_access_token)  AS access_token,
                pkg_aox_util.fn_encrypt_data(v_refresh_token) AS refresh_token
            FROM dual
        ) src
        ON (ui.usr_id_user = src.usr_id_user AND ui.provider = src.provider)
        WHEN MATCHED THEN
            UPDATE SET
                access_token  = src.access_token,
                refresh_token = COALESCE(src.refresh_token, ui.refresh_token),
                updated_at    = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                usr_id_user,
                provider,
                access_token,
                refresh_token
            )
            VALUES (
                src.usr_id_user,
                src.provider,
                src.access_token,
                src.refresh_token
            );
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Integración guardada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_save_integration;

    -- Procedimiento: Obtener Integración (GET)
    PROCEDURE pr_get_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t;
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT
                access_token,
                refresh_token,
                created_at,
                updated_at
            FROM user_integration
            WHERE usr_id_user = v_user_id
              AND provider    = LOWER(pi_provider)
        ) LOOP
            v_data_obj := json_object_t();
            v_data_obj.put('provider', LOWER(pi_provider));
            -- DESENCRIPTAMOS ANTES DE ENVIAR A ASTRO
            v_data_obj.put('access_token' , pkg_aox_util.fn_decrypt_data(rec.access_token));
            v_data_obj.put('refresh_token', pkg_aox_util.fn_decrypt_data(rec.refresh_token));
            v_data_obj.put('updated_at'   , TO_CHAR(rec.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response_json.put('status', 'success');
            v_response_json.put('data'  , v_data_obj);
            po_response_body := v_response_json.to_clob();
            RETURN;
        END LOOP;

        -- Si no entra al LOOP, es porque no existe la integración
        po_status_code := pkg_aox_util.c_not_found_code;
        v_response_json.put('status'  , 'error');
        v_response_json.put('message' , 'Integración no encontrada para este usuario.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_integration;

    -- Procedimiento: Eliminar Integración (DELETE)
    PROCEDURE pr_delete_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_user_id       NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        DELETE FROM user_integration
        WHERE usr_id_user = v_user_id AND provider = LOWER(pi_provider);

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status'  , 'error');
            v_response_json.put('message' , 'Integración no encontrada.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status'  , 'success');
        v_response_json.put('message' , 'Integración eliminada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_integration;

END pkg_aox_integration_api;
/


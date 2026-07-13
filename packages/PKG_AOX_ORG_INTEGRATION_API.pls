PROMPT CREATE OR REPLACE PACKAGE pkg_aox_org_integration_api
CREATE OR REPLACE PACKAGE pkg_aox_org_integration_api IS

    PROCEDURE pr_save_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_get_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_delete_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_org_integration_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_org_integration_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_org_integration_api IS

    c_provider_pagopar CONSTANT VARCHAR2(50) := 'pagopar';
    c_gone_code        CONSTANT NUMBER := 410;
    c_msg_pagopar_gone CONSTANT VARCHAR2(220) :=
        'Pagopar del comercio fue deprecado para senas. Configura transferencia SIPAP en Ajustes > Pagos. Pagopar queda solo para la suscripcion Hasel.';

    PROCEDURE pr_assert_admin(
        pi_auth_header IN VARCHAR2
    ) IS
        v_role_id NUMBER;
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id <> pkg_aox_util.fn_rol('ADMIN') THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
    END pr_assert_admin;

    PROCEDURE pr_respond_pagopar_gone(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json json_object_t := json_object_t();
    BEGIN
        po_status_code := c_gone_code;
        v_json.put('status', 'error');
        v_json.put('code', 'GONE');
        v_json.put('message', c_msg_pagopar_gone);
        po_response_body := v_json.to_clob();
    END pr_respond_pagopar_gone;

    FUNCTION fn_is_pagopar(pi_provider IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN LOWER(TRIM(pi_provider)) = c_provider_pagopar;
    END fn_is_pagopar;

    PROCEDURE pr_save_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_provider      org_integration.provider%TYPE;
        v_public_key    VARCHAR2(500);
        v_private_key   VARCHAR2(500);
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req    := json_object_t.parse(pi_body);
            v_provider    := LOWER(TRIM(v_json_req.get_string('provider')));
            v_public_key  := TRIM(v_json_req.get_string('public_key'));
            v_private_key := TRIM(v_json_req.get_string('private_key'));
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON inválido o malformado.');
        END;

        -- Fase E: no aceptar claves Pagopar de comercio (senas = SIPAP).
        IF fn_is_pagopar(v_provider) THEN
            pr_respond_pagopar_gone(po_status_code, po_response_body);
            RETURN;
        END IF;

        IF v_provider IS NULL OR v_public_key IS NULL OR v_private_key IS NULL THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Proveedor, clave pública y clave privada son obligatorios.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        MERGE INTO org_integration oi
        USING (
            SELECT
                v_org_id AS org_id_organization,
                LOWER(v_provider) AS provider,
                pkg_aox_util.fn_encrypt_data(v_public_key) AS public_key,
                pkg_aox_util.fn_encrypt_data(v_private_key) AS private_key
            FROM dual
        ) src
        ON (oi.org_id_organization = src.org_id_organization AND oi.provider = src.provider)
        WHEN MATCHED THEN
            UPDATE SET
                public_key  = src.public_key,
                private_key = src.private_key,
                is_active   = 1,
                updated_at  = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                provider,
                public_key,
                private_key,
                is_active
            )
            VALUES (
                src.org_id_organization,
                src.provider,
                src.public_key,
                src.private_key,
                1
            );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Integración guardada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_save_org_integration;

    PROCEDURE pr_get_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
        v_data_obj      json_object_t := json_object_t();
        v_configured    BOOLEAN := FALSE;
    BEGIN
        pr_assert_admin(pi_auth_header);

        IF fn_is_pagopar(pi_provider) THEN
            pr_respond_pagopar_gone(po_status_code, po_response_body);
            RETURN;
        END IF;

        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        FOR rec IN (
            SELECT public_key, private_key, is_active, updated_at
              FROM org_integration
             WHERE org_id_organization = v_org_id
               AND provider = LOWER(TRIM(pi_provider))
        ) LOOP
            v_configured := TRUE;
            v_data_obj.put('provider', LOWER(TRIM(pi_provider)));
            v_data_obj.put('public_key', pkg_aox_util.fn_decrypt_data(rec.public_key));
            v_data_obj.put('private_key_configured', CASE WHEN rec.private_key IS NOT NULL THEN TRUE ELSE FALSE END);
            v_data_obj.put('is_active', rec.is_active);
            v_data_obj.put('updated_at', TO_CHAR(rec.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        END LOOP;

        IF NOT v_configured THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Integración no configurada para esta organización.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data_obj);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_org_integration;

    PROCEDURE pr_delete_org_integration(
        pi_auth_header   IN  VARCHAR2,
        pi_provider      IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header);

        IF fn_is_pagopar(pi_provider) THEN
            pr_respond_pagopar_gone(po_status_code, po_response_body);
            RETURN;
        END IF;

        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        DELETE FROM org_integration
         WHERE org_id_organization = v_org_id
           AND provider = LOWER(TRIM(pi_provider));

        IF SQL%ROWCOUNT = 0 THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Integración no encontrada.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Integración eliminada correctamente.');
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_org_integration;

END pkg_aox_org_integration_api;
/

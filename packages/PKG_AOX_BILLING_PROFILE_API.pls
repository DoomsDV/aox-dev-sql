PROMPT CREATE OR REPLACE PACKAGE pkg_aox_billing_profile_api
CREATE OR REPLACE PACKAGE pkg_aox_billing_profile_api IS

    PROCEDURE pr_get_billing_profile(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_put_billing_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_billing_profile_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_billing_profile_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_billing_profile_api IS

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

    FUNCTION fn_build_data_obj(
        pi_org_id IN NUMBER
    ) RETURN json_object_t IS
        v_data        json_object_t := json_object_t();
        v_name        org_billing_profile.billing_name%TYPE;
        v_doc_type    org_billing_profile.billing_doc_type%TYPE;
        v_doc_number  org_billing_profile.billing_doc_number%TYPE;
        v_email       org_billing_profile.billing_email%TYPE;
        v_updated_at  org_billing_profile.updated_at%TYPE;
        v_found       BOOLEAN := FALSE;
        v_org_name    organization.name%TYPE;
        v_org_email   organization.company_email%TYPE;
    BEGIN
        BEGIN
            SELECT /*+ no_parallel */
                   billing_name,
                   billing_doc_type,
                   billing_doc_number,
                   billing_email,
                   updated_at
              INTO v_name,
                   v_doc_type,
                   v_doc_number,
                   v_email,
                   v_updated_at
              FROM org_billing_profile
             WHERE org_id_organization = pi_org_id;
            v_found := TRUE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_found := FALSE;
        END;

        IF NOT v_found THEN
            BEGIN
                SELECT /*+ no_parallel */ name, company_email
                  INTO v_org_name, v_org_email
                  FROM organization
                 WHERE id_organization = pi_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_org_name := NULL;
                    v_org_email := NULL;
            END;
            v_name := v_org_name;
            v_doc_type := 'CI';
            v_doc_number := NULL;
            v_email := v_org_email;
        END IF;

        v_data.put('billing_name', v_name);
        v_data.put('billing_doc_type', NVL(v_doc_type, 'CI'));
        v_data.put('billing_doc_number', v_doc_number);
        v_data.put('billing_email', v_email);
        v_data.put('is_complete',
            CASE
                WHEN v_name IS NOT NULL
                 AND LENGTH(TRIM(v_name)) >= 2
                 AND v_doc_type IN ('CI', 'RUC')
                 AND v_doc_number IS NOT NULL
                 AND LENGTH(TRIM(v_doc_number)) >= 3
                 AND v_email IS NOT NULL
                 AND INSTR(v_email, '@') > 1
                THEN 1
                ELSE 0
            END
        );
        IF v_found AND v_updated_at IS NOT NULL THEN
            v_data.put('updated_at', TO_CHAR(v_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        END IF;

        RETURN v_data;
    END fn_build_data_obj;

    PROCEDURE pr_get_billing_profile(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_response_json json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', fn_build_data_obj(v_org_id));
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_billing_profile;

    PROCEDURE pr_put_billing_profile(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_user_id       NUMBER;
        v_json_req      json_object_t;
        v_response_json json_object_t := json_object_t();
        v_name          VARCHAR2(200);
        v_doc_type      VARCHAR2(10);
        v_doc_number    VARCHAR2(40);
        v_email         VARCHAR2(255);
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);

            IF v_json_req.has('billing_name') AND NOT v_json_req.get('billing_name').is_null THEN
                v_name := TRIM(v_json_req.get_string('billing_name'));
            END IF;
            IF v_json_req.has('billing_doc_type') AND NOT v_json_req.get('billing_doc_type').is_null THEN
                v_doc_type := UPPER(TRIM(v_json_req.get_string('billing_doc_type')));
            END IF;
            IF v_json_req.has('billing_doc_number') AND NOT v_json_req.get('billing_doc_number').is_null THEN
                v_doc_number := TRIM(v_json_req.get_string('billing_doc_number'));
            END IF;
            IF v_json_req.has('billing_email') AND NOT v_json_req.get('billing_email').is_null THEN
                v_email := LOWER(TRIM(v_json_req.get_string('billing_email')));
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON invalido o malformado.');
        END;

        IF v_doc_type IS NULL OR v_doc_type NOT IN ('CI', 'RUC') THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Elegi el tipo de documento (C.I. o RUC).');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_doc_number IS NULL OR LENGTH(v_doc_number) < 3 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'El numero de documento (C.I. o RUC) es obligatorio.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_name IS NULL OR LENGTH(v_name) < 2 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put(
                'message',
                CASE
                    WHEN v_doc_type = 'RUC' THEN 'La razon social es obligatoria para RUC.'
                    ELSE 'El nombre / razon social es obligatorio.'
                END
            );
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_email IS NULL OR INSTR(v_email, '@') < 2 OR INSTR(v_email, '.') < 3 THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'Ingresa un email de factura valido.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        MERGE /*+ no_parallel */ INTO org_billing_profile t
        USING (
            SELECT
                v_org_id     AS org_id_organization,
                v_name       AS billing_name,
                v_doc_type   AS billing_doc_type,
                v_doc_number AS billing_doc_number,
                v_email      AS billing_email,
                v_user_id    AS updated_by_user
              FROM dual
        ) s
        ON (t.org_id_organization = s.org_id_organization)
        WHEN MATCHED THEN
            UPDATE SET
                t.billing_name       = s.billing_name,
                t.billing_doc_type   = s.billing_doc_type,
                t.billing_doc_number = s.billing_doc_number,
                t.billing_email      = s.billing_email,
                t.updated_by_user    = s.updated_by_user,
                t.updated_at         = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                billing_name,
                billing_doc_type,
                billing_doc_number,
                billing_email,
                updated_by_user
            ) VALUES (
                s.org_id_organization,
                s.billing_name,
                s.billing_doc_type,
                s.billing_doc_number,
                s.billing_email,
                s.updated_by_user
            );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Datos de facturacion guardados correctamente.');
        v_response_json.put('data', fn_build_data_obj(v_org_id));
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_put_billing_profile;

END pkg_aox_billing_profile_api;
/

PROMPT CREATE OR REPLACE PACKAGE pkg_aox_payment_settings_api
CREATE OR REPLACE PACKAGE pkg_aox_payment_settings_api IS

    /** 1 si la org tiene senas habilitadas en org_payment_settings. */
    FUNCTION fn_org_deposits_enabled(
        pi_org_id IN NUMBER
    ) RETURN NUMBER;

    /** Monto de seña del servicio (0 si no aplica / plan / SIPAP off). */
    FUNCTION fn_calculate_deposit(
        pi_ser_id IN NUMBER,
        pi_org_id IN NUMBER
    ) RETURN NUMBER;

    PROCEDURE pr_get_payment_settings(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_put_payment_settings(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_payment_settings_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_payment_settings_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_payment_settings_api IS

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

    FUNCTION fn_org_deposits_enabled(
        pi_org_id IN NUMBER
    ) RETURN NUMBER IS
        v_enabled    NUMBER := 0;
        v_suspended  NUMBER := 0;
    BEGIN
        IF pi_org_id IS NULL THEN
            RETURN 0;
        END IF;

        BEGIN
            SELECT /*+ no_parallel */
                   NVL(deposits_enabled, 0),
                   NVL(deposits_suspended, 0)
              INTO v_enabled, v_suspended
              FROM org_payment_settings
             WHERE org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN 0;
        END;

        IF v_suspended = 1 THEN
            RETURN 0;
        END IF;

        RETURN CASE WHEN v_enabled = 1 THEN 1 ELSE 0 END;
    END fn_org_deposits_enabled;

    FUNCTION fn_calculate_deposit(
        pi_ser_id IN NUMBER,
        pi_org_id IN NUMBER
    ) RETURN NUMBER IS
        v_requires   service.requires_deposit%TYPE;
        v_type       service.deposit_type%TYPE;
        v_value      service.deposit_value%TYPE;
        v_price      service.price%TYPE;
        v_amount     NUMBER;
    BEGIN
        SELECT requires_deposit, deposit_type, deposit_value, price
          INTO v_requires, v_type, v_value, v_price
          FROM service
         WHERE id_service = pi_ser_id
           AND org_id_organization = pi_org_id;

        IF NVL(v_requires, 0) = 0 THEN
            RETURN 0;
        END IF;

        IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'DEPOSIT_COLLECTION') = 0 THEN
            RETURN 0;
        END IF;

        IF fn_org_deposits_enabled(pi_org_id) = 0 THEN
            RETURN 0;
        END IF;

        IF v_type = 'PERCENT' THEN
            v_amount := ROUND(NVL(v_price, 0) * NVL(v_value, 0) / 100);
        ELSIF v_type = 'FIXED' THEN
            v_amount := NVL(v_value, 0);
        ELSE
            RAISE_APPLICATION_ERROR(-20011, 'Tipo de seña inválido.');
        END IF;

        IF v_amount <= 0 THEN
            RAISE_APPLICATION_ERROR(-20012, 'El monto de la seña debe ser mayor a cero.');
        END IF;

        RETURN v_amount;
    END fn_calculate_deposit;

    FUNCTION fn_banks_array RETURN json_array_t IS
        v_arr  json_array_t := json_array_t();
        v_item json_object_t;
    BEGIN
        FOR rec IN (
            SELECT /*+ no_parallel */ id_bank, code, name
              FROM ref_sipap_bank
             WHERE is_active = 1
             ORDER BY sort_order, name
        ) LOOP
            v_item := json_object_t();
            v_item.put('id_bank', rec.id_bank);
            v_item.put('code', rec.code);
            v_item.put('name', rec.name);
            v_arr.append(v_item);
        END LOOP;
        RETURN v_arr;
    END fn_banks_array;

    FUNCTION fn_build_data_obj(
        pi_org_id IN NUMBER
    ) RETURN json_object_t IS
        v_data             json_object_t := json_object_t();
        v_deposits         NUMBER := 0;
        v_policy           org_payment_settings.refund_policy%TYPE;
        v_bank_id          org_payment_settings.bank_id%TYPE;
        v_bank_name        ref_sipap_bank.name%TYPE;
        v_account_holder   org_payment_settings.account_holder%TYPE;
        v_document_id      org_payment_settings.document_id%TYPE;
        v_bank_alias       org_payment_settings.bank_alias%TYPE;
        v_updated_at       org_payment_settings.updated_at%TYPE;
        v_strike_count     NUMBER := 0;
        v_suspended        NUMBER := 0;
        v_suspended_at     TIMESTAMP WITH TIME ZONE;
        v_suspended_reason VARCHAR2(400);
        v_found            BOOLEAN := FALSE;
        v_has_feature      NUMBER;
    BEGIN
        BEGIN
            SELECT /*+ no_parallel */
                   NVL(ops.deposits_enabled, 0),
                   ops.refund_policy,
                   ops.bank_id,
                   b.name,
                   ops.account_holder,
                   ops.document_id,
                   ops.bank_alias,
                   ops.updated_at,
                   NVL(ops.refund_strike_count, 0),
                   NVL(ops.deposits_suspended, 0),
                   ops.deposits_suspended_at,
                   ops.deposits_suspended_reason
              INTO v_deposits,
                   v_policy,
                   v_bank_id,
                   v_bank_name,
                   v_account_holder,
                   v_document_id,
                   v_bank_alias,
                   v_updated_at,
                   v_strike_count,
                   v_suspended,
                   v_suspended_at,
                   v_suspended_reason
              FROM org_payment_settings ops
              LEFT JOIN ref_sipap_bank b
                ON b.id_bank = ops.bank_id
             WHERE ops.org_id_organization = pi_org_id;
            v_found := TRUE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_found := FALSE;
        END;

        v_has_feature := pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'DEPOSIT_COLLECTION');

        v_data.put(
            'deposits_enabled',
            CASE
                WHEN v_found AND v_suspended = 0 AND v_deposits = 1 THEN 1
                ELSE 0
            END
        );
        v_data.put('refund_policy', v_policy);
        IF v_bank_id IS NOT NULL THEN
            v_data.put('bank_id', v_bank_id);
        ELSE
            v_data.put_null('bank_id');
        END IF;
        v_data.put('bank_name', v_bank_name);
        v_data.put('account_holder', v_account_holder);
        v_data.put('document_id', v_document_id);
        v_data.put('bank_alias', v_bank_alias);
        v_data.put('plan_allows_deposits', v_has_feature);
        v_data.put('refund_strike_count', CASE WHEN v_found THEN v_strike_count ELSE 0 END);
        v_data.put('deposits_suspended', CASE WHEN v_found THEN v_suspended ELSE 0 END);
        v_data.put('max_refund_strikes', 3);
        v_data.put('banks', fn_banks_array());
        IF v_suspended_reason IS NOT NULL THEN
            v_data.put('deposits_suspended_reason', v_suspended_reason);
        END IF;
        IF v_suspended_at IS NOT NULL THEN
            v_data.put('deposits_suspended_at', TO_CHAR(v_suspended_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        END IF;
        IF v_found AND v_updated_at IS NOT NULL THEN
            v_data.put('updated_at', TO_CHAR(v_updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        END IF;

        RETURN v_data;
    END fn_build_data_obj;

    PROCEDURE pr_get_payment_settings(
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
    END pr_get_payment_settings;

    PROCEDURE pr_put_payment_settings(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_user_id        NUMBER;
        v_json_req       json_object_t;
        v_response_json  json_object_t := json_object_t();
        v_deposits       NUMBER := 0;
        v_policy         VARCHAR2(20);
        v_bank_id        NUMBER;
        v_bank_name      VARCHAR2(120);
        v_account_holder VARCHAR2(200);
        v_document_id    VARCHAR2(40);
        v_bank_alias     VARCHAR2(120);
        v_suspended      NUMBER := 0;
        v_bank_active    NUMBER := 0;
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id  := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_user_id := pkg_aox_util.fn_get_user_id_from_jwt(pi_auth_header);

        BEGIN
            v_json_req := json_object_t.parse(pi_body);

            IF v_json_req.has('deposits_enabled') THEN
                IF v_json_req.get('deposits_enabled').is_true THEN
                    v_deposits := 1;
                ELSIF v_json_req.get('deposits_enabled').is_false THEN
                    v_deposits := 0;
                ELSE
                    v_deposits := NVL(v_json_req.get_number('deposits_enabled'), 0);
                END IF;
            END IF;

            IF v_json_req.has('refund_policy') AND NOT v_json_req.get('refund_policy').is_null THEN
                v_policy := UPPER(TRIM(v_json_req.get_string('refund_policy')));
            END IF;
            IF v_json_req.has('bank_id') AND NOT v_json_req.get('bank_id').is_null THEN
                v_bank_id := v_json_req.get_number('bank_id');
            END IF;
            IF v_json_req.has('account_holder') AND NOT v_json_req.get('account_holder').is_null THEN
                v_account_holder := TRIM(v_json_req.get_string('account_holder'));
            END IF;
            IF v_json_req.has('document_id') AND NOT v_json_req.get('document_id').is_null THEN
                v_document_id := TRIM(v_json_req.get_string('document_id'));
            END IF;
            IF v_json_req.has('bank_alias') AND NOT v_json_req.get('bank_alias').is_null THEN
                v_bank_alias := TRIM(v_json_req.get_string('bank_alias'));
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002, 'JSON invalido o malformado.');
        END;

        IF v_deposits NOT IN (0, 1) THEN
            po_status_code := pkg_aox_util.c_bad_request_code;
            v_response_json.put('status', 'error');
            v_response_json.put('message', 'deposits_enabled debe ser 0 o 1.');
            po_response_body := v_response_json.to_clob();
            RETURN;
        END IF;

        IF v_bank_id IS NOT NULL THEN
            BEGIN
                SELECT /*+ no_parallel */ name, is_active
                  INTO v_bank_name, v_bank_active
                  FROM ref_sipap_bank
                 WHERE id_bank = v_bank_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_bank_name := NULL;
                    v_bank_active := 0;
            END;

            IF v_bank_name IS NULL OR v_bank_active <> 1 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Elegi un banco / financiera valido del listado.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        IF v_deposits = 1 THEN
            pkg_aox_subscription_api.pr_assert_org_has_feature(v_org_id, 'DEPOSIT_COLLECTION');
            pkg_aox_subscription_api.fn_assert_org_can_write(v_org_id);

            BEGIN
                SELECT /*+ no_parallel */ NVL(deposits_suspended, 0)
                  INTO v_suspended
                  FROM org_payment_settings
                 WHERE org_id_organization = v_org_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_suspended := 0;
            END;

            IF v_suspended = 1 THEN
                po_status_code := pkg_aox_util.c_forbidden_code;
                v_response_json.put('status', 'error');
                v_response_json.put(
                    'message',
                    'Las senas estan suspendidas por 3 strikes de reembolso. Contacta a soporte Hasel.'
                );
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_policy IS NULL OR v_policy NOT IN ('FLEXIBLE', 'MODERATE', 'STRICT') THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put(
                    'message',
                    'Elegi una politica de cancelacion (Flexible, Moderada o Estricta) para habilitar senas.'
                );
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_bank_id IS NULL OR v_bank_name IS NULL THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El banco / financiera es obligatorio.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_account_holder IS NULL OR LENGTH(v_account_holder) < 2 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El titular de la cuenta es obligatorio.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_document_id IS NULL OR LENGTH(v_document_id) < 3 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El documento (C.I. o RUC) es obligatorio.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;

            IF v_bank_alias IS NULL OR LENGTH(v_bank_alias) < 3 THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'El alias bancario SIPAP es obligatorio.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        ELSE
            IF v_policy IS NOT NULL AND v_policy NOT IN ('FLEXIBLE', 'MODERATE', 'STRICT') THEN
                po_status_code := pkg_aox_util.c_bad_request_code;
                v_response_json.put('status', 'error');
                v_response_json.put('message', 'Politica de cancelacion invalida.');
                po_response_body := v_response_json.to_clob();
                RETURN;
            END IF;
        END IF;

        MERGE /*+ no_parallel */ INTO org_payment_settings t
        USING (
            SELECT
                v_org_id         AS org_id_organization,
                v_deposits       AS deposits_enabled,
                v_policy         AS refund_policy,
                v_bank_id        AS bank_id,
                v_account_holder AS account_holder,
                v_document_id    AS document_id,
                v_bank_alias     AS bank_alias,
                v_user_id        AS updated_by_user
              FROM dual
        ) s
        ON (t.org_id_organization = s.org_id_organization)
        WHEN MATCHED THEN
            UPDATE SET
                t.deposits_enabled = s.deposits_enabled,
                t.refund_policy    = s.refund_policy,
                t.bank_id          = s.bank_id,
                t.account_holder   = s.account_holder,
                t.document_id      = s.document_id,
                t.bank_alias       = s.bank_alias,
                t.updated_by_user  = s.updated_by_user,
                t.updated_at       = CURRENT_TIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (
                org_id_organization,
                deposits_enabled,
                refund_policy,
                bank_id,
                account_holder,
                document_id,
                bank_alias,
                updated_by_user
            ) VALUES (
                s.org_id_organization,
                s.deposits_enabled,
                s.refund_policy,
                s.bank_id,
                s.account_holder,
                s.document_id,
                s.bank_alias,
                s.updated_by_user
            );

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('message', 'Configuracion de cobros guardada correctamente.');
        v_response_json.put('data', fn_build_data_obj(v_org_id));
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_put_payment_settings;

END pkg_aox_payment_settings_api;
/

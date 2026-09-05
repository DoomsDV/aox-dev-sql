PROMPT CREATE OR REPLACE PACKAGE pkg_aox_addon_api
CREATE OR REPLACE PACKAGE pkg_aox_addon_api IS

    FUNCTION fn_org_specialty_code(
        pi_org_id IN NUMBER
    ) RETURN VARCHAR2;

    FUNCTION fn_addon_eligible(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) RETURN NUMBER;

    PROCEDURE pr_list_addons(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_activate_module_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    PROCEDURE pr_cancel_module_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_addon_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_addon_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_addon_api IS

    PROCEDURE pr_assert_admin(
        pi_auth_header IN VARCHAR2
    ) IS
        v_role_id NUMBER;
    BEGIN
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);
        IF v_role_id <> pkg_aox_util.fn_rol('ADMIN') AND NVL(v_role_id, 0) <> 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'No autorizado.');
        END IF;
    END pr_assert_admin;

    FUNCTION fn_require_org_id(
        pi_auth_header IN VARCHAR2
    ) RETURN NUMBER IS
        v_org_id NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_session,
                'Token inválido o sin organización asociada.'
            );
        END IF;
        RETURN v_org_id;
    END fn_require_org_id;

    FUNCTION fn_org_specialty_code(
        pi_org_id IN NUMBER
    ) RETURN VARCHAR2 IS
        v_code org_specialty.code%TYPE;
    BEGIN
        IF NVL(pi_org_id, 0) <= 0 THEN
            RETURN NULL;
        END IF;

        SELECT os.code
          INTO v_code
          FROM organization o
          LEFT JOIN org_specialty os
            ON os.id_org_specialty = o.org_spe_id_specialty
         WHERE o.id_organization = pi_org_id;

        RETURN v_code;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_org_specialty_code;

    FUNCTION fn_addon_eligible(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) RETURN NUMBER IS
    BEGIN
        RETURN pkg_aox_addon_eligibility.fn_addon_eligible(pi_org_id, pi_addon_id);
    END fn_addon_eligible;

    FUNCTION fn_parse_addon_code(
        pi_body IN CLOB
    ) RETURN VARCHAR2 IS
        v_json json_object_t;
        v_code VARCHAR2(30);
    BEGIN
        BEGIN
            v_json := json_object_t.parse(pi_body);
            IF v_json.has('addon_code') AND NOT v_json.get('addon_code').is_null THEN
                v_code := UPPER(TRIM(v_json.get_string('addon_code')));
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'JSON invalido o malformado.');
        END;

        IF v_code IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'addon_code es obligatorio.');
        END IF;

        RETURN v_code;
    END fn_parse_addon_code;

    FUNCTION fn_build_addon_item(
        pi_org_id         IN NUMBER,
        pi_id_addon       IN NUMBER,
        pi_code           IN VARCHAR2,
        pi_name           IN VARCHAR2,
        pi_short_desc     IN VARCHAR2,
        pi_feature_code   IN VARCHAR2,
        pi_price_amount   IN NUMBER,
        pi_currency       IN VARCHAR2,
        pi_billing_period IN VARCHAR2,
        pi_audience_code  IN VARCHAR2,
        pi_org_status     IN VARCHAR2,
        pi_grant_type     IN VARCHAR2
    ) RETURN json_object_t IS
        v_item json_object_t := json_object_t();
    BEGIN
        v_item.put('id_addon', pi_id_addon);
        v_item.put('code', pi_code);
        v_item.put('name', pi_name);
        v_item.put('short_description', pi_short_desc);
        v_item.put('feature_code', pi_feature_code);
        v_item.put('price_amount', pi_price_amount);
        v_item.put('currency', pi_currency);
        v_item.put('billing_period', pi_billing_period);
        IF pi_audience_code IS NULL THEN
            v_item.put_null('audience_code');
        ELSE
            v_item.put('audience_code', pi_audience_code);
        END IF;
        v_item.put('eligible', fn_addon_eligible(pi_org_id, pi_id_addon));
        v_item.put('is_active_for_org', CASE WHEN pi_org_status = 'ACTIVE' THEN 1 ELSE 0 END);
        IF pi_grant_type IS NULL THEN
            v_item.put_null('grant_type');
        ELSE
            v_item.put('grant_type', pi_grant_type);
        END IF;
        IF pi_org_status IS NULL THEN
            v_item.put_null('status');
        ELSE
            v_item.put('status', pi_org_status);
        END IF;
        RETURN v_item;
    END fn_build_addon_item;

    FUNCTION fn_addon_item_by_id(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) RETURN json_object_t IS
        v_id_addon       ref_addon.id_addon%TYPE;
        v_code           ref_addon.code%TYPE;
        v_name           ref_addon.name%TYPE;
        v_short_desc     ref_addon.short_description%TYPE;
        v_feature_code   ref_addon.feature_code%TYPE;
        v_price_amount   ref_addon.price_amount%TYPE;
        v_currency       ref_addon.currency%TYPE;
        v_billing_period ref_addon.billing_period%TYPE;
        v_audience_code  ref_addon.audience_code%TYPE;
        v_org_status     org_addon.status%TYPE;
        v_grant_type     org_addon.grant_type%TYPE;
    BEGIN
        SELECT ra.id_addon,
               ra.code,
               ra.name,
               ra.short_description,
               ra.feature_code,
               ra.price_amount,
               ra.currency,
               ra.billing_period,
               ra.audience_code,
               oa.status,
               oa.grant_type
          INTO v_id_addon,
               v_code,
               v_name,
               v_short_desc,
               v_feature_code,
               v_price_amount,
               v_currency,
               v_billing_period,
               v_audience_code,
               v_org_status,
               v_grant_type
          FROM ref_addon ra
          LEFT JOIN org_addon oa
            ON oa.rad_id_addon = ra.id_addon
           AND oa.org_id_organization = pi_org_id
         WHERE ra.id_addon = pi_addon_id;

        RETURN fn_build_addon_item(
            pi_org_id         => pi_org_id,
            pi_id_addon       => v_id_addon,
            pi_code           => v_code,
            pi_name           => v_name,
            pi_short_desc     => v_short_desc,
            pi_feature_code   => v_feature_code,
            pi_price_amount   => v_price_amount,
            pi_currency       => v_currency,
            pi_billing_period => v_billing_period,
            pi_audience_code  => v_audience_code,
            pi_org_status     => v_org_status,
            pi_grant_type     => v_grant_type
        );
    END fn_addon_item_by_id;

    PROCEDURE pr_success_item(
        pi_org_id        IN  NUMBER,
        pi_addon_id      IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_response_json json_object_t := json_object_t();
    BEGIN
        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', fn_addon_item_by_id(pi_org_id, pi_addon_id));
        po_response_body := v_response_json.to_clob();
    END pr_success_item;

    PROCEDURE pr_list_addons(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_response_json  json_object_t := json_object_t();
        v_data           json_object_t := json_object_t();
        v_items          json_array_t  := json_array_t();
        v_active_items   json_array_t  := json_array_t();
        v_available_items json_array_t := json_array_t();
        v_item           json_object_t;
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id := fn_require_org_id(pi_auth_header);

        FOR rec IN (
            SELECT ra.id_addon,
                   ra.code,
                   ra.name,
                   ra.short_description,
                   ra.feature_code,
                   ra.price_amount,
                   ra.currency,
                   ra.billing_period,
                   ra.audience_code,
                   oa.status     AS org_status,
                   oa.grant_type AS grant_type
              FROM ref_addon ra
              LEFT JOIN org_addon oa
                ON oa.rad_id_addon = ra.id_addon
               AND oa.org_id_organization = v_org_id
             WHERE ra.is_active = 1
             ORDER BY ra.sort_order, ra.id_addon
        ) LOOP
            IF fn_addon_eligible(v_org_id, rec.id_addon) = 0 THEN
                CONTINUE;
            END IF;
            v_item := fn_build_addon_item(
                pi_org_id         => v_org_id,
                pi_id_addon       => rec.id_addon,
                pi_code           => rec.code,
                pi_name           => rec.name,
                pi_short_desc     => rec.short_description,
                pi_feature_code   => rec.feature_code,
                pi_price_amount   => rec.price_amount,
                pi_currency       => rec.currency,
                pi_billing_period => rec.billing_period,
                pi_audience_code  => rec.audience_code,
                pi_org_status     => rec.org_status,
                pi_grant_type     => rec.grant_type
            );
            v_items.append(v_item);
            IF rec.org_status = 'ACTIVE' THEN
                v_active_items.append(v_item);
            ELSE
                v_available_items.append(v_item);
            END IF;
        END LOOP;

        v_data.put('addons_billing_live', pkg_aox_subscription_api.fn_addons_billing_live);
        v_data.put('items', v_items);
        v_data.put('active_items', v_active_items);
        v_data.put('available_items', v_available_items);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data', v_data);
        po_response_body := v_response_json.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_addons;

    PROCEDURE pr_activate_module_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_code           VARCHAR2(30);
        v_id_addon       ref_addon.id_addon%TYPE;
        v_price_amount   ref_addon.price_amount%TYPE;
        v_currency       ref_addon.currency%TYPE;
        v_org_status     org_addon.status%TYPE;
        v_exists         NUMBER := 0;
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id := fn_require_org_id(pi_auth_header);
        v_code   := fn_parse_addon_code(pi_body);

        BEGIN
            SELECT id_addon,
                   price_amount,
                   currency
              INTO v_id_addon,
                   v_price_amount,
                   v_currency
              FROM ref_addon
             WHERE code = v_code
               AND is_active = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_validation,
                    'Complemento no encontrado o inactivo.'
                );
        END;

        IF fn_addon_eligible(v_org_id, v_id_addon) = 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Este complemento no está disponible para el rubro de tu organización.'
            );
        END IF;

        BEGIN
            SELECT status
              INTO v_org_status
              FROM org_addon
             WHERE org_id_organization = v_org_id
               AND rad_id_addon = v_id_addon;
            v_exists := 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_exists := 0;
                v_org_status := NULL;
        END;

        IF v_org_status = 'ACTIVE' THEN
            pr_success_item(v_org_id, v_id_addon, po_status_code, po_response_body);
            RETURN;
        END IF;

        -- Fail closed: cobro Pagopar todavía no está implementado.
        IF pkg_aox_subscription_api.fn_addons_billing_live = 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El cobro de complementos todavía no está habilitado.'
            );
        END IF;

        IF v_exists = 1 THEN
            UPDATE /*+ no_parallel */ org_addon
               SET status                = 'ACTIVE',
                   grant_type            = 'PREVIEW',
                   price_snapshot_amount = v_price_amount,
                   currency              = v_currency,
                   started_at            = SYSTIMESTAMP,
                   canceled_at           = NULL,
                   billing_started_at    = NULL,
                   updated_at            = SYSTIMESTAMP
             WHERE org_id_organization = v_org_id
               AND rad_id_addon = v_id_addon
               AND status IN ('CANCELED', 'EXPIRED');
        ELSE
            INSERT /*+ no_parallel */ INTO org_addon (
                org_id_organization,
                rad_id_addon,
                status,
                grant_type,
                price_snapshot_amount,
                currency,
                started_at,
                canceled_at,
                billing_started_at
            ) VALUES (
                v_org_id,
                v_id_addon,
                'ACTIVE',
                'PREVIEW',
                v_price_amount,
                v_currency,
                SYSTIMESTAMP,
                NULL,
                NULL
            );
        END IF;

        pr_success_item(v_org_id, v_id_addon, po_status_code, po_response_body);
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_activate_module_addon;

    PROCEDURE pr_cancel_module_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_code     VARCHAR2(30);
        v_id_addon ref_addon.id_addon%TYPE;
        v_updated  NUMBER;
    BEGIN
        pr_assert_admin(pi_auth_header);
        v_org_id := fn_require_org_id(pi_auth_header);
        v_code   := fn_parse_addon_code(pi_body);

        BEGIN
            SELECT id_addon
              INTO v_id_addon
              FROM ref_addon
             WHERE code = v_code;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(
                    pkg_aox_util.c_sqlcode_validation,
                    'Complemento no encontrado o inactivo.'
                );
        END;

        UPDATE /*+ no_parallel */ org_addon
           SET status      = 'CANCELED',
               canceled_at = SYSTIMESTAMP,
               updated_at  = SYSTIMESTAMP
         WHERE org_id_organization = v_org_id
           AND rad_id_addon = v_id_addon
           AND status = 'ACTIVE';

        v_updated := SQL%ROWCOUNT;
        IF NVL(v_updated, 0) = 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El complemento no está activo.'
            );
        END IF;

        pr_success_item(v_org_id, v_id_addon, po_status_code, po_response_body);
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_cancel_module_addon;

END pkg_aox_addon_api;
/

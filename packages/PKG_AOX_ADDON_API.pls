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
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
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

    PROCEDURE pr_put_module_billing_fields(
        pi_org_id     IN NUMBER,
        pi_addon_id   IN NUMBER,
        pi_price      IN NUMBER,
        pi_org_status IN VARCHAR2,
        pi_grant_type IN VARCHAR2,
        pio_item      IN OUT NOCOPY json_object_t
    ) IS
        v_period_start TIMESTAMP WITH TIME ZONE;
        v_period_end   TIMESTAMP WITH TIME ZONE;
        v_days         NUMBER := 0;
        v_per          NUMBER := 30;
        v_prorate      NUMBER := 0;
        v_inv_id       NUMBER;
        v_inv_amount   NUMBER;
        v_inv_gross    NUMBER;
        v_inv_start    TIMESTAMP WITH TIME ZONE;
        v_inv_end      TIMESTAMP WITH TIME ZONE;
        v_base         NUMBER;
        v_unused       NUMBER := 0;
        v_refund_type  VARCHAR2(10) := 'none';
        v_refund_amt   NUMBER := 0;

        FUNCTION lf_unused(
            pi_full  IN NUMBER,
            pi_start IN TIMESTAMP WITH TIME ZONE,
            pi_end   IN TIMESTAMP WITH TIME ZONE
        ) RETURN NUMBER IS
            v_d NUMBER;
            v_p NUMBER;
            v_u NUMBER;
        BEGIN
            IF NVL(pi_full, 0) <= 0 OR pi_end IS NULL OR pi_end <= systimestamp THEN
                RETURN 0;
            END IF;
            v_d := GREATEST(0, TRUNC(CAST(pi_end AS DATE)) - TRUNC(CAST(systimestamp AS DATE)));
            v_p := GREATEST(1, TRUNC(CAST(pi_end AS DATE)) - TRUNC(CAST(NVL(pi_start, ADD_MONTHS(pi_end, -1)) AS DATE)));
            v_u := CEIL(pi_full * v_d / v_p);
            RETURN LEAST(NVL(v_u, 0), pi_full);
        END lf_unused;
    BEGIN
        BEGIN
            SELECT current_period_start, current_period_end
              INTO v_period_start, v_period_end
              FROM org_subscription
             WHERE org_id_organization = pi_org_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_period_end := NULL;
        END;

        IF v_period_end IS NOT NULL AND v_period_end > systimestamp THEN
            v_days := GREATEST(0, TRUNC(CAST(v_period_end AS DATE)) - TRUNC(CAST(systimestamp AS DATE)));
            v_per  := GREATEST(1, TRUNC(CAST(v_period_end AS DATE)) - TRUNC(CAST(NVL(v_period_start, ADD_MONTHS(v_period_end, -1)) AS DATE)));
            IF v_days > 0 AND NVL(pi_price, 0) > 0 THEN
                v_prorate := CEIL(pi_price * v_days / v_per);
                IF v_prorate > 0 AND v_prorate < 1000 THEN
                    v_prorate := 1000;
                END IF;
            END IF;
        END IF;

        pio_item.put('prorate_amount', v_prorate);
        pio_item.put('days_remaining', v_days);
        pio_item.put('period_days', v_per);

        IF pi_org_status = 'ACTIVE' AND pi_grant_type = 'PAID' THEN
            BEGIN
                SELECT i.id_invoice,
                       i.amount,
                       NVL(i.gross_amount, i.amount),
                       i.period_start,
                       i.period_end
                  INTO v_inv_id, v_inv_amount, v_inv_gross, v_inv_start, v_inv_end
                  FROM org_subscription_invoice i
                 WHERE i.org_id_organization = pi_org_id
                   AND i.invoice_type = 'MODULE_ADDON'
                   AND i.rad_id_addon = pi_addon_id
                   AND i.status = 'PAID'
                   AND i.period_end > systimestamp
                   AND i.einvoice_cdc IS NOT NULL
                   AND i.einvoice_status IN ('SENT_PENDING_ARTIFACTS', 'SENT_PENDING_KUDE', 'SENT')
                   AND UPPER(NVL(i.einvoice_estado_sifen, '')) = 'APROBADO'
                   AND TRIM(i.einvoice_cod_res) = '0260'
                   AND NOT EXISTS (
                       SELECT 1
                         FROM subscription_credit_note n
                        WHERE n.source_invoice_id = i.id_invoice
                          AND n.status IN ('PENDING', 'PROCESSING', 'DONE')
                   )
                 ORDER BY i.id_invoice DESC
                 FETCH FIRST 1 ROW ONLY;
                v_base := CASE WHEN NVL(v_inv_amount, 0) > 0 THEN v_inv_amount ELSE NVL(v_inv_gross, 0) END;
                v_unused := lf_unused(v_base, v_inv_start, v_inv_end);
                IF NVL(v_unused, 0) > 0 THEN
                    v_refund_type := 'nce';
                    v_refund_amt  := v_unused;
                END IF;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL;
            END;

            IF v_refund_type = 'none' THEN
                BEGIN
                    SELECT i.id_invoice,
                           i.amount,
                           NVL(i.gross_amount, i.amount),
                           i.period_start,
                           i.period_end
                      INTO v_inv_id, v_inv_amount, v_inv_gross, v_inv_start, v_inv_end
                      FROM org_subscription_invoice i
                     WHERE i.org_id_organization = pi_org_id
                       AND i.invoice_type = 'MODULE_ADDON'
                       AND i.rad_id_addon = pi_addon_id
                       AND i.status = 'PAID'
                       AND i.period_end > systimestamp
                     ORDER BY i.id_invoice DESC
                     FETCH FIRST 1 ROW ONLY;
                    v_base := CASE WHEN NVL(v_inv_amount, 0) > 0 THEN v_inv_amount ELSE NVL(v_inv_gross, 0) END;
                    v_refund_type := 'credit';
                    v_refund_amt  := lf_unused(v_base, v_inv_start, v_inv_end);
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_refund_type := 'credit';
                        v_refund_amt  := 0;
                END;
            END IF;
        END IF;

        pio_item.put('cancel_refund_type', v_refund_type);
        pio_item.put('cancel_credit_amount', v_refund_amt);
    END pr_put_module_billing_fields;

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
        pr_put_module_billing_fields(
            pi_org_id     => pi_org_id,
            pi_addon_id   => pi_id_addon,
            pi_price      => pi_price_amount,
            pi_org_status => pi_org_status,
            pi_grant_type => pi_grant_type,
            pio_item      => v_item
        );
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
        pi_auth_header      IN  VARCHAR2,
        pi_body             IN  CLOB,
        po_status_code      OUT NUMBER,
        po_response_body    OUT CLOB,
        pi_idempotency_key  IN  VARCHAR2 DEFAULT NULL
    ) IS
        v_org_id         NUMBER;
        v_code           VARCHAR2(30);
        v_id_addon       ref_addon.id_addon%TYPE;
        v_price_amount   ref_addon.price_amount%TYPE;
        v_currency       ref_addon.currency%TYPE;
        v_org_status     org_addon.status%TYPE;
        v_org_grant      org_addon.grant_type%TYPE;
        v_exists         NUMBER := 0;
        v_invoice_id     NUMBER;
        v_hash           VARCHAR2(128);
        v_response_json  json_object_t := json_object_t();
        v_data           json_object_t := json_object_t();
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
            SELECT status, grant_type
              INTO v_org_status, v_org_grant
              FROM org_addon
             WHERE org_id_organization = v_org_id
               AND rad_id_addon = v_id_addon;
            v_exists := 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_exists := 0;
                v_org_status := NULL;
                v_org_grant  := NULL;
        END;

        IF v_org_status = 'ACTIVE' AND (
               pkg_aox_subscription_api.fn_addons_billing_live = 0
            OR v_org_grant = 'PAID'
        ) THEN
            pr_success_item(v_org_id, v_id_addon, po_status_code, po_response_body);
            RETURN;
        END IF;

        IF pkg_aox_subscription_api.fn_addons_billing_live = 1 THEN
            MERGE /*+ no_parallel */ INTO org_addon t
            USING (SELECT v_org_id AS org_id, v_id_addon AS addon_id FROM dual) s
               ON (t.org_id_organization = s.org_id AND t.rad_id_addon = s.addon_id)
             WHEN MATCHED THEN
                UPDATE SET t.price_snapshot_amount = v_price_amount,
                           t.currency              = v_currency,
                           t.updated_at            = SYSTIMESTAMP
                 WHERE t.status IN ('CANCELED', 'EXPIRED')
             WHEN NOT MATCHED THEN
                INSERT (
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
                    'CANCELED',
                    'PREVIEW',
                    v_price_amount,
                    v_currency,
                    SYSTIMESTAMP,
                    SYSTIMESTAMP,
                    NULL
                );

            pkg_aox_subscription_billing_api.pr_charge_target(
                pi_org_id           => v_org_id,
                pi_target_type      => 'MODULE_ADDON',
                pi_plan_code        => NULL,
                pi_addon_code       => v_code,
                po_invoice_id       => v_invoice_id,
                po_hash             => v_hash,
                pi_idempotency_key  => pi_idempotency_key
            );

            v_data.put('addon', fn_addon_item_by_id(v_org_id, v_id_addon));
            v_data.put('target_type', 'MODULE_ADDON');
            IF v_hash IS NULL THEN
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response_json.put('status', 'success');
                IF v_invoice_id IS NOT NULL THEN
                    v_response_json.put('message', 'Complemento activado usando tu saldo a favor. No hubo cargo en la tarjeta.');
                    v_data.put('invoice_id', v_invoice_id);
                    v_data.put('payment_status', 'PAID');
                    v_data.put('status', 'PAID');
                ELSE
                    v_response_json.put('message', 'Complemento activado. Entra en el cargo de la próxima renovación.');
                    v_data.put_null('invoice_id');
                    v_data.put('payment_status', 'PAID');
                    v_data.put('status', 'PAID');
                END IF;
                v_data.put_null('hash');
                v_data.put('requires_polling', 0);
            ELSE
                po_status_code := pkg_aox_util.c_success_create_code;
                v_response_json.put('status', 'success');
                v_response_json.put('message', 'Estamos confirmando el cobro del complemento.');
                v_data.put('invoice_id', v_invoice_id);
                v_data.put('hash', v_hash);
                v_data.put('payment_status', 'PENDING');
                v_data.put('status', 'PENDING');
                v_data.put('requires_polling', 1);
            END IF;
            v_response_json.put('data', v_data);
            po_response_body := v_response_json.to_clob();
            RETURN;
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
    BEGIN
        pkg_aox_subscription_billing_api.pr_cancel_module_addon(
            pi_auth_header,
            pi_body,
            po_status_code,
            po_response_body
        );
    END pr_cancel_module_addon;

END pkg_aox_addon_api;
/

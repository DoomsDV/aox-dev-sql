PROMPT CREATE OR REPLACE PACKAGE pkg_aox_subscription_billing_api
CREATE OR REPLACE PACKAGE pkg_aox_subscription_billing_api IS
/**
 * API comercial de suscripci?n (Fase 5): cat?logo de planes/addons,
 * checkout de suscripci?n v?a Pagopar (facturaci?n de la PLATAFORMA).
 *
 * Facturaci?n de plan/addons -> org_subscription_invoice (este package).
 * Se?as de citas -> payment_transaction v?a SIPAP (PKG_AOX_PAYMENTS_API /
 * PKG_AOX_PAYMENT_SETTINGS_API). Pagopar de se?as fue deprecado (Fase E).
 *
 * Claves Pagopar de la plataforma (Hasel cobra a la organizaci?n) en app_parameter:
 *   SUBSCRIPTION_PAGOPAR_PUBLIC_KEY / SUBSCRIPTION_PAGOPAR_PRIVATE_KEY
 * Token SHA1: pkg_aox_pagopar_api.fn_pagopar_sha1_token.
 */

    c_forma_pago_bancard CONSTANT NUMBER := 9;
    c_forma_pago_qr      CONSTANT NUMBER := 24;

    -- GET /workspace/plans  (cat?logo + snapshot de la suscripci?n actual)
    PROCEDURE pr_get_plans(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/checkout  (inicia pago Pagopar de plan o addon)
    PROCEDURE pr_create_checkout(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/change-plan
    -- Downgrade: agenda pending_plan hasta current_period_end (sin credito de plan).
    -- Cancelar agenda: plan_code = plan actual. Upgrade de pago: usar activate.
    -- FREE no se agenda aqui: usar pr_cancel_subscription.
    PROCEDURE pr_change_plan(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/cancel
    -- Terminar suscripcion: agenda FREE al fin de ciclo, auto_renew=0, canceled_at.
    -- Al aplicar: FREE + READ_ONLY + cancela addons sin credito.
    PROCEDURE pr_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/cancel/undo
    -- Deshace cancelacion programada (antes del period_end).
    PROCEDURE pr_undo_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/addon/cancel  (inmediato + credito por dias no usados)
    PROCEDURE pr_cancel_storage_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/invoice/:hash  (estado de una factura por hash Pagopar)
    PROCEDURE pr_get_invoice_by_hash(
        pi_auth_header   IN  VARCHAR2,
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/invoices  (historial de facturas de la org)
    PROCEDURE pr_list_invoices(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /pagopar/subscription/webhook  (confirmaci?n Pagopar de facturaci?n de plataforma)
    PROCEDURE pr_subscription_webhook(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    ----------------------------------------------------------------------------
    -- Pago recurrente: catastro de tarjeta (uPay) + activacion + ciclo de cobro
    -- (API Pagopar pago-recurrente/3.0 via PKG_AOX_PAGOPAR_API).
    ----------------------------------------------------------------------------

    -- POST /workspace/subscription/card/add  -> agregar-cliente + agregar-tarjeta
    -- Devuelve { id_form, iframe_url, provider } para incrustar el iframe uPay.
    PROCEDURE pr_add_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/card/confirm  -> confirmar-tarjeta + listar-tarjeta
    -- Persiste las tarjetas catastradas ACTIVE en org_payment_card.
    PROCEDURE pr_confirm_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- GET /workspace/subscription/cards  -> tarjetas persistidas de la organizacion
    PROCEDURE pr_list_cards(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- DELETE /workspace/subscription/card/:id  -> eliminar-tarjeta (Pagopar + local)
    PROCEDURE pr_delete_card(
        pi_auth_header   IN  VARCHAR2,
        pi_card_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- POST /workspace/subscription/activate  -> primer cobro recurrente con la tarjeta default
    PROCEDURE pr_activate_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    -- Job HASEL_SUBSCRIPTION_BILLING_CYCLE: cobro mensual automatico + dunning.
    -- No expone HTTP; lo invoca DBMS_SCHEDULER (ver migracion del job, solo en produccion).
    PROCEDURE pr_run_billing_cycle;

END pkg_aox_subscription_billing_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_billing_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_billing_api IS

    c_iso_fmt      CONSTANT VARCHAR2(40) := 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM';
    c_plan_premium CONSTANT VARCHAR2(30) := 'PREMIUM';
    c_plan_base    CONSTANT VARCHAR2(30) := 'BASE';
    c_plan_free    CONSTANT VARCHAR2(30) := 'FREE';

    --------------------------------------------------------------------------
    -- Helpers
    --------------------------------------------------------------------------
    FUNCTION fn_ts_to_iso(pi_ts IN TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
    BEGIN
        IF pi_ts IS NULL THEN RETURN NULL; END IF;
        RETURN TO_CHAR(pi_ts, c_iso_fmt);
    END fn_ts_to_iso;

    FUNCTION fn_is_forma_pago_allowed(pi_forma_pago IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN pi_forma_pago IN (c_forma_pago_bancard, c_forma_pago_qr);
    END fn_is_forma_pago_allowed;

    PROCEDURE pr_assert_admin(pi_auth_header IN VARCHAR2, po_org_id OUT NUMBER) IS
        v_role_id NUMBER;
    BEGIN
        po_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        v_role_id := pkg_aox_util.fn_get_role_id_from_jwt(pi_auth_header);

        IF NVL(po_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        -- Solo ADMIN (role_id = 1) gestiona facturaci?n del plan.
        IF NVL(v_role_id, 0) <> 1 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Solo el administrador puede gestionar el plan y la facturaci?n.');
        END IF;
    END pr_assert_admin;

    PROCEDURE pr_get_platform_keys(
        po_public_key  OUT VARCHAR2,
        po_private_key OUT VARCHAR2
    ) IS
    BEGIN
        po_public_key  := fn_get_parameter('SUBSCRIPTION_PAGOPAR_PUBLIC_KEY');
        po_private_key := fn_get_parameter('SUBSCRIPTION_PAGOPAR_PRIVATE_KEY');

        IF po_public_key IS NULL OR TRIM(po_public_key) IS NULL
           OR po_private_key IS NULL OR TRIM(po_private_key) IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'La facturaci?n de suscripci?n no est? configurada. Contact? a soporte de Hasel.'
            );
        END IF;
    END pr_get_platform_keys;

    FUNCTION fn_http_post_json(pi_url IN VARCHAR2, pi_body IN CLOB) RETURN CLOB IS
        v_response CLOB;
    BEGIN
        apex_web_service.g_request_headers.delete();
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';

        v_response := apex_web_service.make_rest_request(
            p_url         => pi_url,
            p_http_method => 'POST',
            p_body        => pi_body
        );

        IF apex_web_service.g_status_code NOT BETWEEN 200 AND 299 THEN
            RAISE_APPLICATION_ERROR(
                -20014,
                'Pagopar respondi? HTTP ' || apex_web_service.g_status_code || ': '
                || DBMS_LOB.SUBSTR(v_response, 1000, 1)
            );
        END IF;

        RETURN v_response;
    END fn_http_post_json;

    /** Recalcula y persiste storage_limit_bytes = storage del plan + addons activos. */
    PROCEDURE pr_refresh_storage_limit(pi_org_id IN NUMBER) IS
        v_limit NUMBER;
    BEGIN
        -- Calcular en un statement separado: no se puede consultar org_subscription
        -- dentro del UPDATE de la misma tabla (tabla mutante).
        v_limit := pkg_aox_subscription_api.fn_get_storage_limit_bytes(pi_org_id);

        UPDATE /*+ no_parallel */ org_subscription
           SET storage_limit_bytes = v_limit,
               updated_at          = systimestamp
         WHERE org_id_organization = pi_org_id;
    END pr_refresh_storage_limit;

    PROCEDURE pr_put_features(pi_plan_id IN NUMBER, pio_plan IN OUT NOCOPY json_object_t) IS
        v_features json_array_t := json_array_t();
    BEGIN
        FOR rec IN (
            SELECT feature_code
              FROM ref_plan_feature
             WHERE pln_id_plan = pi_plan_id
               AND is_enabled = 1
             ORDER BY feature_code
        ) LOOP
            v_features.append(rec.feature_code);
        END LOOP;
        pio_plan.put('features', v_features);
    END pr_put_features;

    --------------------------------------------------------------------------
    -- Pago recurrente: helpers privados
    --------------------------------------------------------------------------
    PROCEDURE pr_get_org_contact(
        pi_org_id IN  NUMBER,
        po_name   OUT VARCHAR2,
        po_email  OUT VARCHAR2,
        po_phone  OUT VARCHAR2
    ) IS
        -- Pagopar (agregar-cliente) exige celular con minimo 10 digitos.
        c_phone_fallback CONSTANT VARCHAR2(20) := '0981000000';
        v_digits         VARCHAR2(60);
    BEGIN
        SELECT name, company_email
          INTO po_name, po_email
          FROM organization
         WHERE id_organization = pi_org_id;

        BEGIN
            SELECT REGEXP_REPLACE(public_whatsapp, '[^0-9]', '')
              INTO v_digits
              FROM workspace_setting
             WHERE org_id_organization = pi_org_id
               AND public_whatsapp IS NOT NULL
               AND LENGTH(REGEXP_REPLACE(public_whatsapp, '[^0-9]', '')) >= 10
               AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_digits := NULL;
        END;

        IF v_digits IS NULL THEN
            BEGIN
                SELECT REGEXP_REPLACE(phone_number, '[^0-9]', '')
                  INTO v_digits
                  FROM professional
                 WHERE org_id_organization = pi_org_id
                   AND LENGTH(REGEXP_REPLACE(phone_number, '[^0-9]', '')) >= 10
                   AND ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_digits := NULL;
            END;
        END IF;

        IF v_digits IS NULL OR LENGTH(v_digits) < 10 THEN
            po_phone := c_phone_fallback;
        ELSE
            po_phone := v_digits;
        END IF;

        IF po_email IS NULL OR po_email NOT LIKE '%@%' THEN
            po_email := 'facturacion+org' || pi_org_id || '@hasel.app';
        END IF;
    END pr_get_org_contact;

    /** iniciar-transaccion (comercios/2.0): crea el pedido y devuelve el hash. */
    FUNCTION fn_iniciar_transaccion(
        pi_org_id      IN NUMBER,
        pi_invoice_id  IN NUMBER,
        pi_amount      IN NUMBER,
        pi_item_name   IN VARCHAR2,
        pi_desc        IN VARCHAR2,
        pi_public_key  IN VARCHAR2,
        pi_private_key IN VARCHAR2,
        pi_expires_at  IN TIMESTAMP WITH TIME ZONE,
        pi_forma_pago  IN NUMBER DEFAULT c_forma_pago_bancard
    ) RETURN VARCHAR2 IS
        v_id_pedido     VARCHAR2(64) := 'SUB-' || pi_invoice_id;
        v_token         VARCHAR2(64);
        v_org_name      organization.name%TYPE;
        v_org_email     organization.company_email%TYPE;
        v_org_phone     VARCHAR2(60);
        v_comprador     json_object_t := json_object_t();
        v_item          json_object_t := json_object_t();
        v_items         json_array_t  := json_array_t();
        v_pp_body       json_object_t := json_object_t();
        v_pp_raw        CLOB;
        v_pp_resp       json_object_t;
        v_pp_result     json_array_t;
        v_pp_result_obj json_object_t;
        v_api_url       VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_API_INICIAR_URL'), 'https://api.pagopar.com/api/comercios/2.0/iniciar-transaccion');
    BEGIN
        pr_get_org_contact(pi_org_id, v_org_name, v_org_email, v_org_phone);
        v_token := pkg_aox_pagopar_api.fn_pagopar_sha1_token(pi_private_key || v_id_pedido || TO_CHAR(pi_amount));

        v_comprador.put('ruc', '');
        v_comprador.put('email', v_org_email);
        v_comprador.put('ciudad', '1');
        v_comprador.put('nombre', v_org_name);
        v_comprador.put('telefono', v_org_phone);
        v_comprador.put('direccion', '');
        v_comprador.put('documento', TO_CHAR(pi_org_id));
        v_comprador.put('coordenadas', '');
        v_comprador.put('razon_social', v_org_name);
        v_comprador.put('tipo_documento', 'CI');
        v_comprador.put('direccion_referencia', '');

        v_item.put('ciudad', '1');
        v_item.put('nombre', pi_item_name);
        v_item.put('cantidad', 1);
        v_item.put('categoria', '1909');
        v_item.put('public_key', pi_public_key);
        v_item.put('url_imagen', '');
        v_item.put('descripcion', pi_desc);
        v_item.put('id_producto', pi_invoice_id);
        v_item.put('precio_total', pi_amount);
        v_item.put('vendedor_telefono', '');
        v_item.put('vendedor_direccion', '');
        v_item.put('vendedor_direccion_referencia', '');
        v_item.put('vendedor_direccion_coordenadas', '');
        v_items.append(v_item);

        v_pp_body.put('token', v_token);
        v_pp_body.put('comprador', v_comprador);
        v_pp_body.put('public_key', pi_public_key);
        v_pp_body.put('monto_total', pi_amount);
        v_pp_body.put('tipo_pedido', 'VENTA-COMERCIO');
        v_pp_body.put('compras_items', v_items);
        v_pp_body.put('fecha_maxima_pago', TO_CHAR(pi_expires_at AT TIME ZONE 'America/Asuncion', 'YYYY-MM-DD HH24:MI:SS'));
        v_pp_body.put('id_pedido_comercio', v_id_pedido);
        v_pp_body.put('descripcion_resumen', pi_desc);
        v_pp_body.put('forma_pago', pi_forma_pago);

        v_pp_raw  := fn_http_post_json(v_api_url, v_pp_body.to_clob());
        v_pp_resp := json_object_t.parse(v_pp_raw);

        IF NOT v_pp_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20018, NVL(v_pp_resp.get_string('resultado'), 'Pagopar rechazo la transaccion.'));
        END IF;

        v_pp_result     := v_pp_resp.get_array('resultado');
        v_pp_result_obj := TREAT(v_pp_result.get(0) AS json_object_t);
        RETURN v_pp_result_obj.get_string('data');
    END fn_iniciar_transaccion;

    /** pagopar_card_id de la tarjeta default ACTIVE de la organizacion (NULL si no hay). */
    FUNCTION fn_default_card_pagopar_id(pi_org_id IN NUMBER) RETURN VARCHAR2 IS
        v_card_id org_payment_card.pagopar_card_id%TYPE;
    BEGIN
        SELECT pagopar_card_id INTO v_card_id
          FROM org_payment_card
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE'
           AND is_default = 1
           AND pagopar_card_id IS NOT NULL
         FETCH FIRST 1 ROW ONLY;
        RETURN v_card_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        RETURN NULL;
    END fn_default_card_pagopar_id;

    /** Llama listar-tarjeta y devuelve el alias_token temporal (15 min) de una tarjeta. */
    FUNCTION fn_alias_token_for(
        pi_org_id         IN NUMBER,
        pi_pagopar_card_id IN VARCHAR2,
        pi_public_key     IN VARCHAR2,
        pi_private_key    IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_raw    CLOB;
        v_resp   json_object_t;
        v_arr    json_array_t;
        v_obj    json_object_t;
    BEGIN
        v_raw  := pkg_aox_pagopar_api.fn_list_cards(pi_public_key, pi_private_key, TO_CHAR(pi_org_id));
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RETURN NULL;
        END IF;
        v_arr := v_resp.get_array('resultado');
        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            v_obj := json_object_t(v_arr.get(i));
            IF v_obj.get_string('tarjeta') = pi_pagopar_card_id THEN
                RETURN v_obj.get_string('alias_token');
            END IF;
        END LOOP;
        RETURN NULL;
    END fn_alias_token_for;

    /** Upsert de las tarjetas de listar-tarjeta en org_payment_card. Devuelve cantidad ACTIVE. */
    PROCEDURE pr_sync_cards(pi_org_id IN NUMBER, pi_list_raw IN CLOB) IS
        v_resp     json_object_t;
        v_arr      json_array_t;
        v_obj      json_object_t;
        v_card_id  VARCHAR2(64);
        v_brand    VARCHAR2(40);
        v_masked   VARCHAR2(40);
        v_card_type VARCHAR2(20);
        v_issuer   VARCHAR2(120);
        v_provider VARCHAR2(20);
        v_has_def  NUMBER := 0;
        v_active   NUMBER := 0;
    BEGIN
        v_resp := json_object_t.parse(pi_list_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RETURN;
        END IF;

        v_arr := v_resp.get_array('resultado');
        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            -- Extraer a variables PL/SQL: no usar json_object_t.* dentro de MERGE (ORA-40573).
            v_obj       := json_object_t(v_arr.get(i));
            v_card_id   := v_obj.get_string('tarjeta');
            v_brand     := v_obj.get_string('marca');
            v_masked    := v_obj.get_string('tarjeta_numero');
            v_card_type := v_obj.get_string('tipo_tarjeta');
            v_issuer    := v_obj.get_string('emisor');
            v_provider  := NVL(v_obj.get_string('proveedor'), 'uPay');

            MERGE /*+ no_parallel */ INTO org_payment_card t
            USING (SELECT pi_org_id AS org_id, v_card_id AS card_id FROM dual) s
               ON (t.org_id_organization = s.org_id AND t.pagopar_card_id = s.card_id)
            WHEN MATCHED THEN
                UPDATE SET t.status        = 'ACTIVE',
                           t.brand         = v_brand,
                           t.masked_number = v_masked,
                           t.card_type     = v_card_type,
                           t.issuer        = v_issuer,
                           t.provider      = NVL(v_provider, t.provider),
                           t.confirmed_at  = NVL(t.confirmed_at, systimestamp),
                           t.updated_at    = systimestamp
            WHEN NOT MATCHED THEN
                INSERT (org_id_organization, provider, pagopar_identificador, pagopar_card_id,
                        brand, masked_number, card_type, issuer, status, is_default, confirmed_at)
                VALUES (pi_org_id, v_provider, TO_CHAR(pi_org_id), s.card_id,
                        v_brand, v_masked, v_card_type, v_issuer,
                        'ACTIVE', 0, systimestamp);
        END LOOP;

        -- Marcar DELETED las tarjetas locales ACTIVE que Pagopar ya no lista.
        UPDATE /*+ no_parallel */ org_payment_card
           SET status = 'DELETED', is_default = 0, updated_at = systimestamp
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE'
           AND NOT EXISTS (
               SELECT 1 FROM json_table(
                   pi_list_raw, '$.resultado[*]'
                   COLUMNS (tarjeta VARCHAR2(64) PATH '$.tarjeta')
               ) jt WHERE jt.tarjeta = org_payment_card.pagopar_card_id
           );

        -- Asegurar una tarjeta default si hay ACTIVE y ninguna default.
        SELECT COUNT(*) INTO v_active FROM org_payment_card
         WHERE org_id_organization = pi_org_id AND status = 'ACTIVE';
        SELECT COUNT(*) INTO v_has_def FROM org_payment_card
         WHERE org_id_organization = pi_org_id AND status = 'ACTIVE' AND is_default = 1;

        IF v_active > 0 AND v_has_def = 0 THEN
            UPDATE /*+ no_parallel */ org_payment_card
               SET is_default = 1, updated_at = systimestamp
             WHERE id_payment_card = (
                 SELECT id_payment_card FROM (
                     SELECT id_payment_card FROM org_payment_card
                      WHERE org_id_organization = pi_org_id AND status = 'ACTIVE'
                      ORDER BY confirmed_at DESC NULLS LAST, id_payment_card DESC
                 ) WHERE ROWNUM = 1
             );
        END IF;
    END pr_sync_cards;

    --------------------------------------------------------------------------
    -- Facturacion consolidada / prorrateo
    --------------------------------------------------------------------------
    PROCEDURE pr_get_period_bounds(
        pi_org_id       IN  NUMBER,
        po_period_start OUT TIMESTAMP WITH TIME ZONE,
        po_period_end   OUT TIMESTAMP WITH TIME ZONE
    ) IS
    BEGIN
        SELECT current_period_start, current_period_end
          INTO po_period_start, po_period_end
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_period_start := NULL;
            po_period_end   := NULL;
    END pr_get_period_bounds;

    FUNCTION fn_calendar_days_between(
        pi_from IN TIMESTAMP WITH TIME ZONE,
        pi_to   IN TIMESTAMP WITH TIME ZONE
    ) RETURN NUMBER IS
    BEGIN
        IF pi_from IS NULL OR pi_to IS NULL THEN
            RETURN 0;
        END IF;
        RETURN GREATEST(0, TRUNC(CAST(pi_to AS DATE)) - TRUNC(CAST(pi_from AS DATE)));
    END fn_calendar_days_between;

    FUNCTION fn_prorate_amount(
        pi_full_amount    IN NUMBER,
        pi_days_remaining IN NUMBER,
        pi_period_days    IN NUMBER,
        pi_enforce_min    IN NUMBER DEFAULT 1
    ) RETURN NUMBER IS
        v_period NUMBER := GREATEST(1, NVL(pi_period_days, 1));
        v_days   NUMBER := GREATEST(0, NVL(pi_days_remaining, 0));
        v_amt    NUMBER;
    BEGIN
        IF v_days <= 0 OR NVL(pi_full_amount, 0) <= 0 THEN
            RETURN 0;
        END IF;
        v_amt := CEIL(pi_full_amount * v_days / v_period);
        -- Pagopar exige minimo 1000 Gs en cobros; creditos no aplican piso.
        IF NVL(pi_enforce_min, 1) = 1 AND v_amt > 0 AND v_amt < 1000 THEN
            v_amt := 1000;
        END IF;
        RETURN v_amt;
    END fn_prorate_amount;

    /** Credito por tiempo no usado de cualquier item mensual (plan o addon). */
    FUNCTION fn_unused_credit_amount(
        pi_org_id       IN NUMBER,
        pi_full_monthly IN NUMBER
    ) RETURN NUMBER IS
        v_start TIMESTAMP WITH TIME ZONE;
        v_end   TIMESTAMP WITH TIME ZONE;
        v_days  NUMBER;
        v_per   NUMBER;
    BEGIN
        IF NVL(pi_full_monthly, 0) <= 0 THEN
            RETURN 0;
        END IF;
        pr_get_period_bounds(pi_org_id, v_start, v_end);
        IF v_end IS NULL OR v_end <= systimestamp THEN
            RETURN 0;
        END IF;
        v_days := fn_calendar_days_between(systimestamp, v_end);
        v_per  := fn_calendar_days_between(NVL(v_start, ADD_MONTHS(v_end, -1)), v_end);
        IF v_per < 1 THEN
            v_per := 30;
        END IF;
        RETURN fn_prorate_amount(pi_full_monthly, v_days, v_per, 0);
    END fn_unused_credit_amount;

    PROCEDURE pr_grant_credit(
        pi_org_id    IN NUMBER,
        pi_amount    IN NUMBER,
        pi_reason    IN VARCHAR2,
        pi_ref_code  IN VARCHAR2 DEFAULT NULL,
        pi_invoice_id IN NUMBER DEFAULT NULL
    ) IS
        v_bal NUMBER;
        v_amt NUMBER := GREATEST(0, ROUND(NVL(pi_amount, 0)));
    BEGIN
        IF v_amt <= 0 THEN
            RETURN;
        END IF;
        UPDATE /*+ no_parallel */ org_subscription
           SET account_balance = NVL(account_balance, 0) + v_amt,
               updated_at      = systimestamp
         WHERE org_id_organization = pi_org_id
        RETURNING account_balance INTO v_bal;

        INSERT /*+ no_parallel */ INTO org_billing_credit_ledger (
            org_id_organization, delta_amount, balance_after, reason, invoice_id, ref_code
        ) VALUES (
            pi_org_id, v_amt, v_bal, UPPER(TRIM(pi_reason)), pi_invoice_id, pi_ref_code
        );
    END pr_grant_credit;

    PROCEDURE pr_apply_credit_to_amount(
        pi_org_id         IN  NUMBER,
        pi_gross          IN  NUMBER,
        po_net            OUT NUMBER,
        po_credit_applied OUT NUMBER
    ) IS
        v_bal NUMBER;
        v_gross NUMBER := GREATEST(0, ROUND(NVL(pi_gross, 0)));
    BEGIN
        SELECT NVL(account_balance, 0)
          INTO v_bal
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        po_credit_applied := LEAST(v_bal, v_gross);
        po_net            := v_gross - po_credit_applied;
    END pr_apply_credit_to_amount;

    PROCEDURE pr_consume_credit(
        pi_org_id         IN NUMBER,
        pi_credit_applied IN NUMBER,
        pi_invoice_id     IN NUMBER
    ) IS
        v_bal NUMBER;
        v_amt NUMBER := GREATEST(0, ROUND(NVL(pi_credit_applied, 0)));
        v_already NUMBER;
    BEGIN
        IF v_amt <= 0 THEN
            RETURN;
        END IF;

        -- Idempotencia: no consumir dos veces la misma factura.
        SELECT COUNT(*)
          INTO v_already
          FROM org_billing_credit_ledger
         WHERE invoice_id = pi_invoice_id
           AND reason = 'APPLY_INVOICE';
        IF v_already > 0 THEN
            RETURN;
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET account_balance = GREATEST(0, NVL(account_balance, 0) - v_amt),
               updated_at      = systimestamp
         WHERE org_id_organization = pi_org_id
        RETURNING account_balance INTO v_bal;

        INSERT /*+ no_parallel */ INTO org_billing_credit_ledger (
            org_id_organization, delta_amount, balance_after, reason, invoice_id, ref_code
        ) VALUES (
            pi_org_id, -v_amt, v_bal, 'APPLY_INVOICE', pi_invoice_id, NULL
        );
    END pr_consume_credit;

    PROCEDURE pr_cancel_active_addons_no_credit(pi_org_id IN NUMBER) IS
    BEGIN
        UPDATE /*+ no_parallel */ org_storage_addon
           SET status  = 'CANCELED',
               ends_at = NVL(ends_at, systimestamp)
         WHERE org_id_organization = pi_org_id
           AND status = 'ACTIVE';
    END pr_cancel_active_addons_no_credit;

    PROCEDURE pr_apply_due_pending_plan(pi_org_id IN NUMBER) IS
        v_pending_id   NUMBER;
        v_pending_at   TIMESTAMP WITH TIME ZONE;
        v_period_end   TIMESTAMP WITH TIME ZONE;
        v_pending_code VARCHAR2(30);
    BEGIN
        SELECT pending_pln_id_plan, pending_plan_change_at, current_period_end
          INTO v_pending_id, v_pending_at, v_period_end
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        IF v_pending_id IS NULL THEN
            RETURN;
        END IF;

        IF (v_pending_at IS NOT NULL AND v_pending_at <= systimestamp)
           OR (v_period_end IS NOT NULL AND v_period_end <= systimestamp) THEN
            BEGIN
                SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_pending_code := NULL;
            END;

            IF v_pending_code = c_plan_free THEN
                -- Terminar: FREE + READ_ONLY + apagar cobros + cancelar addons (sin credito).
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_pending_id,
                       status                 = 'READ_ONLY',
                       auto_renew             = 0,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = pi_org_id;
                pr_cancel_active_addons_no_credit(pi_org_id);
            ELSE
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_pending_id,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = pi_org_id;
            END IF;
            pr_refresh_storage_limit(pi_org_id);
        END IF;
    END pr_apply_due_pending_plan;

    PROCEDURE pr_fulfill_paid_subscription(
        pi_org_id  IN NUMBER,
        pi_plan_id IN NUMBER
    ) IS
    BEGIN
        UPDATE /*+ no_parallel */ org_subscription
           SET pln_id_plan            = pi_plan_id,
               status                 = 'ACTIVE',
               auto_renew             = 1,
               canceled_at            = NULL,
               current_period_start   = systimestamp,
               current_period_end     = ADD_MONTHS(GREATEST(NVL(current_period_end, systimestamp), systimestamp), 1),
               grace_ends_at          = NULL,
               charge_retry_count     = 0,
               last_charge_at         = systimestamp,
               pending_pln_id_plan    = NULL,
               pending_plan_change_at = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = pi_org_id;
        pr_refresh_storage_limit(pi_org_id);
    END pr_fulfill_paid_subscription;

    PROCEDURE pr_fulfill_paid_addon(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) IS
    BEGIN
        IF pi_addon_id IS NULL THEN
            RETURN;
        END IF;
        MERGE /*+ no_parallel */ INTO org_storage_addon t
        USING (SELECT pi_org_id AS org_id, pi_addon_id AS addon_id FROM dual) s
           ON (t.org_id_organization = s.org_id AND t.sad_id_storage_addon = s.addon_id AND t.status = 'ACTIVE')
        WHEN MATCHED THEN
            UPDATE SET t.quantity = t.quantity + 1
        WHEN NOT MATCHED THEN
            INSERT (org_id_organization, sad_id_storage_addon, quantity, status)
            VALUES (s.org_id, s.addon_id, 1, 'ACTIVE');
        pr_refresh_storage_limit(pi_org_id);
    END pr_fulfill_paid_addon;

    FUNCTION fn_addons_monthly_total(pi_org_id IN NUMBER) RETURN NUMBER IS
        v_total NUMBER;
    BEGIN
        SELECT NVL(SUM(r.price_amount * o.quantity), 0)
          INTO v_total
          FROM org_storage_addon o
          JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
         WHERE o.org_id_organization = pi_org_id
           AND o.status = 'ACTIVE'
           AND r.is_active = 1;
        RETURN v_total;
    END fn_addons_monthly_total;

    FUNCTION fn_addons_desc_suffix(pi_org_id IN NUMBER) RETURN VARCHAR2 IS
        v_parts VARCHAR2(500);
    BEGIN
        SELECT LISTAGG(r.name || CASE WHEN o.quantity > 1 THEN ' x' || o.quantity ELSE '' END, ' + ')
                 WITHIN GROUP (ORDER BY r.sort_order, r.id_storage_addon)
          INTO v_parts
          FROM org_storage_addon o
          JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
         WHERE o.org_id_organization = pi_org_id
           AND o.status = 'ACTIVE';
        RETURN v_parts;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_addons_desc_suffix;

    PROCEDURE pr_activate_addon_free(
        pi_org_id   IN NUMBER,
        pi_addon_id IN NUMBER
    ) IS
    BEGIN
        MERGE /*+ no_parallel */ INTO org_storage_addon t
        USING (SELECT pi_org_id AS org_id, pi_addon_id AS addon_id FROM dual) s
           ON (t.org_id_organization = s.org_id AND t.sad_id_storage_addon = s.addon_id AND t.status = 'ACTIVE')
        WHEN MATCHED THEN
            UPDATE SET t.quantity = t.quantity + 1
        WHEN NOT MATCHED THEN
            INSERT (org_id_organization, sad_id_storage_addon, quantity, status)
            VALUES (s.org_id, s.addon_id, 1, 'ACTIVE');
        pr_refresh_storage_limit(pi_org_id);
        COMMIT;
    END pr_activate_addon_free;

    /**
     * Cobro recurrente de un target con la tarjeta default:
     *   PLAN            -> solo precio del plan (activacion / upgrade)
     *   STORAGE_ADDON   -> prorrateo hasta current_period_end
     *   CONSOLIDATED    -> plan + addons ACTIVE (ciclo de renovacion)
     * Aplica account_balance (gross/credit_applied/amount neto).
     * Si net=0: PAID inmediato sin Pagopar. Si net>0: webhook confirma PAID.
     */
    PROCEDURE pr_charge_target(
        pi_org_id      IN  NUMBER,
        pi_target_type IN  VARCHAR2,
        pi_plan_code   IN  VARCHAR2,
        pi_addon_code  IN  VARCHAR2,
        po_invoice_id  OUT NUMBER,
        po_hash        OUT VARCHAR2
    ) IS
        v_public_key   VARCHAR2(500);
        v_private_key  VARCHAR2(500);
        v_sub_id       org_subscription.id_subscription%TYPE;
        v_plan_id      ref_plan.id_plan%TYPE;
        v_addon_id     ref_storage_addon.id_storage_addon%TYPE;
        v_full_amount  NUMBER;
        v_gross        NUMBER := 0;
        v_net          NUMBER := 0;
        v_credit       NUMBER := 0;
        v_pay_amount   NUMBER;
        v_currency     VARCHAR2(3) := 'PYG';
        v_item_name    VARCHAR2(150);
        v_desc         VARCHAR2(255);
        v_invoice_type VARCHAR2(20);
        v_period_start TIMESTAMP WITH TIME ZONE := systimestamp;
        v_period_end   TIMESTAMP WITH TIME ZONE := ADD_MONTHS(systimestamp, 1);
        v_sub_start    TIMESTAMP WITH TIME ZONE;
        v_sub_end      TIMESTAMP WITH TIME ZONE;
        v_days_rem     NUMBER;
        v_period_days  NUMBER;
        v_addon_total  NUMBER;
        v_addon_suffix VARCHAR2(500);
        v_expires_at   TIMESTAMP WITH TIME ZONE := systimestamp + NUMTODSINTERVAL(NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_PAYMENT_PENDING_MINUTES')), 1440), 'MINUTE');
        v_founder      NUMBER(1,0) := 0;
        v_card_id      org_payment_card.pagopar_card_id%TYPE;
        v_alias_token  VARCHAR2(256);
        v_pay_raw      CLOB;
        v_pay_resp     json_object_t;
        v_target       VARCHAR2(20) := UPPER(TRIM(pi_target_type));
    BEGIN
        SELECT id_subscription, NVL(is_founder, 0)
          INTO v_sub_id, v_founder
          FROM org_subscription
         WHERE org_id_organization = pi_org_id;

        pr_get_period_bounds(pi_org_id, v_sub_start, v_sub_end);

        IF v_target IN ('PLAN', 'CONSOLIDATED') AND UPPER(TRIM(pi_plan_code)) = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'El plan Continuidad no se cobra. Elegi Base o Premium para reactivar.'
            );
        END IF;

        IF v_target = 'PLAN' THEN
            BEGIN
                SELECT id_plan, price_amount, currency, name
                  INTO v_plan_id, v_gross, v_currency, v_item_name
                  FROM ref_plan WHERE code = pi_plan_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
            END;

            IF v_founder = 1 AND pi_plan_code = c_plan_premium THEN
                v_gross := ROUND(v_gross * 0.5);
                v_desc := 'Suscripcion ' || v_item_name || ' fundador 50% (1 mes)';
            ELSE
                v_desc := 'Suscripcion ' || v_item_name || ' (1 mes)';
            END IF;
            v_invoice_type := 'SUBSCRIPTION';

        ELSIF v_target = 'CONSOLIDATED' THEN
            BEGIN
                SELECT id_plan, price_amount, currency, name
                  INTO v_plan_id, v_gross, v_currency, v_item_name
                  FROM ref_plan WHERE code = pi_plan_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
            END;

            IF v_founder = 1 AND pi_plan_code = c_plan_premium THEN
                v_gross := ROUND(v_gross * 0.5);
            END IF;

            v_addon_total  := fn_addons_monthly_total(pi_org_id);
            v_addon_suffix := fn_addons_desc_suffix(pi_org_id);
            v_gross        := NVL(v_gross, 0) + NVL(v_addon_total, 0);

            IF v_addon_suffix IS NOT NULL THEN
                v_desc := v_item_name || ' + ' || v_addon_suffix || ' (1 mes)';
            ELSE
                v_desc := 'Suscripcion ' || v_item_name || ' (1 mes)';
            END IF;

            IF v_sub_end IS NOT NULL THEN
                v_period_start := NVL(v_sub_end, systimestamp);
                v_period_end   := ADD_MONTHS(v_period_start, 1);
            END IF;
            v_invoice_type := 'SUBSCRIPTION';

        ELSIF v_target = 'STORAGE_ADDON' THEN
            IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'APPOINTMENT_HISTORY') = 0 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Los paquetes de almacenamiento solo estan disponibles en el plan Premium.');
            END IF;
            BEGIN
                SELECT id_storage_addon, price_amount, currency, name
                  INTO v_addon_id, v_full_amount, v_currency, v_item_name
                  FROM ref_storage_addon WHERE code = pi_addon_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Paquete de almacenamiento no valido.');
            END;

            IF v_sub_end IS NOT NULL AND v_sub_end > systimestamp THEN
                v_days_rem    := fn_calendar_days_between(systimestamp, v_sub_end);
                v_period_days := fn_calendar_days_between(
                    NVL(v_sub_start, ADD_MONTHS(v_sub_end, -1)),
                    v_sub_end
                );
                IF v_period_days < 1 THEN
                    v_period_days := 30;
                END IF;
                v_gross        := fn_prorate_amount(v_full_amount, v_days_rem, v_period_days, 1);
                v_period_start := systimestamp;
                v_period_end   := v_sub_end;
                IF v_days_rem <= 0 THEN
                    v_desc := v_item_name || ' (sin cobro; entra en la renovacion)';
                ELSE
                    v_desc := v_item_name || ' (prorrateo ' || v_days_rem || ' dia(s))';
                END IF;
            ELSE
                v_gross        := v_full_amount;
                v_period_start := systimestamp;
                v_period_end   := ADD_MONTHS(systimestamp, 1);
                v_desc         := v_item_name || ' (1 mes)';
            END IF;

            IF NVL(v_gross, 0) <= 0 THEN
                pr_activate_addon_free(pi_org_id, v_addon_id);
                po_invoice_id := NULL;
                po_hash       := NULL;
                RETURN;
            END IF;
            v_invoice_type := 'STORAGE_ADDON';
            v_plan_id      := NULL;
        ELSE
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'target_type invalido (PLAN, STORAGE_ADDON o CONSOLIDATED).');
        END IF;

        pr_apply_credit_to_amount(pi_org_id, v_gross, v_net, v_credit);
        IF v_credit > 0 THEN
            v_desc := SUBSTR(v_desc || ' - credito ' || TO_CHAR(v_credit) || ' Gs', 1, 255);
        END IF;

        -- Cubierto 100% por saldo: PAID sin Pagopar ni tarjeta.
        IF v_net <= 0 THEN
            INSERT /*+ no_parallel */ INTO org_subscription_invoice (
                org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
                sad_id_storage_addon, description, amount, gross_amount, credit_applied,
                currency, status, period_start, period_end, due_date, paid_at, payment_provider
            ) VALUES (
                pi_org_id, v_sub_id, v_invoice_type, v_plan_id,
                v_addon_id, v_desc, 0, v_gross, v_credit,
                v_currency, 'PAID', v_period_start, v_period_end, v_expires_at, systimestamp, 'credit'
            ) RETURNING id_invoice INTO po_invoice_id;

            pr_consume_credit(pi_org_id, v_credit, po_invoice_id);

            IF v_invoice_type = 'SUBSCRIPTION' THEN
                pr_fulfill_paid_subscription(pi_org_id, v_plan_id);
            ELSIF v_invoice_type = 'STORAGE_ADDON' THEN
                pr_fulfill_paid_addon(pi_org_id, v_addon_id);
            END IF;
            COMMIT;
            po_hash := NULL;
            RETURN;
        END IF;

        pr_get_platform_keys(v_public_key, v_private_key);
        v_card_id := fn_default_card_pagopar_id(pi_org_id);
        IF v_card_id IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'Agrega una tarjeta antes de activar la suscripcion.');
        END IF;

        -- Minimo Pagopar 1000 Gs; no se consume credito extra.
        v_pay_amount := v_net;
        IF v_pay_amount > 0 AND v_pay_amount < 1000 THEN
            v_pay_amount := 1000;
        END IF;

        INSERT /*+ no_parallel */ INTO org_subscription_invoice (
            org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
            sad_id_storage_addon, description, amount, gross_amount, credit_applied,
            currency, status, period_start, period_end, due_date, payment_provider
        ) VALUES (
            pi_org_id, v_sub_id, v_invoice_type, v_plan_id,
            v_addon_id, v_desc, v_pay_amount, v_gross, v_credit,
            v_currency, 'PENDING', v_period_start, v_period_end, v_expires_at, 'pagopar'
        ) RETURNING id_invoice INTO po_invoice_id;

        po_hash := fn_iniciar_transaccion(
            pi_org_id      => pi_org_id,
            pi_invoice_id  => po_invoice_id,
            pi_amount      => v_pay_amount,
            pi_item_name   => v_item_name,
            pi_desc        => v_desc,
            pi_public_key  => v_public_key,
            pi_private_key => v_private_key,
            pi_expires_at  => v_expires_at,
            pi_forma_pago  => c_forma_pago_bancard
        );

        UPDATE /*+ no_parallel */ org_subscription_invoice
           SET external_reference = po_hash
         WHERE id_invoice = po_invoice_id;

        COMMIT;

        v_alias_token := fn_alias_token_for(pi_org_id, v_card_id, v_public_key, v_private_key);
        IF v_alias_token IS NULL THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice SET status = 'FAILED' WHERE id_invoice = po_invoice_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20031, 'No se pudo obtener la tarjeta catastrada para el cobro.');
        END IF;

        v_pay_raw  := pkg_aox_pagopar_api.fn_pay(v_public_key, v_private_key, TO_CHAR(pi_org_id), po_hash, v_alias_token);
        v_pay_resp := json_object_t.parse(v_pay_raw);

        IF NOT v_pay_resp.get_boolean('respuesta') THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice SET status = 'FAILED' WHERE id_invoice = po_invoice_id;
            COMMIT;
            RAISE_APPLICATION_ERROR(-20032, NVL(v_pay_resp.get_string('resultado'), 'Pagopar rechazo el cobro de la tarjeta.'));
        END IF;
    END pr_charge_target;

    --------------------------------------------------------------------------
    -- GET /workspace/plans
    --------------------------------------------------------------------------
    PROCEDURE pr_get_plans(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id          NUMBER;
        v_response        json_object_t := json_object_t();
        v_data            json_object_t := json_object_t();
        v_current         json_object_t := json_object_t();
        v_plans           json_array_t  := json_array_t();
        v_addons          json_array_t  := json_array_t();

        v_cur_plan_code   ref_plan.code%TYPE;
        v_cur_plan_name   ref_plan.name%TYPE;
        v_cur_plan_id     ref_plan.id_plan%TYPE;
        v_cur_plan_price  ref_plan.price_amount%TYPE;
        v_status          org_subscription.status%TYPE;
        v_is_founder      org_subscription.is_founder%TYPE;
        v_billing_exempt  org_subscription.billing_exempt%TYPE;
        v_storage_used    org_subscription.storage_used_bytes%TYPE;
        v_trial_ends_at   org_subscription.trial_ends_at%TYPE;
        v_period_start    org_subscription.current_period_start%TYPE;
        v_period_end      org_subscription.current_period_end%TYPE;
        v_grace_ends_at   org_subscription.grace_ends_at%TYPE;
        v_account_balance NUMBER := 0;
        v_pending_plan_id NUMBER;
        v_pending_at      TIMESTAMP WITH TIME ZONE;
        v_pending_code    VARCHAR2(30);
        v_pending_name    VARCHAR2(100);
        v_eff_state       VARCHAR2(20);
        v_storage_limit   NUMBER;
        v_platform_ok     NUMBER := 0;
        v_dummy_pub       VARCHAR2(500);
        v_dummy_priv      VARCHAR2(500);
        v_plan_monthly    NUMBER := 0;
        v_addons_monthly  NUMBER := 0;
        v_days_rem        NUMBER := 0;
        v_period_days     NUMBER := 30;
        v_active_addons   json_array_t := json_array_t();
        v_auto_renew      NUMBER(1,0) := 1;
        v_canceled_at     TIMESTAMP WITH TIME ZONE;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        -- Aplicar cancelacion/downgrade vencidos antes de armar el snapshot.
        pr_apply_due_pending_plan(v_org_id);
        COMMIT;

        SELECT s.pln_id_plan, p.code, p.name, p.price_amount, s.status, s.is_founder, s.billing_exempt,
               s.storage_used_bytes, s.trial_ends_at, s.current_period_start, s.current_period_end, s.grace_ends_at,
               NVL(s.account_balance, 0), s.pending_pln_id_plan, s.pending_plan_change_at,
               NVL(s.auto_renew, 1), s.canceled_at
          INTO v_cur_plan_id, v_cur_plan_code, v_cur_plan_name, v_cur_plan_price, v_status, v_is_founder, v_billing_exempt,
               v_storage_used, v_trial_ends_at, v_period_start, v_period_end, v_grace_ends_at,
               v_account_balance, v_pending_plan_id, v_pending_at,
               v_auto_renew, v_canceled_at
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_pending_plan_id IS NOT NULL THEN
            BEGIN
                SELECT code, name INTO v_pending_code, v_pending_name
                  FROM ref_plan WHERE id_plan = v_pending_plan_id;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                v_pending_code := NULL;
                v_pending_name := NULL;
            END;
        END IF;

        v_eff_state     := pkg_aox_subscription_api.fn_get_subscription_state(v_org_id);
        v_storage_limit := pkg_aox_subscription_api.fn_get_storage_limit_bytes(v_org_id);

        BEGIN
            pr_get_platform_keys(v_dummy_pub, v_dummy_priv);
            v_platform_ok := 1;
        EXCEPTION WHEN OTHERS THEN
            v_platform_ok := 0;
        END;

        IF NVL(v_is_founder, 0) = 1 AND v_cur_plan_code = c_plan_premium THEN
            v_plan_monthly := ROUND(v_cur_plan_price * 0.5);
        ELSE
            v_plan_monthly := NVL(v_cur_plan_price, 0);
        END IF;
        v_addons_monthly := fn_addons_monthly_total(v_org_id);

        IF v_period_end IS NOT NULL AND v_period_end > systimestamp THEN
            v_days_rem    := fn_calendar_days_between(systimestamp, v_period_end);
            v_period_days := fn_calendar_days_between(
                NVL(v_period_start, ADD_MONTHS(v_period_end, -1)),
                v_period_end
            );
            IF v_period_days < 1 THEN
                v_period_days := 30;
            END IF;
        ELSE
            v_days_rem    := 0;
            v_period_days := 30;
        END IF;

        FOR rec IN (
            SELECT r.code, r.name, r.price_amount, o.quantity, r.extra_bytes
              FROM org_storage_addon o
              JOIN ref_storage_addon r ON r.id_storage_addon = o.sad_id_storage_addon
             WHERE o.org_id_organization = v_org_id
               AND o.status = 'ACTIVE'
             ORDER BY r.sort_order, r.id_storage_addon
        ) LOOP
            DECLARE
                v_oa json_object_t := json_object_t();
                v_cancel_credit NUMBER;
            BEGIN
                v_cancel_credit := fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 0);
                v_oa.put('code', rec.code);
                v_oa.put('name', rec.name);
                v_oa.put('quantity', rec.quantity);
                v_oa.put('price_amount', rec.price_amount);
                v_oa.put('line_total', rec.price_amount * rec.quantity);
                v_oa.put('extra_bytes', rec.extra_bytes);
                v_oa.put('cancel_credit_amount', v_cancel_credit);
                v_oa.put('cancelable', 1);
                v_active_addons.append(v_oa);
            END;
        END LOOP;

        -- Snapshot actual
        v_current.put('plan_code'          , v_cur_plan_code);
        v_current.put('plan_name'          , v_cur_plan_name);
        v_current.put('status'             , v_status);
        v_current.put('effective_status'   , v_eff_state);
        v_current.put('can_write'          , pkg_aox_subscription_api.fn_org_can_write(v_org_id));
        v_current.put('is_founder'         , v_is_founder);
        v_current.put('billing_exempt'     , v_billing_exempt);
        v_current.put('founder_discount_percent', CASE WHEN NVL(v_is_founder, 0) = 1 THEN 50 ELSE 0 END);
        v_current.put('trial_ends_at'      , fn_ts_to_iso(v_trial_ends_at));
        v_current.put('current_period_start', fn_ts_to_iso(v_period_start));
        v_current.put('current_period_end' , fn_ts_to_iso(v_period_end));
        -- Alias UX: proxima fecha de facturacion (= current_period_end; editable en APEX).
        v_current.put('next_billing_at'    , fn_ts_to_iso(v_period_end));
        v_current.put('grace_ends_at'      , fn_ts_to_iso(v_grace_ends_at));
        -- Estimado del proximo cargo neto (despues de saldo a favor).
        v_current.put('next_charge_estimate',
            GREATEST(0, (v_plan_monthly + v_addons_monthly) - NVL(v_account_balance, 0)));
        v_current.put('storage_used_bytes' , v_storage_used);
        v_current.put('storage_limit_bytes', v_storage_limit);
        v_current.put('supports_storage_addons', CASE WHEN v_cur_plan_code = c_plan_premium THEN 1 ELSE 0 END);
        v_current.put('billing_configured' , v_platform_ok);
        v_current.put('plan_monthly_amount', v_plan_monthly);
        v_current.put('addons_monthly_amount', v_addons_monthly);
        v_current.put('monthly_total', v_plan_monthly + v_addons_monthly);
        v_current.put('days_remaining_in_period', v_days_rem);
        v_current.put('period_days', v_period_days);
        v_current.put('account_balance', v_account_balance);
        v_current.put('auto_renew', v_auto_renew);
        v_current.put('canceled_at', fn_ts_to_iso(v_canceled_at));
        v_current.put('cancel_scheduled',
            CASE WHEN v_pending_code = c_plan_free THEN 1 ELSE 0 END);
        IF v_pending_code IS NOT NULL THEN
            v_current.put('pending_plan_code', v_pending_code);
            v_current.put('pending_plan_name', v_pending_name);
            v_current.put('pending_plan_change_at', fn_ts_to_iso(v_pending_at));
        ELSE
            v_current.put_null('pending_plan_code');
            v_current.put_null('pending_plan_name');
            v_current.put_null('pending_plan_change_at');
        END IF;
        v_current.put('active_storage_addons', v_active_addons);

        -- Planes comerciales (excluye FREE / Continuidad del catalogo de compra)
        FOR rec IN (
            SELECT id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, sort_order
              FROM ref_plan
             WHERE is_active = 1
               AND code <> c_plan_free
             ORDER BY sort_order, id_plan
        ) LOOP
            DECLARE
                v_plan json_object_t := json_object_t();
                v_checkout NUMBER;
            BEGIN
                v_plan.put('id_plan'            , rec.id_plan);
                v_plan.put('code'               , rec.code);
                v_plan.put('name'               , rec.name);
                v_plan.put('price_amount'       , rec.price_amount);
                v_plan.put('currency'           , rec.currency);
                v_plan.put('billing_period'     , rec.billing_period);
                v_plan.put('storage_limit_bytes', rec.storage_limit_bytes);
                v_plan.put('is_current'         , CASE WHEN rec.id_plan = v_cur_plan_id THEN 1 ELSE 0 END);
                -- Precio a cobrar: fundadores pagan 50% del Premium de por vida.
                IF NVL(v_is_founder, 0) = 1 AND rec.code = c_plan_premium THEN
                    v_checkout := ROUND(rec.price_amount * 0.5);
                    v_plan.put('checkout_price_amount', v_checkout);
                    v_plan.put('founder_discount_percent', 50);
                ELSE
                    v_checkout := rec.price_amount;
                    v_plan.put('checkout_price_amount', v_checkout);
                    v_plan.put('founder_discount_percent', 0);
                END IF;
                -- Total mensual si eligen este plan (addons solo aplican en Premium).
                IF rec.code = c_plan_premium THEN
                    v_plan.put('monthly_total', v_checkout + v_addons_monthly);
                ELSE
                    v_plan.put('monthly_total', v_checkout);
                END IF;
                pr_put_features(rec.id_plan, v_plan);
                v_plans.append(v_plan);
            END;
        END LOOP;

        -- Addons de storage activos
        FOR rec IN (
            SELECT id_storage_addon, code, name, extra_bytes, price_amount, currency, billing_period, sort_order
              FROM ref_storage_addon
             WHERE is_active = 1
             ORDER BY sort_order, id_storage_addon
        ) LOOP
            DECLARE
                v_addon json_object_t := json_object_t();
                v_prorate NUMBER;
            BEGIN
                v_prorate := fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 1);
                v_addon.put('id_storage_addon', rec.id_storage_addon);
                v_addon.put('code'            , rec.code);
                v_addon.put('name'            , rec.name);
                v_addon.put('extra_bytes'     , rec.extra_bytes);
                v_addon.put('price_amount'    , rec.price_amount);
                v_addon.put('currency'        , rec.currency);
                v_addon.put('billing_period'  , rec.billing_period);
                v_addon.put('prorate_amount'  , v_prorate);
                v_addon.put('cancel_credit_amount', fn_prorate_amount(rec.price_amount, v_days_rem, v_period_days, 0));
                v_addon.put('days_remaining'  , v_days_rem);
                v_addon.put('period_days'     , v_period_days);
                v_addons.append(v_addon);
            END;
        END LOOP;

        v_data.put('current'       , v_current);
        v_data.put('plans'         , v_plans);
        v_data.put('storage_addons', v_addons);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data'  , v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'No se encontr? suscripci?n para la organizaci?n.',
                po_response_body => po_response_body
            );
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_plans;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/checkout
    --------------------------------------------------------------------------
    PROCEDURE pr_create_checkout(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_target_type VARCHAR2(20);
        v_plan_code   VARCHAR2(30);
        v_addon_code  VARCHAR2(30);
        v_invoice_id  NUMBER;
        v_hash        VARCHAR2(128);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        -- Modelo "solo recurrente": ya no se redirige a pagopar.com/pagos.
        -- El cobro se hace con la tarjeta catastrada (uPay) via pago-recurrente/3.0.
        pr_assert_admin(pi_auth_header, v_org_id);

        v_req         := json_object_t.parse(pi_body);
        v_target_type := UPPER(TRIM(NVL(v_req.get_string('target_type'), 'PLAN')));
        v_plan_code   := UPPER(TRIM(v_req.get_string('plan_code')));
        v_addon_code  := UPPER(TRIM(v_req.get_string('addon_code')));

        pr_charge_target(
            pi_org_id      => v_org_id,
            pi_target_type => v_target_type,
            pi_plan_code   => v_plan_code,
            pi_addon_code  => v_addon_code,
            po_invoice_id  => v_invoice_id,
            po_hash        => v_hash
        );

        IF v_hash IS NULL AND v_target_type = 'STORAGE_ADDON' THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'Almacenamiento activado. Se sumara al cargo de la proxima renovacion.');
            v_data.put_null('invoice_id');
            v_data.put_null('hash');
            v_data.put('status', 'ACTIVE');
            v_data.put('charged', 0);
            v_data.put('requires_polling', 0);
            v_data.put('target_type', v_target_type);
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Cobro iniciado con la tarjeta registrada. Se confirmara en unos instantes.');
        v_data.put('invoice_id', v_invoice_id);
        v_data.put('hash', v_hash);
        v_data.put('status', 'PENDING');
        v_data.put('charged', 1);
        v_data.put('requires_polling', 1);
        v_data.put('target_type', v_target_type);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'SUBSCRIPTION_CHECKOUT',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_CREATE_CHECKOUT',
                pi_http_method     => 'POST',
                pi_endpoint        => '/workspace/subscription/checkout',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_create_checkout;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/change-plan
    -- Downgrade: agenda hasta current_period_end (sin credito de plan).
    -- Mantener plan actual: cancela agenda. Upgrade pago: usar activate.
    --------------------------------------------------------------------------
    PROCEDURE pr_change_plan(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id           NUMBER;
        v_req              json_object_t;
        v_plan_code        VARCHAR2(30);
        v_plan_id          ref_plan.id_plan%TYPE;
        v_plan_price       NUMBER;
        v_cur_plan_id      NUMBER;
        v_cur_plan_code    VARCHAR2(30);
        v_cur_plan_price   NUMBER;
        v_period_end       TIMESTAMP WITH TIME ZONE;
        v_billing_exempt   org_subscription.billing_exempt%TYPE;
        v_response         json_object_t := json_object_t();
        v_data             json_object_t := json_object_t();
        v_scheduled        NUMBER := 0;
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        v_req       := json_object_t.parse(pi_body);
        v_plan_code := UPPER(TRIM(v_req.get_string('plan_code')));

        BEGIN
            SELECT id_plan, price_amount
              INTO v_plan_id, v_plan_price
              FROM ref_plan WHERE code = v_plan_code AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
        END;

        IF v_plan_code = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Para terminar la suscripcion usa Terminar suscripcion (no Pasar a Base).'
            );
        END IF;

        SELECT s.pln_id_plan, p.code, p.price_amount, s.current_period_end, s.billing_exempt
          INTO v_cur_plan_id, v_cur_plan_code, v_cur_plan_price, v_period_end, v_billing_exempt
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        -- Cancelar downgrade / terminacion agendada (pedir el plan actual).
        IF v_plan_id = v_cur_plan_id THEN
            UPDATE /*+ no_parallel */ org_subscription
               SET pending_pln_id_plan    = NULL,
                   pending_plan_change_at = NULL,
                   auto_renew             = 1,
                   canceled_at            = NULL,
                   updated_at             = systimestamp
             WHERE org_id_organization = v_org_id;
            COMMIT;
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('message', 'Cambio de plan cancelado. Seguis con ' || v_cur_plan_code || '.');
            v_data.put('plan_code', v_cur_plan_code);
            v_data.put('scheduled', 0);
            v_data.put('pending_cleared', 1);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        -- Upgrade (precio mayor): requiere cobro via activate, salvo exentos.
        IF NVL(v_plan_price, 0) > NVL(v_cur_plan_price, 0) THEN
            IF NVL(v_billing_exempt, 0) = 1 THEN
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan            = v_plan_id,
                       pending_pln_id_plan    = NULL,
                       pending_plan_change_at = NULL,
                       updated_at             = systimestamp
                 WHERE org_id_organization = v_org_id;
                pr_refresh_storage_limit(v_org_id);
                COMMIT;
                po_status_code := pkg_aox_util.c_success_ok_code;
                v_response.put('status', 'success');
                v_response.put('message', 'Plan actualizado correctamente.');
                v_data.put('plan_code', v_plan_code);
                v_data.put('scheduled', 0);
                v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
                v_response.put('data', v_data);
                po_response_body := v_response.to_clob();
                RETURN;
            END IF;
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Para subir de plan necesitás completar el pago con tu tarjeta.'
            );
        END IF;

        -- Downgrade / mismo precio hacia Base: agendar al fin del ciclo (sin credito de plan).
        -- Cliente de pago: limpia cancelacion (auto_renew) y agenda BASE.
        IF v_period_end IS NULL THEN
            v_period_end := ADD_MONTHS(systimestamp, 1);
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = v_plan_id,
               pending_plan_change_at = v_period_end,
               auto_renew             = 1,
               canceled_at            = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;
        COMMIT;
        v_scheduled := 1;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message',
            'Cambio a ' || v_plan_code || ' programado. Seguis con ' || v_cur_plan_code
            || ' hasta el fin del periodo. Luego se cobra la tarifa de ' || v_plan_code || '.');
        v_data.put('plan_code', v_cur_plan_code);
        v_data.put('pending_plan_code', v_plan_code);
        v_data.put('pending_plan_change_at', fn_ts_to_iso(v_period_end));
        v_data.put('scheduled', v_scheduled);
        v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_change_plan;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/cancel
    --------------------------------------------------------------------------
    PROCEDURE pr_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_cur_plan_code  VARCHAR2(30);
        v_period_end     TIMESTAMP WITH TIME ZONE;
        v_billing_exempt NUMBER(1,0);
        v_is_founder     NUMBER(1,0);
        v_status         VARCHAR2(20);
        v_free_id        NUMBER;
        v_response       json_object_t := json_object_t();
        v_data           json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        BEGIN
            SELECT id_plan INTO v_free_id FROM ref_plan WHERE code = c_plan_free AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan de continuidad no configurado.');
        END;

        SELECT p.code, s.current_period_end, NVL(s.billing_exempt, 0), NVL(s.is_founder, 0), s.status
          INTO v_cur_plan_code, v_period_end, v_billing_exempt, v_is_founder, v_status
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_billing_exempt = 1 OR v_is_founder = 1 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Las cuentas fundador o exentas no usan Terminar suscripcion.'
            );
        END IF;

        IF v_cur_plan_code = c_plan_free OR v_status = 'READ_ONLY' THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Tu cuenta ya esta en modo continuidad / solo lectura. Renova un plan para reactivar.'
            );
        END IF;

        IF v_period_end IS NULL THEN
            v_period_end := ADD_MONTHS(systimestamp, 1);
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = v_free_id,
               pending_plan_change_at = v_period_end,
               auto_renew             = 0,
               canceled_at            = NVL(canceled_at, systimestamp),
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;

        -- Si el periodo ya vencio, aplicar de inmediato.
        pr_apply_due_pending_plan(v_org_id);
        COMMIT;

        DECLARE
            v_pending_id   NUMBER;
            v_pending_at   TIMESTAMP WITH TIME ZONE;
            v_pending_code VARCHAR2(30);
        BEGIN
            SELECT s.pending_pln_id_plan, s.pending_plan_change_at, p.code, s.status
              INTO v_pending_id, v_pending_at, v_cur_plan_code, v_status
              FROM org_subscription s
              JOIN ref_plan p ON p.id_plan = s.pln_id_plan
             WHERE s.org_id_organization = v_org_id;

            IF v_pending_id IS NOT NULL THEN
                SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
            END IF;

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            IF v_status = 'READ_ONLY' OR v_cur_plan_code = c_plan_free THEN
                v_response.put('message',
                    'Suscripcion terminada. Tu cuenta quedo en modo solo lectura (Continuidad).');
                v_data.put('scheduled', 0);
                v_data.put('applied', 1);
            ELSE
                v_response.put('message',
                    'Cancelacion programada. Seguis con ' || v_cur_plan_code
                    || ' hasta el fin del periodo; luego pasas a Continuidad (solo lectura) sin cobros.');
                v_data.put('scheduled', 1);
                v_data.put('applied', 0);
                v_data.put('pending_plan_code', NVL(v_pending_code, c_plan_free));
                v_data.put('pending_plan_change_at', fn_ts_to_iso(v_pending_at));
            END IF;
            v_data.put('plan_code', v_cur_plan_code);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_cancel_subscription;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/cancel/undo
    --------------------------------------------------------------------------
    PROCEDURE pr_undo_cancel_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id        NUMBER;
        v_cur_plan_code VARCHAR2(30);
        v_pending_id    NUMBER;
        v_pending_code  VARCHAR2(30);
        v_response      json_object_t := json_object_t();
        v_data          json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        SELECT p.code, s.pending_pln_id_plan
          INTO v_cur_plan_code, v_pending_id
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        IF v_pending_id IS NULL THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'No hay una cancelacion programada para deshacer.'
            );
        END IF;

        SELECT code INTO v_pending_code FROM ref_plan WHERE id_plan = v_pending_id;
        IF v_pending_code <> c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'Hay un cambio de plan programado (no una cancelacion). Usa Mantener plan.'
            );
        END IF;

        IF v_cur_plan_code = c_plan_free THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_validation,
                'La cancelacion ya se aplico. Renova un plan Base o Premium para reactivar.'
            );
        END IF;

        UPDATE /*+ no_parallel */ org_subscription
           SET pending_pln_id_plan    = NULL,
               pending_plan_change_at = NULL,
               auto_renew             = 1,
               canceled_at            = NULL,
               updated_at             = systimestamp
         WHERE org_id_organization = v_org_id;
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Cancelacion anulada. Seguis con ' || v_cur_plan_code || '.');
        v_data.put('plan_code', v_cur_plan_code);
        v_data.put('scheduled', 0);
        v_data.put('pending_cleared', 1);
        v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_undo_cancel_subscription;

    --------------------------------------------------------------------------
    -- POST /workspace/subscription/addon/cancel
    --------------------------------------------------------------------------
    PROCEDURE pr_cancel_storage_addon(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_addon_code  VARCHAR2(30);
        v_addon_id    NUMBER;
        v_addon_price NUMBER;
        v_addon_name  VARCHAR2(150);
        v_row_id      NUMBER;
        v_qty         NUMBER;
        v_credit      NUMBER;
        v_balance     NUMBER;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req        := json_object_t.parse(pi_body);
        v_addon_code := UPPER(TRIM(v_req.get_string('addon_code')));

        BEGIN
            SELECT id_storage_addon, price_amount, name
              INTO v_addon_id, v_addon_price, v_addon_name
              FROM ref_storage_addon
             WHERE code = v_addon_code AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Paquete de almacenamiento no valido.');
        END;

        BEGIN
            SELECT id_org_storage_addon, quantity
              INTO v_row_id, v_qty
              FROM org_storage_addon
             WHERE org_id_organization = v_org_id
               AND sad_id_storage_addon = v_addon_id
               AND status = 'ACTIVE'
             ORDER BY id_org_storage_addon DESC
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'No tenes ese paquete de almacenamiento activo.');
        END;

        v_credit := fn_unused_credit_amount(v_org_id, v_addon_price);
        pr_grant_credit(v_org_id, v_credit, 'CANCEL_ADDON', v_addon_code, NULL);

        IF v_qty > 1 THEN
            UPDATE /*+ no_parallel */ org_storage_addon
               SET quantity = quantity - 1
             WHERE id_org_storage_addon = v_row_id;
        ELSE
            UPDATE /*+ no_parallel */ org_storage_addon
               SET status  = 'CANCELED',
                   ends_at = systimestamp,
                   quantity = 1
             WHERE id_org_storage_addon = v_row_id;
        END IF;

        pr_refresh_storage_limit(v_org_id);

        SELECT NVL(account_balance, 0)
          INTO v_balance
          FROM org_subscription
         WHERE org_id_organization = v_org_id;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message',
            CASE WHEN v_credit > 0
                 THEN 'Almacenamiento cancelado. Se acreditaron ' || TO_CHAR(v_credit) || ' Gs a favor.'
                 ELSE 'Almacenamiento cancelado.'
            END);
        v_data.put('addon_code', v_addon_code);
        v_data.put('addon_name', v_addon_name);
        v_data.put('credit_granted', v_credit);
        v_data.put('account_balance', v_balance);
        v_data.put('storage_limit_bytes', pkg_aox_subscription_api.fn_get_storage_limit_bytes(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_cancel_storage_addon;

    --------------------------------------------------------------------------
    -- GET /workspace/subscription/invoice/:hash
    --------------------------------------------------------------------------
    PROCEDURE pr_get_invoice_by_hash(
        pi_auth_header   IN  VARCHAR2,
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        FOR rec IN (
            SELECT i.id_invoice, i.invoice_type, i.status, i.amount, i.currency,
                   i.description, p.code AS plan_code, i.paid_at, i.external_reference
              FROM org_subscription_invoice i
              LEFT JOIN ref_plan p ON p.id_plan = i.pln_id_plan
             WHERE i.external_reference = TRIM(pi_hash)
               AND i.org_id_organization = v_org_id
             ORDER BY i.id_invoice DESC
             FETCH FIRST 1 ROW ONLY
        ) LOOP
            v_data.put('invoice_id'  , rec.id_invoice);
            v_data.put('invoice_type', rec.invoice_type);
            v_data.put('status'      , rec.status);
            v_data.put('amount'      , rec.amount);
            v_data.put('currency'    , rec.currency);
            v_data.put('description' , rec.description);
            v_data.put('plan_code'   , rec.plan_code);
            v_data.put('paid_at'     , fn_ts_to_iso(rec.paid_at));
            v_data.put('hash'        , rec.external_reference);
            v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));

            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END LOOP;

        po_status_code := pkg_aox_util.c_not_found_code;
        pkg_aox_util.pr_build_api_error_response(
            pi_status_code   => po_status_code,
            pi_api_code      => pkg_aox_util.c_api_code_not_found,
            pi_message       => 'Factura no encontrada.',
            po_response_body => po_response_body
        );
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_get_invoice_by_hash;

    --------------------------------------------------------------------------
    -- GET /workspace/subscription/invoices
    --------------------------------------------------------------------------
    PROCEDURE pr_list_invoices(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
        v_items    json_array_t  := json_array_t();
        v_period_end TIMESTAMP WITH TIME ZONE;
        v_balance  NUMBER;
        v_plan_amt NUMBER;
        v_addon_amt NUMBER;
        v_plan_code VARCHAR2(30);
        v_plan_name VARCHAR2(100);
        v_founder  NUMBER;
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token invalido o sin organizacion asociada.');
        END IF;

        SELECT s.current_period_end, NVL(s.account_balance, 0), NVL(s.is_founder, 0),
               p.code, p.name,
               CASE WHEN NVL(s.is_founder, 0) = 1 AND p.code = c_plan_premium
                    THEN ROUND(p.price_amount * 0.5) ELSE p.price_amount END
          INTO v_period_end, v_balance, v_founder, v_plan_code, v_plan_name, v_plan_amt
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        v_addon_amt := fn_addons_monthly_total(v_org_id);

        FOR rec IN (
            SELECT i.id_invoice, i.invoice_type, i.status, i.amount,
                   NVL(i.gross_amount, i.amount) AS gross_amount,
                   NVL(i.credit_applied, 0) AS credit_applied,
                   i.currency, i.description, i.payment_provider,
                   i.created_at, i.paid_at, i.period_start, i.period_end,
                   i.external_reference, p.code AS plan_code, p.name AS plan_name
              FROM org_subscription_invoice i
              LEFT JOIN ref_plan p ON p.id_plan = i.pln_id_plan
             WHERE i.org_id_organization = v_org_id
             ORDER BY i.created_at DESC, i.id_invoice DESC
             FETCH FIRST 50 ROWS ONLY
        ) LOOP
            DECLARE v_item json_object_t := json_object_t();
            BEGIN
                v_item.put('invoice_id', rec.id_invoice);
                v_item.put('invoice_type', rec.invoice_type);
                v_item.put('status', rec.status);
                v_item.put('amount', rec.amount);
                v_item.put('gross_amount', rec.gross_amount);
                v_item.put('credit_applied', rec.credit_applied);
                v_item.put('currency', rec.currency);
                v_item.put('description', rec.description);
                v_item.put('payment_provider', rec.payment_provider);
                v_item.put('plan_code', rec.plan_code);
                v_item.put('plan_name', rec.plan_name);
                v_item.put('created_at', fn_ts_to_iso(rec.created_at));
                v_item.put('paid_at', fn_ts_to_iso(rec.paid_at));
                v_item.put('period_start', fn_ts_to_iso(rec.period_start));
                v_item.put('period_end', fn_ts_to_iso(rec.period_end));
                v_item.put('hash', rec.external_reference);
                v_items.append(v_item);
            END;
        END LOOP;

        v_data.put('next_billing_at', fn_ts_to_iso(v_period_end));
        v_data.put('plan_code', v_plan_code);
        v_data.put('plan_name', v_plan_name);
        v_data.put('plan_monthly_amount', v_plan_amt);
        v_data.put('addons_monthly_amount', v_addon_amt);
        v_data.put('monthly_total', v_plan_amt + v_addon_amt);
        v_data.put('account_balance', v_balance);
        v_data.put('next_charge_estimate', GREATEST(0, (v_plan_amt + v_addon_amt) - v_balance));
        v_data.put('invoices', v_items);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_invoices;

    --------------------------------------------------------------------------
    -- POST /pagopar/subscription/webhook
    --------------------------------------------------------------------------
    PROCEDURE pr_subscription_webhook(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_req            json_object_t;
        v_result_arr     json_array_t;
        v_result_obj     json_object_t;
        v_hash_pedido    VARCHAR2(128);
        v_token_received VARCHAR2(256);
        v_token_expected VARCHAR2(256);
        v_pagado         BOOLEAN;

        v_invoice_id     NUMBER;
        v_org_id         NUMBER;
        v_invoice_type   VARCHAR2(20);
        v_status         VARCHAR2(20);
        v_plan_id        NUMBER;
        v_addon_id       NUMBER;
        v_invoice_amount NUMBER;
        v_credit_applied NUMBER;
        v_period_start   TIMESTAMP WITH TIME ZONE;
        v_period_end     TIMESTAMP WITH TIME ZONE;
        v_desc           VARCHAR2(255);

        v_public_key     VARCHAR2(500);
        v_private_key    VARCHAR2(500);
        v_echo           json_array_t := json_array_t();
    BEGIN
        v_req        := json_object_t.parse(pi_body);
        v_result_arr := v_req.get_array('resultado');
        v_result_obj := TREAT(v_result_arr.get(0) AS json_object_t);

        v_hash_pedido    := v_result_obj.get_string('hash_pedido');
        v_token_received := LOWER(TRIM(v_result_obj.get_string('token')));
        v_pagado         := v_result_obj.get_boolean('pagado');

        BEGIN
            SELECT id_invoice, org_id_organization, invoice_type, status, pln_id_plan,
                   sad_id_storage_addon, amount, credit_applied, period_start, period_end, description
              INTO v_invoice_id, v_org_id, v_invoice_type, v_status, v_plan_id,
                   v_addon_id, v_invoice_amount, v_credit_applied, v_period_start, v_period_end, v_desc
              FROM org_subscription_invoice
             WHERE external_reference = v_hash_pedido
             ORDER BY id_invoice DESC
             FETCH FIRST 1 ROW ONLY;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            po_status_code := 404;
            po_response_body := '{"status":"error","message":"Factura no encontrada."}';
            RETURN;
        END;

        pr_get_platform_keys(v_public_key, v_private_key);
        v_token_expected := pkg_aox_pagopar_api.fn_pagopar_sha1_token(v_private_key || v_hash_pedido);

        IF v_token_expected <> v_token_received THEN
            po_status_code := 403;
            po_response_body := '{"status":"error","message":"Token inv?lido."}';
            RETURN;
        END IF;

        -- Idempotencia: si ya est? pagada, devolvemos OK (echo) sin re-procesar.
        IF v_status = 'PAID' THEN
            v_echo.append(v_result_obj);
            po_status_code := 200;
            po_response_body := v_echo.to_clob();
            RETURN;
        END IF;

        IF v_pagado THEN
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET status = 'PAID', paid_at = systimestamp
             WHERE id_invoice = v_invoice_id;

            -- Consumir credito declarado en la factura (idempotente via ledger).
            pr_consume_credit(v_org_id, NVL(v_credit_applied, 0), v_invoice_id);

            IF v_invoice_type = 'SUBSCRIPTION' THEN
                pr_fulfill_paid_subscription(v_org_id, v_plan_id);

            ELSIF v_invoice_type = 'STORAGE_ADDON' THEN
                IF v_addon_id IS NULL THEN
                    BEGIN
                        SELECT id_storage_addon INTO v_addon_id
                          FROM ref_storage_addon
                         WHERE price_amount = (
                                   SELECT NVL(gross_amount, amount)
                                     FROM org_subscription_invoice
                                    WHERE id_invoice = v_invoice_id
                               )
                           AND is_active = 1
                         FETCH FIRST 1 ROW ONLY;
                    EXCEPTION WHEN NO_DATA_FOUND THEN
                        v_addon_id := NULL;
                    END;
                END IF;
                pr_fulfill_paid_addon(v_org_id, v_addon_id);
            END IF;
        ELSE
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET status = 'FAILED'
             WHERE id_invoice = v_invoice_id
               AND status = 'PENDING';
            -- FAILED: no se consume credito (sigue disponible).
        END IF;

        COMMIT;

        v_echo.append(v_result_obj);
        po_status_code := 200;
        po_response_body := v_echo.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name        => 'SUBSCRIPTION_WEBHOOK',
                pi_process_name    => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_SUBSCRIPTION_WEBHOOK',
                pi_http_method     => 'POST',
                pi_endpoint        => '/pagopar/subscription/webhook',
                pi_status          => 'ERROR',
                pi_error_code      => SQLCODE,
                pi_error_message   => SQLERRM,
                pi_error_stack     => DBMS_UTILITY.FORMAT_ERROR_STACK,
                pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body    => pi_body
            );
            po_status_code := 500;
            po_response_body := '{"status":"error","message":"Error interno procesando webhook de suscripci?n."}';
    END pr_subscription_webhook;

    --------------------------------------------------------------------------
    -- Tarjetas catastradas (uPay) + activacion + ciclo de cobro
    --------------------------------------------------------------------------
    PROCEDURE pr_build_cards_json(pi_org_id IN NUMBER, po_cards OUT json_array_t) IS
        v_card json_object_t;
    BEGIN
        po_cards := json_array_t();
        FOR rec IN (
            SELECT id_payment_card, provider, brand, masked_number, card_type, issuer, is_default
              FROM org_payment_card
             WHERE org_id_organization = pi_org_id
               AND status = 'ACTIVE'
             ORDER BY is_default DESC, confirmed_at DESC NULLS LAST, id_payment_card DESC
        ) LOOP
            v_card := json_object_t();
            v_card.put('id', rec.id_payment_card);
            v_card.put('provider', rec.provider);
            v_card.put('brand', rec.brand);
            v_card.put('masked_number', rec.masked_number);
            v_card.put('card_type', rec.card_type);
            v_card.put('issuer', rec.issuer);
            v_card.put('is_default', rec.is_default);
            po_cards.append(v_card);
        END LOOP;
    END pr_build_cards_json;

    PROCEDURE pr_add_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_provider    VARCHAR2(20);
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_name        organization.name%TYPE;
        v_email       organization.company_email%TYPE;
        v_phone       VARCHAR2(60);
        v_return_url  VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_RETURN_URL'), 'https://hasel.app/panel/plan');
        v_iframe_base VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_IFRAME_URL'), 'https://www.pagopar.com/upay-iframe/?id-form=');
        v_raw         CLOB;
        v_resp        json_object_t;
        v_id_form     VARCHAR2(200);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req      := CASE WHEN pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN json_object_t.parse(pi_body) ELSE json_object_t() END;
        v_provider := NVL(TRIM(v_req.get_string('provider')), NVL(fn_get_parameter('SUBSCRIPTION_CARD_PROVIDER'), 'uPay'));

        pr_get_platform_keys(v_public_key, v_private_key);
        pr_get_org_contact(v_org_id, v_name, v_email, v_phone);

        -- agregar-cliente (idempotente): si falla por token/permiso, corta con el mensaje de Pagopar.
        v_raw  := pkg_aox_pagopar_api.fn_add_customer(v_public_key, v_private_key, TO_CHAR(v_org_id), v_name, v_email, v_phone);
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20033, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo el alta del cliente.'));
        END IF;

        -- agregar-tarjeta -> id-form para el iframe.
        v_raw  := pkg_aox_pagopar_api.fn_add_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_return_url, v_provider);
        v_resp := json_object_t.parse(v_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RAISE_APPLICATION_ERROR(-20034, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo el alta de la tarjeta.'));
        END IF;
        v_id_form := v_resp.get_string('resultado');

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('id_form', v_id_form);
        v_data.put('iframe_url', v_iframe_base || v_id_form);
        v_data.put('provider', v_provider);
        v_data.put('return_url', v_return_url);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_CARD_ADD', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_ADD_CARD',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/card/add', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_add_card;

    PROCEDURE pr_confirm_card(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_return_url  VARCHAR2(500) := NVL(fn_get_parameter('PAGOPAR_UPAY_RETURN_URL'), 'https://hasel.app/panel/plan');
        v_list_raw    CLOB;
        v_cards       json_array_t;
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        pr_get_platform_keys(v_public_key, v_private_key);

        -- confirmar-tarjeta es obligatorio tras el retorno del iframe (exito o fallo).
        BEGIN
            v_list_raw := pkg_aox_pagopar_api.fn_confirm_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_return_url);
        EXCEPTION WHEN OTHERS THEN
            NULL; -- si confirmar falla, seguimos e intentamos listar igual
        END;

        -- listar-tarjeta -> persistir tarjetas ACTIVE.
        v_list_raw := pkg_aox_pagopar_api.fn_list_cards(v_public_key, v_private_key, TO_CHAR(v_org_id));
        pr_sync_cards(v_org_id, v_list_raw);
        COMMIT;

        pr_build_cards_json(v_org_id, v_cards);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('cards', v_cards);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_CARD_CONFIRM', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_CONFIRM_CARD',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/card/confirm', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_confirm_card;

    PROCEDURE pr_list_cards(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id   NUMBER;
        v_cards    json_array_t;
        v_response json_object_t := json_object_t();
        v_data     json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        pr_build_cards_json(v_org_id, v_cards);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_data.put('cards', v_cards);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_list_cards;

    PROCEDURE pr_delete_card(
        pi_auth_header   IN  VARCHAR2,
        pi_card_id       IN  NUMBER,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_public_key  VARCHAR2(500);
        v_private_key VARCHAR2(500);
        v_card_pp_id  org_payment_card.pagopar_card_id%TYPE;
        v_was_default org_payment_card.is_default%TYPE;
        v_alias_token VARCHAR2(256);
        v_raw         CLOB;
        v_resp        json_object_t;
        v_response    json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        BEGIN
            SELECT pagopar_card_id, is_default INTO v_card_pp_id, v_was_default
              FROM org_payment_card
             WHERE id_payment_card = pi_card_id
               AND org_id_organization = v_org_id
               AND status = 'ACTIVE';
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Tarjeta no encontrada.');
        END;

        pr_get_platform_keys(v_public_key, v_private_key);

        -- alias_token temporal (15 min) para poder eliminar en Pagopar.
        IF v_card_pp_id IS NOT NULL THEN
            v_alias_token := fn_alias_token_for(v_org_id, v_card_pp_id, v_public_key, v_private_key);
            IF v_alias_token IS NOT NULL THEN
                v_raw  := pkg_aox_pagopar_api.fn_delete_card(v_public_key, v_private_key, TO_CHAR(v_org_id), v_alias_token);
                v_resp := json_object_t.parse(v_raw);
                IF NOT v_resp.get_boolean('respuesta') THEN
                    RAISE_APPLICATION_ERROR(-20035, NVL(v_resp.get_string('resultado'), 'Pagopar rechazo la eliminacion de la tarjeta.'));
                END IF;
            END IF;
        END IF;

        UPDATE /*+ no_parallel */ org_payment_card
           SET status = 'DELETED', is_default = 0, updated_at = systimestamp
         WHERE id_payment_card = pi_card_id;

        -- Promover otra tarjeta ACTIVE a default si eliminamos la default.
        IF NVL(v_was_default, 0) = 1 THEN
            UPDATE /*+ no_parallel */ org_payment_card
               SET is_default = 1, updated_at = systimestamp
             WHERE id_payment_card = (
                 SELECT id_payment_card FROM (
                     SELECT id_payment_card FROM org_payment_card
                      WHERE org_id_organization = v_org_id AND status = 'ACTIVE'
                      ORDER BY confirmed_at DESC NULLS LAST, id_payment_card DESC
                 ) WHERE ROWNUM = 1
             );
        END IF;

        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Tarjeta eliminada.');
        v_response.put('data', json_object_t());
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_delete_card;

    PROCEDURE pr_activate_subscription(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id      NUMBER;
        v_req         json_object_t;
        v_target_type VARCHAR2(20);
        v_plan_code   VARCHAR2(30);
        v_addon_code  VARCHAR2(30);
        v_invoice_id  NUMBER;
        v_hash        VARCHAR2(128);
        v_response    json_object_t := json_object_t();
        v_data        json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);
        v_req         := CASE WHEN pi_body IS NOT NULL AND DBMS_LOB.GETLENGTH(pi_body) > 0 THEN json_object_t.parse(pi_body) ELSE json_object_t() END;
        v_target_type := UPPER(TRIM(NVL(v_req.get_string('target_type'), 'PLAN')));
        v_plan_code   := UPPER(TRIM(NVL(v_req.get_string('plan_code'), c_plan_premium)));
        v_addon_code  := UPPER(TRIM(v_req.get_string('addon_code')));

        -- Upgrade/activacion limpia cualquier downgrade pendiente.
        IF v_target_type = 'PLAN' THEN
            UPDATE /*+ no_parallel */ org_subscription
               SET pending_pln_id_plan    = NULL,
                   pending_plan_change_at = NULL,
                   updated_at             = systimestamp
             WHERE org_id_organization = v_org_id;
            COMMIT;
        END IF;

        pr_charge_target(
            pi_org_id      => v_org_id,
            pi_target_type => v_target_type,
            pi_plan_code   => v_plan_code,
            pi_addon_code  => v_addon_code,
            po_invoice_id  => v_invoice_id,
            po_hash        => v_hash
        );

        -- Sin hash: alta gratis (addon 0 dias) o factura cubierta 100% por saldo a favor.
        IF v_hash IS NULL THEN
            po_status_code := pkg_aox_util.c_success_ok_code;
            v_response.put('status', 'success');
            IF v_invoice_id IS NOT NULL THEN
                v_response.put('message', 'Activado usando tu saldo a favor. No hubo cargo en la tarjeta.');
                v_data.put('invoice_id', v_invoice_id);
                v_data.put('status', 'PAID');
            ELSIF v_target_type = 'STORAGE_ADDON' THEN
                v_response.put('message', 'Almacenamiento activado. Se sumara al cargo de la proxima renovacion.');
                v_data.put_null('invoice_id');
                v_data.put('status', 'ACTIVE');
                v_data.put('prorated', 0);
            ELSE
                v_response.put('message', 'Activacion completada.');
                v_data.put_null('invoice_id');
                v_data.put('status', 'ACTIVE');
            END IF;
            v_data.put_null('hash');
            v_data.put('requires_polling', 0);
            v_data.put('target_type', v_target_type);
            v_response.put('data', v_data);
            po_response_body := v_response.to_clob();
            RETURN;
        END IF;

        po_status_code := pkg_aox_util.c_success_create_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Suscripcion activada. Estamos confirmando el cobro.');
        v_data.put('invoice_id', v_invoice_id);
        v_data.put('hash', v_hash);
        v_data.put('status', 'PENDING');
        v_data.put('requires_polling', 1);
        v_data.put('target_type', v_target_type);
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_log_api(
                pi_api_name => 'SUBSCRIPTION_ACTIVATE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_ACTIVATE_SUBSCRIPTION',
                pi_http_method => 'POST', pi_endpoint => '/workspace/subscription/activate', pi_status => 'ERROR',
                pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                pi_request_body => pi_body
            );
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_activate_subscription;

    PROCEDURE pr_run_billing_cycle IS
        v_invoice_id NUMBER;
        v_hash       VARCHAR2(128);
        v_plan_code  VARCHAR2(30);
        v_auto_renew NUMBER(1,0);
        v_max_retry  NUMBER := NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_MAX_CHARGE_RETRIES')), 4);
    BEGIN
        -- 1) Aplicar pending vencidos (incluye Terminar→FREE aunque auto_renew=0).
        FOR rec IN (
            SELECT s.org_id_organization AS org_id
              FROM org_subscription s
             WHERE s.pending_pln_id_plan IS NOT NULL
               AND (
                    (s.pending_plan_change_at IS NOT NULL AND s.pending_plan_change_at <= systimestamp)
                 OR (s.current_period_end IS NOT NULL AND s.current_period_end <= systimestamp)
               )
        ) LOOP
            BEGIN
                pr_apply_due_pending_plan(rec.org_id);
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    pkg_aox_util.pr_log_api(
                        pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_APPLY_PENDING',
                        pi_http_method => 'JOB', pi_endpoint => 'HASEL_SUBSCRIPTION_BILLING_CYCLE', pi_status => 'ERROR',
                        pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                        pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                        pi_request_body => TO_CLOB('org_id=' || rec.org_id)
                    );
            END;
        END LOOP;

        -- 2) Cobrar renovaciones (Base y Premium). No cobra FREE ni auto_renew=0.
        FOR rec IN (
            SELECT s.org_id_organization AS org_id
              FROM org_subscription s
             WHERE s.status IN ('ACTIVE', 'PAST_DUE')
               AND NVL(s.auto_renew, 1) = 1
               AND NVL(s.billing_exempt, 0) = 0
               AND s.current_period_end IS NOT NULL
               AND s.current_period_end <= systimestamp
               AND NVL(s.charge_retry_count, 0) < v_max_retry
        ) LOOP
            BEGIN
                SELECT p.code, NVL(s.auto_renew, 1)
                  INTO v_plan_code, v_auto_renew
                  FROM org_subscription s
                  JOIN ref_plan p ON p.id_plan = s.pln_id_plan
                 WHERE s.org_id_organization = rec.org_id;

                IF v_plan_code = c_plan_free OR v_auto_renew = 0 THEN
                    CONTINUE;
                END IF;

                -- Contabilizar el intento (dunning). El webhook / PAID por credito lo resetea.
                UPDATE /*+ no_parallel */ org_subscription
                   SET charge_retry_count = NVL(charge_retry_count, 0) + 1,
                       last_charge_at     = systimestamp,
                       updated_at         = systimestamp
                 WHERE org_id_organization = rec.org_id;
                COMMIT;

                -- Un solo cargo: plan efectivo (BASE o PREMIUM) + addons ACTIVE, menos account_balance.
                pr_charge_target(
                    pi_org_id      => rec.org_id,
                    pi_target_type => 'CONSOLIDATED',
                    pi_plan_code   => v_plan_code,
                    pi_addon_code  => NULL,
                    po_invoice_id  => v_invoice_id,
                    po_hash        => v_hash
                );
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    pkg_aox_util.pr_log_api(
                        pi_api_name => 'SUBSCRIPTION_BILLING_CYCLE', pi_process_name => 'PKG_AOX_SUBSCRIPTION_BILLING_API.PR_RUN_BILLING_CYCLE',
                        pi_http_method => 'JOB', pi_endpoint => 'HASEL_SUBSCRIPTION_BILLING_CYCLE', pi_status => 'ERROR',
                        pi_error_code => SQLCODE, pi_error_message => SQLERRM,
                        pi_error_stack => DBMS_UTILITY.FORMAT_ERROR_STACK, pi_error_backtrace => DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
                        pi_request_body => TO_CLOB('org_id=' || rec.org_id)
                    );
            END;
        END LOOP;
    END pr_run_billing_cycle;

END pkg_aox_subscription_billing_api;
/

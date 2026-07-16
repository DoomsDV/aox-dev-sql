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

    -- POST /workspace/subscription/change-plan  (cambio inmediato sin pago; solo founders/exentos)
    PROCEDURE pr_change_plan(
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
            v_obj := TREAT(v_arr.get(i) AS json_object_t);
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
        v_has_def  NUMBER := 0;
        v_active   NUMBER := 0;
    BEGIN
        v_resp := json_object_t.parse(pi_list_raw);
        IF NOT v_resp.get_boolean('respuesta') THEN
            RETURN;
        END IF;

        v_arr := v_resp.get_array('resultado');
        FOR i IN 0 .. v_arr.get_size - 1 LOOP
            v_obj     := TREAT(v_arr.get(i) AS json_object_t);
            v_card_id := v_obj.get_string('tarjeta');

            MERGE /*+ no_parallel */ INTO org_payment_card t
            USING (SELECT pi_org_id AS org_id, v_card_id AS card_id FROM dual) s
               ON (t.org_id_organization = s.org_id AND t.pagopar_card_id = s.card_id)
            WHEN MATCHED THEN
                UPDATE SET t.status        = 'ACTIVE',
                           t.brand         = v_obj.get_string('marca'),
                           t.masked_number = v_obj.get_string('tarjeta_numero'),
                           t.card_type     = v_obj.get_string('tipo_tarjeta'),
                           t.issuer        = v_obj.get_string('emisor'),
                           t.provider      = NVL(v_obj.get_string('proveedor'), t.provider),
                           t.confirmed_at  = NVL(t.confirmed_at, systimestamp),
                           t.updated_at    = systimestamp
            WHEN NOT MATCHED THEN
                INSERT (org_id_organization, provider, pagopar_identificador, pagopar_card_id,
                        brand, masked_number, card_type, issuer, status, is_default, confirmed_at)
                VALUES (pi_org_id, NVL(v_obj.get_string('proveedor'), 'uPay'), TO_CHAR(pi_org_id), s.card_id,
                        v_obj.get_string('marca'), v_obj.get_string('tarjeta_numero'),
                        v_obj.get_string('tipo_tarjeta'), v_obj.get_string('emisor'),
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

    /**
     * Cobro recurrente de un target (plan o addon) con la tarjeta default:
     * crea invoice PENDING -> iniciar-transaccion -> listar-tarjeta -> pagar.
     * El estado PAID lo aplica el webhook. Hace COMMIT del invoice+hash antes de pagar.
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
        v_amount       NUMBER;
        v_currency     VARCHAR2(3);
        v_item_name    VARCHAR2(150);
        v_desc         VARCHAR2(255);
        v_period_start TIMESTAMP WITH TIME ZONE := systimestamp;
        v_period_end   TIMESTAMP WITH TIME ZONE := ADD_MONTHS(systimestamp, 1);
        v_expires_at   TIMESTAMP WITH TIME ZONE := systimestamp + NUMTODSINTERVAL(NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_PAYMENT_PENDING_MINUTES')), 1440), 'MINUTE');
        v_founder      NUMBER(1,0) := 0;
        v_card_id      org_payment_card.pagopar_card_id%TYPE;
        v_alias_token  VARCHAR2(256);
        v_pay_raw      CLOB;
        v_pay_resp     json_object_t;
    BEGIN
        pr_get_platform_keys(v_public_key, v_private_key);

        v_card_id := fn_default_card_pagopar_id(pi_org_id);
        IF v_card_id IS NULL THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation,
                'Agrega una tarjeta antes de activar la suscripcion.');
        END IF;

        SELECT id_subscription INTO v_sub_id FROM org_subscription WHERE org_id_organization = pi_org_id;

        IF pi_target_type = 'PLAN' THEN
            BEGIN
                SELECT id_plan, price_amount, currency, name
                  INTO v_plan_id, v_amount, v_currency, v_item_name
                  FROM ref_plan WHERE code = pi_plan_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no valido.');
            END;

            SELECT NVL(is_founder, 0) INTO v_founder FROM org_subscription WHERE org_id_organization = pi_org_id;
            IF v_founder = 1 AND pi_plan_code = c_plan_premium THEN
                v_amount := ROUND(v_amount * 0.5);
                v_desc := 'Suscripcion ' || v_item_name || ' fundador 50% (1 mes)';
            ELSE
                v_desc := 'Suscripcion ' || v_item_name || ' (1 mes)';
            END IF;

            INSERT /*+ no_parallel */ INTO org_subscription_invoice (
                org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
                description, amount, currency, status, period_start, period_end, due_date,
                payment_provider
            ) VALUES (
                pi_org_id, v_sub_id, 'SUBSCRIPTION', v_plan_id,
                v_desc, v_amount, v_currency, 'PENDING', v_period_start, v_period_end, v_expires_at,
                'pagopar'
            ) RETURNING id_invoice INTO po_invoice_id;

        ELSIF pi_target_type = 'STORAGE_ADDON' THEN
            IF pkg_aox_subscription_api.fn_org_has_feature(pi_org_id, 'APPOINTMENT_HISTORY') = 0 THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_forbidden, 'Los paquetes de almacenamiento solo estan disponibles en el plan Premium.');
            END IF;
            BEGIN
                SELECT price_amount, currency, name
                  INTO v_amount, v_currency, v_item_name
                  FROM ref_storage_addon WHERE code = pi_addon_code AND is_active = 1;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Paquete de almacenamiento no valido.');
            END;
            v_desc := v_item_name || ' (1 mes)';

            INSERT /*+ no_parallel */ INTO org_subscription_invoice (
                org_id_organization, sub_id_subscription, invoice_type, pln_id_plan,
                description, amount, currency, status, period_start, period_end, due_date,
                payment_provider
            ) VALUES (
                pi_org_id, v_sub_id, 'STORAGE_ADDON', NULL,
                v_desc, v_amount, v_currency, 'PENDING', v_period_start, v_period_end, v_expires_at,
                'pagopar'
            ) RETURNING id_invoice INTO po_invoice_id;
        ELSE
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'target_type invalido (PLAN o STORAGE_ADDON).');
        END IF;

        IF NVL(v_amount, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'El monto a facturar es invalido.');
        END IF;

        po_hash := fn_iniciar_transaccion(
            pi_org_id      => pi_org_id,
            pi_invoice_id  => po_invoice_id,
            pi_amount      => v_amount,
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

        -- Persistir invoice + hash antes de pagar: el webhook puede llegar muy rapido.
        COMMIT;

        -- alias_token temporal (15 min) de la tarjeta default.
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
        v_status          org_subscription.status%TYPE;
        v_is_founder      org_subscription.is_founder%TYPE;
        v_billing_exempt  org_subscription.billing_exempt%TYPE;
        v_storage_used    org_subscription.storage_used_bytes%TYPE;
        v_trial_ends_at   org_subscription.trial_ends_at%TYPE;
        v_period_end      org_subscription.current_period_end%TYPE;
        v_grace_ends_at   org_subscription.grace_ends_at%TYPE;
        v_eff_state       VARCHAR2(20);
        v_storage_limit   NUMBER;
        v_platform_ok     NUMBER := 0;
        v_dummy_pub       VARCHAR2(500);
        v_dummy_priv      VARCHAR2(500);
    BEGIN
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);
        IF NVL(v_org_id, 0) <= 0 THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_session, 'Token inv?lido o sin organizaci?n asociada.');
        END IF;

        SELECT s.pln_id_plan, p.code, p.name, s.status, s.is_founder, s.billing_exempt,
               s.storage_used_bytes, s.trial_ends_at, s.current_period_end, s.grace_ends_at
          INTO v_cur_plan_id, v_cur_plan_code, v_cur_plan_name, v_status, v_is_founder, v_billing_exempt,
               v_storage_used, v_trial_ends_at, v_period_end, v_grace_ends_at
          FROM org_subscription s
          JOIN ref_plan p ON p.id_plan = s.pln_id_plan
         WHERE s.org_id_organization = v_org_id;

        v_eff_state     := pkg_aox_subscription_api.fn_get_subscription_state(v_org_id);
        v_storage_limit := pkg_aox_subscription_api.fn_get_storage_limit_bytes(v_org_id);

        BEGIN
            pr_get_platform_keys(v_dummy_pub, v_dummy_priv);
            v_platform_ok := 1;
        EXCEPTION WHEN OTHERS THEN
            v_platform_ok := 0;
        END;

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
        v_current.put('current_period_end' , fn_ts_to_iso(v_period_end));
        v_current.put('grace_ends_at'      , fn_ts_to_iso(v_grace_ends_at));
        v_current.put('storage_used_bytes' , v_storage_used);
        v_current.put('storage_limit_bytes', v_storage_limit);
        v_current.put('supports_storage_addons', CASE WHEN v_cur_plan_code = c_plan_premium THEN 1 ELSE 0 END);
        v_current.put('billing_configured' , v_platform_ok);

        -- Planes activos
        FOR rec IN (
            SELECT id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, sort_order
              FROM ref_plan
             WHERE is_active = 1
             ORDER BY sort_order, id_plan
        ) LOOP
            DECLARE v_plan json_object_t := json_object_t();
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
                    v_plan.put('checkout_price_amount', ROUND(rec.price_amount * 0.5));
                    v_plan.put('founder_discount_percent', 50);
                ELSE
                    v_plan.put('checkout_price_amount', rec.price_amount);
                    v_plan.put('founder_discount_percent', 0);
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
            DECLARE v_addon json_object_t := json_object_t();
            BEGIN
                v_addon.put('id_storage_addon', rec.id_storage_addon);
                v_addon.put('code'            , rec.code);
                v_addon.put('name'            , rec.name);
                v_addon.put('extra_bytes'     , rec.extra_bytes);
                v_addon.put('price_amount'    , rec.price_amount);
                v_addon.put('currency'        , rec.currency);
                v_addon.put('billing_period'  , rec.billing_period);
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
    -- POST /workspace/subscription/change-plan  (sin pago; solo founders/exentos)
    --------------------------------------------------------------------------
    PROCEDURE pr_change_plan(
        pi_auth_header   IN  VARCHAR2,
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_org_id         NUMBER;
        v_req            json_object_t;
        v_plan_code      VARCHAR2(30);
        v_plan_id        ref_plan.id_plan%TYPE;
        v_is_founder     org_subscription.is_founder%TYPE;
        v_billing_exempt org_subscription.billing_exempt%TYPE;
        v_response       json_object_t := json_object_t();
        v_data           json_object_t := json_object_t();
    BEGIN
        pr_assert_admin(pi_auth_header, v_org_id);

        v_req       := json_object_t.parse(pi_body);
        v_plan_code := UPPER(TRIM(v_req.get_string('plan_code')));

        SELECT is_founder, billing_exempt
          INTO v_is_founder, v_billing_exempt
          FROM org_subscription
         WHERE org_id_organization = v_org_id;

        -- El cambio inmediato sin pago solo se permite a founders / exentos de facturaci?n.
        -- El resto debe pasar por el checkout de Pagopar.
        IF NVL(v_is_founder, 0) = 0 AND NVL(v_billing_exempt, 0) = 0 THEN
            RAISE_APPLICATION_ERROR(
                pkg_aox_util.c_sqlcode_forbidden,
                'Para cambiar de plan necesit?s completar el pago del nuevo plan.'
            );
        END IF;

        BEGIN
            SELECT id_plan INTO v_plan_id FROM ref_plan WHERE code = v_plan_code AND is_active = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_aox_util.c_sqlcode_validation, 'Plan no v?lido.');
        END;

        UPDATE /*+ no_parallel */ org_subscription
           SET pln_id_plan          = v_plan_id,
               current_period_start = systimestamp,
               current_period_end   = ADD_MONTHS(systimestamp, 1),
               grace_ends_at        = NULL,
               updated_at           = systimestamp
         WHERE org_id_organization = v_org_id;

        pr_refresh_storage_limit(v_org_id);
        COMMIT;

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response.put('status', 'success');
        v_response.put('message', 'Plan actualizado correctamente.');
        v_data.put('plan_code', v_plan_code);
        v_data.put('effective_status', pkg_aox_subscription_api.fn_get_subscription_state(v_org_id));
        v_response.put('data', v_data);
        po_response_body := v_response.to_clob();
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    END pr_change_plan;

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
        v_addon_code     VARCHAR2(30);
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
                   period_start, period_end, description
              INTO v_invoice_id, v_org_id, v_invoice_type, v_status, v_plan_id,
                   v_period_start, v_period_end, v_desc
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

            IF v_invoice_type = 'SUBSCRIPTION' THEN
                -- Cobro recurrente: extiende el periodo +1 mes desde el fin vigente
                -- (o desde ahora si ya vencio) y resetea el dunning.
                UPDATE /*+ no_parallel */ org_subscription
                   SET pln_id_plan          = v_plan_id,
                       status               = 'ACTIVE',
                       current_period_start = systimestamp,
                       current_period_end   = ADD_MONTHS(GREATEST(NVL(current_period_end, systimestamp), systimestamp), 1),
                       grace_ends_at        = NULL,
                       charge_retry_count   = 0,
                       last_charge_at       = systimestamp,
                       updated_at           = systimestamp
                 WHERE org_id_organization = v_org_id;

                pr_refresh_storage_limit(v_org_id);

            ELSIF v_invoice_type = 'STORAGE_ADDON' THEN
                -- Resolver el addon por su nombre (guardado en la descripci?n) no es fiable;
                -- lo resolvemos por el monto de la factura (precio del addon).
                BEGIN
                    SELECT id_storage_addon INTO v_addon_id
                      FROM ref_storage_addon
                     WHERE price_amount = (SELECT amount FROM org_subscription_invoice WHERE id_invoice = v_invoice_id)
                       AND is_active = 1
                     FETCH FIRST 1 ROW ONLY;
                EXCEPTION WHEN NO_DATA_FOUND THEN
                    v_addon_id := NULL;
                END;

                IF v_addon_id IS NOT NULL THEN
                    MERGE /*+ no_parallel */ INTO org_storage_addon t
                    USING (SELECT v_org_id AS org_id, v_addon_id AS addon_id FROM dual) s
                       ON (t.org_id_organization = s.org_id AND t.sad_id_storage_addon = s.addon_id AND t.status = 'ACTIVE')
                    WHEN MATCHED THEN
                        UPDATE SET t.quantity = t.quantity + 1
                    WHEN NOT MATCHED THEN
                        INSERT (org_id_organization, sad_id_storage_addon, quantity, status)
                        VALUES (s.org_id, s.addon_id, 1, 'ACTIVE');
                END IF;

                pr_refresh_storage_limit(v_org_id);
            END IF;
        ELSE
            UPDATE /*+ no_parallel */ org_subscription_invoice
               SET status = 'FAILED'
             WHERE id_invoice = v_invoice_id
               AND status = 'PENDING';
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

        pr_charge_target(
            pi_org_id      => v_org_id,
            pi_target_type => v_target_type,
            pi_plan_code   => v_plan_code,
            pi_addon_code  => v_addon_code,
            po_invoice_id  => v_invoice_id,
            po_hash        => v_hash
        );

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
        v_max_retry  NUMBER := NVL(TO_NUMBER(fn_get_parameter('SUBSCRIPTION_MAX_CHARGE_RETRIES')), 4);
    BEGIN
        FOR rec IN (
            SELECT s.org_id_organization AS org_id, p.code AS plan_code
              FROM org_subscription s
              JOIN ref_plan p ON p.id_plan = s.pln_id_plan
             WHERE s.status IN ('ACTIVE', 'PAST_DUE')
               AND NVL(s.auto_renew, 1) = 1
               AND NVL(s.billing_exempt, 0) = 0
               AND NVL(s.is_founder, 0) = 0
               AND s.current_period_end IS NOT NULL
               AND s.current_period_end <= systimestamp
               AND NVL(s.charge_retry_count, 0) < v_max_retry
               AND p.code <> c_plan_base
               AND EXISTS (
                   SELECT 1 FROM org_payment_card c
                    WHERE c.org_id_organization = s.org_id_organization
                      AND c.status = 'ACTIVE' AND c.is_default = 1
               )
        ) LOOP
            BEGIN
                -- Contabilizar el intento (dunning). El webhook lo resetea al confirmar.
                UPDATE /*+ no_parallel */ org_subscription
                   SET charge_retry_count = NVL(charge_retry_count, 0) + 1,
                       last_charge_at     = systimestamp,
                       updated_at         = systimestamp
                 WHERE org_id_organization = rec.org_id;
                COMMIT;

                pr_charge_target(
                    pi_org_id      => rec.org_id,
                    pi_target_type => 'PLAN',
                    pi_plan_code   => rec.plan_code,
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

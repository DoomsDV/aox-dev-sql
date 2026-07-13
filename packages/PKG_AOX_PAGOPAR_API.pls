PROMPT CREATE OR REPLACE PACKAGE pkg_aox_pagopar_api
CREATE OR REPLACE PACKAGE pkg_aox_pagopar_api IS

    c_forma_pago_bancard CONSTANT NUMBER := 9;
    c_forma_pago_qr      CONSTANT NUMBER := 24;

    /** Token SHA1 Pagopar (usado por billing de suscripcion Hasel). */
    FUNCTION fn_pagopar_sha1_token(pi_plain_text IN VARCHAR2) RETURN VARCHAR2;

    ----------------------------------------------------------------------------
    -- Pago recurrente / catastro de tarjetas (API pago-recurrente/3.0)
    -- Doc: catastro-tarjetas-pagos-recurrentes-preautorizacion
    -- Token de todos estos endpoints = fn_pagopar_sha1_token(private_key || 'PAGO-RECURRENTE').
    -- Todos devuelven el CLOB de respuesta crudo de Pagopar (JSON { respuesta, resultado }).
    -- El caller (PKG_AOX_SUBSCRIPTION_BILLING_API) parsea y persiste.
    ----------------------------------------------------------------------------

    /** Token para la API de pago recurrente: sha1(private_key || 'PAGO-RECURRENTE'). */
    FUNCTION fn_recurrente_token(pi_private_key IN VARCHAR2) RETURN VARCHAR2;

    /** agregar-cliente: registra al comprador (idempotente). */
    FUNCTION fn_add_customer(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_nombre        IN VARCHAR2,
        pi_email         IN VARCHAR2,
        pi_celular       IN VARCHAR2
    ) RETURN CLOB;

    /** agregar-tarjeta: crea la tarjeta y devuelve el id-form del iframe uPay/Bancard. */
    FUNCTION fn_add_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_url           IN VARCHAR2,
        pi_proveedor     IN VARCHAR2 DEFAULT 'uPay'
    ) RETURN CLOB;

    /** confirmar-tarjeta: obligatorio tras el retorno del iframe (exito o fallo). */
    FUNCTION fn_confirm_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_url           IN VARCHAR2
    ) RETURN CLOB;

    /** listar-tarjeta: devuelve las tarjetas + alias_token temporal (15 min) por tarjeta. */
    FUNCTION fn_list_cards(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2
    ) RETURN CLOB;

    /** eliminar-tarjeta: borra la tarjeta referida por su alias_token temporal. */
    FUNCTION fn_delete_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_alias_token   IN VARCHAR2
    ) RETURN CLOB;

    /** pagar: debita un pedido (hash de iniciar-transaccion) contra una tarjeta (alias_token). */
    FUNCTION fn_pay(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_hash_pedido   IN VARCHAR2,
        pi_alias_token   IN VARCHAR2
    ) RETURN CLOB;

    /**
     * DEPRECATED Fase E: usar pkg_aox_payment_settings_api.fn_calculate_deposit.
     * Se mantiene como wrapper para no romper callers legacy.
     */
    FUNCTION fn_calculate_deposit(
        pi_ser_id IN NUMBER,
        pi_org_id IN NUMBER
    ) RETURN NUMBER;

    /** DEPRECATED Fase E: senas solo por SIPAP. Responde HTTP 410. */
    PROCEDURE pr_create_payment_order(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    /** DEPRECATED Fase E: webhook de senas Pagopar. Responde HTTP 410. */
    PROCEDURE pr_webhook_notification(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    /** DEPRECATED Fase E: consulta hash de senas Pagopar. Responde HTTP 410. */
    PROCEDURE pr_get_payment_by_hash(
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

    /**
     * DEPRECATED wrapper: el job HASEL_EXPIRE_PENDING_PAYMENTS debe apuntar a
     * pkg_aox_payments_api.pr_expire_pending_payments. Se mantiene por compat.
     */
    PROCEDURE pr_expire_pending_payments;

END pkg_aox_pagopar_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_pagopar_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_pagopar_api IS

    c_gone_code CONSTANT NUMBER := 410;
    c_msg_deposit_gone CONSTANT VARCHAR2(200) :=
        'El cobro de senas por Pagopar fue deprecado. Usa transferencia SIPAP (Ajustes > Pagos).';

    PROCEDURE pr_respond_gone(
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
        v_json json_object_t := json_object_t();
    BEGIN
        po_status_code := c_gone_code;
        v_json.put('status', 'error');
        v_json.put('code', 'GONE');
        v_json.put('message', c_msg_deposit_gone);
        po_response_body := v_json.to_clob();
    END pr_respond_gone;

    FUNCTION fn_pagopar_sha1_token(pi_plain_text IN VARCHAR2) RETURN VARCHAR2 IS
        v_hash RAW(20);
    BEGIN
        v_hash := DBMS_CRYPTO.HASH(
            UTL_I18N.STRING_TO_RAW(NVL(pi_plain_text, ''), 'AL32UTF8'),
            DBMS_CRYPTO.HASH_SH1
        );
        RETURN LOWER(RAWTOHEX(v_hash));
    END fn_pagopar_sha1_token;

    ----------------------------------------------------------------------------
    -- Pago recurrente / catastro de tarjetas (API pago-recurrente/3.0)
    ----------------------------------------------------------------------------
    FUNCTION fn_recurrente_base_url RETURN VARCHAR2 IS
    BEGIN
        RETURN RTRIM(
            NVL(fn_get_parameter('PAGOPAR_RECURRENTE_BASE_URL'),
                'https://api.pagopar.com/api/pago-recurrente/3.0/'),
            '/'
        ) || '/';
    END fn_recurrente_base_url;

    FUNCTION fn_recurrente_token(pi_private_key IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN fn_pagopar_sha1_token(pi_private_key || 'PAGO-RECURRENTE');
    END fn_recurrente_token;

    /** POST JSON a un endpoint de pago-recurrente/3.0; valida HTTP 2xx y devuelve el CLOB. */
    FUNCTION fn_recurrente_post(
        pi_endpoint IN VARCHAR2,
        pi_body     IN CLOB
    ) RETURN CLOB IS
        v_response CLOB;
        v_url      VARCHAR2(600) := fn_recurrente_base_url || LTRIM(pi_endpoint, '/');
    BEGIN
        IF v_url NOT LIKE '%/' THEN
            v_url := v_url || '/';
        END IF;

        apex_web_service.g_request_headers.delete();
        apex_web_service.g_request_headers(1).name  := 'Content-Type';
        apex_web_service.g_request_headers(1).value := 'application/json';

        v_response := apex_web_service.make_rest_request(
            p_url         => v_url,
            p_http_method => 'POST',
            p_body        => pi_body
        );

        IF apex_web_service.g_status_code NOT BETWEEN 200 AND 299 THEN
            RAISE_APPLICATION_ERROR(
                -20030,
                'Pagopar (pago-recurrente) respondio HTTP ' || apex_web_service.g_status_code || ': '
                || DBMS_LOB.SUBSTR(v_response, 1000, 1)
            );
        END IF;

        RETURN v_response;
    END fn_recurrente_post;

    FUNCTION fn_add_customer(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_nombre        IN VARCHAR2,
        pi_email         IN VARCHAR2,
        pi_celular       IN VARCHAR2
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('identificador', pi_identificador);
        v_body.put('nombre_apellido', pi_nombre);
        v_body.put('email', pi_email);
        v_body.put('celular', pi_celular);
        RETURN fn_recurrente_post('agregar-cliente', v_body.to_clob());
    END fn_add_customer;

    FUNCTION fn_add_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_url           IN VARCHAR2,
        pi_proveedor     IN VARCHAR2 DEFAULT 'uPay'
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('url', pi_url);
        v_body.put('proveedor', pi_proveedor);
        v_body.put('identificador', pi_identificador);
        RETURN fn_recurrente_post('agregar-tarjeta', v_body.to_clob());
    END fn_add_card;

    FUNCTION fn_confirm_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_url           IN VARCHAR2
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('url', pi_url);
        v_body.put('identificador', pi_identificador);
        RETURN fn_recurrente_post('confirmar-tarjeta', v_body.to_clob());
    END fn_confirm_card;

    FUNCTION fn_list_cards(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('identificador', pi_identificador);
        RETURN fn_recurrente_post('listar-tarjeta', v_body.to_clob());
    END fn_list_cards;

    FUNCTION fn_delete_card(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_alias_token   IN VARCHAR2
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('tarjeta', pi_alias_token);
        v_body.put('identificador', pi_identificador);
        RETURN fn_recurrente_post('eliminar-tarjeta', v_body.to_clob());
    END fn_delete_card;

    FUNCTION fn_pay(
        pi_public_key    IN VARCHAR2,
        pi_private_key   IN VARCHAR2,
        pi_identificador IN VARCHAR2,
        pi_hash_pedido   IN VARCHAR2,
        pi_alias_token   IN VARCHAR2
    ) RETURN CLOB IS
        v_body json_object_t := json_object_t();
    BEGIN
        v_body.put('token', fn_recurrente_token(pi_private_key));
        v_body.put('token_publico', pi_public_key);
        v_body.put('hash_pedido', pi_hash_pedido);
        v_body.put('tarjeta', pi_alias_token);
        v_body.put('identificador', pi_identificador);
        RETURN fn_recurrente_post('pagar', v_body.to_clob());
    END fn_pay;

    FUNCTION fn_calculate_deposit(
        pi_ser_id IN NUMBER,
        pi_org_id IN NUMBER
    ) RETURN NUMBER IS
    BEGIN
        RETURN pkg_aox_payment_settings_api.fn_calculate_deposit(pi_ser_id, pi_org_id);
    END fn_calculate_deposit;

    PROCEDURE pr_create_payment_order(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
    BEGIN
        pr_respond_gone(po_status_code, po_response_body);
    END pr_create_payment_order;

    PROCEDURE pr_webhook_notification(
        pi_body          IN  CLOB,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
    BEGIN
        pr_respond_gone(po_status_code, po_response_body);
    END pr_webhook_notification;

    PROCEDURE pr_get_payment_by_hash(
        pi_hash          IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    ) IS
    BEGIN
        pr_respond_gone(po_status_code, po_response_body);
    END pr_get_payment_by_hash;

    PROCEDURE pr_expire_pending_payments IS
    BEGIN
        pkg_aox_payments_api.pr_expire_pending_payments;
    END pr_expire_pending_payments;

END pkg_aox_pagopar_api;
/

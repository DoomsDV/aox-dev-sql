-- Migracion ORDS: handlers de pago recurrente / catastro de tarjeta (uPay)
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere que el modulo
-- 'hasel' (/api/v1/) ya exista (PUBLISHED).
--
-- Endpoints (modulo hasel, prefijo /api/v1/):
--   POST   /workspace/subscription/card/add      -> pr_add_card
--   POST   /workspace/subscription/card/confirm  -> pr_confirm_card
--   GET    /workspace/subscription/cards          -> pr_list_cards
--   DELETE /workspace/subscription/card/:id       -> pr_delete_card
--   POST   /workspace/subscription/activate       -> pr_activate_subscription
--
-- El webhook de confirmacion (POST /pagopar/v1/subscription/webhook) ya esta
-- registrado en 20260710_subscription_billing_ords.sql y se reutiliza (el `pagar`
-- de pago-recurrente dispara la misma notificacion de pago).

BEGIN
    ----------------------------------------------------------------------------
    -- POST /workspace/subscription/card/add
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/card/add');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/card/add',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_add_card(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- POST /workspace/subscription/card/confirm
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/card/confirm');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/card/confirm',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_confirm_card(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- GET /workspace/subscription/cards
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/cards');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/cards',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_list_cards(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- DELETE /workspace/subscription/card/:id
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/card/:id');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/card/:id',
        p_method      => 'DELETE',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_delete_card(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_card_id       => TO_NUMBER(:id),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ----------------------------------------------------------------------------
    -- POST /workspace/subscription/activate
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/activate');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/activate',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_activate_subscription(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

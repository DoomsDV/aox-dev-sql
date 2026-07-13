-- Migracion ORDS: Fase 5 - Handlers de facturacion de suscripcion
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere que los modulos
-- 'hasel' (/api/v1/) y 'pagopar' (/pagopar/v1/) ya existan (PUBLISHED).
--
-- Endpoints:
--   GET  /api/v1/workspace/plans                         -> pr_get_plans
--   POST /api/v1/workspace/subscription/checkout         -> pr_create_checkout
--   POST /api/v1/workspace/subscription/change-plan      -> pr_change_plan
--   GET  /api/v1/workspace/subscription/invoice/:hash    -> pr_get_invoice_by_hash
--   POST /pagopar/v1/subscription/webhook                -> pr_subscription_webhook

BEGIN
    ----------------------------------------------------------------------------
    -- GET /workspace/plans
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/plans');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/plans',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_get_plans(
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
    -- POST /workspace/subscription/checkout
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/checkout');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/checkout',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_create_checkout(
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
    -- POST /workspace/subscription/change-plan
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/change-plan');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/change-plan',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_change_plan(
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
    -- GET /workspace/subscription/invoice/:hash
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'workspace/subscription/invoice/:hash');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/invoice/:hash',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_get_invoice_by_hash(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_hash          => :hash,
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
    -- POST /pagopar/subscription/webhook
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'pagopar', p_pattern => 'subscription/webhook');
    ORDS.define_handler(
        p_module_name => 'pagopar',
        p_pattern     => 'subscription/webhook',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_subscription_webhook(
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

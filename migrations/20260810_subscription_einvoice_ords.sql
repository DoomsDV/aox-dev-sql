-- Migracion ORDS: Facturacion electronica SIFEN de suscripciones (callback interno Astro).
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere modulo 'hasel' PUBLISHED.
--
-- Endpoints internos (SIN JWT de usuario; protegidos por header X-Service-Token,
-- validado dentro de cada procedure via pr_assert_service_token):
--   POST /api/v1/internal/subscription-invoices/:id/einvoice
--   GET  /api/v1/internal/subscription-invoices/pending-kude
--   POST /api/v1/internal/subscription-invoices/:id/einvoice-kude
--
-- Llamados desde bookmate (Astro) src/pages/api/internal/esign/*.ts.

BEGIN
    ----------------------------------------------------------------------------
    -- POST /internal/subscription-invoices/:id/einvoice
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'internal/subscription-invoices/:id/einvoice');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_result(
        pi_service_token => owa_util.get_cgi_env('HTTP_X_SERVICE_TOKEN'),
        pi_invoice_id    => TO_NUMBER(:id),
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
    -- GET /internal/subscription-invoices/pending-kude
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'internal/subscription-invoices/pending-kude');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/pending-kude',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_list_pending_kude(
        pi_service_token => owa_util.get_cgi_env('HTTP_X_SERVICE_TOKEN'),
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
    -- POST /internal/subscription-invoices/:id/einvoice-kude
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'internal/subscription-invoices/:id/einvoice-kude');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice-kude',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_kude(
        pi_service_token => owa_util.get_cgi_env('HTTP_X_SERVICE_TOKEN'),
        pi_invoice_id    => TO_NUMBER(:id),
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

PROMPT === ORDS internal/subscription-invoices/* registrado ===

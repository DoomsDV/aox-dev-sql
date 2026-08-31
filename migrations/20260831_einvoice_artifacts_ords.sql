-- ORDS: callback de artefactos fiscales (XML + KuDE) para suscripciones.
-- Idempotente. Requiere modulo 'hasel' PUBLISHED y
-- migrations/20260831_einvoice_artifacts.sql + paquete actualizado.
--
-- POST /api/v1/internal/subscription-invoices/:id/einvoice-artifacts
-- Body JSON (Astro poll-kude):
--   {
--     "cdc": "<44>",
--     "kudeUrl": "https://...",
--     "xml": "<?xml ...>",
--     "xmlSha256": "<hex lowercase>",
--     "xmlSize": 1234,
--     "xmlMime": "application/xml; charset=UTF-8"
--   }

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice-artifacts'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'internal/subscription-invoices/:id/einvoice-artifacts',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_save_einvoice_artifacts(
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

PROMPT === ORDS internal/subscription-invoices/:id/einvoice-artifacts registrado ===

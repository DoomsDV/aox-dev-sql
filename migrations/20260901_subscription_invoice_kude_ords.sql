-- ORDS: GET /workspace/subscription/invoices/:id/kude
-- Metadatos de descarga del KuDE (PDF) para el proxy autenticado de Bookmate.
PROMPT === ORDS subscription/invoices/:id/kude ===

BEGIN
    BEGIN
        ORDS.delete_handler(
            p_module_name  => 'hasel',
            p_uri_template => 'workspace/subscription/invoices/:id/kude',
            p_method       => 'GET'
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    BEGIN
        ORDS.delete_template(
            p_module_name  => 'hasel',
            p_uri_template => 'workspace/subscription/invoices/:id/kude'
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/invoices/:id/kude'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/subscription/invoices/:id/kude',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_subscription_billing_api.pr_get_invoice_kude(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_invoice_id    => TO_NUMBER(:id),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    -- :status_code (no :status) para propagar HTTP 404/409 reales a Astro.
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

PROMPT OK: ORDS subscription/invoices/:id/kude

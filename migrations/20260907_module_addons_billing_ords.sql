-- Fase 2 cobro fiscal de complementos de módulo: Idempotency-Key en POST /workspace/addons.
-- Compilar PKG_AOX_ADDON_API y PKG_AOX_SUBSCRIPTION_BILLING_API antes de este handler.

BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/addons',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_addon_api.pr_activate_module_addon(
        pi_auth_header      => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_body             => :body_text,
        po_status_code      => v_status_code,
        po_response_body    => v_response_body,
        pi_idempotency_key  => owa_util.get_cgi_env('HTTP_IDEMPOTENCY_KEY')
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

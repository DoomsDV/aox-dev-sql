-- Migracion ORDS: Hub publico del negocio
--
-- Public:
--   GET /public/v1/org/:slug  -> pkg_aox_public_booking_api.pr_get_org_hub

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'org/:slug'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'org/:slug',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_get_org_hub(
        pi_org_slug      => :slug,
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

PROMPT === ORDS GET /public/v1/org/:slug registrado ===

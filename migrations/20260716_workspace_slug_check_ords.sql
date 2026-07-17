-- Migracion ORDS: validar disponibilidad de profile_slug del negocio
--
--   GET /api/v1/workspace/profile-slug-available?slug=...

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/profile-slug-available'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/profile-slug-available',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_workspace_api.pr_check_profile_slug(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_slug          => :slug,
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

PROMPT === ORDS GET /api/v1/workspace/profile-slug-available registrado ===

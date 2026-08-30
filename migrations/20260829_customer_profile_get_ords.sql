-- Migracion ORDS: GET /customers/:id (perfil del cliente).
-- Requiere PKG_AOX_CUSTOMER_API.pr_get_customer_profile (ya existente).
-- Este handler ya estaba desplegado en produccion (wksp_aox) pero nunca
-- quedo versionado como migracion ni aplicado en DEV (aoxdev); se agrega
-- aqui para cerrar el drift entre ambientes.

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_get_customer_profile(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_cus_id        => TO_NUMBER(:id),
        pi_pro_id        => TO_NUMBER(:pro_id),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

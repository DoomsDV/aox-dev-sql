-- Migracion ORDS: PUT /customers/:id (editar nombre y telefono del cliente).
-- Requiere PKG_AOX_CUSTOMER_API.pr_update_customer_profile.
-- El template 'customers/:id' ya existe por el handler GET; se re-declara aqui
-- de forma idempotente por si esta migracion se ejecuta en un ambiente donde
-- todavia no fue creado manualmente.

BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id'
    );

    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'customers/:id',
        p_method      => 'PUT',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_customer_api.pr_update_customer_profile(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_cus_id        => TO_NUMBER(:id),
        pi_body          => :body_text,
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

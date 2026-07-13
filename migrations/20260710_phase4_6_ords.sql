-- Migracion ORDS: Fase 4 (adjuntos de historial) + Fase 6 (rentabilidad)
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere que el modulo
-- 'hasel' (/api/v1/) ya exista (PUBLISHED).
--
-- Endpoints:
--   POST   /api/v1/appointments/:id/attachments             -> pr_upload_attachment
--   DELETE /api/v1/appointments/:id/attachments/:att_id      -> pr_delete_attachment
--   GET    /api/v1/dashboard/profitability                   -> pr_get_profitability

BEGIN
    ----------------------------------------------------------------------------
    -- POST /appointments/:id/attachments  (subir adjunto al historial)
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'appointments/:id/attachments');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/:id/attachments',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_upload_attachment(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_app_id        => :id,
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
    -- DELETE /appointments/:id/attachments/:att_id  (eliminar adjunto)
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'appointments/:id/attachments/:att_id');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/:id/attachments/:att_id',
        p_method      => 'DELETE',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_delete_attachment(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_app_id        => :id,
        pi_attachment_id => :att_id,
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
    -- GET /dashboard/profitability  (metricas de rentabilidad Premium)
    ----------------------------------------------------------------------------
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'dashboard/profitability');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'dashboard/profitability',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_dashboard_api.pr_get_profitability(
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

    COMMIT;
END;
/

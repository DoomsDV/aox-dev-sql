-- Migracion ORDS: Directorio publico /explorar
--
-- Public:
--   GET /public/v1/directory  -> pkg_aox_public_booking_api.pr_search_org_directory
-- Query params: search (texto), specialty, city_id, department_id, offset (rechazado si > 0)
-- Nota: NO usar "q" — reservado por ORDS (QBE).

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'directory'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'directory',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_public_booking_api.pr_search_org_directory(
        pi_query         => :search,
        pi_specialty     => :specialty,
        pi_city_id       => CASE WHEN :city_id IS NULL OR TRIM(:city_id) IS NULL THEN NULL ELSE TO_NUMBER(:city_id) END,
        pi_department_id => CASE WHEN :department_id IS NULL OR TRIM(:department_id) IS NULL THEN NULL ELSE TO_NUMBER(:department_id) END,
        pi_offset        => NVL(CASE WHEN :offset IS NULL OR TRIM(:offset) IS NULL THEN 0 ELSE TO_NUMBER(:offset) END, 0),
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

PROMPT === ORDS GET /public/v1/directory registrado ===

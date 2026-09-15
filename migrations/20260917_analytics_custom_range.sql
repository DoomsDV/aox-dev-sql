-- HAS-57 / HAS-62: rango personalizado (from_date / to_date) en GET /dashboard/analytics.
-- Requiere 20260916_tenant_analytics.sql. Máximo 90 días inclusive.

@@../packages/PKG_AOX_DASHBOARD_API.pls

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'dashboard/analytics');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'dashboard/analytics',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
    v_days          NUMBER;
    v_location_id   NUMBER;
    v_professional  NUMBER;
    v_from_date     VARCHAR2(20);
    v_to_date       VARCHAR2(20);
BEGIN
    BEGIN
        v_days := TO_NUMBER(:days);
    EXCEPTION
        WHEN OTHERS THEN
            v_days := 7;
    END;
    BEGIN
        v_location_id := TO_NUMBER(:location_id);
    EXCEPTION
        WHEN OTHERS THEN
            v_location_id := NULL;
    END;
    BEGIN
        v_professional := TO_NUMBER(:professional_id);
    EXCEPTION
        WHEN OTHERS THEN
            v_professional := NULL;
    END;
    v_from_date := NULLIF(TRIM(:from_date), '');
    v_to_date   := NULLIF(TRIM(:to_date), '');

    pkg_aox_dashboard_api.pr_get_analytics(
        pi_auth_header     => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_days            => v_days,
        pi_location_id     => v_location_id,
        pi_professional_id => v_professional,
        pi_from_date       => v_from_date,
        pi_to_date         => v_to_date,
        po_status_code     => v_status_code,
        po_response_body   => v_response_body
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

-- Migracion ORDS: fechas con disponibilidad publica (calendario)
--
-- Public:
--   GET /public/v1/available-dates?pro_id&loc_id&ser_id&from_date&to_date
--       [&exclude_app_id]

BEGIN
    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'available-dates'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'available-dates',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
    v_exclude_app   NUMBER := NULL;
BEGIN
    BEGIN
        IF :exclude_app_id IS NOT NULL AND LENGTH(TRIM(:exclude_app_id)) > 0 THEN
            v_exclude_app := TO_NUMBER(:exclude_app_id);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            v_exclude_app := NULL;
    END;

    pkg_aox_public_booking_api.pr_get_available_dates(
        pi_pro_id         => TO_NUMBER(:pro_id),
        pi_loc_id         => TO_NUMBER(:loc_id),
        pi_ser_id         => TO_NUMBER(:ser_id),
        pi_from_date      => :from_date,
        pi_to_date        => :to_date,
        pi_exclude_app_id => v_exclude_app,
        po_status_code    => v_status_code,
        po_response_body  => v_response_body
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

PROMPT === ORDS GET /public/v1/available-dates registrado ===

-- Migracion ORDS: Fase 4 del plan de correccion N+1 (bulk de citas).
-- Ejecutar como el esquema ORDS-enabled (aoxdev). Requiere que el modulo
-- 'hasel' (/api/v1/) ya exista (PUBLISHED) y que PKG_AOX_APPOINTMENT_API
-- tenga PR_CREATE_APPOINTMENTS_BULK (ver packages/PKG_AOX_APPOINTMENT_API.pls).
--
-- Endpoint:
--   POST /api/v1/appointments/bulk  -> pkg_aox_appointment_api.pr_create_appointments_bulk
--
-- Reemplaza el guardado masivo de citas (escaneo de agenda) que antes hacia N
-- POSTs secuenciales a /appointments desde el frontend (bookmate/src/lib/appointments.ts,
-- createAppointmentsBulkWithOrds) por una sola llamada HTTP con N operaciones
-- resueltas dentro de la misma conexion PL/SQL.

BEGIN
    ORDS.define_template(p_module_name => 'hasel', p_pattern => 'appointments/bulk');
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'appointments/bulk',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_appointment_api.pr_create_appointments_bulk(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
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

    COMMIT;
END;
/

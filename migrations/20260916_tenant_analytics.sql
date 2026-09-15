-- HAS-50: capability analytics.view (Admin por default) + GET /dashboard/analytics.
-- Reversible: DELETE FROM role_capability_default / capability WHERE code='analytics.view'
-- y ORDS.DELETE_HANDLER de dashboard/analytics.

PROMPT === 20260916_tenant_analytics ===

PROMPT --- capability analytics.view ---
MERGE INTO capability t
USING (
    SELECT
        'analytics.view' AS code,
        'analytics' AS group_code,
        'Analiticas' AS group_label,
        'Ver analiticas' AS label,
        'Ver el resumen de citas, inasistencias y senas del negocio.' AS description,
        'MENU' AS kind,
        15 AS sort_order
      FROM dual
) s
ON (t.code = s.code)
WHEN MATCHED THEN UPDATE SET
    t.group_code   = s.group_code,
    t.group_label  = s.group_label,
    t.label        = s.label,
    t.description  = s.description,
    t.kind         = s.kind,
    t.sort_order   = s.sort_order,
    t.is_active    = 1
WHEN NOT MATCHED THEN INSERT (
    code, group_code, group_label, label, description, kind, sort_order, is_active
) VALUES (
    s.code, s.group_code, s.group_label, s.label, s.description, s.kind, s.sort_order, 1
);
COMMIT;

DECLARE
    v_admin  NUMBER := pkg_aox_util.fn_rol('ADMIN');
    v_prof   NUMBER := pkg_aox_util.fn_rol('PROFESIONAL');
    v_recep  NUMBER := pkg_aox_util.fn_rol('RECEPCIONISTA');
    v_cap_id NUMBER;

    PROCEDURE upsert_grant(pi_role_id NUMBER, pi_granted NUMBER) IS
    BEGIN
        MERGE INTO role_capability_default t
        USING (SELECT pi_role_id AS role_id, v_cap_id AS cap_id FROM dual) s
        ON (t.rol_id_role = s.role_id AND t.cap_id_capability = s.cap_id)
        WHEN MATCHED THEN UPDATE SET t.is_granted = pi_granted
        WHEN NOT MATCHED THEN INSERT (rol_id_role, cap_id_capability, is_granted)
        VALUES (s.role_id, s.cap_id, pi_granted);
    END;
BEGIN
    SELECT id_capability INTO v_cap_id FROM capability WHERE code = 'analytics.view';
    upsert_grant(v_admin, 1);
    upsert_grant(v_recep, 0);
    upsert_grant(v_prof, 0);
END;
/
COMMIT;

PROMPT --- PKG_AOX_DASHBOARD_API (pr_get_analytics) ---
@@../packages/PKG_AOX_DASHBOARD_API.pls

PROMPT --- ORDS GET /dashboard/analytics ---
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

    pkg_aox_dashboard_api.pr_get_analytics(
        pi_auth_header     => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_days            => v_days,
        pi_location_id     => v_location_id,
        pi_professional_id => v_professional,
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

PROMPT === 20260916_tenant_analytics finalizada ===

-- Bookmate Assistant: entitlement preview, capability gates y endpoints de lectura.
-- Ejecutar como AOXDEV después de role capabilities, addons y encuesta; puede
-- correr antes de habilitar las políticas RLS porque no activa ningún tenant.
-- No activa el complemento para ninguna organización: usar el script operativo
-- scripts/grant_ai_assistant_preview.sql con un :org_id explícito.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === capability assistant.use ===
MERGE INTO capability t
USING (
    SELECT 'assistant.use' AS code,
           'assistant' AS group_code,
           'Asistente' AS group_label,
           'Usar asistente inteligente' AS label,
           'Consultar datos operativos con el asistente de Bookmate.' AS description,
           'ADDON' AS kind,
           150 AS sort_order,
           'AI_ASSISTANT' AS requires_entitlement,
           0 AS is_locked,
           1 AS is_active
      FROM dual
) s
ON (t.code = s.code)
WHEN MATCHED THEN UPDATE SET
    t.group_code = s.group_code,
    t.group_label = s.group_label,
    t.label = s.label,
    t.description = s.description,
    t.kind = s.kind,
    t.sort_order = s.sort_order,
    t.requires_entitlement = s.requires_entitlement,
    t.is_locked = s.is_locked,
    t.is_active = s.is_active
WHEN NOT MATCHED THEN INSERT (
    code, group_code, group_label, label, description, kind, sort_order,
    requires_entitlement, is_locked, is_active
) VALUES (
    s.code, s.group_code, s.group_label, s.label, s.description, s.kind,
    s.sort_order, s.requires_entitlement, s.is_locked, s.is_active
);

DECLARE
    v_admin NUMBER := pkg_aox_util.fn_rol('ADMIN');
    v_recep NUMBER := pkg_aox_util.fn_rol('RECEPCIONISTA');
    v_prof  NUMBER := pkg_aox_util.fn_rol('PROFESIONAL');
    v_cap   NUMBER;

    PROCEDURE upsert_default(pi_role_id NUMBER, pi_granted NUMBER) IS
    BEGIN
        MERGE INTO role_capability_default t
        USING (SELECT pi_role_id AS role_id, v_cap AS cap_id, pi_granted AS granted FROM dual) s
        ON (t.rol_id_role = s.role_id AND t.cap_id_capability = s.cap_id)
        WHEN MATCHED THEN UPDATE SET t.is_granted = s.granted
        WHEN NOT MATCHED THEN INSERT (rol_id_role, cap_id_capability, is_granted)
        VALUES (s.role_id, s.cap_id, s.granted);
    END;
BEGIN
    SELECT id_capability INTO v_cap FROM capability WHERE code = 'assistant.use';
    upsert_default(v_admin, 1);
    upsert_default(v_recep, 0);
    upsert_default(v_prof, 0);
END;
/

PROMPT === ref_addon AI_ASSISTANT ===
MERGE INTO ref_addon t
USING (
    SELECT 'AI_ASSISTANT' AS code,
           'Asistente inteligente' AS name,
           'Asistente operativo de lectura para consultas del negocio.' AS short_description,
           'AI_ASSISTANT' AS feature_code,
           0 AS price_amount,
           'PYG' AS currency,
           'MONTHLY' AS billing_period,
           1 AS is_active,
           150 AS sort_order,
           CAST(NULL AS VARCHAR2(30)) AS audience_code
      FROM dual
) s
ON (t.feature_code = s.feature_code)
WHEN MATCHED THEN UPDATE SET
    t.code = s.code,
    t.name = s.name,
    t.short_description = s.short_description,
    t.price_amount = s.price_amount,
    t.currency = s.currency,
    t.billing_period = s.billing_period,
    t.is_active = s.is_active,
    t.sort_order = s.sort_order,
    t.audience_code = s.audience_code
WHEN NOT MATCHED THEN INSERT (
    id_addon, code, name, short_description, feature_code,
    price_amount, currency, billing_period, is_active, sort_order, audience_code
) VALUES (
    (SELECT NVL(MAX(id_addon), 0) + 1 FROM ref_addon),
    s.code, s.name, s.short_description, s.feature_code,
    s.price_amount, s.currency, s.billing_period, s.is_active,
    s.sort_order, s.audience_code
);

COMMIT;

PROMPT === compile assistant read package ===
@@../packages/PKG_AOX_SUBSCRIPTION_API.pls
@@../packages/PKG_AOX_DASHBOARD_API.pls
@@../packages/PKG_AOX_APPOINTMENT_API.pls
@@../packages/PKG_AOX_CUSTOMER_API.pls
@@../packages/PKG_AOX_LOCATION_API.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_SPECIALTY_API.pls
@@../packages/PKG_AOX_PROFESSIONAL_API.pls
@@../packages/PKG_AOX_SCHEDULE_API.pls
@@../packages/PKG_AOX_WORKSPACE_API.pls
@@../packages/PKG_AOX_PAYMENTS_API.pls
@@../packages/PKG_AOX_PAYMENT_SETTINGS_API.pls
@@../packages/PKG_AOX_ADDON_API.pls
@@../packages/PKG_AOX_ASSISTANT_API.pls
-- SUBSCRIPTION_API reemplaza su especificación al compilarse y puede
-- invalidar el body dependiente de permisos; recompilar solo ese body.
ALTER PACKAGE pkg_aox_permission_api COMPILE BODY;

PROMPT === ORDS assistant review endpoints ===
BEGIN
    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/reviews/summary'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/reviews/summary',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_assistant_api.pr_review_summary(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_days          => NVL(TO_NUMBER(:days), 30),
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/reviews/recent'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'assistant/reviews/recent',
        p_method      => 'GET',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_assistant_api.pr_list_reviews(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_days          => NVL(TO_NUMBER(:days), 30),
        pi_limit         => NVL(TO_NUMBER(:limit), 10),
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

PROMPT OK: Bookmate Assistant foundation and review endpoints

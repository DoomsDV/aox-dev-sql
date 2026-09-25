-- Mail de factura con el firmador de etick en bucket privado.
--
-- Desde 2026-09-24 el kude_url del webhook invoice.ready es el link estable del
-- firmador (/v1/documents/{cdc}/kude/pdf), que exige la API key y redirige a un
-- link temporal. pr_send_einvoice_email ahora pide ese link a GET .../kude.
--
-- APEX_MAIL_APP_ID: app APEX que da la identidad de workspace a apex_mail
-- (100 en prod AOX, 2100 en aoxdevelop AOXDEV). Se toma de la app que tiene la
-- plantilla configurada; si no se encuentra, el paquete usa 100.
--
-- Secretos por ambiente (no van en el repo): ESIGN_API_KEY y ESIGN_WEBHOOK_SECRET
-- se cargan a mano desde el panel de etick del cliente emisor.

PROMPT === app_parameter APEX_MAIL_APP_ID ===
-- En PL/SQL: dentro de un MERGE/INSERT ... SELECT la vista de APEX no devuelve filas.
DECLARE
    v_app NUMBER;
BEGIN
    SELECT MIN(application_id) INTO v_app
      FROM apex_appl_email_templates
     WHERE UPPER(static_id) = UPPER(fn_get_parameter('APEX_EMAIL_TEMPLATE_FACTURASUSCRIPCION'));
    IF v_app IS NOT NULL THEN
        MERGE INTO app_parameter t
        USING (SELECT 'APEX_MAIL_APP_ID' AS param_key FROM dual) s
        ON (t.param_key = s.param_key)
        WHEN NOT MATCHED THEN
            INSERT (param_key, param_value, description)
            VALUES ('APEX_MAIL_APP_ID', TO_CHAR(v_app),
                    'App APEX para la sesion de apex_mail (identidad de workspace).');
    END IF;
    COMMIT;
END;
/

PROMPT === Compilar paquete billing (KuDE via link temporal + APEX_MAIL_APP_ID) ===
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

-- Facturacion electronica SIFEN (firmador esign) de suscripciones Hasel.
-- Ejecutar como el esquema ORDS-enabled (aoxdev).
--
-- Agrega a org_subscription_invoice el estado del ciclo de emision de Factura
-- Electronica (FE) ante el firmador, y los app_parameter que necesita
-- PKG_AOX_SUBSCRIPTION_BILLING_API.pr_notificar_emision_fe / pr_save_einvoice_result /
-- pr_list_pending_kude / pr_save_einvoice_kude.
--
-- Flujo: ver PKG_AOX_SUBSCRIPTION_BILLING_API.pls (seccion "Factura electronica SIFEN").

PROMPT === org_subscription_invoice.einvoice_* ===

DECLARE
    v_exists NUMBER;

    PROCEDURE add_col(pi_ddl IN VARCHAR2, pi_column IN VARCHAR2) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
          FROM user_tab_columns
         WHERE table_name = 'ORG_SUBSCRIPTION_INVOICE'
           AND column_name = pi_column;
        IF v_count = 0 THEN
            EXECUTE IMMEDIATE pi_ddl;
        END IF;
    END add_col;
BEGIN
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_status VARCHAR2(20) DEFAULT 'NONE' NOT NULL)]', 'EINVOICE_STATUS');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_cdc VARCHAR2(44) NULL)]', 'EINVOICE_CDC');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_estado_sifen VARCHAR2(20) NULL)]', 'EINVOICE_ESTADO_SIFEN');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_cod_res VARCHAR2(10) NULL)]', 'EINVOICE_COD_RES');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_prot_aut VARCHAR2(30) NULL)]', 'EINVOICE_PROT_AUT');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_kude_url VARCHAR2(500) NULL)]', 'EINVOICE_KUDE_URL');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_ambiente VARCHAR2(10) NULL)]', 'EINVOICE_AMBIENTE');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_sent_at TIMESTAMP(6) WITH TIME ZONE NULL)]', 'EINVOICE_SENT_AT');
    add_col(q'[ALTER TABLE org_subscription_invoice ADD (einvoice_error VARCHAR2(500) NULL)]', 'EINVOICE_ERROR');
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE org_subscription_invoice ADD CONSTRAINT chk_orginv_einvoice_status CHECK (
            einvoice_status IN ('NONE', 'PENDING', 'SENT_PENDING_KUDE', 'SENT', 'FAILED')
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2260) THEN -- constraint ya existe
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN org_subscription_invoice.einvoice_status IS
  'Ciclo de emision de Factura Electronica SIFEN: NONE (no aplica/no configurado) | PENDING (webhook enviado al firmador) | SENT_PENDING_KUDE (FE aprobada, esperando PDF) | SENT (email con KuDE enviado) | FAILED.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_cdc IS 'CDC (44 digitos) del documento emitido en el firmador esign.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_estado_sifen IS 'estado devuelto por POST /v1/documents del firmador (APROBADO | RECHAZADO | FIRMADO).';
COMMENT ON COLUMN org_subscription_invoice.einvoice_cod_res IS 'codRes SIFEN (ej. 0260 aprobado).';
COMMENT ON COLUMN org_subscription_invoice.einvoice_prot_aut IS 'Protocolo de autorizacion SIFEN.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_kude_url IS 'URL publica del KuDE (PDF) en el bucket del firmador, una vez listo.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_ambiente IS 'Ambiente SIFEN de la emision (test | prod), segun el prefijo de la api key usada.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_sent_at IS 'Cuando se envio el email de factura con el KuDE adjunto al billing_email.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_error IS 'Ultimo error del ciclo de emision (SIFEN rechazado o fallo de envio de email).';

COMMIT;

PROMPT === app_parameter: integracion firmador esign ===

MERGE INTO app_parameter t
USING (
    SELECT 'ESIGN_WEBHOOK_URL' AS param_key,
           'https://staging.hasel.app/api/v1/internal/subscription-invoices' AS param_value,
           'Base URL del callback Astro que recibe el resultado de emision SIFEN (POST /api/internal/esign/emit-invoice). Cambiar a https://hasel.app/... en produccion.' AS description
      FROM dual UNION ALL
    SELECT 'ESIGN_CALLBACK_SERVICE_TOKEN',
           'esign_svc_8f2a1c6d4b7e4f0f9c3a2d5e6b1a9c7f',
           'Secreto compartido (header X-Service-Token) entre Oracle y Astro (ESIGN_CALLBACK_SERVICE_TOKEN en bookmate/.env.development). Valor de arranque para TEST; regenerar antes de producir en serio y actualizar en ambos lados.'
      FROM dual UNION ALL
    SELECT 'ESIGN_ESTABLECIMIENTO', '001', 'Establecimiento SIFEN de Hasel como emisor (panel esign).' FROM dual UNION ALL
    SELECT 'ESIGN_PUNTO_EXPEDICION', '001', 'Punto de expedicion SIFEN de Hasel como emisor (panel esign).' FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT === OK: subscription_einvoice_sifen (columnas + app_parameter) ===
PROMPT NOTA: reemplazar ESIGN_CALLBACK_SERVICE_TOKEN y ESIGN_WEBHOOK_URL con los valores reales
PROMPT       (el token debe ser identico al ESIGN_CALLBACK_SERVICE_TOKEN de bookmate/.env.development).

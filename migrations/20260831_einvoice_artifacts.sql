-- Artefactos fiscales privados (XML firmado + metadatos) y estados neutros
-- de entrega. Idempotente. NO guarda URL publica de XML.
--
-- Companero ORDS: 20260831_einvoice_artifacts_ords.sql
-- Paquete: PKG_AOX_SUBSCRIPTION_BILLING_API (pr_save_einvoice_artifacts).

PROMPT === org_subscription_invoice: XML privado + email lease/snapshot ===

DECLARE
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
    -- XML firmado canónico (copia privada AOX; nunca URL pública).
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_xml_firmado CLOB)', 'EINVOICE_XML_FIRMADO');
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_xml_sha256 VARCHAR2(64))', 'EINVOICE_XML_SHA256');
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_xml_size NUMBER)', 'EINVOICE_XML_SIZE');
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_xml_mime VARCHAR2(100))', 'EINVOICE_XML_MIME');
    add_col(
        'ALTER TABLE org_subscription_invoice ADD (einvoice_xml_available_at TIMESTAMP(6) WITH TIME ZONE)',
        'EINVOICE_XML_AVAILABLE_AT'
    );
    -- Lease real del claim de email + trazabilidad del intento.
    add_col(
        'ALTER TABLE org_subscription_invoice ADD (einvoice_email_lease_until TIMESTAMP(6) WITH TIME ZONE)',
        'EINVOICE_EMAIL_LEASE_UNTIL'
    );
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_email_mail_id NUMBER)', 'EINVOICE_EMAIL_MAIL_ID');
    -- Snapshot del destinatario efectivo al enviar (no reconsultar profile).
    add_col('ALTER TABLE org_subscription_invoice ADD (einvoice_email_to VARCHAR2(255))', 'EINVOICE_EMAIL_TO');
END;
/

-- Ampliar CHECK de einvoice_status: SENT_PENDING_ARTIFACTS (preferido) +
-- SENT_PENDING_KUDE (legacy, misma semántica: FE aprobada, artefactos/email pendientes).
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_subscription_invoice DROP CONSTRAINT chk_orginv_einvoice_status';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2443, -23292) THEN -- no existe
            RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE org_subscription_invoice ADD CONSTRAINT chk_orginv_einvoice_status CHECK (
            einvoice_status IN (
                'NONE',
                'PENDING',
                'SENT_PENDING_ARTIFACTS',
                'SENT_PENDING_KUDE',
                'SENT',
                'FAILED'
            )
        )
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-2264, -2260) THEN
            RAISE;
        END IF;
END;
/

-- Semantica CHECK (documentacion; el constraint no admite comentarios inline en todos los builds):
-- NONE: no aplica / no configurado
-- PENDING: webhook/outbox enviado al firmador (emision en curso)
-- SENT_PENDING_ARTIFACTS: FE SIFEN aprobada; faltan XML y/o KuDE y/o email
-- SENT_PENDING_KUDE: alias legacy de SENT_PENDING_ARTIFACTS (compat)
-- SENT: correo con XML+PDF entregado a la cola APEX Mail
-- FAILED: rechazo SIFEN u error terminal de emision (no de email)

COMMENT ON COLUMN org_subscription_invoice.einvoice_status IS
  'Ciclo FE SIFEN vs entrega: NONE | PENDING (emision pedida) | SENT_PENDING_ARTIFACTS (aprobada, esperando XML+KuDE+email; alias legacy SENT_PENDING_KUDE) | SENT (email encolado) | FAILED (rechazo SIFEN). Email detallado en einvoice_email_*.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_xml_firmado IS
  'Copia privada del XML firmado canónico (CLOB). NUNCA exponer ni guardar URL pública.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_xml_sha256 IS
  'SHA-256 hex (lowercase) del XML firmado, calculado en el puente Astro y verificado en Oracle.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_xml_size IS
  'Tamaño en bytes del XML firmado.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_xml_mime IS
  'MIME del XML (application/xml; charset=UTF-8).';
COMMENT ON COLUMN org_subscription_invoice.einvoice_xml_available_at IS
  'Cuando AOX persistió el XML privado (artefacto listo).';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_lease_until IS
  'Vencimiento del claim PENDING de email; expirado permite reintento.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_mail_id IS
  'apex_mail.send mail_id del ultimo intento (trazabilidad).';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_to IS
  'Snapshot del billing_email efectivo usado en el envio.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_email_status IS
  'Correo con adjuntos XML+PDF: NONE | PENDING (lease) | SENT | FAILED. Independiente del ciclo SIFEN.';
COMMENT ON COLUMN org_subscription_invoice.einvoice_kude_url IS
  'URL del KuDE (PDF). El XML NO tiene URL publica; vive en einvoice_xml_firmado.';

COMMIT;

PROMPT === OK: 20260831_einvoice_artifacts ===

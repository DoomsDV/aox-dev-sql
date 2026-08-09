-- Hardening seguridad uploads (auditoría ORDS: hallazgos R1/R2/R4), Fase 1:
-- max bytes ANTES de clobbase642blob + rate limit en pr_upload_public_receipt
-- (PKG_AOX_PUBLIC_BOOKING_API) y max bytes en pr_upload_attachment (PKG_AOX_APPOINTMENT_API).
-- Requiere redeploy de ambos paquetes (ver aox-dev/install_all.sql); esta migración
-- solo agrega los app_parameter que usan.

PROMPT === 20260809_receipt_attachment_upload_hardening ===

BEGIN
    MERGE INTO app_parameter t
    USING (
        SELECT 'RECEIPT_MAX_BYTES' AS param_key, '8388608' AS param_value,
               'Tamano maximo (bytes) del comprobante SIPAP antes de decodificar base64 (8 MB)' AS description FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_RECEIPT_UPLOAD_MAX', '10',
               'Max intentos de upload de comprobante por token de reserva por ventana' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_RECEIPT_UPLOAD_WINDOW_SEC', '900',
               'Ventana en segundos del rate limit de upload de comprobante por token' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_RECEIPT_UPLOAD_IP_MAX', '30',
               'Max intentos de upload de comprobante por IP por ventana' FROM dual
        UNION ALL
        SELECT 'RATE_LIMIT_RECEIPT_UPLOAD_IP_WINDOW_SEC', '900',
               'Ventana en segundos del rate limit de upload de comprobante por IP' FROM dual
        UNION ALL
        SELECT 'ATTACHMENT_MAX_BYTES', '20971520',
               'Tamano maximo (bytes) de un adjunto de cita antes de decodificar base64 (20 MB)' FROM dual
    ) s
    ON (t.param_key = s.param_key)
    WHEN NOT MATCHED THEN
        INSERT (param_key, param_value, description)
        VALUES (s.param_key, s.param_value, s.description);

    COMMIT;
END;
/

PROMPT === 20260809_receipt_attachment_upload_hardening done ===

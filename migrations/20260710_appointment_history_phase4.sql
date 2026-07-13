-- Migracion: Fase 4 - Historial por cita + storage
-- Roadmap Hasel: Premium + Planes + Historial
--
-- Contenido:
--   * Tablas nuevas: appointment_session_record (notas 1:1 por cita) y
--     appointment_attachment (archivos, suman a storage_used_bytes).
--   * PKG_AOX_BUCKET: pr_upload_appointment_attachment / pr_delete_appointment_attachment
--     con gate de feature APPOINTMENT_HISTORY, escritura y paywall de bytes.
--   * PKG_AOX_APPOINTMENT_API: guarda el historial al pasar la cita a COMPLETADO en la
--     MISMA transaccion (session_notes en el PUT) y expone historial en el detalle.
--   * PKG_AOX_CUSTOMER_API: flags de historial (has_history / attachment_count) en reservas.

PROMPT === 1. Tablas de historial ===
@@../tables/APPOINTMENT_SESSION_RECORD.sql
@@../tables/APPOINTMENT_ATTACHMENT.sql

PROMPT === 2. Bucket (adjuntos + paywall storage) ===
@@../packages/PKG_AOX_BUCKET.pls

PROMPT === 3. Appointment API (historial al completar) ===
@@../packages/PKG_AOX_APPOINTMENT_API.pls

PROMPT === 4. Customer API (flags de historial en reservas) ===
@@../packages/PKG_AOX_CUSTOMER_API.pls

PROMPT === 5. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Objetos invalidos restantes ===
SELECT object_type, object_name, status
  FROM user_objects
 WHERE status = 'INVALID'
   AND object_type IN ('PACKAGE', 'PACKAGE BODY')
 ORDER BY object_type, object_name;

PROMPT === Fase 4 (historial + storage) finalizada ===

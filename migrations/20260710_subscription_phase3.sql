-- Migracion: Fase 3 - Gateo backend (enforcement de suscripcion y entitlements)
-- Roadmap Hasel: Premium + Planes + Historial
--
-- Contenido:
--   * PKG_AOX_SUBSCRIPTION_API: agrega helpers de enforcement
--       - pr_assert_org_has_feature (403 si el plan no incluye el feature)
--       - pr_assert_public_booking_open (cartel mantenimiento si READ_ONLY / vencido)
--   * Gates aplicados en los paquetes de negocio:
--       - PKG_AOX_APPOINTMENT_API: bloquea crear / editar / eliminar citas en READ_ONLY / vencido.
--       - PKG_AOX_IA_API: recepcion por voz requiere VOICE_RECEPTION; resumen IA requiere
--         AI_MORNING_DIGEST y se desactiva en READ_ONLY.
--       - PKG_AOX_SERVICE_API: configurar seña (requires_deposit=1) requiere DEPOSIT_COLLECTION.
--       - PKG_AOX_PAGOPAR_API: fn_calculate_deposit devuelve 0 si el plan no incluye señas
--         (downgrade a Base); reserva publica con seña en mantenimiento si READ_ONLY.
--       - PKG_AOX_PUBLIC_BOOKING_API: reserva y reprogramacion publicas en mantenimiento si READ_ONLY.
--
-- Nota: SUBSCRIPTION_API se recompila primero (dependencia de los demas paquetes).

PROMPT === 1. API de suscripción (helpers de enforcement) ===
@@../packages/PKG_AOX_SUBSCRIPTION_API.pls

PROMPT === 2. Gate de escritura de citas ===
@@../packages/PKG_AOX_APPOINTMENT_API.pls

PROMPT === 3. Gates de IA (voz + resumen) ===
@@../packages/PKG_AOX_IA_API.pls

PROMPT === 4. Gate de señas en configuración de servicios ===
@@../packages/PKG_AOX_SERVICE_API.pls

PROMPT === 5. Gate de señas / reserva pública con pago ===
@@../packages/PKG_AOX_PAGOPAR_API.pls

PROMPT === 6. Gate de reserva pública (mantenimiento) ===
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 7. Recompilacion de objetos invalidos ===
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

PROMPT === Fase 3 (gateo backend) finalizada ===

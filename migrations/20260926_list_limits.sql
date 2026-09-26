-- Topes de tamano en listados y calendario (las respuestas no crecen sin limite con el volumen).
--   * PKG_AOX_HTTP.fn_page_size: limit 1..200 (NULL/<1 -> 9). Antes limit=0 dividia por cero
--     en total_pages y limit=100000 devolvia la tabla entera. Aplica a customers,
--     professionals, services, specialties y locations. El front pide como maximo 200
--     (export de clientes, que recorre total_pages con el per_page devuelto).
--   * appointments/calendar: rango maximo 62 dias (FullCalendar pide a lo sumo 42 en la
--     vista mes); mas que eso responde 400 VALIDATION_ERROR.
--   * workspace/customers/:id/body-snapshots: los 200 mas recientes.
-- Como AOXDEV / WKSP_AOX. Idempotente (CREATE OR REPLACE de paquetes).

SET SERVEROUTPUT ON SIZE UNLIMITED

@@../packages/PKG_AOX_HTTP.pls
@@../packages/PKG_AOX_CUSTOMER_API.pls
@@../packages/PKG_AOX_PROFESSIONAL_API.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_SPECIALTY_API.pls
@@../packages/PKG_AOX_LOCATION_API.pls
@@../packages/PKG_AOX_APPOINTMENT_API.pls
@@../packages/PKG_AOX_BODY_MAP_API.pls

EXEC DBMS_UTILITY.compile_schema(USER, compile_all => FALSE);

PROMPT === Objetos INVALID (esperado: ninguno)
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID' ORDER BY 1, 2;

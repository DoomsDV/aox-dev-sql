-- Lectura temporal para copiar ATC_KB_* hacia HASEL_ADMIN.ops_atc_kb_*.
-- Ejecutar como AOXDEV antes de copy_atc_kb_data.sql en HASEL_ADMIN.

GRANT SELECT ON atc_kb_document TO hasel_admin;
GRANT SELECT ON atc_kb_chunk TO hasel_admin;

PROMPT === GRANT SELECT atc_kb_* a hasel_admin (copia KB) ===
/
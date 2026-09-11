-- Drop de la KB ATC en AOXDEV tras copiar a HASEL_ADMIN y validar /ai/atc/ask.
-- No ejecutar hasta que PKG_AOX_ATC_CHAT lea hasel_admin.ops_atc_kb_* y el chat responda.

BEGIN
    EXECUTE IMMEDIATE 'DROP INDEX idx_atc_kb_chunk_vec';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-1418, -942) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE atc_kb_chunk CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE atc_kb_document CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

PROMPT === ATC_KB_* dropped from AOXDEV (fuente = HASEL_ADMIN) ===
/
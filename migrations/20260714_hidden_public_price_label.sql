-- Migracion: texto configurable para precios ocultos (Opción 1)
-- Default plataforma: 'A evaluar'
-- workspace_setting.hidden_public_price_label = default de org
-- service.hidden_public_price_label = override opcional por servicio

PROMPT === 1. Columna en workspace_setting ===
BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE workspace_setting ADD hidden_public_price_label VARCHAR2(80) DEFAULT 'A evaluar'
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL;
        ELSE RAISE;
        END IF;
END;
/

UPDATE workspace_setting
   SET hidden_public_price_label = NVL(NULLIF(TRIM(hidden_public_price_label), ''), 'A evaluar')
 WHERE hidden_public_price_label IS NULL
    OR TRIM(hidden_public_price_label) IS NULL;
COMMIT;

PROMPT === 2. Columna override en service ===
BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE service ADD hidden_public_price_label VARCHAR2(80) NULL
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL;
        ELSE RAISE;
        END IF;
END;
/

PROMPT === 3. Packages ===
@@../packages/PKG_AOX_WORKSPACE_API.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 4. Recompilacion ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === hidden_public_price_label finalizada ===

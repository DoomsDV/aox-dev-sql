-- Inclusiones públicas del servicio (una línea por ítem).
-- Vacío = no se muestra en /r/[token].

PROMPT === 1. Columna service.public_includes ===
BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE service ADD public_includes VARCHAR2(2000) NULL
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL; -- column already exists
        ELSE RAISE;
        END IF;
END;
/

PROMPT === 2. Packages ===
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === service.public_includes finalizada ===

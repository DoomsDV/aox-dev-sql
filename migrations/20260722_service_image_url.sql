-- Migracion: image_url en service (portada opcional del servicio)
-- Subida via PKG_AOX_BUCKET; expuesta en panel y reserva publica.

PROMPT === 1. Columna image_url ===
BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE service ADD image_url VARCHAR2(1000) NULL
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL; -- column already exists
        ELSE RAISE;
        END IF;
END;
/

PROMPT === 2. Packages ===
@@../packages/PKG_AOX_BUCKET.pls
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === image_url en service finalizada ===

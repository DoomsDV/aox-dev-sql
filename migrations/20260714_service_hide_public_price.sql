-- Migracion: hide_public_price en service
-- Permite ocultar el monto en la reserva publica mostrando "Se define en consulta".
-- El precio real (service.price) se mantiene para panel, senas y dashboard.

PROMPT === 1. Columna hide_public_price ===
BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE service ADD hide_public_price NUMBER(1) DEFAULT 0 NOT NULL
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN NULL; -- column already exists
        ELSE RAISE;
        END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        ALTER TABLE service ADD CONSTRAINT chk_ser_hide_public_price
            CHECK (hide_public_price IN (0, 1))
    ]';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE IN (-2260, -2264) THEN NULL; -- name/check already used
        ELSE RAISE;
        END IF;
END;
/

PROMPT === 2. Packages que exponen el flag ===
@@../packages/PKG_AOX_SERVICE_API.pls
@@../packages/PKG_AOX_PUBLIC_BOOKING_API.pls

PROMPT === 3. Recompilacion de objetos invalidos ===
BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === hide_public_price en service finalizada ===

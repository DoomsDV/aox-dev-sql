-- Bio corta del profesional (1-2 lineas) para el hub publico.
-- Sin foto + bio el profesional no se lista en GET /public/v1/org/:slug.

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === professional.short_bio ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE professional ADD short_bio VARCHAR2(280)';
    DBMS_OUTPUT.PUT_LINE('professional.short_bio agregada.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -1430 THEN
            DBMS_OUTPUT.PUT_LINE('professional.short_bio ya existe.');
        ELSE
            RAISE;
        END IF;
END;
/

COMMENT ON COLUMN professional.short_bio IS
    'Bio corta (1-2 lineas) para el hub publico. Sin foto y bio el profesional no se lista en el hub.';

PROMPT === Migracion professional.short_bio completada ===

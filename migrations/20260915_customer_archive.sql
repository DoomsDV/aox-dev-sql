-- HAS-23: archivar cliente (soft delete).
-- is_active=1 visible en listado/busqueda del dia a dia.
-- is_active=0 archivado. Nunca DELETE FROM customer.

PROMPT === 20260915_customer_archive ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
END;
/

DECLARE
    PROCEDURE add_col(pi_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_ddl;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-1430, -904) THEN
                NULL;
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    add_col('ALTER TABLE customer ADD is_active NUMBER(1,0) DEFAULT 1 NOT NULL');
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        COMMENT ON COLUMN customer.is_active IS
          '1 = visible en listado/busqueda del dia a dia. 0 = archivado (soft delete). Nunca se borra la fila.'
    ]';
END;
/

DECLARE
    PROCEDURE add_ck(pi_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_ddl;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-2264, -2275) THEN
                NULL;
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    add_ck('ALTER TABLE customer ADD CONSTRAINT ck_customer_is_active CHECK (is_active IN (0, 1))');
END;
/

DECLARE
    PROCEDURE add_idx(pi_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_ddl;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-955, -1408) THEN
                NULL;
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    add_idx(q'[
        CREATE INDEX idx_customer_org_active
          ON customer (org_id_organization, is_active)
    ]');
END;
/

UPDATE /*+ no_parallel */ customer
   SET is_active = 1
 WHERE is_active IS NULL;

COMMIT;

PROMPT === 20260915_customer_archive: OK ===

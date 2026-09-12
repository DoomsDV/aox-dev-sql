-- Alta de clientes: nombre/apellido, CI y correo.
-- first_name/last_name son nullable para no romper INSERT de citas/publico/IA.

PROMPT === 20260912_customer_create_fields ===

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
                NULL; -- columna ya existe
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    add_col('ALTER TABLE customer ADD first_name VARCHAR2(80)');
    add_col('ALTER TABLE customer ADD last_name VARCHAR2(80)');
    add_col('ALTER TABLE customer ADD document_number VARCHAR2(20)');
    add_col('ALTER TABLE customer ADD email VARCHAR2(150)');
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
        COMMENT ON COLUMN customer.first_name IS
          'Nombre de pila. Nullable: citas y reserva publica pueden seguir insertando solo full_name.'
    ]';
    EXECUTE IMMEDIATE q'[
        COMMENT ON COLUMN customer.last_name IS
          'Apellido. Nullable por el mismo motivo que first_name.'
    ]';
    EXECUTE IMMEDIATE q'[
        COMMENT ON COLUMN customer.document_number IS
          'CI paraguaya, solo digitos (5-8). Unica por organizacion cuando no es NULL.'
    ]';
    EXECUTE IMMEDIATE q'[
        COMMENT ON COLUMN customer.email IS
          'Correo en minusculas. Unico por organizacion cuando no es NULL.'
    ]';
END;
/

PROMPT Backfill first_name / last_name desde full_name
UPDATE /*+ no_parallel */ customer
   SET first_name = NULLIF(TRIM(SUBSTR(full_name, 1, INSTR(full_name || ' ', ' ') - 1)), ''),
       last_name  = NULLIF(TRIM(SUBSTR(full_name, INSTR(full_name || ' ', ' '))), '')
 WHERE first_name IS NULL;

COMMIT;

DECLARE
    PROCEDURE add_idx(pi_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE pi_ddl;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE IN (-955, -1408) THEN
                NULL; -- index ya existe
            ELSE
                RAISE;
            END IF;
    END;
BEGIN
    -- UNIQUE constraint en (org, col) trata varios NULL como duplicado al validar.
    -- Indice funcional: solo indexa filas con valor, varios clientes sin CI/correo conviven.
    add_idx(q'[
        CREATE UNIQUE INDEX uq_customer_document
          ON customer (
            CASE WHEN document_number IS NOT NULL THEN org_id_organization END,
            document_number
          )
    ]');
    add_idx(q'[
        CREATE UNIQUE INDEX uq_customer_email
          ON customer (
            CASE WHEN email IS NOT NULL THEN org_id_organization END,
            email
          )
    ]');
END;
/

PROMPT === 20260912_customer_create_fields: OK ===

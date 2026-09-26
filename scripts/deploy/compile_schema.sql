-- Recompila lo invalido del esquema conectado y lista lo que quede (esperado: nada).
EXEC DBMS_UTILITY.compile_schema(USER, compile_all => FALSE);

PROMPT === Objetos INVALID (esperado: ninguno)
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID' ORDER BY 1, 2;

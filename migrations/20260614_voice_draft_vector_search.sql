PROMPT === Cita rapida por voz: resolucion vectorial (Fase 3) ===
@@../packages/PKG_AOX_IA_MANAGER.pls

BEGIN
  DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT Verificacion:
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name = 'PKG_AOX_IA_MANAGER'
 ORDER BY object_type;

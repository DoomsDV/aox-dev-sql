PROMPT === Fase 5: observabilidad y umbrales vector search ===

PROMPT === 1) Parametros de tuning (app_parameter) ===

MERGE INTO app_parameter t
USING (
    SELECT 'VECTOR_SEARCH_AUTO_SCORE' AS param_key, '0.82' AS param_value,
           'Score minimo para auto-asignar entidad en cita por voz (0-1).' AS description
      FROM dual
) s ON (t.param_key = s.param_key)
WHEN MATCHED THEN UPDATE SET t.param_value = s.param_value, t.description = s.description
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description) VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT 'VECTOR_SEARCH_GAP_SCORE' AS param_key, '0.05' AS param_value,
           'Gap minimo entre top-1 y top-2 para auto-asignar (0-1).' AS description
      FROM dual
) s ON (t.param_key = s.param_key)
WHEN MATCHED THEN UPDATE SET t.param_value = s.param_value, t.description = s.description
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description) VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT 'VECTOR_SEARCH_MIN_SCORE' AS param_key, '0.55' AS param_value,
           'Score minimo para incluir candidato en el draft (0-1).' AS description
      FROM dual
) s ON (t.param_key = s.param_key)
WHEN MATCHED THEN UPDATE SET t.param_value = s.param_value, t.description = s.description
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description) VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT 'VECTOR_SEARCH_TOP_K' AS param_key, '5' AS param_value,
           'Cantidad de resultados vectoriales por entidad (1-20).' AS description
      FROM dual
) s ON (t.param_key = s.param_key)
WHEN MATCHED THEN UPDATE SET t.param_value = s.param_value, t.description = s.description
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description) VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT === 2) Indice para metricas en aox_ai_log ===

BEGIN
    EXECUTE IMMEDIATE '
        CREATE INDEX idx_aox_ai_log_process_created
            ON aox_ai_log (process_name, SYS_EXTRACT_UTC(created_at))
    ';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE NOT IN (-955, -1408) THEN
            RAISE;
        END IF;
END;
/

PROMPT === 3) Paquetes ===
@@../packages/PKG_AOX_VECTOR_SEARCH.pls
@@../packages/PKG_AOX_IA_MANAGER.pls
@@../packages/PKG_AOX_IA_API.pls

BEGIN
    DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/

PROMPT === Verificacion ===
SELECT param_key, param_value
  FROM app_parameter
 WHERE param_key LIKE 'VECTOR_SEARCH%'
 ORDER BY param_key;

SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('PKG_AOX_IA_MANAGER', 'PKG_AOX_IA_API', 'PKG_AOX_VECTOR_SEARCH')
 ORDER BY object_type, object_name;

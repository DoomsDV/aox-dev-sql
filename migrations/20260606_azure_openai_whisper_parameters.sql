PROMPT === Parametros Azure OpenAI Whisper (Cita rapida por voz) ===
PROMPT Reemplaza YOUR_WHISPER_API_KEY con la Key 1 o Key 2 del recurso danv-mpisuuzv-eastus2 en Azure Portal.

MERGE INTO app_parameter t
USING (
    SELECT
        'AZURE_OPENAI_WHISPER_ENDPOINT' AS param_key,
        'https://danv-mpisuuzv-eastus2.cognitiveservices.azure.com' AS param_value,
        'URI base del recurso Azure (sin /openai/deployments/...).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT
        'AZURE_OPENAI_WHISPER_DEPLOYMENT' AS param_key,
        'whisper' AS param_value,
        'Nombre de la implementacion Whisper en Azure OpenAI.' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT
        'AZURE_OPENAI_WHISPER_API_VERSION' AS param_key,
        '2024-06-01' AS param_value,
        'Version API para Whisper (transcriptions).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

MERGE INTO app_parameter t
USING (
    SELECT
        'AZURE_OPENAI_WHISPER_API_KEY' AS param_key,
        'YOUR_WHISPER_API_KEY' AS param_value,
        'API Key del recurso Whisper (Key 1 o Key 2 del portal Azure).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN
    UPDATE SET
        t.param_value = s.param_value,
        t.description = s.description
WHEN NOT MATCHED THEN
    INSERT (param_key, param_value, description)
    VALUES (s.param_key, s.param_value, s.description);

COMMIT;

PROMPT Verificacion:
SELECT param_key, param_value, description
  FROM app_parameter
 WHERE param_key LIKE 'AZURE_OPENAI%'
 ORDER BY param_key;

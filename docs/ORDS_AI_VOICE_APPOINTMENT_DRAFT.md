# ORDS — Cita rápida por voz

Contrato consumido por `bookmate/src/lib/appointment-ai.ts`.

## Endpoint

| Método | Ruta ORDS | Handler |
|--------|-----------|---------|
| POST | `/ai/appointments/voice-draft` | `PKG_AOX_IA_API.PR_PARSE_VOICE_APPOINTMENT_DRAFT` |

Variable Astro: `ORDS_AI_VOICE_APPOINTMENT_DRAFT`

Ejemplo:

`https://<adb-host>/ords/aoxdev/ai/appointments/voice-draft`

## Request

Headers:

- `Authorization: Bearer <jwt>`
- `Content-Type: application/json`

Body JSON:

```json
{
  "audio_base64": "<base64 del .webm>",
  "mime_type": "audio/webm",
  "filename": "cita.webm"
}
```

## Response 200

```json
{
  "status": "success",
  "data": {
    "transcript": "Cita mañana a las 10 con Juan Pérez",
    "draft": {
      "customer_name": "Juan Pérez",
      "customer_phone": "981123456",
      "pro_id_professional": 12,
      "loc_id_location": 3,
      "ser_id_service": 5,
      "start_time": "2026-04-18T10:00:00-03:00",
      "end_time": "2026-04-18T10:30:00-03:00",
      "confidence": "medium",
      "missing_fields": []
    }
  }
}
```

## Handler ORDS (PL/SQL)

Mismo módulo `/ai/` que `chat/message` y `dashboard/ai-summary`.

```sql
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
    v_body_clob     CLOB;
    v_dest_offset   INTEGER := 1;
    v_src_offset    INTEGER := 1;
    v_lang_context  INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    v_warning       INTEGER;
BEGIN
    IF :body IS NOT NULL THEN
        DBMS_LOB.CREATETEMPORARY(v_body_clob, TRUE);
        DBMS_LOB.CONVERTTOCLOB(
            dest_lob     => v_body_clob,
            src_blob     => :body,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => v_dest_offset,
            src_offset   => v_src_offset,
            blob_csid    => DBMS_LOB.DEFAULT_CSID,
            lang_context => v_lang_context,
            warning      => v_warning
        );
    END IF;

    pkg_aox_ia_api.pr_parse_voice_appointment_draft(
        pi_auth_header   => owa_util.get_cgi_env('HTTP_AUTHORIZATION'),
        pi_body          => v_body_clob,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );

    :status_code := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    htp.prn(v_response_body);
END;
```

Notas:

- ORDS entrega `:body` como **BLOB**; conviene convertir a **CLOB** antes de llamar al API package (audios base64 pueden ser grandes).
- Si aparece `PLS-00306` al llamar al procedimiento, el **package body no está desplegado** o quedó inválido tras actualizar solo el spec.

## Despliegue SQL (orden)

```sql
@packages/PKG_AOX_IA_MANAGER.pls
@packages/PKG_AOX_IA_API.pls
@migrations/20260606_azure_openai_whisper_parameters.sql

BEGIN
  DBMS_UTILITY.compile_schema(schema => USER, compile_all => FALSE);
END;
/
```

Verificar:

```sql
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('PKG_AOX_IA_MANAGER', 'PKG_AOX_IA_API')
 ORDER BY object_type, object_name;

SELECT line, position, text
  FROM user_errors
 WHERE name IN ('PKG_AOX_IA_MANAGER', 'PKG_AOX_IA_API')
 ORDER BY name, type, sequence;
```

Debe quedar **VALID** y sin filas en `user_errors`.

## Parámetros `app_parameter`

Whisper (oído):

- `AZURE_OPENAI_WHISPER_ENDPOINT`
- `AZURE_OPENAI_WHISPER_API_KEY`
- `AZURE_OPENAI_WHISPER_API_VERSION` (ej. `2024-06-01`)
- `AZURE_OPENAI_WHISPER_DEPLOYMENT` (ej. `whisper`)

GPT (cerebro) — mismos del resumen IA:

- `AZURE_OPENAI_ENDPOINT`
- `AZURE_OPENAI_API_KEY`
- `AZURE_OPENAI_API_VERSION`
- `AZURE_OPENAI_DEPLOYMENT`

## ACL de red

Permitir salida HTTPS hacia el host de Azure OpenAI / Cognitive Services usado por Whisper y GPT.

## Errores frecuentes

| Síntoma | Causa probable |
|---------|----------------|
| `The request could not be processed for a user defined resource` + `PLS-00306` | Package body sin `PR_PARSE_VOICE_APPOINTMENT_DRAFT` o inválido |
| `PLS-00302: component ... must be declared` | Falta compilar `PKG_AOX_IA_MANAGER` / `PKG_AOX_IA_API` |
| `Faltan parametros Azure OpenAI para Whisper` | Migración Whisper sin ejecutar o key vacía |
| `No se detecto voz en la grabacion` | Audio vacío, muy corto o ruido |

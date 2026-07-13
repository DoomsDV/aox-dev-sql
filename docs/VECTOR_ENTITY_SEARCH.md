# Búsqueda vectorial por organización (Fase 1)

Embeddings en Oracle Autonomous 26ai / 23ai+ para resolver entidades de la org en **cita rápida por voz**.

## Componentes

| Artefacto | Descripción |
|-----------|-------------|
| `tables/ORG_ENTITY_EMBEDDING.sql` | Tabla + índices |
| `migrations/20260613_org_entity_embedding.sql` | Migración idempotente + parámetros + paquete |
| `packages/PKG_AOX_VECTOR_SEARCH.pls` | Embed, sync, búsqueda top-k |

## Tabla `org_entity_embedding`

| Columna | Tipo | Notas |
|---------|------|-------|
| `org_id_organization` | NUMBER | Filtro multi-tenant |
| `entity_type` | VARCHAR2 | `CUSTOMER`, `PROFESSIONAL`, `SERVICE`, `LOCATION` |
| `entity_id` | NUMBER | PK de la entidad |
| `source_text` | VARCHAR2(1000) | Texto embedido |
| `embedding` | `VECTOR(1536, FLOAT32)` | Azure `text-embedding-3-small` |

## Parámetros `app_parameter`

| Clave | Uso |
|-------|-----|
| `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | ej. `text-embedding-3-small` |
| `AZURE_OPENAI_EMBEDDING_API_VERSION` | ej. `2024-02-01` |
| `AZURE_OPENAI_EMBEDDING_DIMENSIONS` | `1536` (debe coincidir con la columna) |
| `AZURE_OPENAI_ENDPOINT` | Reutilizado |
| `AZURE_OPENAI_API_KEY` | Reutilizado |

## Despliegue

```sql
@migrations/20260613_org_entity_embedding.sql
```

Verificar:

```sql
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name IN ('PKG_AOX_VECTOR_SEARCH')
 ORDER BY object_type;

SELECT COUNT(*) FROM org_entity_embedding;
```

## Backfill por organización

```sql
BEGIN
  pkg_aox_vector_search.pr_sync_org_embeddings(pi_org_id => :org_id);
  COMMIT;
END;
/
```

Sync de una entidad:

```sql
BEGIN
  pkg_aox_vector_search.pr_sync_entity_embedding(
    pi_org_id      => 1,
    pi_entity_type => 'CUSTOMER',
    pi_entity_id   => 42
  );
  COMMIT;
END;
/
```

## Búsqueda top-k (prueba)

```sql
SELECT pkg_aox_vector_search.fn_search_top_k(
         pi_org_id      => 1,
         pi_entity_type => 'CUSTOMER',
         pi_query_text  => 'Juan Perez',
         pi_top_k       => 5
       ) AS candidates
  FROM dual;
```

Respuesta JSON:

```json
[
  {
    "entity_type": "CUSTOMER",
    "entity_id": 42,
    "source_text": "Juan Pérez | tel: 981123456",
    "label": "Juan Pérez | tel: 981123456",
    "distance": 0.08,
    "score": 0.92
  }
]
```

## Texto indexado por entidad

| Tipo | `source_text` |
|------|----------------|
| CUSTOMER | `{full_name} \| tel: {phone}` |
| PROFESSIONAL | `{display_name}` + especialidad |
| SERVICE | `{name} \| duracion: {min} min` |
| LOCATION | `{name} \| {address}` |

Profesionales usan **`professional.display_name`** (identidad por org).

## ACL de red

Permitir HTTPS hacia el host Azure OpenAI (mismo que chat/Whisper).

## Fase 2 — Reindex automático

| Artefacto | Descripción |
|-----------|-------------|
| `triggers/TRG_VECTOR_EMBEDDING_SYNC.sql` | Triggers en `customer`, `professional`, `service`, `location` |
| `migrations/20260615_vector_embedding_auto_sync.sql` | Triggers + job nocturno |
| Job `HASEL_SYNC_ORG_EMBEDDINGS` | Diario 03:00 → `pr_sync_all_orgs_embeddings` |

Despliegue:

```sql
@migrations/20260615_vector_embedding_auto_sync.sql
```

### Triggers (tiempo real)

Tras INSERT/UPDATE de columnas relevantes o DELETE, llaman a `pr_on_entity_embedding_changed`. Los errores de Azure **no bloquean** el DML (se ignoran en el trigger).

| Tabla | Columnas observadas |
|-------|---------------------|
| `customer` | `full_name`, `phone_number` |
| `professional` | `display_name`, `spe_id_specialty`, `is_active`, `usr_id_user` |
| `service` | `name`, `duration_minutes`, `is_active` |
| `location` | `name`, `address`, `is_active` |

### Job nocturno (red de seguridad)

Reindexa **todas las orgs** con `pr_sync_all_orgs_embeddings` (commit por org).

Verificar:

```sql
SELECT trigger_name, table_name, status
  FROM user_triggers
 WHERE trigger_name LIKE 'TRG_%VECTOR_EMBEDDING%';

SELECT job_name, enabled, state, next_run_date
  FROM user_scheduler_jobs
 WHERE job_name = 'HASEL_SYNC_ORG_EMBEDDINGS';
```

Ejecución manual del job:

```sql
BEGIN
  DBMS_SCHEDULER.RUN_JOB('HASEL_SYNC_ORG_EMBEDDINGS');
END;
/
```

## Cita por voz + vector search (Fase 3)

```sql
@migrations/20260614_voice_draft_vector_search.sql
```

Respuesta draft ampliada:

```json
{
  "customer_name": "Juan",
  "id_customer": null,
  "candidates": {
    "customer": [
      { "entity_id": 42, "label": "Juan Pérez | tel: 981123456", "score": 0.91 }
    ]
  }
}
```

## Fase 5 — Observabilidad y tuning

| Artefacto | Descripción |
|-----------|-------------|
| `migrations/20260616_vector_search_observability.sql` | Parámetros + índice + paquetes |
| `aox_ai_log` | Log por cita por voz (`process_name = VOICE_APPOINTMENT_VECTOR_DRAFT`) |
| `app_parameter` | Umbrales ajustables sin redeploy de PL/SQL |

Despliegue:

```sql
@migrations/20260616_vector_search_observability.sql
```

### Parámetros de tuning

| Clave | Default | Uso |
|-------|---------|-----|
| `VECTOR_SEARCH_AUTO_SCORE` | `0.82` | Auto-asignar si top-1 ≥ este score |
| `VECTOR_SEARCH_GAP_SCORE` | `0.05` | Gap mínimo top-1 vs top-2 para auto-asignar |
| `VECTOR_SEARCH_MIN_SCORE` | `0.55` | Score mínimo para mostrar candidatos |
| `VECTOR_SEARCH_TOP_K` | `5` | Resultados vectoriales por búsqueda (1–20) |

Cambio en caliente (sin recompilar):

```sql
UPDATE app_parameter SET param_value = '0.85' WHERE param_key = 'VECTOR_SEARCH_AUTO_SCORE';
COMMIT;
```

### Log por request (`aox_ai_log`)

Cada cita por voz exitosa inserta una fila:

| Columna | Contenido |
|---------|-----------|
| `process_name` | `VOICE_APPOINTMENT_VECTOR_DRAFT` |
| `request_payload` | `{ transcript, gpt_slots }` |
| `response_body` | Draft final JSON |
| `parameters` | `{ thresholds, metrics, resolution_trace }` |

Modos en `resolution_trace[].mode`:

| Modo | Significado |
|------|-------------|
| `AUTO` | Vector top-1 auto-asignado |
| `PHONE_EXACT` | Cliente por teléfono exacto |
| `ROLE_FIXED` | Profesional fijado por rol sesión |
| `CANDIDATES` | Ambigüedad → panel de confirmación |
| `NONE` | Sin resultados útiles |
| `ERROR` | Fallo en búsqueda vectorial |

Errores de sync en triggers → `PKG_AOX_VECTOR_SEARCH.PR_ON_ENTITY_EMBEDDING_CHANGED`.

### Consultas de métricas (últimos 30 días)

Volumen y tasa de auto-resolución:

```sql
SELECT
       COUNT(*) AS total_voice_drafts,
       ROUND(AVG(TO_NUMBER(JSON_VALUE(parameters, '$.metrics.auto_resolved_fields'))), 2) AS avg_auto_fields,
       ROUND(AVG(TO_NUMBER(JSON_VALUE(parameters, '$.metrics.candidate_fields'))), 2) AS avg_candidate_fields,
       ROUND(AVG(TO_NUMBER(JSON_VALUE(parameters, '$.metrics.unresolved_fields'))), 2) AS avg_unresolved_fields
  FROM aox_ai_log
 WHERE process_name = 'VOICE_APPOINTMENT_VECTOR_DRAFT'
   AND status = 'SUCCESS'
   AND created_at >= SYSTIMESTAMP - INTERVAL '30' DAY;
```

Por organización:

```sql
SELECT org_id,
       COUNT(*) AS drafts,
       SUM(CASE WHEN TO_NUMBER(JSON_VALUE(parameters, '$.metrics.candidate_fields')) > 0 THEN 1 ELSE 0 END) AS with_candidates,
       ROUND(100 * SUM(CASE WHEN TO_NUMBER(JSON_VALUE(parameters, '$.metrics.candidate_fields')) > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_needs_confirmation
  FROM aox_ai_log
 WHERE process_name = 'VOICE_APPOINTMENT_VECTOR_DRAFT'
   AND status = 'SUCCESS'
   AND created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
 GROUP BY org_id
 ORDER BY drafts DESC;
```

Últimos traces (debug):

```sql
SELECT created_at, org_id, user_id,
       JSON_QUERY(parameters, '$.resolution_trace') AS trace,
       JSON_VALUE(response_body, '$.confidence') AS confidence
  FROM aox_ai_log
 WHERE process_name = 'VOICE_APPOINTMENT_VECTOR_DRAFT'
 ORDER BY created_at DESC
 FETCH FIRST 20 ROWS ONLY;
```

Errores de reindex en triggers:

```sql
SELECT created_at, org_id, error_message, parameters
  FROM aox_ai_log
 WHERE process_name = 'PKG_AOX_VECTOR_SEARCH.PR_ON_ENTITY_EMBEDDING_CHANGED'
   AND status = 'ERROR'
 ORDER BY created_at DESC
 FETCH FIRST 50 ROWS ONLY;
```

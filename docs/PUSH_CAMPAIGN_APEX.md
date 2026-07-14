# Push Campaign — cablear desde APEX (Hasel_admn)

Canal paralelo de campañas/avisos push a `platform_user` (admins/profesionales). **No** reemplaza ni modifica las notificaciones fijas de `PKG_AOX_FCM_API` (citas, digest, etc.).

## Objetos

| Objeto | Uso |
|--------|-----|
| `PUSH_VAR_CATALOG` | Variables de sistema del título (`NOMBRE`, `APELLIDO`, `EMAIL`) |
| `PUSH_CAMPAIGN` | Campaña |
| `PUSH_CAMPAIGN_VAR` | Variables custom del body (clave/valor) |
| `PUSH_CAMPAIGN_DELIVERY` | Resultado por dispositivo |
| `PKG_AOX_PUSH_CAMPAIGN` | CRUD + job Scheduler + envío |

## Audiencia

| `audience_type` | `role_id` | Destinatarios |
|-----------------|-----------|---------------|
| `ALL_ACTIVE` | `NULL` | `platform_user` activos con membresía activa (cualquier rol) y token FCM |
| `ROLE` | `id_role` | Mismos con `org_member.rol_id_role = role_id` |

LOV roles: `SELECT id_role, name FROM role WHERE is_active = 1 ORDER BY name`.

## Estados

`DRAFT` → `SCHEDULED` → `SENDING` → `SENT` | `ERROR`  
También: `DISABLED`, `CANCELLED`.

Programación: un job `DBMS_SCHEDULER` one-shot `HASEL_PUSH_CAMP_<id>` con `start_date = send_at`.

## Variables

- **Título:** solo catálogo `{{NOMBRE}}`, `{{APELLIDO}}`, `{{EMAIL}}`.
- **Body / URL:** catálogo + custom de la campaña.
- Custom JSON: `[{"key":"FECHA_CORTE","value":"20/07/2026"}]` (keys se guardan en UPPER).

## Process APEX — crear

```sql
DECLARE
    l_id NUMBER;
BEGIN
    pkg_aox_push_campaign.pr_create_campaign(
        pi_name           => :PXX_NAME,
        pi_title_template => :PXX_TITLE,
        pi_body_template  => :PXX_BODY,
        pi_url_template   => :PXX_URL,          -- opcional
        pi_audience_type  => :PXX_AUDIENCE,     -- ALL_ACTIVE | ROLE
        pi_role_id        => :PXX_ROLE_ID,      -- null si ALL_ACTIVE
        pi_send_at        => :PXX_SEND_AT,      -- TIMESTAMP WITH TIME ZONE
        pi_send_now       => NVL(:PXX_SEND_NOW, 0), -- 1 = enviar ya
        pi_vars_json      => :PXX_VARS_JSON,    -- CLOB JSON array
        pi_created_by     => :APP_USER,
        po_campaign_id    => l_id
    );
    :PXX_ID_CAMPAIGN := l_id;
END;
```

## Process — actualizar

```sql
BEGIN
    pkg_aox_push_campaign.pr_update_campaign(
        pi_campaign_id    => :PXX_ID_CAMPAIGN,
        pi_name           => :PXX_NAME,
        pi_title_template => :PXX_TITLE,
        pi_body_template  => :PXX_BODY,
        pi_url_template   => :PXX_URL,
        pi_audience_type  => :PXX_AUDIENCE,
        pi_role_id        => :PXX_ROLE_ID,
        pi_send_at        => :PXX_SEND_AT,
        pi_schedule       => NVL(:PXX_SCHEDULE, 0), -- 1 = crear/recrear job
        pi_vars_json      => :PXX_VARS_JSON
    );
END;
```

No se puede editar si `status` es `SENDING` o `SENT`.

## Otras acciones

| Acción | Llamada |
|--------|---------|
| Deshabilitar | `pr_set_enabled(id, 0)` |
| Rehabilitar (+ job si `send_at` futuro) | `pr_set_enabled(id, 1)` |
| Cancelar | `pr_cancel_campaign(id)` |
| Eliminar | `pr_delete_campaign(id)` (bloqueado si `SENDING`) |
| Solo vars | `pr_replace_campaign_vars(id, json)` |
| Enviar ahora | `pr_send_now(id)` |

## Interactive Reports (SQL sugerido)

Campañas:

```sql
SELECT c.id_campaign,
       c.name,
       c.audience_type,
       r.name AS role_name,
       c.send_at,
       c.status,
       c.is_enabled,
       c.sent_at,
       c.error_message,
       c.created_at
  FROM push_campaign c
  LEFT JOIN role r ON r.id_role = c.role_id
 ORDER BY c.created_at DESC
```

Catálogo:

```sql
SELECT var_key, label_es, sample_value
  FROM push_var_catalog
 WHERE is_active = 1
 ORDER BY sort_order
```

Entregas:

```sql
SELECT d.id_delivery,
       d.platform_user_id,
       pu.email,
       d.status,
       d.resolved_title,
       d.error_message,
       d.sent_at
  FROM push_campaign_delivery d
  JOIN platform_user pu ON pu.id_platform_user = d.platform_user_id
 WHERE d.id_campaign = :PXX_ID_CAMPAIGN
 ORDER BY d.sent_at DESC NULLS LAST
```

## Requisitos

- Parámetros `FCM_PUSH_SERVICE_URL` y `FCM_PUSH_SERVICE_BEARER` (los mismos que usa `pr_send_push`).
- Privilegio `CREATE JOB` / uso de `DBMS_SCHEDULER` en el schema (Autonomous: normalmente disponible al owner).

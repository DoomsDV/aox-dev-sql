# Configuración de sistema (workspace)

## Tablas de referencia

| Tabla | Valores |
|-------|---------|
| `ref_booking_slot_interval` | 15, 30, 45, 60 minutos |
| `ref_reminder_hours` | 2, 6, 12, 24, 48, 72 horas |
| `ref_cancel_wait_hours` | 1, 2, 3, 4, 6, 12 horas |

## Columnas en `workspace_setting`

- `rsi_id_slot_interval` → FK `ref_booking_slot_interval`
- `rh_id_reminder_hours` → FK `ref_reminder_hours`
- `cwh_id_cancel_wait_hours` → FK `ref_cancel_wait_hours` (NULL si `unanswered_alert_action = KEEP`)

## Regla de negocio

`reminder_hours > cancel_wait_hours` (validado en frontend y en `PKG_AOX_WORKSPACE_API.pr_validate_system_timing`).

## Migración en BD existente

Ejecutar:

```sql
@migrations/workspace_system_settings_alter.sql
```

## ORDS

Sin cambios de ruta: `GET/PUT /workspace` devuelve/acepta los nuevos campos y `catalogs` en el JSON.

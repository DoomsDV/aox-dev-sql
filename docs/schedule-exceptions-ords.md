# ORDS — Excepciones de horario

Registrar estos endpoints en el modulo REST de profesionales (mismo esquema que `GET/PUT .../schedule`).

| Metodo | Ruta | Procedimiento |
|--------|------|----------------|
| GET | `professionals/:id/schedule-exceptions?from=&to=` | `pkg_aox_schedule_exception_api.pr_list_schedule_exceptions` |
| GET | `professionals/:id/schedule-exceptions/:date` | `pkg_aox_schedule_exception_api.pr_get_schedule_exception` |
| PUT | `professionals/:id/schedule-exceptions/:date` | `pkg_aox_schedule_exception_api.pr_upsert_schedule_exception` |
| DELETE | `professionals/:id/schedule-exceptions/:date` | `pkg_aox_schedule_exception_api.pr_delete_schedule_exception` |

Parametros ORDS sugeridos:

- `id` → `pi_prof_id`
- `date` → `pi_exception_date`
- `from` / `to` → query bind en listado
- Body PUT → `pi_body`
- `Authorization` header → `pi_auth_header`

Despliegue SQL (como `WKSP_AOX`):

```sql
@tables/PROFESSIONAL_SCHEDULE_EXCEPTION.sql
@tables/PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT.sql
@packages/PKG_AOX_SCHEDULE_EXCEPTION_API.pls
-- Recompilar PKG_AOX_UTIL y PKG_AOX_PUBLIC_BOOKING_API si ya estaban desplegados
```

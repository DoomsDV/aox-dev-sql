# Contrato de códigos de error API (ORDS / Bookmate)

Respuestas de error JSON estándar:

```json
{
  "status": "error",
  "code": "SESSION_EXPIRED",
  "message": "Token inválido o expirado."
}
```

## Códigos

| `code` | HTTP habitual | Significado | Acción en panel (fetch guard) |
|--------|---------------|-------------|-------------------------------|
| `SESSION_EXPIRED` | 401 | JWT ausente, inválido o expirado | Alerta sesión → logout → login |
| `ORG_ACCESS_INACTIVE` | 401 | Usuario/org/profesional desactivado | Alerta acceso → logout → login |
| `FORBIDDEN` | 403 | Sin permiso para la operación | Error inline; **no** cerrar sesión |
| `INVALID_CREDENTIALS` | 401 | Login con credenciales incorrectas | Solo en `/api/auth/login` |
| `VALIDATION_ERROR` | 400 | Datos inválidos | Mostrar error de formulario |
| `NOT_FOUND` | 404 | Recurso inexistente | Error contextual |
| `CONFLICT` | 409 | Conflicto de negocio | Error contextual |
| `INTERNAL_ERROR` | 500 | Error no controlado | Error genérico |

## SQLCODE en PL/SQL (`PKG_AOX_UTIL`)

| Constante | Valor | Uso |
|-----------|-------|-----|
| `c_sqlcode_session` | -20001 | Token / JWT / sesión |
| `c_sqlcode_validation` | -20002 | Validación de entrada |
| `c_sqlcode_forbidden` | -20011 | Permisos de negocio |

Procedimientos centralizados:

- `pr_resolve_api_error` — mapea SQLCODE + mensaje → HTTP + `code`
- `pr_build_api_error_response` — arma el CLOB JSON
- `pr_handle_api_exception` — atajo para bloques `WHEN OTHERS`

## Despliegue — orden de recompilación

Ver lista completa en [DEPLOY_PRODUCTION_CHECKLIST.md](./DEPLOY_PRODUCTION_CHECKLIST.md) Fase 4. Resumen:

1. `PKG_AOX_UTIL` (obligatorio primero)
2. `PKG_AOX_JWT`, `PKG_AOX_AUTH`, `PKG_AOX_BUCKET`, `PKG_AOX_META_API`, `PKG_AOX_FCM_API`
3. `PKG_AOX_AUTH_API`, `PKG_AOX_CATALOG_API`, catálogos de dominio
4. APIs de negocio (professional, appointment, schedule, etc.)
5. IA: `PKG_AOX_AI_CONTEXT` → `PKG_AOX_AI_TOOLS` → `PKG_AOX_IA_MANAGER` → `PKG_AOX_IA_API` / `PKG_AOX_CHAT_MANAGER` → `PKG_AOX_CHAT_API`
6. Públicos: `PKG_AOX_PUBLIC_BOOKING_API`, `PKG_AOX_PAGOPAR_API`
7. `ALTER PACKAGE ... COMPILE` o `UTL_RECOMP.RECOMP_PARALLEL` al final

## Frontend

- `bookmate/src/lib/api-error-codes.ts` — constantes
- `bookmate/src/lib/session-auth-messages.ts` — clasificación (prioriza `code`)
- `bookmate/src/lib/session-fetch-guard.ts` — alertas de sesión

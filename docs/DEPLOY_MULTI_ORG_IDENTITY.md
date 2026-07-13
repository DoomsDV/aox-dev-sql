# Deploy: Identidad multi-organización (`platform_user` + `org_member`)

> **Checklist completo de producción (orden global, Pagopar, invitaciones, QA):**  
> [DEPLOY_PRODUCTION_CHECKLIST.md](./DEPLOY_PRODUCTION_CHECKLIST.md)

## Modelo

| Tabla | Rol |
|-------|-----|
| `platform_user` | Identidad global: email único, contraseña, nombre, verificación |
| `org_member` | Membresía en una org con rol (`id_org_member` = antiguo `app_user.id_user`) |
| `professional` | `usr_id_user` → `org_member.id_org_member` (sin cambio de IDs) |

**JWT / frontend:** `user_id` sigue siendo `id_org_member`. No requiere cambios en Astro.

## Orden de despliegue (base existente)

### 1) Recompilar paquetes (antes de la migración SQL)

```text
packages/PKG_AOX_AUTH_API.pls
packages/PKG_AOX_JWT.pls
packages/PKG_AOX_AUTH.pls
packages/PKG_AOX_PROFESSIONAL_API.pls
packages/PKG_AOX_USER_API.pls
```

Los demás paquetes que solo hacen `JOIN app_user` siguen funcionando vía **vista** `app_user`.

### 2) Ejecutar migración de datos

Desde SQL*Plus/SQLcl conectado al esquema de la app:

```sql
@migrations/20260528_multi_org_identity.sql
```

Ese script:

1. Valida que no haya correos duplicados ni profesionales huérfanos.
2. Crea `platform_user` y `org_member` (si no existen).
3. Copia datos preservando **`id_org_member = app_user.id_user`**.
4. Reapunta FKs (`professional`, sesiones, verificación, etc.).
5. Renombra tabla `app_user` → `app_user_legacy`.
6. Crea vista `app_user` de compatibilidad.
7. Actualiza trigger de slug de `professional`.

### 3) Recompilar paquetes (después)

Recompilar los mismos paquetes del paso 1 y cualquier paquete inválido.

### 4) ORDS: endpoints de auth multi-org

Registrar en el módulo de auth (mismo prefijo que login):

- `POST /auth/select-organization` → `PKG_AOX_AUTH_API.PR_SELECT_ORGANIZATION`
- `POST /auth/create-organization` → `PKG_AOX_AUTH_API.PR_CREATE_ORGANIZATION` (requiere `Authorization: Bearer`, crea org + membresía ADMIN para el `platform_user` autenticado)

Variables Astro (opcional):

- `ORDS_AUTH_SELECT_ORG_URL` → por defecto `/auth/select-organization`
- `ORDS_AUTH_CREATE_ORGANIZATION_URL` → por defecto `/auth/create-organization`

### 4b) Frontend: crear organización (cuenta existente)

- Registro público: enlace **«¿Ya tienes una cuenta? Crea tu organización»** → login con `redirectTo=/auth/create-organization`.
- Tras login con varias membresías: va **directo** a `/auth/create-organization` (cookie `selection_token`, sin pantalla `select-org`).
- `POST /auth/create-organization` acepta Bearer de sesión **o** `selection_token` (`org_selection=1`) para identificar al `platform_user`.
- Tras crear: `POST /api/organization/create` → sesión JWT de la **nueva** org → `/panel/dashboard`.

### 4d) Frontend: invitación con cuenta multi-org

- Login con `redirectTo=/auth/accept-invite?token=...` y `selection_required`: va **directo** a accept-invite (sin `select-org`).
- Cookie `org_selection_ctx` guarda el `selection_token` y el `redirectTo` con el token de invitación.
- `/auth/accept-invite` acepta la invitación en servidor con `selection_token` → sesión de la **org invitada** → panel.
- `POST /auth/accept-invitation` (ORDS) acepta Bearer de sesión **o** `selection_token` para verificar al `platform_user` invitado.

### 5) Selector de organización (frontend)

Si el usuario tiene **más de una** membresía activa:

1. Login valida credenciales y devuelve `selection_required: 1` + lista de orgs + `selection_token` (JWT corto, 10 min).
2. Astro redirige a `/auth/select-org`.
3. El usuario elige org → `POST /api/auth/select-org` → emite JWT normal.

Con **una sola** org (Daniel, Alex, Max hoy): entra directo al panel, sin pantalla extra.

### 6) Pruebas mínimas

- Login admin y un empleado con citas.
- Calendario: citas visibles.
- Alta de personal nuevo.
- Refresh token (cerrar sesión / volver a entrar).
- (Opcional) Segunda membresía de prueba: mismo email en otra org → debe aparecer selector.
- Usuario con cuenta existente: login → `/auth/create-organization` (aunque tenga 2+ orgs) → crea segunda org propia y entra al panel de la nueva.
- Usuario con 2+ orgs: enlace de invitación → login → accept-invite (sin elegir org previa) → panel de la org invitada.
- Con sesión activa: clic en el nombre de la org (sidebar) → modal → `POST /auth/switch-organization` (ORDS) vía `/api/session/switch-organization`.

### 4c) ORDS: conmutador de organización en panel

- `POST /auth/my-organizations` → `PKG_AOX_AUTH_API.PR_LIST_MY_ORGANIZATIONS` (Bearer)
- `POST /auth/switch-organization` → `PKG_AOX_AUTH_API.PR_SWITCH_ORGANIZATION` (Bearer + `org_member_id`)

Variables Astro (opcional):

- `ORDS_AUTH_MY_ORGANIZATIONS_URL` → `/auth/my-organizations`
- `ORDS_AUTH_SWITCH_ORGANIZATION_URL` → `/auth/switch-organization`

## Verificación SQL

```sql
SELECT COUNT(*) AS app_user_legacy FROM app_user_legacy;
SELECT COUNT(*) AS org_member FROM org_member;
SELECT COUNT(*) AS platform_user FROM platform_user;

SELECT COUNT(*) AS huerfanos_pro
  FROM professional p
  LEFT JOIN org_member m ON m.id_org_member = p.usr_id_user
 WHERE m.id_org_member IS NULL;
-- Debe ser 0
```

## Rollback (solo emergencia)

No hay rollback automático. Restaurar desde backup de BD tomado **antes** del paso 2.

## Instalación greenfield

`install_all.sql` ya usa `PLATFORM_USER.sql` + `ORG_MEMBER.sql` en lugar de `APP_USER.sql`.

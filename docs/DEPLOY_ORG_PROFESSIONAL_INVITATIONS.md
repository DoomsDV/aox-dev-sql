# Deploy: Invitaciones de personal a organización

> **Checklist maestro de producción:** [DEPLOY_PRODUCTION_CHECKLIST.md](./DEPLOY_PRODUCTION_CHECKLIST.md)

## Resumen

El alta de personal desde el panel **ya no crea** `platform_user` ni contraseña. En su lugar:

1. Crea `professional` pendiente (`usr_id_user` NULL).
2. Registra `org_invitation` con token.
3. Envía correo con template APEX `ACCEPTINVITE` vía `apex_mail.send` (HTML + asunto con `#ORG_NAME#`).
4. El invitado acepta en `/auth/accept-invite?token=...` (nueva cuenta o login si ya existe).

## Orden en producción

### 1) Backup de base de datos

### 2) Recompilar paquetes (antes de la migración)

```text
packages/PKG_AOX_AUTH_API.pls
packages/PKG_AOX_PROFESSIONAL_API.pls
```

### 3) Ejecutar migración SQL

```sql
@migrations/20260529_org_professional_invitations.sql
```

Incluye:

- Tabla `org_invitation`
- `professional.usr_id_user` nullable
- Trigger `trg_professional_slug` actualizado

### 4) Recompilar paquetes (después)

Los mismos del paso 2.

### 5) ORDS — endpoints nuevos (módulo auth)

| Método | Ruta | Procedimiento |
|--------|------|----------------|
| POST | `/auth/invitation` | `PKG_AOX_AUTH_API.PR_GET_INVITATION` |
| POST | `/auth/accept-invitation` | `PKG_AOX_AUTH_API.PR_ACCEPT_INVITATION` |

El alta de personal sigue en `POST /professionals` → `PKG_AOX_PROFESSIONAL_API.PR_CREATE_PROF_AND_USER` (ahora envía invitación).

### 6) Parámetro opcional de aplicación

En `fn_get_parameter` (o tabla de parámetros APEX):

| Clave | Uso |
|-------|-----|
| `APP_PUBLIC_BASE_URL` | Base del frontend para enlaces del mail (ej. `https://staging.hasel.app`) |
| `MAIL_FROM_ADDRESS` | Remitente (ya usado en otros mails) |

**Template APEX `ACCEPTINVITE`** (Static ID `ACCEPTINVITE`): HTML de referencia en `templates/ACCEPTINVITE.html`. Placeholders JSON en `pr_send_invitation_email`:

| Placeholder | Origen |
|-------------|--------|
| `#ORG_NAME#` | Nombre de la organización |
| `#INVITE_URL#` | URL `/auth/accept-invite?token=...` |
| `#EXPIRES_AT#` | Fecha de vencimiento formateada |

Saludo genérico en el cuerpo (sin nombre del invitado). El usuario completa su identidad al aceptar.

**Templates APEX de referencia** en `aox-dev/templates/`:

| Static ID | Archivo | Placeholders |
|-----------|---------|--------------|
| `ACCEPTINVITE` | `ACCEPTINVITE.html` | `#ORG_NAME#`, `#INVITE_URL#`, `#EXPIRES_AT#` |
| `VERIFICATIONCODE` | `VERIFICATIONCODE.html` | `#NOMBRE#`, `#CODIGO#` |

**Migración `20260612_professional_display_name.sql`:** columnas `display_name` en `professional` y `org_invitation`; elimina `invite_first_name` / `invite_last_name`.

Asunto del template: `Invitación para unirte a #ORG_NAME#`.

### 7) Frontend Astro

Variables opcionales en `.env`:

```env
ORDS_AUTH_GET_INVITATION_URL=.../auth/invitation
ORDS_AUTH_ACCEPT_INVITATION_URL=.../auth/accept-invitation
```

Rutas nuevas:

- `/auth/accept-invite`
- `/api/auth/invitation`
- `/api/auth/accept-invitation`

### 8) Edición de personal activo

El `PUT /professionals/:id` **no permite** cambiar `email`, `apex_user_name` ni `password` cuando el profesional ya tiene cuenta (`usr_id_user` no null). Solo datos de org y nombre en `platform_user`.

### 9) Pruebas sugeridas

1. Admin invita correo nuevo → llega mail → aceptar → crear contraseña → login.
2. Admin invita correo ya registrado → mail → login → aceptación automática o botón tras sesión.
3. Listado panel muestra **Invitación pendiente**.
4. Reinvitar mismo correo pendiente → error 409.
5. Invitar correo que ya es miembro de la org → error 409.

## Archivos tocados

| Área | Archivos |
|------|----------|
| SQL | `tables/ORG_INVITATION.sql`, `migrations/20260529_org_professional_invitations.sql` |
| Oracle | `PKG_AOX_AUTH_API.pls`, `PKG_AOX_PROFESSIONAL_API.pls` |
| Astro | `AcceptInviteForm.astro`, `professionals.astro`, `lib/auth.ts`, `lib/professionals.ts`, APIs auth |

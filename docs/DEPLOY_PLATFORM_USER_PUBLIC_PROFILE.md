# Deploy: Perfil público global (`platform_user`)

Enlace futuro: `https://{dominio}/u/{public_slug}`

## Columnas nuevas en `platform_user`

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `public_slug` | `VARCHAR2(100)` UNIQUE | Slug global del usuario |
| `profile_image_url` | `VARCHAR2(4000)` | URL OCI de la foto personal |
| `profile_image_mime` | `VARCHAR2(100)` | MIME type |
| `profile_image_file_name` | `VARCHAR2(255)` | Nombre del archivo en bucket |

Bucket: `platform_users/{id_platform_user}/{YYYYMMDD_HH24MISS}_{archivo}`

## Orden de despliegue

### 1) Recompilar utilidades (antes del backfill)

```text
packages/PKG_AOX_UTIL.pls
```

### 2) Ejecutar migración SQL

```sql
@migrations/20260601_platform_user_public_profile.sql
```

### 3) Recompilar paquetes

```text
packages/PKG_AOX_BUCKET.pls
packages/PKG_AOX_USER_API.pls
packages/PKG_AOX_AUTH_API.pls
```

### 4) ORDS

Registrar endpoint de sugerencia de slug:

| Método | Ruta | Handler |
|--------|------|---------|
| GET | `/profile/me/public-slug/suggest` | `PKG_AOX_USER_API.PR_SUGGEST_PUBLIC_SLUG` |

Parámetro query: `name` (nombre completo).

Los endpoints existentes `GET/PUT /profile/me` devuelven/aceptan:

```json
{
  "public_profile": {
    "public_slug": "juan-perez",
    "image_url": "https://..."
  }
}
```

Body `PUT /profile/me`:

```json
{
  "first_name": "Juan",
  "last_name": "Pérez",
  "public_slug": "juan-perez",
  "phone_number": "+595981123456",
  "image_base64": "...",
  "image_name": "avatar.jpg",
  "image_mime": "image/jpeg"
}
```

## Frontend (bookmate)

- Ajustes → Mi perfil: foto y enlace personal (`/u/...`).
- La foto del profesional por org solo la edita el admin en Panel → Profesionales.
- Variable opcional: `ORDS_PROFILE_PUBLIC_SLUG_SUGGEST_URL`

## Notas

- El slug se normaliza con `fn_generate_slug` (minúsculas, sin tildes).
- Colisiones: se agrega `-{id_platform_user}` automáticamente.
- Usuarios nuevos reciben `public_slug` al registrarse (AUTH API).

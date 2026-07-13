# ORDS: Perfil público global `/public/user/:public_slug`

Contrato esperado por el frontend (`bookmate/src/lib/public-user-profile.ts`).

## Endpoint

| Método | Ruta ORDS sugerida | Handler sugerido |
|--------|-------------------|------------------|
| GET | `/public/user/:public_slug` | `PKG_AOX_PUBLIC_BOOKING_API.PR_GET_USER_PUBLIC_PROFILE` |

Variable Astro: `ORDS_PUBLIC_USER_PROFILE_URL` (placeholder `:slug`).

Proxy interno: `GET /api/public/user/{slug}`

## Request

- Path param: `public_slug` (valor de `platform_user.public_slug`)

## Response 200

```json
{
  "status": "success",
  "data": {
    "public_slug": "dann-villasanti",
    "full_name": "Dann Villasanti",
    "image_url": "https://.../platform_users/12/20260529_avatar.jpg",
    "locations": [
      {
        "id_location": 3,
        "name": "Sucursal Centro",
        "address": "Av. ...",
        "latitude": -25.28,
        "longitude": -57.63,
        "org_id_organization": 1,
        "organization_name": "Clínica Sonrisas",
        "organization_slug": "clinica-sonrisas",
        "id_professional": 12,
        "services": [
          {
            "id_service": 5,
            "name": "Consulta",
            "duration_minutes": 30,
            "price": 150000,
            "requires_deposit": 1,
            "deposit_type": "PERCENT",
            "deposit_value": 30,
            "deposit_amount": 45000
          }
        ]
      }
    ]
  }
}
```

## Reglas de negocio sugeridas

1. Resolver `platform_user` por `public_slug` (activo).
2. Listar solo sucursales donde el profesional tiene horario (`professional_schedule`) en orgs activas.
3. Por cada sucursal, incluir `id_professional` de esa org para el mismo `platform_user`.
4. Servicios: `professional_service` + `service` activos de esa org/profesional.
5. No incluir especialidad global (varía por org).

## Errores

| Código | Cuándo |
|--------|--------|
| 404 | Slug no encontrado o usuario inactivo |
| 400 | Slug vacío |

## Reserva (sin cambios)

Tras elegir sucursal/servicio, el frontend reutiliza APIs existentes:

- `GET /public/available-slots?pro_id&loc_id&ser_id&target_date`
- `POST /public/appointments` (con `org_id_organization`, `reserve_for_deposit` + SIPAP)
- Comprobante SIPAP vía endpoints de payments/receipt (no Pagopar)

`POST /public/payments` (Pagopar de señas) está **deprecado** (HTTP 410). Ver [DEPLOY_PAGOPAR.md](./DEPLOY_PAGOPAR.md).

No requiere endpoints nuevos para el wizard de reserva.

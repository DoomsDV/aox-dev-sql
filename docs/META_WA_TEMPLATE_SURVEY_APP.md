# Plantilla Meta — encuesta de producto Hasel

Parámetros en **`HASEL_ADMIN.OPS_PARAMETER`** (no en `AOXDEV.APP_PARAMETER`):

| Key | Valor |
|-----|--------|
| `META_WA_TEMPLATE_SURVEY_APP` | `encuesta_satisfaccion_hasel_app_v1` |
| `META_WA_FLOW_SURVEY_APP` | `1845033659995085` (`encuesta_satisfaccion_hasel_flow`) |

El CSAT de citas sigue en AOXDEV: `META_WA_TEMPLATE_SURVEY` / `META_WA_FLOW_SURVEY` (`encuesta_satisfaccion_flow` = `1047139264900441`).

El JSON de diseño del Flow está en `docs/wa-flow-encuesta-app-admin.json`.

Pantalla: `SURVEY_APP`. Payload dinámico:

```json
{
  "heading": "¿Cómo te está yendo con Hasel?",
  "admin_name": "Dann",
  "org_name": "Consultorio General",
  "flow_token": "ENCUESTA_APP_12"
}
```

`flow_token` debe ser `ENCUESTA_APP_{id_delivery}`. No usar el prefijo `ENCUESTA_` del CSAT de citas.

El panel admin lee esos params y los pasa al puente AOXDEV al enviar. Sin plantilla aprobada, el backend hace fallback al Flow interactivo (ventana 24h) usando el Flow ID.

## Envío

Se dispara desde el panel admin (`/encuestas`). Destinatario = teléfono de `professional` del `org_member`.

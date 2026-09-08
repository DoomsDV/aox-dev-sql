# Plantilla Meta — encuesta CSAT (`encuesta_satisfaccion_hasel_v1`)

Parámetro BD: `META_WA_TEMPLATE_SURVEY` = `encuesta_satisfaccion_hasel_v1`  
Flow ID (aoxdev): `META_WA_FLOW_SURVEY` = `1047139264900441` (`encuesta_satisfaccion_flow`)

## Crear en Meta Business Manager

1. **WhatsApp Manager → Plantillas de mensajes → Crear plantilla**
2. **Categoría:** `UTILITY` (no Marketing)
3. **Nombre:** `encuesta_satisfaccion_hasel_v1`
4. **Idioma:** Español (`es`)

### Componentes

| Componente | Tipo | Contenido |
|------------|------|-----------|
| Header | **IMAGE** | Variable `{{1}}` — URL de foto del profesional o logo de la org |
| Body | Texto | `Hola {{1}}, gracias por tu visita con {{2}} por {{3}}. ¿Cómo fue tu experiencia?` |
| Botón | **FLOW** | Texto del botón: `Calificar` → Flow: `encuesta_satisfaccion_flow` |

Variables del body (en orden):

1. Nombre del cliente  
2. Nombre del profesional  
3. Nombre del servicio  

### Flow payload (`flow_action_payload.data`)

El backend envía un **string JSON** con:

```json
{
  "heading": "¿Cómo fue tu experiencia con Dr. X?",
  "professional_name": "Dr. X",
  "flow_token": "ENCUESTA_122"
}
```

El Flow debe tener `heading` como texto 100% dinámico: `"text": "${data.heading}"`.

## Prueba en aoxdev

1. Cita `COMPLETADO` con teléfono de prueba (`+595986541799`, cita `122`).
2. **Manual:** `POST /api/v1/appointments/122/survey` con JWT de la org.
3. **Auto:** activar `survey_auto_enabled = 1` en Ajustes → Sistema; marcar cita completada o forzar `survey_due_at` y `survey_status = 'NOT_SENT'`.
4. Completar el Flow en WhatsApp → webhook `attendance-reply` debe guardar `survey_score` y `survey_comment`.

### Sin plantilla aprobada

Si la plantilla aún no está aprobada, `pr_send_survey_wa` hace fallback a **mensaje interactivo con Flow** (solo válido dentro de la ventana de 24 h). El job automático requiere la plantilla UTILITY.

### Verificación SQL

```sql
SELECT id_appointment, survey_status, survey_score, survey_comment, survey_sent_at
  FROM appointment
 WHERE id_appointment = 122;
```

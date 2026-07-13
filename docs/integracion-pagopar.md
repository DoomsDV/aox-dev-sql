# Integración Pagopar de señas (OBSOLETO — Fase E)

> **Estado:** Deprecado. Las señas del comercio usan **SIPAP** (transferencia + comprobante).
> Pagopar queda **solo** para la suscripción Hasel (billing plataforma).
>
> Ver: [DEPLOY_PAGOPAR.md](./DEPLOY_PAGOPAR.md) y [ORDS_SUBSCRIPTION_BILLING.md](./ORDS_SUBSCRIPTION_BILLING.md).

---

## Objetivo original (histórico)

Implementar un flujo de cobro de seña a nivel de servicio vía Pagopar (claves del comercio).
El cliente era redirigido a Pagopar y el webhook confirmaba la reserva.

Ese flujo fue reemplazado por:

1. Ajustes → Pagos (SIPAP + políticas Flexible/Moderada/Estricta)
2. Reserva pública con código `HASEL-*` + datos bancarios
3. Upload de comprobante + OCR
4. Menú Cobros (aprobar/rechazar)
5. Reembolsos + 3 strikes

Los endpoints `POST /public/payments`, webhook `/pagopar/respuesta` y
`/org-integrations/pagopar` responden **HTTP 410**.

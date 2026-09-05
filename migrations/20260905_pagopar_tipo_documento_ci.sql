-- Pagopar iniciar-transaccion: tipo_documento solo admite 'CI'.
-- El RUC del perfil fiscal va en comprador.ruc (base-DV).
-- Requiere: packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

PROMPT === Compilar PKG_AOX_SUBSCRIPTION_BILLING_API (tipo_documento CI) ===
@@../packages/PKG_AOX_SUBSCRIPTION_BILLING_API.pls

PROMPT === 20260905_pagopar_tipo_documento_ci: OK ===

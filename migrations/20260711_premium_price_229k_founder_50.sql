-- Migracion: Premium 229.000 Gs + fundadores con 50% permanente (ya no billing_exempt)
-- Precio de lista Premium: 249000 -> 229000
-- Beneficio fundador: 50% de descuento de por vida (114.500 Gs/mes), no gratis.

PROMPT === 1. Actualizar precio Premium ===
UPDATE ref_plan
   SET price_amount = 229000
 WHERE code = 'PREMIUM';

COMMIT;

PROMPT === 2. Fundadores: quitar exencion total; mantienen is_founder (50% en checkout) ===
UPDATE org_subscription
   SET billing_exempt = 0
 WHERE is_founder = 1
   AND NVL(billing_exempt, 0) = 1;

COMMIT;

PROMPT === Migracion premium 229k + founder 50% OK ===

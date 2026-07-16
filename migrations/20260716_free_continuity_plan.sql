-- Plan FREE (Continuidad): 0 Gs, 0 storage. Destino de "Terminar suscripción".
-- No se ofrece en el catálogo de compra (filtrado en pr_get_plans).

PROMPT === Seed plan FREE (Continuidad) ===

MERGE INTO ref_plan t
USING (
  SELECT 3 AS id_plan,
         'FREE' AS code,
         'Continuidad' AS name,
         0 AS price_amount,
         'PYG' AS currency,
         'MONTHLY' AS billing_period,
         0 AS storage_limit_bytes,
         1 AS is_active,
         0 AS sort_order
    FROM dual
) s
ON (t.id_plan = s.id_plan)
WHEN MATCHED THEN UPDATE SET
  t.code = s.code,
  t.name = s.name,
  t.price_amount = s.price_amount,
  t.currency = s.currency,
  t.billing_period = s.billing_period,
  t.storage_limit_bytes = s.storage_limit_bytes,
  t.is_active = s.is_active,
  t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_plan, code, name, price_amount, currency, billing_period, storage_limit_bytes, is_active, sort_order)
  VALUES (s.id_plan, s.code, s.name, s.price_amount, s.currency, s.billing_period, s.storage_limit_bytes, s.is_active, s.sort_order);

COMMIT;

PROMPT OK: plan FREE Continuidad

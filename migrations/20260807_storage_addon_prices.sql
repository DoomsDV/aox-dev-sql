-- Migracion: ajuste de precios de almacenamiento adicional
--   +5 GB:  30.000 -> 15.000 Gs/mes
--   +15 GB: 70.000 -> 35.000 Gs/mes

PROMPT === Actualizar precios ref_storage_addon ===
UPDATE ref_storage_addon
   SET price_amount = 15000
 WHERE code = 'STORAGE_5GB';

UPDATE ref_storage_addon
   SET price_amount = 35000
 WHERE code = 'STORAGE_15GB';

COMMIT;

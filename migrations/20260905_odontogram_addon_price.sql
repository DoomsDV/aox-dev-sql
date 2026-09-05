-- Precio de lista del complemento Odontograma 3D: 100.000 → 69.000 Gs/mes.

PROMPT === Actualizar precio ref_addon ODONTOGRAM_3D ===
UPDATE ref_addon
   SET price_amount = 69000
 WHERE code = 'ODONTOGRAM_3D';

COMMIT;

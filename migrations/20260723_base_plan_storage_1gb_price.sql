-- Migracion: Plan Base — 1 GB de storage + precio 129.000 Gs/mes
-- Constantes:
--   1 GB = 1 * 1073741824 = 1073741824 bytes
--   5 GB = 5 * 1073741824 = 5368709120 bytes (Premium, sin cambio)
-- Nota: no usar fn_get_storage_limit_bytes dentro de UPDATE org_subscription
-- (ORA-04091 mutating table; la funcion lee org_subscription).

PROMPT === 1. Actualizar precio y storage del plan BASE ===
UPDATE ref_plan
   SET price_amount        = 129000,
       storage_limit_bytes = 1073741824
 WHERE code = 'BASE';

COMMIT;

PROMPT === 2. Backfill storage_limit_bytes en org_subscription ===
-- plan bytes + addons ACTIVE (misma formula que fn_get_storage_limit_bytes).
MERGE /*+ no_parallel */ INTO org_subscription t
USING (
  SELECT s.org_id_organization AS org_id,
         NVL(p.storage_limit_bytes, 0)
           + NVL(addb.addon_bytes, 0) AS new_limit
    FROM org_subscription s
    JOIN ref_plan p
      ON p.id_plan = s.pln_id_plan
    LEFT JOIN (
      SELECT osa.org_id_organization,
             SUM(a.extra_bytes * NVL(osa.quantity, 1)) AS addon_bytes
        FROM org_storage_addon osa
        JOIN ref_storage_addon a
          ON a.id_storage_addon = osa.sad_id_storage_addon
       WHERE osa.status = 'ACTIVE'
       GROUP BY osa.org_id_organization
    ) addb
      ON addb.org_id_organization = s.org_id_organization
) src
ON (t.org_id_organization = src.org_id)
WHEN MATCHED THEN UPDATE SET
  t.storage_limit_bytes = src.new_limit,
  t.updated_at          = SYSTIMESTAMP;

COMMIT;

PROMPT === Migracion Base 1 GB + 129k OK ===

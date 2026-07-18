-- Migracion: PROFITABILITY_ANALYTICS pasa a plan Base (sigue en Premium).
-- Continuidad/FREE no recibe el entitlement.

MERGE INTO ref_plan_feature t
USING (
  SELECT 1 AS pln_id_plan, 'PROFITABILITY_ANALYTICS' AS feature_code FROM dual
) s
ON (t.pln_id_plan = s.pln_id_plan AND t.feature_code = s.feature_code)
WHEN NOT MATCHED THEN
  INSERT (pln_id_plan, feature_code, is_enabled)
  VALUES (s.pln_id_plan, s.feature_code, 1);

COMMIT;

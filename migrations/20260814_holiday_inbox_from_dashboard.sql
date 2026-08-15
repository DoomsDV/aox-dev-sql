-- Holiday reminder lives in the inbox bell (not the dashboard AI strip).
-- PKG_AOX_INBOX_API.pr_list / pr_unread_count now enqueue the upcoming
-- holiday (admin/recepcionista, no location_closure yet) with the same
-- dedupe_key as the daily job. No FCM on this path.
--
-- Deploy: aox-dev/packages/PKG_AOX_INBOX_API.pls

MERGE INTO app_parameter t
USING (
    SELECT 'HOLIDAY_HINT_DAYS' AS param_key,
           '15' AS param_value,
           'Ventana en dias para encolar el feriado proximo en la campanita.' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN MATCHED THEN UPDATE SET t.description = s.description
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description)
VALUES (s.param_key, s.param_value, s.description);

COMMIT;

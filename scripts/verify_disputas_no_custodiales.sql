-- Escenarios repetibles en DEV (aoxdev). No aplica strikes ni creditos.
-- Ejecutar despues de la migracion 20260901 y de recompilar paquetes.

PROMPT === verify_disputas_no_custodiales ===

SELECT 'dispute_status_check' AS check_name, constraint_name, search_condition
  FROM user_constraints
 WHERE table_name = 'ORG_REFUND_DISPUTE'
   AND constraint_name = 'CHK_REFUND_DISPUTE_STATUS';

SELECT dispute_status, COUNT(*) AS n
  FROM org_refund_dispute
 GROUP BY dispute_status
 ORDER BY 1;

SELECT 'legacy_status_remainders' AS check_name, COUNT(*) AS n
  FROM org_refund_dispute
 WHERE dispute_status IN ('OPEN', 'EVIDENCE_PROCESSING', 'EVIDENCE_ACCEPTED', 'EXPIRED_STRIKE', 'CUSTOMER_FOLLOW_UP');

SELECT 'phone_audit_rows' AS check_name, issue_code, COUNT(*) AS n
  FROM customer_phone_audit
 GROUP BY issue_code
 ORDER BY 1;

SELECT 'compensation_gate' AS check_name, param_value
  FROM app_parameter
 WHERE param_key = 'DISPUTE_COMPENSATION_ENABLED';

SELECT 'enforcement_levels' AS check_name, NVL(refund_enforcement_level, 'NONE') AS lvl, COUNT(*) AS n
  FROM org_payment_settings
 GROUP BY NVL(refund_enforcement_level, 'NONE')
 ORDER BY 1;

SELECT object_name, status
  FROM user_objects
 WHERE object_name IN (
    'PKG_AOX_REFUND_DISPUTES_API',
    'PKG_AOX_REFUND_COMPENSATION_API',
    'PKG_AOX_PAYMENT_SETTINGS_API'
 )
 ORDER BY object_name, object_type;

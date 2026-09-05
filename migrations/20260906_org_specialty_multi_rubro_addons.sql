-- Multi-rubro org + elegibilidad fail-closed de complementos clínicos.
-- Orden: codes → M:N → flag → puentes → (paquetes en commit siguiente).

PROMPT === backfill org_specialty.code (13 rubros) ===
MERGE INTO org_specialty t
USING (
  SELECT 1  AS id_org_specialty, 'HAIR_BARBERSHOP'      AS code FROM dual UNION ALL
  SELECT 2,  'BEAUTY_AESTHETICS' FROM dual UNION ALL
  SELECT 3,  'SPA_WELLNESS' FROM dual UNION ALL
  SELECT 4,  'HEALTH' FROM dual UNION ALL
  SELECT 5,  'PSYCHOLOGY_MENTAL_HEALTH' FROM dual UNION ALL
  SELECT 6,  'PHYSIO_REHAB' FROM dual UNION ALL
  SELECT 7,  'SPORTS_FITNESS' FROM dual UNION ALL
  SELECT 8,  'YOGA_PILATES' FROM dual UNION ALL
  SELECT 9,  'PROFESSIONAL_SERVICES' FROM dual UNION ALL
  SELECT 10, 'EDUCATION_CLASSES' FROM dual UNION ALL
  SELECT 11, 'PETS_VETERINARY' FROM dual UNION ALL
  SELECT 12, 'HOME_MAINTENANCE' FROM dual UNION ALL
  SELECT 13, 'DENTAL' FROM dual
) s
ON (t.id_org_specialty = s.id_org_specialty)
WHEN MATCHED THEN
  UPDATE SET t.code = s.code
   WHERE t.code IS NULL OR t.code <> s.code;
COMMIT;

DECLARE
  v_null_codes NUMBER;
BEGIN
  SELECT COUNT(*)
    INTO v_null_codes
    FROM org_specialty
   WHERE is_active = 1
     AND code IS NULL;
  IF v_null_codes > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'org_specialty.code backfill incompleto: ' || v_null_codes || ' filas NULL.');
  END IF;
END;
/

PROMPT === organization_specialty M:N ===
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE organization_specialty (
      org_id_organization    NUMBER NOT NULL,
      osp_id_org_specialty   NUMBER NOT NULL,
      created_at             TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT pk_organization_specialty PRIMARY KEY (org_id_organization, osp_id_org_specialty),
      CONSTRAINT fk_orgspec_org FOREIGN KEY (org_id_organization)
        REFERENCES organization (id_organization) ON DELETE CASCADE,
      CONSTRAINT fk_orgspec_specialty FOREIGN KEY (osp_id_org_specialty)
        REFERENCES org_specialty (id_org_specialty) ON DELETE CASCADE
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX idx_orgspec_specialty ON organization_specialty (osp_id_org_specialty)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
END;
/

INSERT /*+ no_parallel */ INTO organization_specialty (org_id_organization, osp_id_org_specialty)
SELECT o.id_organization, o.org_spe_id_specialty
  FROM organization o
 WHERE o.org_spe_id_specialty IS NOT NULL
   AND NOT EXISTS (
         SELECT 1
           FROM organization_specialty os
          WHERE os.org_id_organization = o.id_organization
            AND os.osp_id_org_specialty = o.org_spe_id_specialty
       );
COMMIT;

PROMPT === ref_addon.requires_specialty_bridge ===
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE ref_addon ADD requires_specialty_bridge NUMBER(1,0) DEFAULT 0 NOT NULL';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-1430, -2261, -2264) THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE ref_addon ADD CONSTRAINT chk_ref_addon_req_bridge CHECK (requires_specialty_bridge IN (0, 1))
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE NOT IN (-2260, -2261, -2264) THEN RAISE; END IF;
END;
/

UPDATE ref_addon
   SET requires_specialty_bridge = 1
 WHERE feature_code IN ('ODONTOGRAM_3D', 'BODY_MAP');
COMMIT;

PROMPT === puentes ref_addon_specialty por id ===
MERGE INTO ref_addon_specialty t
USING (
  SELECT ra.id_addon AS rad_id_addon, 13 AS osp_id_org_specialty
    FROM ref_addon ra
   WHERE ra.code = 'ODONTOGRAM_3D'
  UNION ALL
  SELECT ra.id_addon, 4
    FROM ref_addon ra
   WHERE ra.code = 'ODONTOGRAM_3D'
  UNION ALL
  SELECT ra.id_addon, 6
    FROM ref_addon ra
   WHERE ra.code = 'BODY_MAP'
  UNION ALL
  SELECT ra.id_addon, 4
    FROM ref_addon ra
   WHERE ra.code = 'BODY_MAP'
) s
ON (t.rad_id_addon = s.rad_id_addon AND t.osp_id_org_specialty = s.osp_id_org_specialty)
WHEN NOT MATCHED THEN
  INSERT (rad_id_addon, osp_id_org_specialty)
  VALUES (s.rad_id_addon, s.osp_id_org_specialty);
COMMIT;

COMMENT ON TABLE ref_addon_specialty IS
  'Puente addon↔rubro comercial. Elegibilidad = intersección con organization_specialty. Sin puente y requires_specialty_bridge=1 → no elegible.';
COMMENT ON COLUMN ref_addon_specialty.osp_id_org_specialty IS 'FK a org_specialty.id_org_specialty.';

PROMPT OK: org_specialty_multi_rubro_addons

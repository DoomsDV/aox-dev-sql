-- Catalogo de bancos SIPAP Paraguay + FK en org_payment_settings.bank_id
-- Ejecutar statement por statement (o con SQLcl). Idempotente donde aplica.

PROMPT === Migration 20260711_ref_sipap_bank ===

BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE ref_sipap_bank (
      id_bank    NUMBER         NOT NULL,
      code       VARCHAR2(30)   NOT NULL,
      name       VARCHAR2(120)  NOT NULL,
      is_active  NUMBER(1,0)    DEFAULT 1 NOT NULL,
      sort_order NUMBER         DEFAULT 0 NOT NULL,
      CONSTRAINT pk_ref_sipap_bank PRIMARY KEY (id_bank),
      CONSTRAINT uq_ref_sipap_bank_code UNIQUE (code),
      CONSTRAINT chk_ref_sipap_bank_active CHECK (is_active IN (0, 1))
    )
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -955 THEN NULL; ELSE RAISE; END IF;
END;
/

MERGE INTO ref_sipap_bank t
USING (
  SELECT 1  AS id_bank, 'CONTINENTAL' AS code, 'Banco Continental' AS name, 1 AS is_active, 10  AS sort_order FROM dual UNION ALL
  SELECT 2,  'ITAU',          'Banco Itaú',                 1, 20  FROM dual UNION ALL
  SELECT 3,  'FAMILIAR',      'Banco Familiar',             1, 30  FROM dual UNION ALL
  SELECT 4,  'GNB',           'Banco GNB',                  1, 40  FROM dual UNION ALL
  SELECT 5,  'ATLAS',         'Banco Atlas',                1, 50  FROM dual UNION ALL
  SELECT 6,  'UENO',          'Ueno Bank',                  1, 60  FROM dual UNION ALL
  SELECT 7,  'BASA',          'Banco Basa',                 1, 70  FROM dual UNION ALL
  SELECT 8,  'VISION',        'Visión Banco',               1, 80  FROM dual UNION ALL
  SELECT 9,  'INTERFISA',     'Interfisa',                  1, 90  FROM dual UNION ALL
  SELECT 10, 'SOLAR',         'Solar Bank',                 1, 100 FROM dual UNION ALL
  SELECT 11, 'SUDAMERIS',     'Banco Sudameris',            1, 110 FROM dual UNION ALL
  SELECT 12, 'BNF',           'Banco Nacional de Fomento',  1, 120 FROM dual UNION ALL
  SELECT 13, 'DO_BRASIL',     'Banco do Brasil',            1, 130 FROM dual UNION ALL
  SELECT 14, 'CITIBANK',      'Citibank',                   1, 140 FROM dual UNION ALL
  SELECT 15, 'REGIONAL',      'Banco Regional',             1, 150 FROM dual UNION ALL
  SELECT 16, 'ZETA',          'Banco Zeta',                 1, 160 FROM dual UNION ALL
  SELECT 17, 'TU_FINANCIERA', 'Tu Financiera',              1, 170 FROM dual UNION ALL
  SELECT 18, 'FINANCIERA_RIO','Financiera Río',             1, 180 FROM dual
) s
ON (t.id_bank = s.id_bank)
WHEN MATCHED THEN UPDATE SET
  t.code = s.code,
  t.name = s.name,
  t.is_active = s.is_active,
  t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (id_bank, code, name, is_active, sort_order)
  VALUES (s.id_bank, s.code, s.name, s.is_active, s.sort_order);
/

COMMIT;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings ADD (bank_id NUMBER NULL)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE q'[
    ALTER TABLE org_payment_settings
      ADD CONSTRAINT fk_org_payset_bank FOREIGN KEY (bank_id)
      REFERENCES ref_sipap_bank (id_bank)
  ]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE IN (-2275, -02275) THEN NULL; ELSE RAISE; END IF;
END;
/

UPDATE /*+ no_parallel */ org_payment_settings ops
   SET bank_id = (
         SELECT MIN(b.id_bank)
           FROM ref_sipap_bank b
          WHERE UPPER(TRIM(b.name)) = UPPER(TRIM(ops.bank_name))
       )
 WHERE ops.bank_id IS NULL
   AND ops.bank_name IS NOT NULL
   AND TRIM(ops.bank_name) IS NOT NULL;
/
COMMIT;
/

UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 1
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('CONTINENTAL', 'BANCO CONTINENTAL', 'BANCO CONT.');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 2
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('ITAU', 'ITAÚ', 'BANCO ITAU', 'BANCO ITAÚ');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 3
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('FAMILIAR', 'BANCO FAMILIAR');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 4
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('GNB', 'BANCO GNB');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 5
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('ATLAS', 'BANCO ATLAS');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 6
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('UENO', 'UENO BANK');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 7
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('BASA', 'BANCO BASA');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 8
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('VISION', 'VISIÓN', 'VISION BANCO', 'VISIÓN BANCO');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 9
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('INTERFISA');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 10
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('SOLAR', 'SOLAR BANK');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 11
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('SUDAMERIS', 'BANCO SUDAMERIS');
/
UPDATE /*+ no_parallel */ org_payment_settings
   SET bank_id = 12
 WHERE bank_id IS NULL
   AND UPPER(TRIM(bank_name)) IN ('BNF', 'BANCO NACIONAL DE FOMENTO');
/
COMMIT;
/

PROMPT === Migration 20260711_ref_sipap_bank done ===
/

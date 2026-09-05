-- Tildes en labels visibles del catálogo del odontograma.

PROMPT === Labels REF_ODONTOGRAM_FINDING con tildes ===
UPDATE ref_odontogram_finding
   SET label = 'Restauración defectuosa'
 WHERE finding_code = 'DEFECTIVE_RESTORATION';

UPDATE ref_odontogram_finding
   SET label = 'Restauración'
 WHERE finding_code = 'RESTORATION';

UPDATE ref_odontogram_finding
   SET label = 'Extracción'
 WHERE finding_code = 'EXTRACTION';

UPDATE ref_odontogram_finding
   SET label = 'Restauración nueva'
 WHERE finding_code = 'RESTORATION_PLAN';

COMMIT;

PROMPT OK: odontogram finding labels tildes

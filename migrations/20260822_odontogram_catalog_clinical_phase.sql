-- Catálogo de hallazgos + fase clínica en eventos del odontograma.

@@../tables/REF_ODONTOGRAM_FINDING.sql

DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_count
      FROM user_tab_cols
     WHERE table_name = 'CUSTOMER_ODONTOGRAM_EVENT'
       AND column_name = 'CLINICAL_PHASE';

    IF v_count = 0 THEN
        EXECUTE IMMEDIATE '
            ALTER TABLE customer_odontogram_event ADD (
                clinical_phase VARCHAR2(20) DEFAULT ''FINDING'' NOT NULL
            )';
    END IF;
END;
/

ALTER TABLE customer_odontogram_event
  DROP CONSTRAINT chk_odoevt_finding
/

ALTER TABLE customer_odontogram_event
  ADD CONSTRAINT chk_odoevt_finding FOREIGN KEY (
    finding_code
  ) REFERENCES ref_odontogram_finding (
    finding_code
  )
/

ALTER TABLE customer_odontogram_event
  ADD CONSTRAINT chk_odoevt_clinical_phase CHECK (
    clinical_phase IN ('FINDING', 'PREEXISTING', 'PLAN')
  )
/

UPDATE customer_odontogram_event e
   SET clinical_phase = (
         SELECT r.clinical_phase
           FROM ref_odontogram_finding r
          WHERE r.finding_code = e.finding_code
       )
 WHERE clinical_phase IS NULL
    OR clinical_phase = 'FINDING';

COMMENT ON COLUMN customer_odontogram_event.clinical_phase IS 'Fase clinica del evento: FINDING, PREEXISTING o PLAN.';

PROMPT OK: odontogram catalog + clinical_phase

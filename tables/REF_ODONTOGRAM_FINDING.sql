PROMPT CREATE TABLE ref_odontogram_finding
CREATE TABLE ref_odontogram_finding (
  finding_code    VARCHAR2(40)   NOT NULL,
  label           VARCHAR2(100)  NOT NULL,
  clinical_phase  VARCHAR2(20)   NOT NULL,
  needs_faces     NUMBER(1,0)    DEFAULT 0 NOT NULL,
  display_color   VARCHAR2(20)   NULL,
  priority_rank   NUMBER(3,0)    DEFAULT 50 NOT NULL,
  visual_kind     VARCHAR2(20)   DEFAULT 'TINT' NOT NULL,
  is_active       NUMBER(1,0)    DEFAULT 1 NOT NULL,
  sort_order      NUMBER(5,0)    DEFAULT 0 NOT NULL
)
/

PROMPT ALTER TABLE ref_odontogram_finding ADD CONSTRAINT pk_ref_odontogram_finding PRIMARY KEY
ALTER TABLE ref_odontogram_finding
  ADD CONSTRAINT pk_ref_odontogram_finding PRIMARY KEY (
    finding_code
  )
/

PROMPT ALTER TABLE ref_odontogram_finding ADD CONSTRAINT chk_rof_phase CHECK
ALTER TABLE ref_odontogram_finding
  ADD CONSTRAINT chk_rof_phase CHECK (
    clinical_phase IN ('FINDING', 'PREEXISTING', 'PLAN')
  )
/

PROMPT ALTER TABLE ref_odontogram_finding ADD CONSTRAINT chk_rof_needs_faces CHECK
ALTER TABLE ref_odontogram_finding
  ADD CONSTRAINT chk_rof_needs_faces CHECK (
    needs_faces IN (0, 1)
  )
/

PROMPT ALTER TABLE ref_odontogram_finding ADD CONSTRAINT chk_rof_visual_kind CHECK
ALTER TABLE ref_odontogram_finding
  ADD CONSTRAINT chk_rof_visual_kind CHECK (
    visual_kind IN ('TINT', 'FACES', 'GHOST', 'HIDE', 'CROWN')
  )
/

PROMPT ALTER TABLE ref_odontogram_finding ADD CONSTRAINT chk_rof_active CHECK
ALTER TABLE ref_odontogram_finding
  ADD CONSTRAINT chk_rof_active CHECK (
    is_active IN (0, 1)
  )
/

COMMENT ON TABLE ref_odontogram_finding IS 'Catalogo de hallazgos/tratamientos del odontograma.';
COMMENT ON COLUMN ref_odontogram_finding.clinical_phase IS 'FINDING=diagnostico, PREEXISTING=preexistencia, PLAN=plan de tratamiento.';
COMMENT ON COLUMN ref_odontogram_finding.needs_faces IS '1 si el hallazgo requiere marcar caras (caries/restauracion).';
COMMENT ON COLUMN ref_odontogram_finding.priority_rank IS 'Menor = mayor prioridad al derivar estado vivo de la pieza.';
COMMENT ON COLUMN ref_odontogram_finding.visual_kind IS 'Modo visual 3D: TINT, FACES, GHOST, HIDE, CROWN.';

PROMPT MERGE ref_odontogram_finding seed
MERGE INTO ref_odontogram_finding t
USING (
  SELECT 'ABSENT' AS finding_code, 'Diente ausente' AS label, 'FINDING' AS clinical_phase,
         0 AS needs_faces, '#bdbdbd' AS display_color, -10 AS priority_rank,
         'HIDE' AS visual_kind, 1 AS is_active, 5 AS sort_order
    FROM dual
  UNION ALL
  SELECT 'FRACTURE', 'Fractura / traumatismo', 'FINDING', 1, '#ff7043', 35, 'FACES', 1, 10 FROM dual
  UNION ALL
  SELECT 'CARIES', 'Caries', 'FINDING', 1, '#e040fb', 40, 'FACES', 1, 15 FROM dual
  UNION ALL
  SELECT 'DEFECTIVE_RESTORATION', 'Restauracion defectuosa', 'FINDING', 1, '#e53935', 30, 'FACES', 1, 20 FROM dual
  UNION ALL
  SELECT 'PERIODONTAL', 'Enfermedad periodontal', 'FINDING', 0, '#8d6e63', 70, 'TINT', 1, 25 FROM dual
  UNION ALL
  SELECT 'ENDODONTIC', 'Endodoncia existente', 'PREEXISTING', 0, '#78909c', 55, 'TINT', 1, 30 FROM dual
  UNION ALL
  SELECT 'IMPLANT', 'Implante existente', 'PREEXISTING', 0, '#607d8b', 15, 'TINT', 1, 35 FROM dual
  UNION ALL
  SELECT 'CROWN_EXISTING', 'Corona existente', 'PREEXISTING', 0, '#ffb300', 20, 'CROWN', 1, 40 FROM dual
  UNION ALL
  SELECT 'RESTORATION', 'Restauracion', 'PREEXISTING', 1, '#00bcd4', 50, 'FACES', 1, 45 FROM dual
  UNION ALL
  SELECT 'SEALANT', 'Sellador', 'PREEXISTING', 1, '#4fc3f7', 60, 'FACES', 1, 50 FROM dual
  UNION ALL
  SELECT 'EXTRACTION', 'Extraccion', 'PLAN', 0, '#9e9e9e', 0, 'GHOST', 1, 55 FROM dual
  UNION ALL
  SELECT 'IMPLANT_PLAN', 'Implante dental', 'PLAN', 0, '#90a4ae', 5, 'GHOST', 1, 60 FROM dual
  UNION ALL
  SELECT 'CROWN', 'Corona', 'PLAN', 0, '#ffca28', 10, 'CROWN', 1, 65 FROM dual
  UNION ALL
  SELECT 'RESTORATION_PLAN', 'Restauracion nueva', 'PLAN', 1, '#26c6da', 45, 'FACES', 1, 70 FROM dual
  UNION ALL
  SELECT 'ENDODONTIC_PLAN', 'Endodoncia nueva', 'PLAN', 0, '#90a4ae', 48, 'TINT', 1, 75 FROM dual
) s
ON (t.finding_code = s.finding_code)
WHEN MATCHED THEN
  UPDATE SET
    t.label = s.label,
    t.clinical_phase = s.clinical_phase,
    t.needs_faces = s.needs_faces,
    t.display_color = s.display_color,
    t.priority_rank = s.priority_rank,
    t.visual_kind = s.visual_kind,
    t.is_active = s.is_active,
    t.sort_order = s.sort_order
WHEN NOT MATCHED THEN
  INSERT (
    finding_code, label, clinical_phase, needs_faces, display_color,
    priority_rank, visual_kind, is_active, sort_order
  ) VALUES (
    s.finding_code, s.label, s.clinical_phase, s.needs_faces, s.display_color,
    s.priority_rank, s.visual_kind, s.is_active, s.sort_order
  )
/

PROMPT CREATE TABLE ref_body_joint_test
CREATE TABLE ref_body_joint_test (
  joint_code    VARCHAR2(20)  NOT NULL,
  test_code     VARCHAR2(30)  NOT NULL,
  label         VARCHAR2(100) NOT NULL,
  sort_order    NUMBER        DEFAULT 0 NOT NULL,
  is_active     NUMBER(1,0)   DEFAULT 1 NOT NULL
)
/

PROMPT ALTER TABLE ref_body_joint_test ADD CONSTRAINT pk_ref_body_joint_test PRIMARY KEY
ALTER TABLE ref_body_joint_test
  ADD CONSTRAINT pk_ref_body_joint_test PRIMARY KEY (
    joint_code,
    test_code
  )
/

PROMPT ALTER TABLE ref_body_joint_test ADD CONSTRAINT chk_ref_body_joint CHECK
ALTER TABLE ref_body_joint_test
  ADD CONSTRAINT chk_ref_body_joint CHECK (
    joint_code IN ('SHOULDER', 'HIP', 'KNEE', 'ANKLE')
  )
/

PROMPT ALTER TABLE ref_body_joint_test ADD CONSTRAINT chk_ref_body_joint_test_active CHECK
ALTER TABLE ref_body_joint_test
  ADD CONSTRAINT chk_ref_body_joint_test_active CHECK (
    is_active IN (0, 1)
  )
/

COMMENT ON TABLE ref_body_joint_test IS 'Catálogo de pruebas clínicas por articulación (lentes Cuerpo).';

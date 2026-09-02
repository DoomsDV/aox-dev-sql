-- Disputas no custodiadas: estados, sanciones graduales, ledger gated, ORDS e idempotencia.
-- No activa compensacion al cliente (DISPUTE_COMPENSATION_ENABLED=0).
-- No toca parametros de cobro de produccion.

PROMPT === 20260901_disputas_no_custodiales ===

BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE PARALLEL DML';
EXCEPTION
    WHEN OTHERS THEN NULL;
END;
/

-- Columnas de caso
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD evidence_received_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD ops_review_due_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD resolution_code VARCHAR2(40)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD resolved_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD resolved_by NUMBER';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute ADD customer_insisted_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute_evidence ADD review_decision VARCHAR2(30)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute_evidence ADD reviewed_by NUMBER';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute_evidence ADD reviewed_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute_evidence ADD review_notes VARCHAR2(500)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings ADD refund_enforcement_level VARCHAR2(30) DEFAULT ''NONE'' NOT NULL';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings ADD refund_enforcement_at TIMESTAMP(6) WITH TIME ZONE';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings ADD refund_enforcement_reason VARCHAR2(400)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_payment_settings ADD refund_enforcement_by NUMBER';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-1430, -904) THEN RAISE; END IF;
END;
/

-- Quitar checks viejos antes del backfill
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute DROP CONSTRAINT chk_refund_dispute_status';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_dispute DROP CONSTRAINT chk_refund_dispute_close';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE org_refund_strike DROP CONSTRAINT chk_refund_strike_reason';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

PROMPT Backfill de estados de disputa
UPDATE /*+ no_parallel */ org_refund_dispute
   SET dispute_status = CASE dispute_status
                          WHEN 'OPEN' THEN 'OPENED'
                          WHEN 'EVIDENCE_PROCESSING' THEN 'PROOF_RECEIVED'
                          WHEN 'EVIDENCE_ACCEPTED' THEN 'UNDER_REVIEW'
                          WHEN 'CUSTOMER_FOLLOW_UP' THEN 'UNDER_REVIEW'
                          WHEN 'EXPIRED_STRIKE' THEN 'TIMED_OUT'
                          ELSE dispute_status
                        END,
       customer_insisted_at = CASE
                                WHEN dispute_status = 'CUSTOMER_FOLLOW_UP' AND customer_insisted_at IS NULL
                                THEN NVL(updated_at, CURRENT_TIMESTAMP)
                                ELSE customer_insisted_at
                              END,
       resolved_at = CASE
                       WHEN dispute_status IN ('EXPIRED_STRIKE', 'DISMISSED') THEN NVL(closed_at, resolved_at)
                       ELSE resolved_at
                     END,
       updated_at = CURRENT_TIMESTAMP
 WHERE dispute_status IN (
    'OPEN', 'EVIDENCE_PROCESSING', 'EVIDENCE_ACCEPTED', 'CUSTOMER_FOLLOW_UP', 'EXPIRED_STRIKE'
 );
/

UPDATE /*+ no_parallel */ org_refund_dispute d
   SET evidence_received_at = (
         SELECT MIN(e.uploaded_at)
           FROM org_refund_dispute_evidence e
          WHERE e.dispute_id = d.id_dispute
       )
 WHERE d.evidence_received_at IS NULL
   AND EXISTS (
         SELECT 1 FROM org_refund_dispute_evidence e WHERE e.dispute_id = d.id_dispute
       );
/

UPDATE /*+ no_parallel */ org_refund_dispute
   SET ops_review_due_at = NVL(
         ops_review_due_at,
         pkg_aox_refund_claims_api.fn_add_business_hours(NVL(evidence_received_at, CURRENT_TIMESTAMP), 24)
       )
 WHERE dispute_status = 'UNDER_REVIEW'
   AND ops_review_due_at IS NULL;
/

COMMIT;
/

BEGIN
    EXECUTE IMMEDIATE q'[
ALTER TABLE org_refund_dispute ADD CONSTRAINT chk_refund_dispute_status CHECK (
    dispute_status IN (
      'OPENED', 'PROOF_RECEIVED', 'UNDER_REVIEW', 'REFUND_SETTLED',
      'TIMED_OUT', 'RESOLVED_BY_OPS', 'DISMISSED'
    )
)
    ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2260) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
ALTER TABLE org_refund_dispute ADD CONSTRAINT chk_refund_dispute_close CHECK (
    close_reason IS NULL
    OR close_reason IN (
      'PROOF_OK', 'TIMEOUT', 'WAIVED', 'CUSTOMER_INSISTED',
      'CUSTOMER_CONFIRMED', 'OPS_SETTLED', 'OPS_DISMISSED', 'OPS_ADVERSE', 'OPS_CREDIT'
    )
)
    ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2260) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
ALTER TABLE org_refund_strike ADD CONSTRAINT chk_refund_strike_reason CHECK (
    reason IN ('TIMEOUT', 'OPS_ADVERSE')
)
    ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2260) THEN RAISE; END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE q'[
      ALTER TABLE org_payment_settings ADD CONSTRAINT chk_org_payset_enforcement CHECK (
        refund_enforcement_level IN (
          'NONE', 'DEPOSITS_ONLY', 'PUBLIC_BOOKINGS', 'PUBLIC_UNPUBLISHED', 'OPERATIONS_SUSPENDED'
        )
      )
    ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2260) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
      ALTER TABLE org_refund_dispute_evidence ADD CONSTRAINT chk_refund_evidence_decision CHECK (
        review_decision IS NULL
        OR review_decision IN ('CANDIDATE', 'REJECTED', 'SETTLED', 'ADVERSE')
      )
    ]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-2264, -2260) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'CREATE INDEX idx_refund_dispute_ops_review ON org_refund_dispute (dispute_status, ops_review_due_at)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

-- Tablas nuevas (idempotente)
BEGIN
    EXECUTE IMMEDIATE q'[
CREATE TABLE org_refund_enforcement_audit (
  id_enforcement_audit NUMBER GENERATED BY DEFAULT AS IDENTITY,
  org_id_organization  NUMBER NOT NULL,
  dispute_id           NUMBER NULL,
  from_level           VARCHAR2(30) NOT NULL,
  to_level             VARCHAR2(30) NOT NULL,
  reason               VARCHAR2(400) NOT NULL,
  actor_user_id        NUMBER NULL,
  created_at           TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT pk_org_refund_enf_audit PRIMARY KEY (id_enforcement_audit),
  CONSTRAINT fk_refund_enf_audit_org FOREIGN KEY (org_id_organization)
    REFERENCES organization (id_organization) ON DELETE CASCADE
)]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'CREATE INDEX idx_refund_enf_audit_org ON org_refund_enforcement_audit (org_id_organization, created_at)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
CREATE TABLE org_refund_dispute_compensation (
  id_compensation       NUMBER GENERATED BY DEFAULT AS IDENTITY,
  dispute_id            NUMBER NOT NULL,
  org_id_organization   NUMBER NOT NULL,
  app_id_appointment    NUMBER NOT NULL,
  cus_id_customer       NUMBER NOT NULL,
  amount_gs             NUMBER NOT NULL,
  credit_status         VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
  debt_status           VARCHAR2(20) DEFAULT 'NONE' NOT NULL,
  issued_at             TIMESTAMP(6) WITH TIME ZONE NULL,
  issued_by             NUMBER NULL,
  recovered_at          TIMESTAMP(6) WITH TIME ZONE NULL,
  recovered_amount_gs   NUMBER DEFAULT 0 NOT NULL,
  notes                 VARCHAR2(500) NULL,
  created_at            TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
  updated_at            TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT pk_org_refund_disp_comp PRIMARY KEY (id_compensation),
  CONSTRAINT uq_refund_disp_comp_dispute UNIQUE (dispute_id),
  CONSTRAINT fk_refund_disp_comp_disp FOREIGN KEY (dispute_id) REFERENCES org_refund_dispute (id_dispute),
  CONSTRAINT fk_refund_disp_comp_org FOREIGN KEY (org_id_organization) REFERENCES organization (id_organization) ON DELETE CASCADE,
  CONSTRAINT chk_refund_disp_comp_credit CHECK (credit_status IN ('PENDING', 'ISSUED', 'REDEEMED', 'REVERSED', 'EXPIRED')),
  CONSTRAINT chk_refund_disp_comp_debt CHECK (debt_status IN ('NONE', 'OPEN', 'RECOVERED', 'WAIVED')),
  CONSTRAINT chk_refund_disp_comp_amt CHECK (amount_gs > 0)
)]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
CREATE TABLE org_refund_dispute_ledger (
  id_ledger_entry       NUMBER GENERATED BY DEFAULT AS IDENTITY,
  org_id_organization   NUMBER NOT NULL,
  dispute_id            NUMBER NOT NULL,
  compensation_id       NUMBER NOT NULL,
  event_type            VARCHAR2(40) NOT NULL,
  amount_gs             NUMBER NOT NULL,
  delta_due             NUMBER DEFAULT 0 NOT NULL,
  balance_due_after     NUMBER DEFAULT 0 NOT NULL,
  idempotency_key       VARCHAR2(120) NOT NULL,
  actor_user_id         NUMBER NULL,
  metadata              CLOB NULL,
  created_at            TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT pk_org_refund_disp_ledger PRIMARY KEY (id_ledger_entry),
  CONSTRAINT uq_refund_disp_ledger_idem UNIQUE (idempotency_key),
  CONSTRAINT fk_refund_disp_ledger_org FOREIGN KEY (org_id_organization) REFERENCES organization (id_organization) ON DELETE CASCADE,
  CONSTRAINT fk_refund_disp_ledger_disp FOREIGN KEY (dispute_id) REFERENCES org_refund_dispute (id_dispute),
  CONSTRAINT fk_refund_disp_ledger_comp FOREIGN KEY (compensation_id) REFERENCES org_refund_dispute_compensation (id_compensation),
  CONSTRAINT chk_refund_disp_ledger_evt CHECK (event_type IN (
    'CUSTOMER_CREDIT_ISSUED', 'ORG_DEBT_OPENED', 'DEBT_RECOVERED', 'CREDIT_REVERSED', 'DEBT_WAIVED'
  ))
)]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
CREATE UNIQUE INDEX uq_refund_disp_ledger_term ON org_refund_dispute_ledger (
  CASE WHEN event_type IN ('CUSTOMER_CREDIT_ISSUED','ORG_DEBT_OPENED','CREDIT_REVERSED','DEBT_WAIVED') THEN dispute_id ELSE NULL END,
  CASE WHEN event_type IN ('CUSTOMER_CREDIT_ISSUED','ORG_DEBT_OPENED','CREDIT_REVERSED','DEBT_WAIVED') THEN event_type ELSE NULL END
)]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE q'[
CREATE TABLE customer_phone_audit (
  id_audit              NUMBER GENERATED BY DEFAULT AS IDENTITY,
  cus_id_customer       NUMBER NOT NULL,
  org_id_organization   NUMBER NOT NULL,
  full_name             VARCHAR2(150) NULL,
  phone_number          VARCHAR2(40) NULL,
  issue_code            VARCHAR2(40) NOT NULL,
  audited_at            TIMESTAMP(6) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT pk_customer_phone_audit PRIMARY KEY (id_audit)
)]';
EXCEPTION WHEN OTHERS THEN IF SQLCODE NOT IN (-955) THEN RAISE; END IF;
END;
/

DELETE FROM customer_phone_audit;
/

INSERT /*+ no_parallel */ INTO customer_phone_audit (
    cus_id_customer, org_id_organization, full_name, phone_number, issue_code
)
SELECT id_customer,
       org_id_organization,
       full_name,
       phone_number,
       CASE
         WHEN phone_number IS NULL OR TRIM(phone_number) IS NULL THEN 'MISSING'
         ELSE 'INVALID_FORMAT'
       END
  FROM customer
 WHERE phone_number IS NULL
    OR TRIM(phone_number) IS NULL
    OR NOT REGEXP_LIKE(phone_number, '^\+5959[0-9]{8}$');
/

COMMIT;
/

MERGE INTO app_parameter t
USING (
    SELECT 'DISPUTE_COMPENSATION_ENABLED' AS param_key,
           '0' AS param_value,
           'Gate F3: 1 habilita credito al cliente y deuda recuperable. Default 0.' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description)
VALUES (s.param_key, s.param_value, s.description);
/

MERGE INTO app_parameter t
USING (
    SELECT 'HASEL_OPS_USER_IDS' AS param_key,
           '-' AS param_value,
           'Lista CSV de user_id JWT autorizados para resolver disputas y restaurar sanciones. Use - si esta vacio (Oracle trata '''' como NULL).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description)
VALUES (s.param_key, s.param_value, s.description);
/

MERGE INTO app_parameter t
USING (
    SELECT 'DISPUTE_COMPENSATION_CAP_GS' AS param_key,
           '500000' AS param_value,
           'Tope Gs por caso de compensacion (F3 gated).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description)
VALUES (s.param_key, s.param_value, s.description);
/

MERGE INTO app_parameter t
USING (
    SELECT 'DISPUTE_COMPENSATION_ORG_MONTH_CAP_GS' AS param_key,
           '2000000' AS param_value,
           'Tope Gs mensual por organizacion (F3 gated).' AS description
      FROM dual
) s
ON (t.param_key = s.param_key)
WHEN NOT MATCHED THEN INSERT (param_key, param_value, description)
VALUES (s.param_key, s.param_value, s.description);
/

COMMIT;
/

PROMPT === ORDS: idempotencia HTTP_IDEMPOTENCY_KEY + confirm/ops ===
BEGIN
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'workspace/payments/:id/refund-proof',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_upload_staff_proof(
        pi_auth_header     => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_transaction_id  => TO_NUMBER(:id),
        pi_body            => :body_text,
        pi_idempotency_key => owa_util.get_cgi_env('HTTP_IDEMPOTENCY_KEY'),
        po_status_code     => v_status_code,
        po_response_body   => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute/confirm-received'
    );
    ORDS.define_handler(
        p_module_name => 'public',
        p_pattern     => 'reservations/:token/refund-dispute/confirm-received',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_confirm_public_settled(
        pi_public_token  => :token,
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'ops/disputes/:id/resolve'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'ops/disputes/:id/resolve',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_ops_resolve_dispute(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_dispute_id    => TO_NUMBER(:id),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    ORDS.define_template(
        p_module_name => 'hasel',
        p_pattern     => 'ops/orgs/:id/enforcement/restore'
    );
    ORDS.define_handler(
        p_module_name => 'hasel',
        p_pattern     => 'ops/orgs/:id/enforcement/restore',
        p_method      => 'POST',
        p_source_type => ords.source_type_plsql,
        p_source      => q'[
DECLARE
    v_status_code   NUMBER;
    v_response_body CLOB;
BEGIN
    pkg_aox_refund_disputes_api.pr_ops_restore_enforcement(
        pi_auth_header   => owa_util.get_cgi_env('AUTHORIZATION'),
        pi_org_id        => TO_NUMBER(:id),
        pi_body          => :body_text,
        po_status_code   => v_status_code,
        po_response_body => v_response_body
    );
    :status := v_status_code;
    owa_util.mime_header('application/json', TRUE);
    IF v_response_body IS NOT NULL THEN htp.prn(v_response_body); END IF;
END;
        ]'
    );

    COMMIT;
END;
/

PROMPT === 20260901_disputas_no_custodiales listo (compilar paquetes .pls despues) ===

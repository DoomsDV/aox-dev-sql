PROMPT === Triggers: hijas B rechazan org_id que no coincide con el padre ===

CREATE OR REPLACE TRIGGER trg_ai_chat_msg_org
BEFORE INSERT OR UPDATE OF ses_id_session, org_id_organization
    ON ai_chat_message
FOR EACH ROW
DECLARE
    v_org ai_chat_session.org_id_organization%TYPE;
BEGIN
    SELECT s.org_id_organization
      INTO v_org
      FROM ai_chat_session s
     WHERE s.id_session = :NEW.ses_id_session;

    IF :NEW.org_id_organization IS NULL OR :NEW.org_id_organization <> v_org THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'ai_chat_message.org_id_organization no coincide con ai_chat_session'
        );
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'ai_chat_message: sesion padre no existe');
END;
/

CREATE OR REPLACE TRIGGER trg_prof_image_org
BEFORE INSERT OR UPDATE OF pro_id_professional, org_id_organization
    ON professional_image
FOR EACH ROW
DECLARE
    v_org professional.org_id_organization%TYPE;
BEGIN
    SELECT p.org_id_organization
      INTO v_org
      FROM professional p
     WHERE p.id_professional = :NEW.pro_id_professional;

    IF :NEW.org_id_organization IS NULL OR :NEW.org_id_organization <> v_org THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'professional_image.org_id_organization no coincide con professional'
        );
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'professional_image: profesional padre no existe');
END;
/

CREATE OR REPLACE TRIGGER trg_sch_exc_slot_org
BEFORE INSERT OR UPDATE OF exc_id_schedule_exception, loc_id_location, org_id_organization
    ON professional_schedule_exception_slot
FOR EACH ROW
DECLARE
    v_org_exc professional_schedule_exception.org_id_organization%TYPE;
    v_org_loc location.org_id_organization%TYPE;
BEGIN
    SELECT e.org_id_organization
      INTO v_org_exc
      FROM professional_schedule_exception e
     WHERE e.id_schedule_exception = :NEW.exc_id_schedule_exception;

    SELECT l.org_id_organization
      INTO v_org_loc
      FROM location l
     WHERE l.id_location = :NEW.loc_id_location;

    IF :NEW.org_id_organization IS NULL
       OR :NEW.org_id_organization <> v_org_exc
       OR :NEW.org_id_organization <> v_org_loc
    THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'professional_schedule_exception_slot.org_id_organization no coincide con exception y location'
        );
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'professional_schedule_exception_slot: padre no existe');
END;
/

CREATE OR REPLACE TRIGGER trg_refund_ev_org
BEFORE INSERT OR UPDATE OF dispute_id, org_id_organization
    ON org_refund_dispute_evidence
FOR EACH ROW
DECLARE
    v_org org_refund_dispute.org_id_organization%TYPE;
BEGIN
    SELECT d.org_id_organization
      INTO v_org
      FROM org_refund_dispute d
     WHERE d.id_dispute = :NEW.dispute_id;

    IF :NEW.org_id_organization IS NULL OR :NEW.org_id_organization <> v_org THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'org_refund_dispute_evidence.org_id_organization no coincide con org_refund_dispute'
        );
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'org_refund_dispute_evidence: disputa padre no existe');
END;
/

CREATE OR REPLACE TRIGGER trg_uint_org
BEFORE INSERT OR UPDATE OF usr_id_user, org_id_organization
    ON user_integration
FOR EACH ROW
DECLARE
    v_org org_member.org_id_organization%TYPE;
BEGIN
    SELECT m.org_id_organization
      INTO v_org
      FROM org_member m
     WHERE m.id_org_member = :NEW.usr_id_user;

    IF :NEW.org_id_organization IS NULL OR :NEW.org_id_organization <> v_org THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'user_integration.org_id_organization no coincide con org_member'
        );
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'user_integration: org_member padre no existe');
END;
/

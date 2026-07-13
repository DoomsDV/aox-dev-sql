PROMPT === Triggers: sync embeddings en entidades de org ===

CREATE OR REPLACE TRIGGER trg_customer_vector_embedding
AFTER INSERT OR UPDATE OF full_name, phone_number OR DELETE ON customer
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :OLD.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_customer,
            pi_entity_id   => :OLD.id_customer,
            pi_deleted     => TRUE
        );
    ELSE
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :NEW.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_customer,
            pi_entity_id   => :NEW.id_customer,
            pi_deleted     => FALSE
        );
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_professional_vector_embedding
AFTER INSERT OR UPDATE OF display_name, spe_id_specialty, is_active, usr_id_user OR DELETE ON professional
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :OLD.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_professional,
            pi_entity_id   => :OLD.id_professional,
            pi_deleted     => TRUE
        );
    ELSE
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :NEW.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_professional,
            pi_entity_id   => :NEW.id_professional,
            pi_deleted     => FALSE
        );
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_service_vector_embedding
AFTER INSERT OR UPDATE OF name, duration_minutes, is_active OR DELETE ON service
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :OLD.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_service,
            pi_entity_id   => :OLD.id_service,
            pi_deleted     => TRUE
        );
    ELSE
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :NEW.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_service,
            pi_entity_id   => :NEW.id_service,
            pi_deleted     => FALSE
        );
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_location_vector_embedding
AFTER INSERT OR UPDATE OF name, address, is_active OR DELETE ON location
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :OLD.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_location,
            pi_entity_id   => :OLD.id_location,
            pi_deleted     => TRUE
        );
    ELSE
        pkg_aox_vector_search.pr_on_entity_embedding_changed(
            pi_org_id      => :NEW.org_id_organization,
            pi_entity_type => pkg_aox_vector_search.c_entity_location,
            pi_entity_id   => :NEW.id_location,
            pi_deleted     => FALSE
        );
    END IF;
END;
/

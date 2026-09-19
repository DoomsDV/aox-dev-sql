PROMPT === Triggers: proyeccion publica ORG_PUBLIC_DIRECTORY / ORG_PUBLIC_TOKEN ===

CREATE OR REPLACE TRIGGER trg_org_public_dir_ws
AFTER INSERT OR UPDATE OF profile_slug, org_id_organization OR DELETE
    ON workspace_setting
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_public_directory.pr_delete_org(:OLD.org_id_organization);
    ELSE
        pkg_aox_public_directory.pr_sync_workspace(
            pi_org_id => :NEW.org_id_organization,
            pi_slug   => :NEW.profile_slug
        );
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_org_public_dir_pay
AFTER INSERT OR UPDATE OF refund_enforcement_level OR DELETE
    ON org_payment_settings
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pkg_aox_public_directory.pr_apply_publication_flags(
            pi_org_id            => :OLD.org_id_organization,
            pi_enforcement_level => 'NONE'
        );
    ELSE
        pkg_aox_public_directory.pr_apply_publication_flags(
            pi_org_id            => :NEW.org_id_organization,
            pi_enforcement_level => :NEW.refund_enforcement_level
        );
    END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_org_public_token_app
AFTER INSERT OR UPDATE OF public_manage_token, org_id_organization OR DELETE
    ON appointment
FOR EACH ROW
BEGIN
    -- DELETE: no tocar org_public_token aqui. El FK ON DELETE CASCADE ya
    -- borra esas filas; un DELETE extra en el trigger provoca ORA-04091
    -- (tabla mutating) y rompe el borrado de citas.
    IF DELETING THEN
        NULL;
    ELSE
        pkg_aox_public_directory.pr_sync_appointment_token(
            pi_appointment_id => :NEW.id_appointment,
            pi_org_id         => :NEW.org_id_organization,
            pi_token          => :NEW.public_manage_token
        );
    END IF;
END;
/

-- El trigger AFTER DELETE en APPOINTMENT no debe borrar ORG_PUBLIC_TOKEN:
-- el FK ON DELETE CASCADE ya lo hace, y un DELETE extra provoca ORA-04091.
-- Reaplica triggers/TRG_ORG_PUBLIC_DIRECTORY.sql (rama trg_org_public_token_app).

SET SERVEROUTPUT ON SIZE UNLIMITED

PROMPT === 20260919_aox_public_token_trigger_cascade ===

@@../triggers/TRG_ORG_PUBLIC_DIRECTORY.sql

PROMPT === 20260919_aox_public_token_trigger_cascade listo ===

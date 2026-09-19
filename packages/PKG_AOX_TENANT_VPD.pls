PROMPT CREATE OR REPLACE PACKAGE pkg_aox_tenant_vpd
CREATE OR REPLACE PACKAGE pkg_aox_tenant_vpd AS
/**
 * DBMS_RLS sobre tablas tenant A/B con fn_aox_tenant_vpd_predicate.
 * ADD_POLICY enable FALSE por defecto. Canario: CUSTOMER + APPOINTMENT.
 * Kill switch: pr_disable_all / pr_disable_canary (DISABLE_POLICY, no DROP).
 * Requiere GRANT EXECUTE ON sys.dbms_rls TO aoxdev (directo; no alcanza el rol).
 */
    c_policy_name CONSTANT VARCHAR2(30) := 'AOX_TENANT_VPD';
    c_policy_fn   CONSTANT VARCHAR2(30) := 'FN_AOX_TENANT_VPD_PREDICATE';

    -- ADD_POLICY enable FALSE si falta. No cambia el enable de las ya existentes.
    PROCEDURE pr_ensure_policies;

    -- Canario: ENABLE_POLICY solo CUSTOMER y APPOINTMENT.
    PROCEDURE pr_enable_canary;
    PROCEDURE pr_disable_canary;

    -- Kill switch: DISABLE_POLICY en todas las tablas A/B. No DROP.
    PROCEDURE pr_disable_all;

    -- Oleadas: ENABLE/DISABLE solo las tablas indicadas (taxonomia A/B).
    -- Si una oleada sangra: pr_disable_tables de esa oleada (no las anteriores).
    PROCEDURE pr_enable_tables(pi_tables IN SYS.ODCIVARCHAR2LIST);
    PROCEDURE pr_disable_tables(pi_tables IN SYS.ODCIVARCHAR2LIST);

    FUNCTION fn_child_tables RETURN SYS.ODCIVARCHAR2LIST;
    FUNCTION fn_target_count RETURN NUMBER;
    FUNCTION fn_policy_count RETURN NUMBER;
    FUNCTION fn_enabled_count RETURN NUMBER;
END pkg_aox_tenant_vpd;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_tenant_vpd
CREATE OR REPLACE PACKAGE BODY pkg_aox_tenant_vpd AS

    FUNCTION fn_target_tables RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        -- A: negocio tenant (org_id_organization NOT NULL).
        -- B: hijas denormalizadas (AI_CHAT_MESSAGE, PROFESSIONAL_IMAGE,
        --    PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT, ORG_REFUND_DISPUTE_EVIDENCE,
        --    USER_INTEGRATION).
        -- Fuera de VPD (C / publico / identidad): ORG_MEMBER, ORG_INVITATION,
        -- ORG_PUBLIC_DIRECTORY, ORG_PUBLIC_TOKEN, APP_USER_LEGACY.
        -- Sin politicas en vistas (APP_USER, V_OPS_*) ni VECTOR$*.
        RETURN SYS.ODCIVARCHAR2LIST(
            'AI_CHAT_SESSION',
            'APPOINTMENT',
            'APPOINTMENT_ATTACHMENT',
            'APPOINTMENT_SERIES',
            'APPOINTMENT_SESSION_RECORD',
            'CUSTOMER',
            'CUSTOMER_BODY_SNAPSHOT',
            'CUSTOMER_ODONTOGRAM_EVENT',
            'CUSTOMER_PHONE_AUDIT',
            'EMBEDDING_SYNC_OUTBOX',
            'LOCATION',
            'LOCATION_CLOSURE',
            'ORGANIZATION_SPECIALTY',
            'ORG_ADDON',
            'ORG_BILLING_CREDIT_LEDGER',
            'ORG_BILLING_PROFILE',
            'ORG_ENTITY_EMBEDDING',
            'ORG_GALLERY_IMAGE',
            'ORG_INTEGRATION',
            'ORG_PAYMENT_CARD',
            'ORG_PAYMENT_SETTINGS',
            'ORG_REFUND_CLAIM',
            'ORG_REFUND_DISPUTE',
            'ORG_REFUND_DISPUTE_COMPENSATION',
            'ORG_REFUND_DISPUTE_LEDGER',
            'ORG_REFUND_ENFORCEMENT_AUDIT',
            'ORG_REFUND_NOTIFY_OUTBOX',
            'ORG_REFUND_STRIKE',
            'ORG_ROLE_CAPABILITY',
            'ORG_STORAGE_ADDON',
            'ORG_SUBSCRIPTION',
            'ORG_SUBSCRIPTION_ACCESS_AUDIT',
            'ORG_SUBSCRIPTION_INVOICE',
            'PAYMENT_TRANSACTION',
            'PROFESSIONAL',
            'PROFESSIONAL_SCHEDULE',
            'PROFESSIONAL_SCHEDULE_EXCEPTION',
            'PROFESSIONAL_SERVICE',
            'SERVICE',
            'SPECIALTY',
            'SUBSCRIPTION_CREDIT_NOTE',
            'SUBSCRIPTION_EINVOICE_OUTBOX',
            'USER_NOTIFICATION',
            'WORKSPACE_SETTING',
            'AI_CHAT_MESSAGE',
            'ORG_REFUND_DISPUTE_EVIDENCE',
            'PROFESSIONAL_IMAGE',
            'PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT',
            'USER_INTEGRATION'
        );
    END fn_target_tables;

    FUNCTION fn_excluded_tables RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'APP_USER_LEGACY',
            'ORG_INVITATION',
            'ORG_MEMBER',
            'ORG_PUBLIC_DIRECTORY',
            'ORG_PUBLIC_TOKEN'
        );
    END fn_excluded_tables;

    FUNCTION fn_list_contains(
        pi_list IN SYS.ODCIVARCHAR2LIST,
        pi_name IN VARCHAR2
    ) RETURN BOOLEAN IS
    BEGIN
        IF pi_list IS NULL THEN
            RETURN FALSE;
        END IF;
        FOR i IN 1 .. pi_list.COUNT LOOP
            IF pi_list(i) = pi_name THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END fn_list_contains;

    PROCEDURE pr_assert_taxonomy IS
        v_targets   SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_excluded  SYS.ODCIVARCHAR2LIST := fn_excluded_tables;
        v_table     VARCHAR2(128);
        v_exists    NUMBER;
        v_nullable  VARCHAR2(1);
        v_drift     VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. v_targets.COUNT LOOP
            v_table := v_targets(i);
            SELECT COUNT(*)
              INTO v_exists
              FROM user_tables
             WHERE table_name = v_table;
            IF v_exists = 0 THEN
                RAISE_APPLICATION_ERROR(
                    -20000,
                    'VPD: falta tabla tenant ' || v_table
                );
            END IF;

            BEGIN
                SELECT nullable
                  INTO v_nullable
                  FROM user_tab_columns
                 WHERE table_name = v_table
                   AND column_name = 'ORG_ID_ORGANIZATION';
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(
                        -20000,
                        'VPD: ' || v_table || ' no tiene org_id_organization'
                    );
            END;
            IF v_nullable <> 'N' THEN
                RAISE_APPLICATION_ERROR(
                    -20000,
                    'VPD: ' || v_table || '.org_id_organization debe ser NOT NULL'
                );
            END IF;
        END LOOP;

        v_drift := NULL;
        FOR rec IN (
            SELECT t.table_name
              FROM user_tables t
              JOIN user_tab_columns c
                ON c.table_name = t.table_name
               AND c.column_name = 'ORG_ID_ORGANIZATION'
             ORDER BY t.table_name
        ) LOOP
            IF NOT fn_list_contains(v_targets, rec.table_name)
               AND NOT fn_list_contains(v_excluded, rec.table_name) THEN
                v_drift := CASE
                               WHEN v_drift IS NULL THEN rec.table_name
                               ELSE v_drift || ',' || rec.table_name
                           END;
            END IF;
        END LOOP;
        IF v_drift IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(
                -20000,
                'VPD: tablas con org_id fuera de taxonomia A/B/C: ' || v_drift
            );
        END IF;
    END pr_assert_taxonomy;

    PROCEDURE pr_add_policy(pi_table IN VARCHAR2) IS
    BEGIN
        SYS.DBMS_RLS.ADD_POLICY(
            object_schema   => USER,
            object_name     => pi_table,
            policy_name     => c_policy_name,
            function_schema => USER,
            policy_function => c_policy_fn,
            statement_types => 'SELECT,INSERT,UPDATE,DELETE',
            update_check    => TRUE,
            enable          => FALSE,
            policy_type     => SYS.DBMS_RLS.DYNAMIC
        );
        DBMS_OUTPUT.PUT_LINE('ADD_POLICY enable=FALSE ' || pi_table);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -1031 THEN
                RAISE_APPLICATION_ERROR(
                    -20000,
                    'VPD ADD_POLICY ORA-01031 en ' || pi_table
                    || '. Repetir como ADMIN: GRANT EXECUTE ON sys.dbms_rls TO aoxdev'
                );
            END IF;
            RAISE;
    END pr_add_policy;

    PROCEDURE pr_ensure_policies IS
        v_targets SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_table   VARCHAR2(128);
        v_exists  NUMBER;
        v_fn      VARCHAR2(128);
    BEGIN
        pr_assert_taxonomy;

        FOR i IN 1 .. v_targets.COUNT LOOP
            v_table := v_targets(i);
            SELECT COUNT(*)
              INTO v_exists
              FROM user_policies
             WHERE object_name = v_table
               AND policy_name = c_policy_name;

            IF v_exists = 0 THEN
                pr_add_policy(v_table);
            ELSE
                SELECT p."FUNCTION"
                  INTO v_fn
                  FROM user_policies p
                 WHERE p.object_name = v_table
                   AND p.policy_name = c_policy_name
                   AND ROWNUM = 1;
                IF UPPER(v_fn) <> c_policy_fn THEN
                    SYS.DBMS_RLS.DROP_POLICY(
                        object_schema => USER,
                        object_name   => v_table,
                        policy_name   => c_policy_name
                    );
                    pr_add_policy(v_table);
                ELSE
                    DBMS_OUTPUT.PUT_LINE('POLICY OK ' || v_table);
                END IF;
            END IF;
        END LOOP;
    END pr_ensure_policies;

    FUNCTION fn_canary_tables RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST('CUSTOMER', 'APPOINTMENT');
    END fn_canary_tables;

    FUNCTION fn_child_tables RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'AI_CHAT_MESSAGE',
            'ORG_REFUND_DISPUTE_EVIDENCE',
            'PROFESSIONAL_IMAGE',
            'PROFESSIONAL_SCHEDULE_EXCEPTION_SLOT',
            'USER_INTEGRATION'
        );
    END fn_child_tables;

    PROCEDURE pr_set_policy_enable(
        pi_table  IN VARCHAR2,
        pi_enable IN BOOLEAN
    ) IS
        v_exists NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_exists
          FROM user_policies
         WHERE object_name = pi_table
           AND policy_name = c_policy_name;
        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(
                -20000,
                'VPD: no hay policy ' || c_policy_name || ' en ' || pi_table
            );
        END IF;
        SYS.DBMS_RLS.ENABLE_POLICY(
            object_schema => USER,
            object_name   => pi_table,
            policy_name   => c_policy_name,
            enable        => pi_enable
        );
        DBMS_OUTPUT.PUT_LINE(
            CASE WHEN pi_enable THEN 'ENABLE_POLICY ' ELSE 'DISABLE_POLICY ' END
            || pi_table
        );
    END pr_set_policy_enable;

    PROCEDURE pr_enable_canary IS
        v_tabs SYS.ODCIVARCHAR2LIST := fn_canary_tables;
    BEGIN
        pr_ensure_policies;
        FOR i IN 1 .. v_tabs.COUNT LOOP
            pr_set_policy_enable(v_tabs(i), TRUE);
        END LOOP;
    END pr_enable_canary;

    PROCEDURE pr_disable_canary IS
        v_tabs SYS.ODCIVARCHAR2LIST := fn_canary_tables;
    BEGIN
        FOR i IN 1 .. v_tabs.COUNT LOOP
            BEGIN
                pr_set_policy_enable(v_tabs(i), FALSE);
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE(
                        'SKIP DISABLE canary ' || v_tabs(i) || ': ' || SQLERRM
                    );
            END;
        END LOOP;
    END pr_disable_canary;

    PROCEDURE pr_enable_tables(pi_tables IN SYS.ODCIVARCHAR2LIST) IS
        v_targets SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_table   VARCHAR2(128);
    BEGIN
        IF pi_tables IS NULL OR pi_tables.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20000, 'VPD: pr_enable_tables sin tablas');
        END IF;
        pr_ensure_policies;
        FOR i IN 1 .. pi_tables.COUNT LOOP
            v_table := UPPER(TRIM(pi_tables(i)));
            IF NOT fn_list_contains(v_targets, v_table) THEN
                RAISE_APPLICATION_ERROR(
                    -20000,
                    'VPD: ' || v_table || ' no esta en taxonomia A/B'
                );
            END IF;
            pr_set_policy_enable(v_table, TRUE);
        END LOOP;
    END pr_enable_tables;

    PROCEDURE pr_disable_tables(pi_tables IN SYS.ODCIVARCHAR2LIST) IS
        v_table VARCHAR2(128);
    BEGIN
        IF pi_tables IS NULL OR pi_tables.COUNT = 0 THEN
            RETURN;
        END IF;
        FOR i IN 1 .. pi_tables.COUNT LOOP
            v_table := UPPER(TRIM(pi_tables(i)));
            BEGIN
                pr_set_policy_enable(v_table, FALSE);
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE(
                        'SKIP DISABLE ' || v_table || ': ' || SQLERRM
                    );
            END;
        END LOOP;
    END pr_disable_tables;

    PROCEDURE pr_disable_all IS
        v_targets SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_table   VARCHAR2(128);
        v_exists  NUMBER;
    BEGIN
        FOR i IN 1 .. v_targets.COUNT LOOP
            v_table := v_targets(i);
            SELECT COUNT(*)
              INTO v_exists
              FROM user_policies
             WHERE object_name = v_table
               AND policy_name = c_policy_name;
            IF v_exists = 0 THEN
                DBMS_OUTPUT.PUT_LINE('SKIP DISABLE (sin policy) ' || v_table);
                CONTINUE;
            END IF;
            SYS.DBMS_RLS.ENABLE_POLICY(
                object_schema => USER,
                object_name   => v_table,
                policy_name   => c_policy_name,
                enable        => FALSE
            );
            DBMS_OUTPUT.PUT_LINE('DISABLE_POLICY ' || v_table);
        END LOOP;
    END pr_disable_all;

    FUNCTION fn_target_count RETURN NUMBER IS
        v_tabs SYS.ODCIVARCHAR2LIST := fn_target_tables;
    BEGIN
        RETURN v_tabs.COUNT;
    END fn_target_count;

    FUNCTION fn_policy_count RETURN NUMBER IS
        v_targets SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_cnt     NUMBER := 0;
        v_one     NUMBER;
    BEGIN
        FOR i IN 1 .. v_targets.COUNT LOOP
            SELECT COUNT(*)
              INTO v_one
              FROM user_policies
             WHERE object_name = v_targets(i)
               AND policy_name = c_policy_name;
            v_cnt := v_cnt + v_one;
        END LOOP;
        RETURN v_cnt;
    END fn_policy_count;

    FUNCTION fn_enabled_count RETURN NUMBER IS
        v_targets SYS.ODCIVARCHAR2LIST := fn_target_tables;
        v_cnt     NUMBER := 0;
        v_one     NUMBER;
    BEGIN
        FOR i IN 1 .. v_targets.COUNT LOOP
            SELECT COUNT(*)
              INTO v_one
              FROM user_policies p
             WHERE p.object_name = v_targets(i)
               AND p.policy_name = c_policy_name
               AND p."ENABLE" = 'YES';
            v_cnt := v_cnt + v_one;
        END LOOP;
        RETURN v_cnt;
    END fn_enabled_count;

END pkg_aox_tenant_vpd;
/

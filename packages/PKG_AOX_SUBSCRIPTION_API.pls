PROMPT CREATE OR REPLACE PACKAGE pkg_aox_subscription_api
CREATE OR REPLACE PACKAGE pkg_aox_subscription_api IS
/**
 * API de suscripción (Fase 2).
 * Fuente de verdad de entitlements, estado de facturación y límite de storage.
 * El enforcement se hace en backend, no solo con flags del frontend.
 */

    -- Días de prueba y de gracia (producto: 14 días trial, 3 días gracia PAST_DUE)
    c_trial_days CONSTANT NUMBER := 14;
    c_grace_days CONSTANT NUMBER := 3;

    -- Id del plan Premium (el trial otorga Premium)
    c_plan_id_premium CONSTANT NUMBER := 2;
    c_plan_id_base    CONSTANT NUMBER := 1;

    /** ¿La organización tiene habilitado un feature por su plan actual? (1/0). */
    FUNCTION fn_org_has_feature(
        pi_org_id       IN NUMBER,
        pi_feature_code IN VARCHAR2
    ) RETURN NUMBER;

    /**
     * Estado efectivo de la suscripción, calculado en el momento:
     * TRIAL, TRIAL_EXPIRED, ACTIVE, PAST_DUE, READ_ONLY, CANCELED, FOUNDER, NONE.
     */
    FUNCTION fn_get_subscription_state(
        pi_org_id IN NUMBER
    ) RETURN VARCHAR2;

    /** Límite total de storage en bytes = plan + addons activos. */
    FUNCTION fn_get_storage_limit_bytes(
        pi_org_id IN NUMBER
    ) RETURN NUMBER;

    /** ¿El estado efectivo permite escritura? (1/0). */
    FUNCTION fn_org_can_write(
        pi_org_id IN NUMBER
    ) RETURN NUMBER;

    /** Lanza error 403 si la organización no puede escribir (READ_ONLY / vencido). */
    PROCEDURE fn_assert_org_can_write(
        pi_org_id IN NUMBER
    );

    /** Lanza error 403 si el plan actual de la organización no incluye el feature. */
    PROCEDURE pr_assert_org_has_feature(
        pi_org_id       IN NUMBER,
        pi_feature_code IN VARCHAR2
    );

    /**
     * Lanza error (cartel de mantenimiento) si la reserva pública debe estar
     * cerrada por estado de suscripción (READ_ONLY / vencido / cancelado).
     */
    PROCEDURE pr_assert_public_booking_open(
        pi_org_id IN NUMBER
    );

    /**
     * Crea la suscripción TRIAL (Premium, 14 días) para la organización si no existe.
     * No hace COMMIT: se ejecuta dentro de la transacción del llamador (ej. registro).
     */
    PROCEDURE pr_ensure_trial_subscription(
        pi_org_id IN NUMBER
    );

    -- GET /workspace/subscription
    PROCEDURE pr_get_subscription(
        pi_auth_header   IN  VARCHAR2,
        po_status_code   OUT NUMBER,
        po_response_body OUT CLOB
    );

END pkg_aox_subscription_api;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_api
CREATE OR REPLACE PACKAGE BODY pkg_aox_subscription_api IS

    c_iso_fmt CONSTANT VARCHAR2(40) := 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM';

    function fn_ts_to_iso(
        pi_ts in timestamp with time zone
    ) return varchar2 is
    begin
        if pi_ts is null then
            return null;
        end if;
        return to_char(pi_ts, c_iso_fmt);
    end fn_ts_to_iso;

    function fn_org_has_feature(
        pi_org_id       in number,
        pi_feature_code in varchar2
    ) return number is
        v_count number;
    begin
        if nvl(pi_org_id, 0) <= 0 or pi_feature_code is null then
            return 0;
        end if;

        select count(*)
          into v_count
          from org_subscription s
          join ref_plan_feature f
            on f.pln_id_plan = s.pln_id_plan
         where s.org_id_organization = pi_org_id
           and f.feature_code = upper(trim(pi_feature_code))
           and f.is_enabled = 1;

        return case when v_count > 0 then 1 else 0 end;
    exception
        when no_data_found then
            return 0;
    end fn_org_has_feature;

    function fn_get_subscription_state(
        pi_org_id in number
    ) return varchar2 is
        v_status         org_subscription.status%type;
        v_is_founder     org_subscription.is_founder%type;
        v_billing_exempt org_subscription.billing_exempt%type;
        v_trial_ends_at  org_subscription.trial_ends_at%type;
        v_period_end     org_subscription.current_period_end%type;
        v_grace_ends_at  org_subscription.grace_ends_at%type;
        v_now            timestamp with time zone := systimestamp;
        v_grace          timestamp with time zone;
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return 'NONE';
        end if;

        select status,
               is_founder,
               billing_exempt,
               trial_ends_at,
               current_period_end,
               grace_ends_at
          into v_status,
               v_is_founder,
               v_billing_exempt,
               v_trial_ends_at,
               v_period_end,
               v_grace_ends_at
          from org_subscription
         where org_id_organization = pi_org_id;

        -- Founders / exentos de facturación: siempre activos
        if nvl(v_is_founder, 0) = 1 or nvl(v_billing_exempt, 0) = 1 or v_status = 'FOUNDER' then
            return 'FOUNDER';
        end if;

        if v_status = 'TRIAL' then
            if v_trial_ends_at is null or v_now <= v_trial_ends_at then
                return 'TRIAL';
            end if;
            return 'TRIAL_EXPIRED';
        elsif v_status = 'ACTIVE' then
            if v_period_end is null or v_now <= v_period_end then
                return 'ACTIVE';
            end if;
            v_grace := nvl(v_grace_ends_at, v_period_end + numtodsinterval(c_grace_days, 'DAY'));
            if v_now <= v_grace then
                return 'PAST_DUE';
            end if;
            return 'READ_ONLY';
        elsif v_status = 'PAST_DUE' then
            v_grace := nvl(v_grace_ends_at, nvl(v_period_end, v_now) + numtodsinterval(c_grace_days, 'DAY'));
            if v_now <= v_grace then
                return 'PAST_DUE';
            end if;
            return 'READ_ONLY';
        elsif v_status = 'READ_ONLY' then
            return 'READ_ONLY';
        elsif v_status = 'CANCELED' then
            return 'CANCELED';
        end if;

        return v_status;
    exception
        when no_data_found then
            return 'NONE';
    end fn_get_subscription_state;

    function fn_get_storage_limit_bytes(
        pi_org_id in number
    ) return number is
        v_plan_bytes  number := 0;
        v_addon_bytes number := 0;
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return 0;
        end if;

        select nvl(p.storage_limit_bytes, 0)
          into v_plan_bytes
          from org_subscription s
          join ref_plan p
            on p.id_plan = s.pln_id_plan
         where s.org_id_organization = pi_org_id;

        select nvl(sum(a.extra_bytes * nvl(osa.quantity, 1)), 0)
          into v_addon_bytes
          from org_storage_addon osa
          join ref_storage_addon a
            on a.id_storage_addon = osa.sad_id_storage_addon
         where osa.org_id_organization = pi_org_id
           and osa.status = 'ACTIVE';

        return nvl(v_plan_bytes, 0) + nvl(v_addon_bytes, 0);
    exception
        when no_data_found then
            return 0;
    end fn_get_storage_limit_bytes;

    function fn_org_can_write(
        pi_org_id in number
    ) return number is
        v_state varchar2(20) := fn_get_subscription_state(pi_org_id);
    begin
        return case
            when v_state in ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') then 0
            else 1
        end;
    end fn_org_can_write;

    procedure fn_assert_org_can_write(
        pi_org_id in number
    ) is
        v_state      varchar2(20) := fn_get_subscription_state(pi_org_id);
        v_plan_code  varchar2(30);
        v_canceled   timestamp with time zone;
    begin
        if v_state in ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') then
            begin
                select p.code, s.canceled_at
                  into v_plan_code, v_canceled
                  from org_subscription s
                  join ref_plan p on p.id_plan = s.pln_id_plan
                 where s.org_id_organization = pi_org_id;
            exception
                when no_data_found then
                    v_plan_code := null;
                    v_canceled  := null;
            end;

            if v_plan_code = 'FREE' or v_canceled is not null then
                raise_application_error(
                    pkg_aox_util.c_sqlcode_forbidden,
                    'Tu cuenta está en solo lectura. Renová tu plan para seguir agendando.'
                );
            end if;

            raise_application_error(
                pkg_aox_util.c_sqlcode_forbidden,
                'Tu suscripción no permite esta acción (estado ' || v_state ||
                '). Regularizá el pago para volver a habilitar la escritura.'
            );
        end if;
    end fn_assert_org_can_write;

    procedure pr_assert_org_has_feature(
        pi_org_id       in number,
        pi_feature_code in varchar2
    ) is
    begin
        if fn_org_has_feature(pi_org_id, pi_feature_code) = 0 then
            raise_application_error(
                pkg_aox_util.c_sqlcode_forbidden,
                'Esta funcionalidad no está incluida en tu plan actual. ' ||
                'Actualizá a Premium para habilitarla.'
            );
        end if;
    end pr_assert_org_has_feature;

    procedure pr_assert_public_booking_open(
        pi_org_id in number
    ) is
        v_state varchar2(20) := fn_get_subscription_state(pi_org_id);
    begin
        if v_state in ('READ_ONLY', 'CANCELED', 'TRIAL_EXPIRED') then
            raise_application_error(
                pkg_aox_util.c_sqlcode_forbidden,
                'La agenda online no está disponible en este momento por mantenimiento. ' ||
                'Por favor, contactá directamente al local para reservar tu turno.'
            );
        end if;
    end pr_assert_public_booking_open;

    procedure pr_ensure_trial_subscription(
        pi_org_id in number
    ) is
    begin
        if nvl(pi_org_id, 0) <= 0 then
            return;
        end if;

        insert /*+ no_parallel */ into org_subscription (
            org_id_organization,
            pln_id_plan,
            status,
            is_founder,
            billing_exempt,
            storage_used_bytes,
            storage_limit_bytes,
            trial_started_at,
            trial_ends_at
        )
        select /*+ no_parallel */ pi_org_id,
               c_plan_id_premium,
               'TRIAL',
               0,
               0,
               0,
               (select storage_limit_bytes from ref_plan where id_plan = c_plan_id_premium),
               systimestamp,
               systimestamp + numtodsinterval(c_trial_days, 'DAY')
          from dual
         where not exists (
                 select 1
                   from org_subscription s
                  where s.org_id_organization = pi_org_id
               );
    end pr_ensure_trial_subscription;

    procedure pr_put_features(
        pi_plan_id in number,
        po_data    in out nocopy json_object_t
    ) is
        v_features json_array_t := json_array_t();
    begin
        for rec in (
            select feature_code
              from ref_plan_feature
             where pln_id_plan = pi_plan_id
               and is_enabled = 1
             order by feature_code
        ) loop
            v_features.append(rec.feature_code);
        end loop;

        po_data.put('features', v_features);
    end pr_put_features;

    -- GET /workspace/subscription
    procedure pr_get_subscription(
        pi_auth_header   in  varchar2,
        po_status_code   out number,
        po_response_body out clob
    ) is
        v_org_id            number;

        v_plan_id           ref_plan.id_plan%type;
        v_plan_code         ref_plan.code%type;
        v_plan_name         ref_plan.name%type;
        v_plan_price        ref_plan.price_amount%type;
        v_plan_currency     ref_plan.currency%type;
        v_plan_period       ref_plan.billing_period%type;

        v_status            org_subscription.status%type;
        v_is_founder        org_subscription.is_founder%type;
        v_billing_exempt    org_subscription.billing_exempt%type;
        v_storage_used      org_subscription.storage_used_bytes%type;
        v_trial_ends_at     org_subscription.trial_ends_at%type;
        v_period_start      org_subscription.current_period_start%type;
        v_period_end        org_subscription.current_period_end%type;
        v_grace_ends_at     org_subscription.grace_ends_at%type;
        v_canceled_at       org_subscription.canceled_at%type;
        v_auto_renew        org_subscription.auto_renew%type;

        v_effective_state   varchar2(20);
        v_storage_limit     number;

        v_response_json     json_object_t := json_object_t();
        v_data              json_object_t := json_object_t();
        v_sub_obj           json_object_t := json_object_t();
        v_plan_obj          json_object_t := json_object_t();
        v_storage_obj       json_object_t := json_object_t();
    begin
        v_org_id := pkg_aox_util.fn_get_org_id_from_jwt(pi_auth_header);

        if nvl(v_org_id, 0) <= 0 then
            raise_application_error(pkg_aox_util.c_sqlcode_session, 'Token inválido o sin organización asociada.');
        end if;

        select
            s.pln_id_plan,
            p.code,
            p.name,
            p.price_amount,
            p.currency,
            p.billing_period,
            s.status,
            s.is_founder,
            s.billing_exempt,
            s.storage_used_bytes,
            s.trial_ends_at,
            s.current_period_start,
            s.current_period_end,
            s.grace_ends_at,
            s.canceled_at,
            nvl(s.auto_renew, 1)
        into
            v_plan_id,
            v_plan_code,
            v_plan_name,
            v_plan_price,
            v_plan_currency,
            v_plan_period,
            v_status,
            v_is_founder,
            v_billing_exempt,
            v_storage_used,
            v_trial_ends_at,
            v_period_start,
            v_period_end,
            v_grace_ends_at,
            v_canceled_at,
            v_auto_renew
        from org_subscription s
        join ref_plan p
            on p.id_plan = s.pln_id_plan
        where s.org_id_organization = v_org_id;

        v_effective_state := fn_get_subscription_state(v_org_id);
        v_storage_limit   := fn_get_storage_limit_bytes(v_org_id);

        -- Suscripción
        v_sub_obj.put('status'              , v_status);
        v_sub_obj.put('effective_status'    , v_effective_state);
        v_sub_obj.put('can_write'           , fn_org_can_write(v_org_id));
        v_sub_obj.put('is_founder'          , v_is_founder);
        v_sub_obj.put('billing_exempt'      , v_billing_exempt);
        v_sub_obj.put('trial_ends_at'       , fn_ts_to_iso(v_trial_ends_at));
        v_sub_obj.put('current_period_start', fn_ts_to_iso(v_period_start));
        v_sub_obj.put('current_period_end'  , fn_ts_to_iso(v_period_end));
        v_sub_obj.put('grace_ends_at'       , fn_ts_to_iso(v_grace_ends_at));
        v_sub_obj.put('canceled_at'         , fn_ts_to_iso(v_canceled_at));
        v_sub_obj.put('auto_renew'          , v_auto_renew);

        -- Plan
        v_plan_obj.put('code'          , v_plan_code);
        v_plan_obj.put('name'          , v_plan_name);
        v_plan_obj.put('price_amount'  , v_plan_price);
        v_plan_obj.put('currency'      , v_plan_currency);
        v_plan_obj.put('billing_period', v_plan_period);

        -- Storage
        v_storage_obj.put('used_bytes' , v_storage_used);
        v_storage_obj.put('limit_bytes', v_storage_limit);

        v_data.put('subscription', v_sub_obj);
        v_data.put('plan'        , v_plan_obj);
        v_data.put('storage'     , v_storage_obj);
        pr_put_features(v_plan_id, v_data);

        po_status_code := pkg_aox_util.c_success_ok_code;
        v_response_json.put('status', 'success');
        v_response_json.put('data'  , v_data);
        po_response_body := v_response_json.to_clob();

    exception
        when no_data_found then
            po_status_code := pkg_aox_util.c_not_found_code;
            pkg_aox_util.pr_build_api_error_response(
                pi_status_code   => po_status_code,
                pi_api_code      => pkg_aox_util.c_api_code_not_found,
                pi_message       => 'No se encontró suscripción para la organización.',
                po_response_body => po_response_body
            );

        when others then
            pkg_aox_util.pr_handle_api_exception(po_status_code, po_response_body);
    end pr_get_subscription;

END pkg_aox_subscription_api;
/

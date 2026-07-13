PROMPT CREATE OR REPLACE PACKAGE pkg_aox_ai_agent_setup
CREATE OR REPLACE PACKAGE pkg_aox_ai_agent_setup IS
    PROCEDURE pr_install(
        pi_profile_name IN VARCHAR2 DEFAULT 'HASEL_AI_PROFILE'
    );
END pkg_aox_ai_agent_setup;
/

PROMPT CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_agent_setup
CREATE OR REPLACE PACKAGE BODY pkg_aox_ai_agent_setup IS
    c_agent_name CONSTANT VARCHAR2(125) := 'HASEL_AGENDA_AGENT';
    c_task_name  CONSTANT VARCHAR2(125) := 'HASEL_AGENDA_TASK';

    FUNCTION fn_team_name RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(fn_get_parameter('HASEL_AI_TEAM_NAME'), 'HASEL_AGENDA_TEAM');
    END fn_team_name;

    PROCEDURE pr_drop_if_exists IS
    BEGIN
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM(fn_team_name); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK(c_task_name, TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_AGENT(c_agent_name); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_CANCEL_APPOINTMENT', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_CREATE_APPOINTMENT', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_FIND_AVAILABILITY', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_LIST_LOCATIONS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_LIST_SERVICES', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_LIST_PROFESSIONALS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_LIST_NEXT_APPOINTMENTS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
        BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('AOX_LIST_APPOINTMENTS', TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
    END pr_drop_if_exists;

    PROCEDURE pr_create_tools IS
    BEGIN
        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_LIST_APPOINTMENTS',
            attributes  => q'~{
                "instruction": "Lista citas de la organizacion actual filtrando por fecha. Convertir SIEMPRE expresiones humanas (hoy, 20 de mayo, el lunes, etc) a YYYY-MM-DD usando la fecha local actual del task. Si el usuario menciona solo una fecha, usar pi_start_date=ESA_FECHA. Si menciona un rango o un mes, completar pi_end_date. Si la primera llamada no devuelve resultados pero el usuario insiste en una fecha cercana, reintentar con un rango pequeno (+/- 1 dia) antes de afirmar que no hay citas. Si el usuario es profesional, el filtro de agenda se aplica automaticamente.",
                "function": "PKG_AOX_AI_TOOLS.FN_LIST_APPOINTMENTS",
                "tool_inputs": [
                    {"name": "pi_start_date", "description": "Fecha inicial obligatoria en formato YYYY-MM-DD."},
                    {"name": "pi_end_date", "description": "Fecha final opcional en formato YYYY-MM-DD. Si falta, se consulta solo pi_start_date."},
                    {"name": "pi_professional_id", "description": "ID de profesional opcional para admin o recepcion."},
                    {"name": "pi_status", "description": "Estado opcional: PENDIENTE, CONFIRMADO, COMPLETADO o CANCELADO."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Lista citas segun rol y organizacion actual.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_LIST_NEXT_APPOINTMENTS',
            attributes  => q'~{
                "instruction": "Lista las proximas citas desde la fecha local actual calculada por la base de datos. Usa esta herramienta para preguntas como proximos dias, proximas citas, semana o siguientes 7 dias. Si el usuario es profesional, la herramienta limita automaticamente a su agenda.",
                "function": "PKG_AOX_AI_TOOLS.FN_LIST_NEXT_APPOINTMENTS",
                "tool_inputs": [
                    {"name": "pi_days", "description": "Cantidad de dias a consultar desde hoy. Por defecto 7. Maximo recomendado 31."},
                    {"name": "pi_professional_id", "description": "ID de profesional opcional para admin o recepcion."},
                    {"name": "pi_status", "description": "Estado opcional: PENDIENTE, CONFIRMADO, COMPLETADO o CANCELADO."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Lista proximas citas desde hoy.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_LIST_PROFESSIONALS',
            attributes  => q'~{
                "instruction": "Lista profesionales activos disponibles para la organizacion actual. Si el usuario es profesional, devuelve solo su propio perfil.",
                "function": "PKG_AOX_AI_TOOLS.FN_LIST_PROFESSIONALS",
                "tool_inputs": [
                    {"name": "pi_query", "description": "Texto opcional para buscar por nombre o telefono."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Lista profesionales activos.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_LIST_SERVICES',
            attributes  => q'~{
                "instruction": "Lista servicios activos de la organizacion actual con duracion y precio.",
                "function": "PKG_AOX_AI_TOOLS.FN_LIST_SERVICES",
                "tool_inputs": [
                    {"name": "pi_query", "description": "Texto opcional para buscar servicio por nombre."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Lista servicios activos.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_LIST_LOCATIONS',
            attributes  => q'~{
                "instruction": "Lista locales o sucursales activos de la organizacion actual.",
                "function": "PKG_AOX_AI_TOOLS.FN_LIST_LOCATIONS",
                "tool_inputs": [
                    {"name": "pi_query", "description": "Texto opcional para buscar por nombre o direccion."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Lista locales activos.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_FIND_AVAILABILITY',
            attributes  => q'~{
                "instruction": "Busca horarios disponibles para un servicio, profesional, local y fecha. No inventes ids: si faltan, primero lista profesionales o servicios y pregunta al usuario.",
                "function": "PKG_AOX_AI_TOOLS.FN_FIND_AVAILABILITY",
                "tool_inputs": [
                    {"name": "pi_target_date", "description": "Fecha a consultar en formato YYYY-MM-DD."},
                    {"name": "pi_service_id", "description": "ID del servicio."},
                    {"name": "pi_location_id", "description": "ID del local o sucursal."},
                    {"name": "pi_professional_id", "description": "ID del profesional. Opcional solo si el usuario autenticado es profesional."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Busca disponibilidad de agenda.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_CREATE_APPOINTMENT',
            attributes  => q'~{
                "instruction": "Crea una cita confirmada. Solo usala cuando el usuario ya haya dado cliente, telefono, servicio, profesional, local y fecha/hora exacta. La herramienta valida rol, organizacion, profesional, servicio, local y solapamientos.",
                "function": "PKG_AOX_AI_TOOLS.FN_CREATE_APPOINTMENT",
                "tool_inputs": [
                    {"name": "pi_customer_name", "description": "Nombre completo del cliente."},
                    {"name": "pi_customer_phone", "description": "Telefono del cliente."},
                    {"name": "pi_service_id", "description": "ID del servicio."},
                    {"name": "pi_location_id", "description": "ID del local o sucursal."},
                    {"name": "pi_start_time", "description": "Inicio en formato YYYY-MM-DDTHH24:MI:SS."},
                    {"name": "pi_professional_id", "description": "ID del profesional. Opcional solo si el usuario autenticado es profesional."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Crea citas de forma segura.'
        );

        DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
            tool_name   => 'AOX_CANCEL_APPOINTMENT',
            attributes  => q'~{
                "instruction": "Cancela una cita cambiando su estado a CANCELADO. Antes de llamar esta tool DEBES tener un pi_appointment_id real obtenido desde AOX_LIST_APPOINTMENTS o desde una conversacion previa del mismo chat. Nunca afirmes que no hay citas sin antes haber llamado a AOX_LIST_APPOINTMENTS con la fecha mencionada por el usuario. Mostrale la cita encontrada al usuario y pedile confirmacion explicita. Solo ejecuta la cancelacion cuando el usuario confirme claramente.",
                "function": "PKG_AOX_AI_TOOLS.FN_CANCEL_APPOINTMENT",
                "tool_inputs": [
                    {"name": "pi_appointment_id", "description": "ID de la cita a cancelar."},
                    {"name": "pi_confirm_cancel", "description": "Debe ser SI cuando el usuario confirma la cancelacion."}
                ]
            }~',
            status      => 'ENABLED',
            description => 'Cancela citas con confirmacion.'
        );
    END pr_create_tools;

    PROCEDURE pr_install(
        pi_profile_name IN VARCHAR2 DEFAULT 'HASEL_AI_PROFILE'
    ) IS
        v_agent_attrs CLOB;
        v_task_attrs  CLOB;
        v_team_attrs  CLOB;
    BEGIN
        pr_drop_if_exists;
        pr_create_tools;

        v_agent_attrs := '{"profile_name": "' || pi_profile_name || '", ' ||
            '"enable_human_tool": "True", ' ||
            '"role": "Sos Hasel, asistente operativo de agenda y reservas. Responde en espanol claro, breve y directo. Nunca inventes datos ni ids: si dudas, primero llama a una tool. La fecha local actual es {current_date} y la hora local es {current_time} en zona horaria {timezone}; usalas para interpretar expresiones como hoy, mañana, esta semana, este mes o nombres de meses. No pidas ni aceptes org_id, user_id o role_id del usuario porque la base ya valida el contexto seguro. Mantene memoria de la conversacion: si en el turno anterior listaste citas y el usuario hace referencia a una de ellas, reutiliza esos ids en lugar de volver a pedir datos."}';

        DBMS_CLOUD_AI_AGENT.CREATE_AGENT(
            agent_name  => c_agent_name,
            attributes  => v_agent_attrs,
            status      => 'ENABLED',
            description => 'Agente de agenda Hasel para Bookmate/AOX.'
        );

        v_task_attrs := q'~{
            "instruction": "Atende la solicitud del usuario: {query}. Fecha local actual: {current_date}. Hora local actual: {current_time}. Zona horaria: {timezone}. Reglas: 1) Antes de afirmar que algo no existe (citas, clientes, servicios) llama siempre a la tool correspondiente con los filtros correctos. 2) Para hoy usa AOX_LIST_APPOINTMENTS con pi_start_date={current_date}. Para proximos dias, proxima semana, siguientes 7 dias usa AOX_LIST_NEXT_APPOINTMENTS. Para fechas explicitas o nombres de mes calcula la fecha en formato YYYY-MM-DD usando {current_date} como referencia y llama a AOX_LIST_APPOINTMENTS. 3) Cuando el usuario diga frases como 'la cita del X de Y', 'cancela la del Z', identifica primero la cita con AOX_LIST_APPOINTMENTS y captura su id_appointment. 4) Para cancelar, primero muestra brevemente la cita encontrada y pide confirmacion explicita; solo llama AOX_CANCEL_APPOINTMENT con pi_confirm_cancel=SI cuando el usuario confirme. Si no encontras la cita por la fecha indicada, intenta tambien un rango de +/- 1 dia antes de decir que no existe. 5) Para crear citas, si falta cliente, telefono, servicio, profesional, local o fecha/hora exacta, pregunta primero. Para los ids usa AOX_LIST_PROFESSIONALS, AOX_LIST_SERVICES o AOX_LIST_LOCATIONS. 6) Mantene memoria de los ids ya mostrados al usuario en turnos anteriores. 7) Responde en espanol, tono profesional y breve, sin exponer JSON salvo que el usuario lo pida.",
            "tools": [
                "AOX_LIST_APPOINTMENTS",
                "AOX_LIST_NEXT_APPOINTMENTS",
                "AOX_LIST_PROFESSIONALS",
                "AOX_LIST_SERVICES",
                "AOX_LIST_LOCATIONS",
                "AOX_FIND_AVAILABILITY",
                "AOX_CREATE_APPOINTMENT",
                "AOX_CANCEL_APPOINTMENT"
            ],
            "enable_human_tool": "True"
        }~';

        DBMS_CLOUD_AI_AGENT.CREATE_TASK(
            task_name   => c_task_name,
            attributes  => v_task_attrs,
            status      => 'ENABLED',
            description => 'Tarea principal de gestion de agenda por chat.'
        );

        v_team_attrs := '{"agents": [{"name": "' || c_agent_name || '", "task": "' || c_task_name || '"}], "process": "sequential"}';

        DBMS_CLOUD_AI_AGENT.CREATE_TEAM(
            team_name   => fn_team_name,
            attributes  => v_team_attrs,
            status      => 'ENABLED',
            description => 'Equipo Hasel para chat de agenda.'
        );
    END pr_install;
END pkg_aox_ai_agent_setup;
/


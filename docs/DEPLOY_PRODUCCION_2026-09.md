# Pase a producción — septiembre 2026 (SaaS + HASEL_ADMIN + VPD)

Esquema de producción: `wksp_aox` (ADB **AOX**, alias ORDS `bookmate`). Control plane nuevo: `hasel_admin` (misma ADB, alias ORDS `hasel_admin`).

Este pase lleva producción al estado de `aoxdevelop`. Incluye:
- las migraciones pendientes (también algunas anteriores al tag `prod`);
- la creación de `HASEL_ADMIN`;
- VPD por tenant en 49 tablas;
- el asistente;
- los arreglos de billing y eSign.

El cobro de planes sigue apagado (`BILLING_ENABLED = 0`, `ADDONS_BILLING_LIVE = 0`).

Se ensayó completo sobre un clon de prod (`AOXREHEARSAL`, 2026-09-25). El orden de `scripts/deploy/pase_2026-09.manifest` es el que funcionó ahí.

**Ensayo de punta a punta con `run_manifest.sh` (2026-09-26)** sobre un clon nuevo de prod, sin intervención salvo los dos pasos de ADMIN:
- Aparecieron dos errores que el ensayo paso a paso no había mostrado, ya corregidos en el repo: `AOX_TENANT_CTX` se creaba después de que `20260919_aox_public_directory` lo necesitara (ahora `policies/01_aox_tenant_ctx.sql` va antes), y esa migración no toleraba reaplicar constraints (`ORA-02264`).
- Resultado: 0 INVALID en `WKSP_AOX` y `HASEL_ADMIN`, 49/49 políticas VPD, 194 handlers con salida por partes y todos los jobs de prod pasados al wrapper. La comparación contra DEV solo muestra las diferencias esperadas (ver Validación), y el smoke HTTP dio 26 de 26 endpoints en 200.
- Tiempo neto de ejecución: unos 11 minutos, sin contar los pasos manuales.

## Por qué no alcanza con `git diff prod..HEAD`

El tag `prod` no reflejaba producción. 28 paquetes estaban en versiones de julio y agosto, y faltaban migraciones de antes del tag:
- `20260718_professionals_is_active_ords`
- `20260901_einvoice_ords_service_token`
- `20260901_disputas_no_custodiales` (su parte ORDS)
- las plantillas de mail v3 y las de WhatsApp v3

El manifiesto las incluye.

## El orden importa

- **Hay dependencias entre migraciones del mismo día y de días distintos.** `cuerpo_body_map` y `org_specialty_multi_rubro_addons` se necesitan mutuamente: se corre `multi_rubro` → `cuerpo_body_map` → `multi_rubro`. Los `*_ords` van después de su migración base. El orden alfabético no sirve; se usa el de los commits.
- **Bloque VPD:** `public_directory` va antes que `tenant_session`, porque las pruebas de la sesión necesitan el body válido.
- **Convergencia de paquetes:** varias migraciones compilan paquetes del HEAD que dependen de objetos que llegan más tarde. `scripts/deploy/converge_packages.sql` los recompila todos en el orden de `install_all.sql` antes de habilitar VPD.
- **KB de ATC:** primero se copia a `hasel_admin` y se compila `PKG_AOX_ATC_CHAT`; recién después corre `20260911_drop_aox_atc_kb`.
- **Con VPD habilitado, una migración de datos sobre tablas con política falla sin contexto** (`ORA-28115`, pasó al reejecutar `20260906_org_specialty_multi_rubro_addons`). Hay dos salidas:
  - correr las migraciones de datos antes del bloque VPD, como hace el manifiesto;
  - en migraciones futuras, fijar el tenant con `pkg_aox_session.set_org` por org, o apagar las políticas con el kill switch mientras corre la migración.
- **Reejecutar el canario con las 49 políticas ya habilitadas dispara su kill switch.** Siempre va `policies/03` → canario → oleadas.

## Preparación

1. **SQL\*Plus** del Instant Client 23.26 en `~/.local/opt/instantclient_23_26` (paquete `instantclient-sqlplus-linux.x64-23.26.2.0.0.zip` sobre el Basic Lite).
2. **Wallet de prod** en `~/Documentos/wallet/Wallet_aox`, con `DIRECTORY` absoluto en `sqlnet.ora`.
3. **Password de WKSP_AOX:** la toma del MCP `aox` en `~/.claude.json`.
4. **Password de HASEL_ADMIN:** se elige para este pase y se guarda en `~/.config/aox_prod.env` (`chmod 600`):
   ```bash
   install -m 600 /dev/null ~/.config/aox_prod.env
   read -rs -p "Password HASEL_ADMIN: " P && printf 'HASEL_ADMIN_PASSWORD=%q\n' "$P" > ~/.config/aox_prod.env; unset P
   ```
5. **Copia de `aox-admin-dev-sql` preparada para prod:**
   ```bash
   ../aox-admin-dev-sql/scripts/prepare_deploy_copy.sh /tmp/hasel-admin-prod
   ```
   El repo admin tiene nombres de DEV fijos: `aoxdev.`, el workspace `AOXDEV` y el bucket `bucket-hasel-aoxdev`. El script los transforma para prod; revisar su salida antes de usarla.
6. **Backup:** anotar la hora exacta de inicio para un point-in-time restore y trabajar en una ventana de poco tráfico.

## Ejecución

```bash
cd aox-dev-sql
AOX_TARGET=prod ADMIN_COPY=/tmp/hasel-admin-prod scripts/deploy/run_manifest.sh
```

- **Pasos manuales (`STOP`):** el driver se detiene e indica con qué `--from` retomar. Son dos:
  1. `scripts/deploy/admin_hasel_admin.sql` como **ADMIN** (Database Actions): crea `HASEL_ADMIN`, las ACL, lo asigna al workspace `AOX` y da `DBMS_RLS` a `WKSP_AOX`. Antes de correrlo, reemplazar `CAMBIAR_PASSWORD`.
  2. `$ADMIN_COPY/scripts/copy_atc_kb_params.sql` como **ADMIN**. Usar la copia preparada: el script del repo lee `aoxdev.app_parameter`.
- **Errores:** el runner (`scripts/deploy/run_sql.sh`) corta ante cualquier `ORA-`. Las migraciones admin corren con `--tolerate`, que solo acepta errores de "ya existe", porque reaplican `tables/*.sql` que `install_all` ya creó.
- **Logs:** uno por archivo en `~/.cache/hasel-deploy/prod/logs`.
- **Ensayo en un clon (recomendado antes de prod):**
  1. Clonar `aoxprod` (Full clone, Developer, sin auto scaling) con Database name `AOXREHEARSAL`, así sirven la conexión `aox_clone` y `AOX_TARGET=clone`.
  2. Apenas quede *Available*, correr `scripts/deploy/neutralize_clone.sql` como **ADMIN**: apaga los jobs y corta WhatsApp, push, Pagopar, eSign y las alertas. El clon arranca con los jobs y las keys de prod.
  3. Descargar el wallet en `~/Documentos/wallet/Wallet_AOXREHEARSAL` (`DIRECTORY` absoluto en `sqlnet.ora`) y la password de HASEL_ADMIN en `~/.config/aox_rehearsal.env`.
  4. `AOX_TARGET=clone ADMIN_COPY=/tmp/hasel-admin-prod scripts/deploy/run_manifest.sh`. En el clon, las líneas `CLONE_DISABLE_JOBS` apagan los jobs que el pase va creando.
  5. Borrar el clon al terminar.
- **Tiempo neto en el ensayo:** unos 15 minutos. Lo más largo: la convergencia (34 s con `converge_packages.sql` en una sola sesión), `aox_public_directory` (63 s), `install_all` admin (61 s), la copia de la KB (61 s) y `aox_tenant_child_org` (18 s, `NOT NULL` en tablas hijas).

## Jobs

`20260926_prod_jobs_wrapper` pasa por `pkg_aox_job_wrapper` los jobs que solo existen en prod: asistencia, digest, sync de embeddings y monitor de incidentes. Sin eso, con VPD encendido correrían sin contexto y no procesarían nada. También crea `JOB_REVOKE_EXPIRED_SESSIONS_JOB`. Los jobs existentes conservan su estado habilitado o no.

**Jobs nuevos que quedan apagados por decisión (2026-09-26):** `HASEL_PROCESS_SURVEY_REQUESTS`, `HASEL_PAGOPAR_RECONCILE` y `HASEL_ADMIN_DISPATCH_CAMPAIGNS` (en `hasel_admin`). Sus migraciones los crean habilitados. `scripts/deploy/keep_jobs_off.sql` los apaga justo después de cada una y otra vez en el cierre, así que no llegan a correr durante el pase. Esto corre también en prod. Para encenderlos más adelante: `DBMS_SCHEDULER.enable('<job>')` como el owner.

`JOB_REVOKE_EXPIRED_SESSIONS_JOB` sí queda habilitado.

## Validación

- **0 INVALID** en `WKSP_AOX` y `HASEL_ADMIN`: el último paso del manifiesto lo lista.
- **49 políticas** `AOX_TENANT_VPD` con `enable = YES`, **194 handlers** en `bookmate` y **60 templates** en `hasel-ops`.
- **0 handlers con `htp.prn(v_response_body)`** y 190 con `pkg_aox_http.pr_print_clob`. `appointments/calendar` de un mes en la org 46 responde 200.
- **Topes:** `appointments/calendar` de un año responde 400 y `customers?limit=100000` devuelve `per_page=200`.
- **Todos los jobs de `WKSP_AOX` apuntan al wrapper**, salvo `HASEL_PAGOPAR_RECONCILE`, que hace su propio `set_org` por org.
- **Comparación contra DEV** con `scripts/deploy/compare_schemas.py` (ver su docstring). Diferencias esperadas:
  - legacy de prod (`DEPT`, `EMP`, `EMPLEADOS`, `DEPARTAMENTOS*`, `TMP_HASEL_MAINT_PKG_BACKUP`, `JS_GET_IVA`);
  - drift de DEV (`PKG_OCI_BRIDGE`, `PROFESSIONAL.DELETED_AT`, `JOB_EXPIRE_PAGOPAR_PAYMENTS`, `JOB_SYNC_ORG_EMBEDDINGS`);
  - los jobs propios de prod;
  - el código de `HASEL_ADMIN` HAS-85/86/87, que está en el repo pero no se compiló en DEV.
- **Smoke con JWT** (firmado en la base con `apex_jwt.encode` y `JWT_TOKEN`, como en el pase de agosto) contra `…/ords/bookmate/api/v1/`:
  - `auth/validate-panel`, `permissions/me`, `permissions/matrix`;
  - `dashboard`, `dashboard/analytics`;
  - `customers` y `customers?archived=1`;
  - `professionals`, `workspace*`, `workspace/subscription`, `inbox`;
  - `public/v1/directory` y `public/v1/org/:slug`;
  - login de `hasel-ops` con un superadmin (`aox-admin-dev-sql/scripts/bootstrap_superadmin.sql`).

## Rollback

- **VPD:** `@policies/03_aox_tenant_vpd_kill_switch.sql` deshabilita las 49 políticas sin borrarlas (4 s en el ensayo). Para volver: `20260919_aox_tenant_vpd_canary` y después `20260919_aox_tenant_vpd_enable_waves` (11 s).
- **Todo lo demás:** point-in-time restore del ADB a la hora anotada. Restaura la base entera, así que se pierde lo que haya entrado después.

## Pendientes fuera de la base

- **Meta:** las plantillas ya están aprobadas y son las mismas que en aoxdevelop (confirmado el 2026-09-26).
- **eSign (después del pase):** cargar `ESIGN_API_KEY` y `ESIGN_WEBHOOK_SECRET` (quedan en `PENDING`). Confirmar `APEX_MAIL_APP_ID = 100`.
- **Consola admin (después del pase):** las migraciones admin solo definen CORS para `localhost`; falta agregar el origen del front admin de prod. Además, `HASEL_ADMIN` arranca sin empleados: para poder entrar hay que crear el primero con `aox-admin-dev-sql/scripts/bootstrap_superadmin.sql`, conectado como `HASEL_ADMIN`, una sola vez.
- **Frontend en la misma ventana:** `bookmate` `staging` → `main` y deploy de `bookmate-admin`.

## Respuestas ORDS de más de 32 KB (se corrige en este pase)

**Problema:** 190 de los 194 handlers terminaban con `htp.prn(v_response_body)`. `htp.prn` recibe `VARCHAR2`, con un máximo de 32767 bytes, así que con un CLOB más grande falla (`ORA-06502`) y ORDS responde **555**. En prod ya pasaba, por ejemplo con `appointments/calendar` de un mes en la org 46 (36 KB).

**Solución** (el patrón que recomienda Oracle: escribir el CLOB por partes con `htp.prn`):
- **`PKG_AOX_HTTP.pr_print_clob`** escribe en partes de 4000 caracteres, que ocupan como máximo 16 KB en AL32UTF8. Es un paquete sin dependencias, así que se aplica en caliente sin invalidar las APIs.
- **`20260926_ords_htp_print_clob.sql`** reescribe todos los handlers (`htp.prn(v_response_body)` → `pkg_aox_http.pr_print_clob(v_response_body)`) y vuelve a declarar sus parámetros. Verifica antes del `COMMIT` que handlers y parámetros sigan iguales, y es idempotente. Va al final (paso 11b del manifiesto) porque las migraciones anteriores definen los handlers con `htp.prn`.
- **Aplicada en aoxdevelop el 2026-09-26 y ensayada en el clon:**
  - la huella de los 56 parámetros no cambió (incluido `X-Service-Token`);
  - el calendario de un mes (35 KB) y el de dos meses (75 KB) responden 200 con JSON válido;
  - los eventos coinciden campo por campo con lo que genera la base.

**Convención para handlers nuevos:** imprimir la respuesta con `pkg_aox_http.pr_print_clob(v_response_body)` y **no** con `htp.prn(<clob>)`. Si una migración define un handler con `htp.prn`, alcanza con volver a correr `20260926_ords_htp_print_clob.sql`.

## Topes de tamaño en listados y calendario (se aplica en este pase)

Con el arreglo de 32 KB las respuestas grandes ya no fallan, pero algunas crecían sin límite con el volumen de datos. `20260926_list_limits.sql` (paso 11c del manifiesto) les pone tope:

| Endpoint | Antes | Ahora |
|---|---|---|
| `customers`, `professionals`, `services`, `specialties`, `locations` | `limit` sin máximo; `limit=0` dividía por cero | `limit` entre 1 y 200 (`pkg_aox_http.fn_page_size`); `per_page` y `total_pages` informan el límite efectivo |
| `appointments/calendar` | cualquier rango | máximo 62 días; más da 400 `VALIDATION_ERROR` (el front pide a lo sumo 42, en la vista mes) |
| `workspace/customers/:id/body-snapshots` | todo el historial | los 200 más recientes |

- **Orden en el pase:** `PKG_AOX_HTTP` se compila al inicio del paso 3 y en `converge_packages.sql`, porque las migraciones anteriores ya compilan los paquetes de listados del HEAD, que lo usan.
- **Aplicado en aoxdevelop y probado en el clon el 2026-09-26:** calendario de 42 y 62 días en 200; 63 días, un año o sin `end` en 400; `limit=0` → 9 y `limit=100000` → 200 en los cinco listados; la exportación de clientes (200 por página) sigue igual. El historial del mapa corporal no se pudo probar por HTTP porque ninguna organización tiene el complemento activo.
- **Convención para listados nuevos:** calcular el tamaño de página con `pkg_aox_http.fn_page_size(pi_limit, <default>)` y acotar por rango de fechas los endpoints por período.
- **Pendiente, no incluido:** `public/v1/directory` devuelve todas las organizaciones (hoy 11) y rechaza `offset`; paginarlo requiere cambiar `/explorar` en el front. Los endpoints de chat IA (`ai/chat/sessions`, `.../messages`) no tienen tope, pero su interfaz se retiró (HAS-24).

## Bugs que ya existían en prod (este pase no los introduce)

- **`GET organization/current`** llama a `pkg_aox_organization_api`, que no existe en ningún entorno.

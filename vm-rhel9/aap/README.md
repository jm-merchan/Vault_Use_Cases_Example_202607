# AAP 2.7 y Vault sobre RHEL 9

Instalación Growth en una VM dedicada: `m6i.2xlarge`, 8 vCPU, 32 GiB de RAM y 150 GiB gp3. El módulo `../terraform/aap` conserva su propio estado. El endpoint HTTPS usa ACM y un ALB; la conexión al nodo también usa HTTPS. SSH está restringido a la IP del operador.

Instalación completada y evaluada el **24 de septiembre de 2026**: RHEL **9.8**, AAP **2.7** (controller **4.8.0**, bundle `2.7-1.1`), **9/9 celdas Bash** del notebook ejecutadas y **5/5 comprobaciones funcionales** correctas. El instalador terminó con `failed=0`; el ALB está saludable y SELinux sigue en Enforcing.

Integración migrada al FQDN de aplicaciones y reevaluada el **25 de septiembre de 2026**: **9/9 celdas y 5/5 pruebas correctas**. La URL de ambas credenciales externas y la audiencia JWT son `https://vault-vm-apps.jose-merchan.sbx.hashidemos.io`. Resultados actuales en [evaluation.json](evaluation.json).

La suscripción importada es **60 Day Product Trial, Self-Supported, 100 Managed Nodes**, válida hasta el **23 de noviembre de 2026**. OIDC de workloads para Vault es **Technology Preview** en AAP 2.7.

## Acceso

Interfaz: **https://aap-vm.jose-merchan.sbx.hashidemos.io**. Usuario: **`admin`**. La contraseña generada está en `../.state/aap/admin-password` (no se publica en Git). Desde `vm-rhel9`, puede consultarse con `cat .state/aap/admin-password`.

SSH desde `vm-rhel9`, en Bash:

```bash
source scripts/notebook-env.sh
ssh "${SSH_ARGS[@]}" "ec2-user@$(jq -r .public_ip "$STATE/aap/infrastructure.json")"
```

Durante la instalación, el progreso está en `~/aap/install.log` y el código de salida final en `~/aap/install.exit`. `0` indica que el playbook del instalador ha terminado correctamente; la validación funcional de Vault requiere además los jobs de evaluación.

## Desplegar e instalar

Desde `vm-rhel9`:

```bash
bash aap/deploy.sh
bash aap/install.sh "$HOME/Downloads/ansible-automation-platform-containerized-setup-bundle-2.7-1.1-x86_64.tar.gz"
```

El despliegue conserva la AMI y subredes seleccionadas, bloquea cualquier plan con borrados o sustituciones y no ejecuta el módulo de infraestructura Vault.

El instalador oficial se ejecuta con `ec2-user`, contenedores Podman rootless y SELinux Enforcing. `feature_flags.FEATURE_OIDC_WORKLOAD_IDENTITY_ENABLED=true` activa los tipos de credenciales Vault OIDC. Las contraseñas, el inventario completo y `manifest.zip` se conservan en `.state/aap/`, excluido de Git. PostgreSQL, Redis, gateway, controller, hub, EDA y métricas están en esta VM.

## Integración implementada

- Vault para ambas credenciales externas: https://vault-vm-apps.jose-merchan.sbx.hashidemos.io, KV v2 `aap-demo/credentials/test`, clave `password`, política `aap-demo-read` limitada a esa ruta. El endpoint administrativo sigue siendo `vault-vm.jose-merchan.sbx.hashidemos.io`.
- AppRole: mount `aap-approle/`, rol `aap-demo`, token de 15 minutos y máximo 30 minutos. SecretID de 30 días. La credencial externa de AAP usa RoleID/SecretID; no usa el token root de Vault.
- OIDC/JWT: mount `aap-jwt/`, rol `aap-demo`, audiencia igual a la URL de aplicaciones de Vault (`https://vault-vm-apps.jose-merchan.sbx.hashidemos.io`), token de 5 minutos y máximo 10 minutos. Claims numéricas restringidas a organización `1`, proyecto `7` y plantilla `9`. El issuer firmado de este bundle es `https://aap-vm.jose-merchan.sbx.hashidemos.io/o/`; discovery publica `/o` sin la barra final. La configuración comprueba el valor exacto emitido.
- AAP: proyecto **Vault VM demo project**, plantillas **Vault VM - AppRole** (ID `8`) y **Vault VM - OIDC** (ID `9`). Las credenciales externas recuperan el secreto y lo inyectan como `AAP_VAULT_DEMO_SECRET`. El [playbook](playbooks/verify-secret.yml) compara su SHA-256 con `no_log: true`.
- El proyecto usa la rama pública dedicada [`codex/aap-vm-vault`](https://github.com/jm-merchan/Vault_Use_Cases_Example_202607/tree/codex/aap-vm-vault); únicamente se publicó el playbook de comprobación. La rama principal no se modificó.

OIDC aquí es la **identidad del workload AAP al acceder a Vault**. El acceso web sigue usando `admin`; esta implementación no configura SSO interactivo de usuarios ni firma de certificados SSH.

## Notebook y resultados

Abrir [15_AAP_Vault_AppRole_OIDC.ipynb](15_AAP_Vault_AppRole_OIDC.ipynb) con el kernel `Vault RHEL9 PoC`. Contiene todos los comandos de configuración y evaluación en Bash, `vault`, `curl` y `jq`, con los resultados guardados en el mismo notebook. No hay una segunda copia en `reports/`.

| Comprobación | Job de la ejecución del notebook | Resultado |
|---|---:|---|
| AppRole, lectura inicial | 15 | successful |
| OIDC, lectura inicial | 16 | successful |
| AppRole, secreto rotado | 17 | successful |
| OIDC, secreto rotado | 18 | successful |
| OIDC, plantilla no autorizada | 19 | error esperado: claim de plantilla rechazada |

[evaluation.json](evaluation.json) conserva la fecha, los IDs y el resultado esperado. El job 19 debe verse como fallido en AAP: demuestra que copiar una plantilla y su credencial no concede acceso a Vault. La evaluación comprueba el error concreto de `aap_controller_job_template_id`, además del fallo del job. Los jobs 3 y 5 permanecen como intentos de diagnóstico anteriores a corregir issuer y tipos numéricos de las claims.

La celda AppRole también comprueba un rechazo **403** fuera de la ruta autorizada. Al repetir el notebook, se reutilizan los objetos existentes y se rota únicamente el secreto dedicado de la demo. Cuando caduque el SecretID, repetir las celdas Vault y credenciales AAP genera y configura uno nuevo.

Los scripts `.sh` son las versiones ejecutables de las mismas celdas. Desde `vm-rhel9`, el orden es:

```bash
bash aap/bootstrap-api.sh
bash aap/activate.sh
bash aap/configure-vault.sh
bash aap/configure-controller.sh
bash aap/configure-oidc.sh
bash aap/configure-credentials.sh
bash aap/evaluate.sh
```

La sesión administrativa de la API se guarda en archivos privados de `.state/aap/`. Las respuestas detalladas y los logs de diagnóstico también están allí; los documentos publicados no contienen contraseñas, tokens o SecretIDs.

## Referencias

- [Topología Growth y requisitos](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/plan-ref_cont_a_env_a).
- [Activación de OIDC mediante feature_flags](https://access.redhat.com/solutions/7147516).
- [Configuración de Vault para OIDC de AAP](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/whats_new-configure_the_hashicorp_vault_server).

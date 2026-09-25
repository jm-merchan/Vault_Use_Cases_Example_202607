# Vault Enterprise sobre VMs RHEL 9

Versión independiente de los **23 notebooks** del repositorio, incluido `_Backup_VSO_Openshift`. Los notebooks originales permanecen intactos. La correspondencia exacta está en [scenario-map.json](scenario-map.json).

La ampliación con una instancia propia de **AAP 2.7 sobre RHEL 9**, integrada con Vault mediante AppRole y OIDC de workloads, está en [aap/README.md](aap/README.md). Su [notebook Bash](aap/15_AAP_Vault_AppRole_OIDC.ipynb) es un caso adicional a los 23 originales y conserva sus resultados de ejecución en el propio archivo.

## Arquitectura implementada

- **6 VMs primarias** RHEL 9 x86_64, dos por zona de disponibilidad. Raft integrado y Autopilot redundancy zones.
- **3 VMs secundarias** RHEL 9 para Performance Replication.
- **1 VM de aplicación** RHEL 9 para Vault Agent y WildFly con OpenJDK 21.
- Vault Enterprise **2.1.1+ent**, servicio `systemd`, SELinux enforcing, TLS interno, KMS auto-unseal e IMDSv2 obligatorio. La AMI oficial RHUI de Red Hat se resuelve en AWS; la versión observada se registra durante la evaluación.
- Tres NLB TCP con TLS hasta Vault y certificados Let’s Encrypt: administración al líder, aplicaciones al activo más cinco performance standbys y un NLB privado para el secundario. API en 443/8200, PR en 8201 por NLB y Raft directo dentro de cada clúster. Configuración, renovación y pruebas: [load-balancing/README.md](load-balancing/README.md).
- PostgreSQL, Oracle, LDAP, VSO, CSI, Prometheus, Grafana y benchmark en el EKS existente, dentro de namespaces `vm-*`. Bases de datos y LDAP usan NLB internos: los nombres `.svc.cluster.local` no se utilizan desde las VMs.
- Los originales de IRSA usan **instance profile EC2** en esta variante; se conserva el nombre del notebook para facilitar la correspondencia. Los escenarios AssumeRole y WIF siguen siendo independientes. Por indicación del usuario, el cuaderno de credenciales estáticas se convierte en otro destino con rol asumido, operado desde Doormat; no crea usuarios IAM ni necesita claves permanentes.

El perfil necesita permiso para crear EC2, IAM, KMS, ELB y registros Route 53 en la VPC de EKS. Los diez nodos `t3.medium`, sus discos y balanceadores permanecen desplegados al terminar. GitHub se evalúa en la rama `codex/vm-rhel9-poc`, sin modificar la rama principal.

## Preparación

Desde este subdirectorio:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m ipykernel install --prefix .venv --name vm-rhel9-poc --display-name 'Vault RHEL9 PoC'
cp .env.example .env
```

Herramientas locales: Terraform >=1.14, AWS CLI, Azure CLI, `vault` Enterprise con `operator import`, `kubectl`, Helm, GitHub CLI, OpenSSH y, para el perfil original, Doormat. Azure y GitHub deben tener una sesión válida. La licencia se lee de `../vault.hclic` o de `VAULT_LICENSE_FILE`; jamás se incluye en user-data o Terraform.

Ajustar `.env` al entorno. La fase de descubrimiento identifica VPC y tres subredes públicas. El primer despliegue usa `DNS_ZONE_NAME`; las ejecuciones siguientes conservan la zona y el orden de subredes registrados. Antes de aplicar, el notebook inspecciona el plan y aborta si contiene destrucciones o sustituciones. La configuración explícita se conserva en `.state/deployment-input.json` y `terraform/infrastructure/runtime.auto.tfvars.json`. El acceso SSH y API directa se restringe a la IPv4 `/32` del operador.

## Ejecución y evidencia

```bash
.venv/bin/python scripts/validate.py
.venv/bin/python scripts/evaluate.py
# Repetir casos fallidos o cuyo código haya cambiado desde la evaluación:
.venv/bin/python scripts/evaluate.py --retry-failed
# Ejecutar un único caso:
.venv/bin/python scripts/evaluate.py 6_Oracle_DB_Engine
```

Los notebooks se abren en Jupyter con el kernel `Vault RHEL9 PoC`, igual que los originales basados en IPython. **Todas las celdas operativas son `%%bash`** y muestran directamente los comandos `aws`, `az`, `vault`, `curl`, `kubectl`, `terraform`, `ssh` y `openssl`, junto con los payloads JSON, políticas HCL, SQL y manifiestos YAML. No llaman a los helpers Python de la primera versión.

Para copiar una celda a una terminal **Bash**, situarse en `vm-rhel9/notebooks` y quitar únicamente la primera línea `%%bash`. Cada celda carga sus variables desde `../scripts/notebook-env.sh`; ese archivo solo prepara el entorno. Las variables que deben sobrevivir entre celdas se guardan en `.state/`, por lo que no se depende de que `%%bash` conserve el shell.

También hay una copia Bash completa de cada notebook en `notebook_sources/`. Por ejemplo:

```bash
cd notebooks
bash ../notebook_sources/5_Secret_Sync_AWS_IRSA_AssumeRole.sh
```

Python queda como herramienta de generación/validación de documentos y evaluación Jupyter. Los antiguos helpers se conservan por compatibilidad, pero los notebooks no los usan. Los notebooks ejecutados y los resultados previos de la edición Python no acreditan la nueva edición Bash: el informe identifica expresamente la implementación evaluada.

`reports/EVALUATION.md` resume la última evaluación; `reports/results.json` registra estado, fecha, duración y copia ejecutada para cada caso. Puede regenerarse el resumen con `.venv/bin/python scripts/report.py`. `passed` requiere completar todas las celdas y sus comprobaciones. `failed` identifica un fallo de ejecución o una assertion; `blocked` identifica un prerrequisito externo ausente. `reports/static-validation.json` es solo validación local de estructura, cobertura y sintaxis, y no acredita funcionalidad.

El orden del evaluador respeta las dependencias: primario → integraciones → secundario → activación PR. Los notebooks que consumen una base de datos preparan su dependencia. El secundario se inicializa una sola vez; después de habilitar PR, su token root de bootstrap deja de servir y las pruebas se autentican mediante un método replicado. La activación reinicia los standbys que se hayan sellado al cambiar las claves de barrera y comprueba los tres nodos secundarios; véase [auto-unseal y replicación](https://developer.hashicorp.com/vault/docs/concepts/seal).

## Qué comprueban los casos

- GitHub OIDC: un workflow real autentica con JWT sujeto a repositorio/rama y lee un secreto sin imprimirlo.
- Agent/WildFly: la aplicación comprueba el secreto renderizado; la actualización KV dispara reinicio mediante template exec. El caso dinámico conecta por JDBC, revoca credenciales y usa un timer systemd como equivalente del cron original.
- VSO/CSI: lectura y actualización del secreto estático, emisión de credenciales PostgreSQL y login SQL efectivo.
- Secrets Sync: estado `SYNCED` y comparación exacta de dos versiones con AWS Secrets Manager o Azure Key Vault.
- Oracle: plugin firmado e Instant Client en todos los nodos, login dinámico, rechazo tras revocación y rotación de un usuario estático.
- Importación: 11 secretos AWS y 10 Azure, contenido estructurado/Unicode/multilínea/PEM, rutas planas y anidadas, tags como metadata y round-trip al mismo nombre cloud.
- LDAP/RBAC: acceso permitido y prohibido, revocación, reautenticación y bloqueo/desbloqueo del namespace; también revocación SQL.
- PR: activación real, lectura desde el secundario y latencia observada de cinco escrituras.
- Auditoría: request en archivo, rotación y reapertura tras SIGHUP.
- Kubernetes Engine: token acotado al namespace, prueba de permiso permitido y denegado, pipeline GitHub y entrega VSO.
- Telemetría: seis targets TLS `up=1` y dashboard de Grafana accesible por API.
- Benchmark: AppRole y KV v2 contra las VMs, 50 RPS/5 workers/30 s; ambas ratios deben ser 100%.
- Complemento OpenShift: dos modalidades JWT (claves locales y JWKS público) y credenciales STS verificadas. Se evalúa su funcionalidad Kubernetes en EKS; esta ejecución no valida SCC/OpenShift.

## Acceso a la demo desplegada

Las IP y los comandos SSH vigentes están en [reports/ACCESS.md](reports/ACCESS.md).

Los endpoints se obtienen de `.state/infrastructure.json`:

- `vault_address`: `https://vault-vm.jose-merchan.sbx.hashidemos.io`, administración dirigida al activo y URL existente de discovery WIF.
- `vault_application_address`: `https://vault-vm-apps.jose-merchan.sbx.hashidemos.io`, peticiones de aplicaciones distribuidas entre los seis nodos sanos del clúster primario.

El [notebook adicional de balanceo](load-balancing/16_Dual_FQDN.ipynb) contiene comandos Bash y evidencia de ejecución. No forma parte de los 23 casos originales. Los FQDN separan el enrutamiento; los permisos siguen dependiendo de las políticas ACL de Vault.

Los notebooks de integración y los consumidores AAP, Agent/WildFly, VSO, CSI, GitHub, importación y benchmark usan el FQDN de aplicaciones. La selección aparece explícitamente en Bash como `export VAULT_ADDR="$VAULT_APPLICATION_ADDR"`. El issuer WIF, las operaciones de infraestructura/PR y el scraping por nodo conservan sus endpoints específicos. Véase [el inventario de integraciones](load-balancing/README.md#integraciones).

Para abrir Grafana con el contexto configurado:

```bash
kubectl --context arn:aws:eks:eu-central-1:492487827579:cluster/eks-infra-dev -n vm-monitoring port-forward svc/grafana 3000:3000
```

Abrir `http://localhost:3000`; usuario `admin`, contraseña local en `.state/grafana-password`. La credencial de bootstrap de Vault está en `.state/primary-init.json`; mantener ese archivo fuera de Git. Los informes públicos de despliegue y benchmark no contienen tokens.

## Estado y credenciales

`.state/`, `.env`, `.venv/`, estados Terraform, variables generadas y notebooks ejecutados están excluidos de Git. `.state/` tiene modo 0700 y sus archivos sensibles 0600. Las contraseñas no se imprimen en las verificaciones. Terraform puede almacenar las credenciales SPN en el estado local; no publicarlo.

Azure toma `AZURE_SUBSCRIPTION_ID` y `AZURE_TENANT_ID` del `.env` original (o de esta variante si se definen); valida la sesión de Azure CLI y su tenant. Si caduca, ejecutar `az login --tenant <tenant>` con la intervención interactiva habitual.

Los tokens de reviewer Kubernetes/engine y métricas duran 24 horas: repetir su configuración antes de otra sesión de demo. Las credenciales AppRole tienen TTL de 24 horas. La API usa Let’s Encrypt: el certificado actual caduca el 24 de diciembre de 2026; renovar con `load-balancing/renew-public-certificates.sh` y una sesión Doormat vigente. El mTLS de 8201 lo gestiona Vault. Los estados y claves de recuperación se conservan para reanudar o retirar el entorno.

## Limpieza

Consultar `scripts/cleanup.py --help`. La limpieza es explícita, por fases, y nunca forma parte de la evaluación automática. Primero se retiran los escenarios cloud/Kubernetes; después, la infraestructura. No ejecutar `terraform destroy` sobre los módulos originales del directorio padre.

## Referencias

- [Vault con Raft e identidad de la VM para auto-unseal](https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-deployment-guide).
- [Autenticación Kubernetes con Vault externo](https://developer.hashicorp.com/vault/docs/auth/kubernetes).
- [Plugin Oracle](https://developer.hashicorp.com/vault/docs/secrets/databases/oracle).
- [Secrets Sync API](https://developer.hashicorp.com/vault/api-docs/system/secrets-sync).

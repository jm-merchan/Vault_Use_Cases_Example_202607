# Ejecución de la variante VM

El entorno se retiró el **25-09-2026**, incluido EKS. Los resultados publicados acreditan la ejecución anterior a esa retirada. Esta guía describe cómo preparar otra ejecución; revisar la documentación o ejecutar los validadores locales **no despliega recursos**. Los notebooks y scripts operativos sí crean recursos, rotan secretos y realizan pruebas de fallo.

Todos los bloques de esta guía se ejecutan en **Bash desde `vm-rhel9`**, salvo indicación expresa. No cargar `notebook-env.sh` directamente en Zsh. No mezclar `.state/`, tokens o estados Terraform de la variante VM con los originales de Kubernetes.

## 1. Preparación local

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m ipykernel install --prefix .venv \
  --name vm-rhel9-poc --display-name 'Vault RHEL9 PoC'
[[ -f .env ]] || cp .env.example .env
```

Editar `.env` con cuenta Doormat, región AWS, nombre/contexto EKS, zona DNS pública y los IDs de Azure. La licencia Enterprise debe estar en `../vault.hclic` o en la ruta absoluta de `VAULT_LICENSE_FILE`. La versión configurada es Vault 2.1.1+ent; se necesitan las capacidades Enterprise usadas por los casos (incluidas PR, namespaces, Secrets Sync y `operator import`).

Instalar las [herramientas del README](README.md#preparación). Podman debe estar en ejecución y poder descargar `certbot/dns-route53`; en macOS, arrancar su máquina si está parada. OpenSSL debe ser versión 3; `notebook-env.sh` selecciona la instalación Homebrew de Apple Silicon si existe. El código local de certificados admite macOS o el almacén CA de RHEL; adaptar esa ruta si se usa otra distribución.

Para la interfaz Jupyter, adicionalmente:

```bash
.venv/bin/pip install jupyterlab
.venv/bin/jupyter lab
```

Elegir el kernel **Vault RHEL9 PoC**. Jupyter ejecuta cada notebook en su carpeta: `notebooks/`, `aap/` o `load-balancing/`. Las celdas `%%bash` son shells independientes: las variables compartidas se guardan en `.state/`. Para copiarlas a una terminal, situarse en la misma carpeta y quitar la línea `%%bash`.

## 2. Estado de una ejecución anterior

**En un despliegue todavía activo**, conservar `.state/` y todos los estados Terraform: contienen identidad SSH, claves de recuperación, IDs, AMI y orden de subredes. `--retry-failed` sirve para repetir fallos en ese mismo entorno, no para validar uno nuevo.

**Tras una retirada completa**, los mismos archivos contienen referencias a recursos que ya no existen. En particular, `deployment-input.json`, los tokens root y el caché Azure no se deben reutilizar. Los resultados `passed` antiguos tampoco acreditan el siguiente despliegue.

Antes de redesplegar, archivar privadamente el estado antiguo. El siguiente bloque solo es apropiado después de verificar la retirada en cloud y que los ocho estados locales están vacíos. La comprobación de estado local por sí sola no detecta recursos huérfanos. No ejecutar esto para reparar un despliegue activo:

```bash
set -euo pipefail
umask 077
# Aborta si todavía quedan recursos gestionados en algún estado local.
for module in infrastructure aap azure-spn azure-wif wif operator-role irsa-assume-role irsa; do
  state_file="terraform/$module/terraform.tfstate"
  if [[ -f "$state_file" ]]; then
    jq -e '[.resources[]? | select(.mode == "managed") | .instances[]?] | length == 0' \
      "$state_file" >/dev/null
  fi
done
archive="$HOME/.vault-demo/archives/vm-rhel9-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$archive/terraform"
chmod 700 "$archive"
cp -R reports "$archive/reports"
cp -R aap load-balancing "$archive/"
[[ ! -d .state ]] || mv .state "$archive/state"
for module in infrastructure aap azure-spn azure-wif wif operator-role irsa-assume-role irsa; do
  mkdir -p "$archive/terraform/$module"
  for file in "terraform/$module"/*.tfstate* "terraform/$module"/*.auto.tfvars.json; do
    [[ ! -f "$file" ]] || mv "$file" "$archive/terraform/$module/"
  done
done
mkdir -m 700 .state
# Vaciar solo el índice de la nueva evaluación, después de respaldar el anterior.
printf '{}\n' > reports/results.json
printf 'Archivo privado: %s\n' "$archive"
```

Este bloque conserva `.env`, código, paquete tar.gz, locks de proveedores y evidencias publicadas. El manifiesto AAP antiguo queda en el archivo privado: usar un manifiesto válido para la nueva instalación. Las salidas de los tres notebooks adicionales siguen siendo históricas hasta volver a ejecutarlos. No recuperar tokens, inventarios ni claves SSH antiguas en el `.state/` nuevo. El caché de Let’s Encrypt permanece fuera del repo en `$HOME/.vault-demo/letsencrypt-vm`; Certbot comprueba/reutiliza o renueva su certificado. No reutilizar las claves KMS pendientes de borrado de la retirada anterior.

## 3. AWS, EKS, Azure y GitHub

Primero debe existir EKS con sus nodos, VPC, tres subredes públicas en zonas distintas, conectividad de salida y controlador AWS Load Balancer para los servicios auxiliares internos. El notebook 1 **descubre** esa red, no crea EKS. Para reproducir esta demo, volver a aplicar el workspace [jose-merchan/eks-infra-vcs](https://app.terraform.io/app/jose-merchan/workspaces/eks-infra-vcs), conservado tras el destroy, y esperar a que el apply termine. No usar la acción Delete Workspace para recrear ni retirar recursos.

Exportar una sesión AWS antes de Certbot, que recibe variables de entorno y no lee el perfil del portátil:

```bash
source scripts/notebook-env.sh
doormat login
doormat aws -a "$DOORMAT_AWS_ACCOUNT" export > "$STATE/aws-session.env"
source "$STATE/aws-session.env"
aws sts get-caller-identity
aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query 'cluster.status' --output text
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --alias "$KUBE_CONTEXT"
"${KUBECTL[@]}" get nodes
"${KUBECTL[@]}" -n kube-system get deployment aws-load-balancer-controller
```

Los notebooks renuevan la sesión AWS si STS falla. Para los scripts adicionales y la renovación TLS, exportarla de nuevo cuando caduque. Se requieren permisos para EC2, IAM/AssumeRole, KMS, ELB, Secrets Manager y Route 53. No se crean usuarios IAM para el antiguo caso de claves estáticas.

Para todos los casos Azure, completar el login interactivo y seleccionar la suscripción; los IDs pueden venir del `.env` original, pero su token Vault nunca se importa:

```bash
source scripts/notebook-env.sh
: "${AZURE_TENANT_ID:?Completar el tenant en .env}"
: "${AZURE_SUBSCRIPTION_ID:?Completar la suscripción en .env}"
az login --tenant "$AZURE_TENANT_ID"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az account show --query '{subscription:id,tenant:tenantId}' -o table
gh auth status
gh repo view --json nameWithOwner --jq .nameWithOwner
```

Azure necesita permisos sobre resource groups, Key Vault, asignaciones RBAC y aplicaciones/SPN de Entra ID. GitHub necesita una sesión con acceso al repositorio y a Actions; los casos 2 y 12 publican workflows en la rama dedicada y lanzan ejecuciones reales. Comprobar el repositorio seleccionado antes de ejecutarlos.

## 4. Los 23 casos originales adaptados

Validar localmente primero:

```bash
.venv/bin/python scripts/validate.py
.venv/bin/python scripts/validate_docs.py
```

La ejecución funcional completa sigue el orden de [scenario-map.json](scenario-map.json):

```bash
.venv/bin/python scripts/evaluate.py
```

No añadir `--retry-failed` al primer run de un despliegue nuevo. El evaluador guarda cada resultado y copia ejecutada, y se detiene si falla el despliegue inicial. En otros fallos puede continuar: un error previo puede provocar fallos dependientes. Revisar `reports/results.json` y repetir los casos afectados después de corregir la causa.

Para ejecución manual, abrir los 23 notebooks en el orden del mapa y ejecutar cada uno completo. Las dependencias relevantes para ejecutar casos aislados son:

| Caso | Dependencias además del notebook 1 |
|---|---|
| 2, 3A, 3B, 4, 5 AWS/Azure, 6, 7 AWS, 11, 12, 13, 14 | Credenciales y servicios indicados en sus celdas; preparan sus propios auxiliares. |
| 7 Azure | `5_Secret_Sync_Azure_CLI_SPN` crea el Key Vault y el caché que reutiliza. |
| 8 RBAC/revocación | PostgreSQL y roles de 3B o 4, más Oracle y sus roles de 6; la última celda prueba ambos motores. |
| 9 secundario | Inventario, certificados y VMs creados por 1; inicializar antes de 10. |
| 10 PR | 9 completo; la activación sustituye el estado del secundario y deja inválido su token de bootstrap. |
| `_Backup_VSO_Openshift` | Consumidores KV/PostgreSQL del caso 4 (orden del mapa); verifica la adaptación JWT/VSO en EKS, no SCC nativo de OpenShift. |

Ejemplo aislado, con dependencias preparadas:

```bash
.venv/bin/python scripts/evaluate.py 6_Oracle_DB_Engine
```

Alternativa sin evaluador Jupyter, con las mismas operaciones CLI visibles:

```bash
(cd notebooks && bash ../notebook_sources/6_Oracle_DB_Engine.sh)
```

Esta alternativa ejecuta las comprobaciones, pero no genera automáticamente una copia Jupyter ni actualiza el índice `reports/results.json`. Los helpers Python antiguos de despliegue no son el procedimiento documentado para ejecutar los casos actuales.

## 5. Los tres complementos

`evaluate.py` ejecuta **23 casos**, no estos tres complementos. Para evaluar todo el contenido, después de los 23 casos:

1. Instalar AAP y esperar al instalador; colocar el manifiesto y ejecutar las nueve celdas de [15_AAP_Vault_AppRole_OIDC.ipynb](aap/15_AAP_Vault_AppRole_OIDC.ipynb), según [aap/README.md](aap/README.md). El bundle se busca en la raíz de `vm-rhel9/`. Deben pasar cuatro jobs y un rechazo OIDC por la claim esperada.
2. Ejecutar [16_Dual_FQDN.ipynb](load-balancing/16_Dual_FQDN.ipynb). Requiere auditoría `file/` activa en los primarios, habilitada por 1; comprueba lecturas reales en los seis nodos.
3. Ejecutar [17_NLB_LetsEncrypt_PR.ipynb](load-balancing/17_NLB_LetsEncrypt_PR.ipynb) con PR ya activa (1 → 9 → 10). Comprueba TLS, aislamiento 8201, reconexión tras reiniciar el líder secundario y autenticación con certificado.

Las copias CLI de los complementos de balanceo se ejecutan así (elegir notebook o script, no hace falta ambos):

```bash
(cd load-balancing && bash 16_Dual_FQDN.sh)
(cd load-balancing && bash 17_NLB_LetsEncrypt_PR.sh)
bash load-balancing/verify-response-headers.sh
bash load-balancing/check-integration-endpoints.sh
```

Los scripts producen los JSON correspondientes, pero no actualizan las salidas guardadas en los notebooks. `nlb-evaluation.json` es el resumen histórico consolidado, no un informe regenerado automáticamente por `evaluate.py`. Para conservar evidencia Jupyter nueva, ejecutar y guardar los notebooks. Sus resultados antiguos no se deben interpretar como pruebas del despliegue nuevo.

## Comprobaciones de acceso

Solo después del nuevo despliegue, desde su inventario actual:

```bash
source scripts/notebook-env.sh
curl -fsS "$VAULT_ADMIN_ADDR/v1/sys/health" | jq '{initialized,sealed,standby}'
curl -fsS "$VAULT_APPLICATION_ADDR/v1/sys/health?perfstandbyok=true" | jq '{initialized,sealed}'
ssh "${SSH_ARGS[@]}" "ec2-user@$(jq -er '.nodes["primary-0"].public_ip' "$STATE/infrastructure.json")"
```

La UI usa `VAULT_ADMIN_ADDR` seguido de `/ui/`. El token de bootstrap **del nuevo despliegue** queda en `.state/primary-init.json`; no imprimirlo en informes. Los clientes usan `VAULT_APPLICATION_ADDR`; PR usa el NLB administrativo en 8201 y Vault administra su mTLS. El NLB secundario es privado y se comprueba desde la VPC. Ver [balanceo y certificados](load-balancing/README.md).

Los endpoints y las IP de [ACCESS.md](reports/ACCESS.md) son históricos hasta regenerar el informe a partir de un nuevo inventario. Cambiar de IP de operador puede requerir actualizar el `/32` de SSH/API directa en Terraform.

## Evidencia y mantenimiento de documentos

Los 23 notebooks de `notebooks/` son editables y no contienen salidas. `reports/*.executed.ipynb` son copias privadas con resultados. Los tres complementos conservan salidas en su propio notebook. No hay dos implementaciones diferentes.

`reports/results.json` contiene fechas y estado por caso; [EVALUATION.md](reports/EVALUATION.md) lo resume. `scripts/report.py` regenera ese resumen y el inventario de acceso, pero no consulta cloud ni ejecuta pruebas. Los hashes generados describen los archivos locales, no acreditan que todos se hayan ejecutado. Comprobar fechas e implementación `bash-cli` y comparar las celdas con sus copias ejecutadas.

`scripts/build_notebooks.py` genera los 23 notebooks y sus copias Bash. Si se editan instrucciones generadas, cambiar también este generador para no perderlas. No regenera los tres complementos. La validación documental comprueba enlaces locales, sintaxis Bash, JSON/YAML documentados, cobertura y conservación de las celdas operativas; no valida DNS, licencias ni APIs.

Los tokens de reviewer/métricas, credenciales AppRole y certificados tienen caducidad. Revisar TTL y renovar configuración antes de reutilizar una demo activa. Para Let's Encrypt, ejecutar el script de renovación con credenciales AWS exportadas; no hay timer automático. No aplicar esa renovación al entorno retirado.

## Retirada

La retirada de septiembre ya terminó; [TEARDOWN.md](reports/TEARDOWN.md) conserva alcance y comprobaciones. Las dos claves KMS quedaron inactivas en `PendingDeletion`, con borrado programado para el 25-10-2026.

Para una instalación futura, el orden de dependencias es:

1. Retirar consumidores y asociaciones de Secrets Sync mientras Vault, bases de datos y controladores siguen accesibles. Purgar únicamente los destinos de esta variante. El provider usado no completó el borrado de destinos con asociaciones: fue necesario usar la API `DELETE /v1/sys/sync/destinations/<tipo>/<nombre>?purge=true` antes de continuar. Revisar el efecto de purge en los secretos cloud antes de aplicarlo.
2. Destruir los módulos de escenarios Azure/AWS con sus estados. Eliminar los recursos creados por CLI, políticas IAM adicionales, aplicaciones/SPN y secretos que aún queden. La eliminación de un resource group no purga automáticamente un Key Vault con soft delete: comprobar el inventario de borrados y la política de retención.
3. Eliminar los objetos VSO/CSI antes que los servicios de base de datos; comprobar finalizers. Retirar los namespaces `vm-*`, releases propios y CRDs/roles de clúster solo si se ha comprobado su propiedad y que no quedan otros consumidores. No borrar CRDs compartidos por su nombre sin esa comprobación.
4. Retirar AAP con su módulo `terraform/aap` y después `terraform/infrastructure`. AAP incluye `prevent_destroy = true`: revisar el plan de retirada, desactivar temporalmente esa protección solo para este módulo y restaurar el código después. Quitar las políticas inline adicionales del rol Vault antes de destruirlo. Mantener los estados hasta confirmar todos los borrados.
5. Verificar ausencia de instancias, discos, balanceadores, DNS, IAM y recursos Azure de la variante. Diferenciar `PendingDeletion` de borrado definitivo para KMS. Solo entonces lanzar el destroy de EKS desde el workspace HCP Terraform, esperar a `applied` y comprobar estado vacío y ausencia del clúster/VPC. Conservar el workspace y el código.

`scripts/cleanup.py --help` describe un **helper parcial heredado**. Sus scopes `scenarios` e `infrastructure` no cubren AAP, todos los controladores/CRD, purga Azure ni HCP Terraform. Tampoco incorporan las correcciones manuales de Secrets Sync/finalizers de la retirada anterior. No basta ejecutar ese helper para declarar eliminada toda la demo.

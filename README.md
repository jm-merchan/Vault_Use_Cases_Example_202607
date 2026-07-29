# PoC de HashiCorp Vault

Este repositorio contiene una prueba de concepto genérica para desplegar y validar capacidades de HashiCorp Vault en entornos Kubernetes y multicloud. Los escenarios se presentan como notebooks ejecutables y cubren desde la instalación inicial hasta integraciones, gobierno, observabilidad y pruebas de rendimiento.

## Objetivos

- Desplegar Vault en Kubernetes con alta disponibilidad y auto-unseal.
- Evaluar distintos métodos de autenticación para personas, aplicaciones y pipelines.
- Gestionar secretos estáticos y credenciales dinámicas.
- Sincronizar e importar secretos entre Vault y gestores de secretos cloud.
- Validar políticas, namespaces, revocación de tokens y leases.
- Comprobar auditoría, rotación de logs, telemetría y replicación.
- Medir el comportamiento de Vault mediante pruebas de rendimiento.

## IA agéntica e idempotencia

Se ha utilizado IA agéntica para diseñar, revisar y adaptar los notebooks con el objetivo de que sean idempotentes. Esto permite volver a ejecutar los escenarios de forma segura y obtener un estado final consistente, aunque parte de la configuración ya exista.

Para conseguirlo, los notebooks incorporan, según el caso:

- comprobaciones previas del estado de recursos y configuraciones;
- operaciones de creación o actualización en lugar de asumir un entorno vacío;
- reutilización de recursos existentes cuando su configuración es válida;
- esperas activas y validaciones para operaciones asíncronas;
- bloques de limpieza controlada para escenarios que necesitan restablecer el entorno;
- mensajes de diagnóstico y validaciones posteriores a cada operación relevante.

La idempotencia se limita a los flujos automatizados por cada notebook. Deben revisarse las celdas de limpieza y las operaciones que rotan, revocan o sustituyen credenciales antes de ejecutarlas en un entorno compartido.

## Escenarios incluidos

| Notebook | Escenario |
|---|---|
| `1_Deploy_Vault_AWS.ipynb` | Despliegue de un clúster de Vault en EKS con AWS KMS e IRSA para auto-unseal. |
| `2_GHA_Vault_OIDC.ipynb` | Autenticación de GitHub Actions en Vault mediante OIDC. |
| `3A_JBOSS_WASS_Agent.ipynb` | Integración de Vault Agent con WildFly y autenticación AppRole. |
| `3B_JBOSS_DB_Engine_Agent.ipynb` | Entrega de credenciales dinámicas de base de datos a WildFly mediante Vault Agent. |
| `4_VSO_CSI.ipynb` | Consumo de secretos estáticos con Vault Secrets Operator y CSI. |
| `5_Secret_Sync_AWS_IRSA.ipynb` | Sincronización de secretos con AWS mediante IRSA. |
| `5_Secret_Sync_AWS_IRSA_AssumeRole.ipynb` | Sincronización con AWS usando IRSA y asunción de rol. |
| `5_Secret_Sync_AWS_WIF_Doormat.ipynb` | Sincronización con AWS mediante Workload Identity Federation. |
| `5_Secret_Sync_AWS_static_account.ipynb` | Sincronización con AWS mediante credenciales estáticas. |
| `5_Secret_Sync_Azure_CLI_SPN.ipynb` | Sincronización con Azure Key Vault mediante CLI y Service Principal. |
| `5_Secret_Sync_Azure_Terraform_SPN.ipynb` | Configuración de la sincronización con Azure mediante Terraform y Service Principal. |
| `5_Secret_Sync_Azure_Terraform_WIF.ipynb` | Configuración de la sincronización con Azure mediante Terraform y federación de identidad. |
| `6_Oracle_DB_Engine.ipynb` | Registro y validación del plugin de base de datos Oracle. |
| `7_Secret_Migrate_Azure.ipynb` | Importación de secretos desde Azure Key Vault. |
| `8_RBAC_Revoke_Namespace.ipynb` | RBAC, LDAP, namespaces, bloqueo y revocación de tokens y leases. |
| `9_VAULT_PR.ipynb` | Preparación y validación de un entorno de Performance Replication. |
| `10_PR_config_tasks.ipynb` | Configuración y medición de replicación entre un primario y un secundario. |
| `11_Audit_logs_k8s.ipynb` | Auditoría y rotación de logs de Vault en Kubernetes. |
| `12_K8S_Engine_Github.ipynb` | Integración de VSO, Kubernetes Secrets Engine y GitHub Actions OIDC. |
| `13_Grafana_Prometheus_Vault_Telemetry.ipynb` | Monitorización de la telemetría de Vault con Prometheus y Grafana. |
| `14_Vault_Benchmark_Kubernetes_AppRole_KV.ipynb` | Pruebas de rendimiento con AppRole y secretos KV v2. |
| `_Backup_VSO_Openshift.ipynb` | Escenario complementario de Vault Secrets Operator en OpenShift. |

El repositorio también incluye módulos Terraform, manifiestos de Kubernetes, valores de Helm e imágenes auxiliares utilizados por estos escenarios.

## Requisitos

Los requisitos concretos dependen del notebook, pero el entorno de trabajo puede necesitar:

- acceso a un clúster Kubernetes, EKS u OpenShift;
- una instancia o licencia de Vault compatible con las funciones evaluadas;
- `vault`, `kubectl`, `helm`, `terraform`, `aws`, `az`, `jq` y `curl`;
- Python y Jupyter para ejecutar los notebooks;
- permisos suficientes en AWS, Azure, GitHub y Kubernetes;
- conectividad entre los componentes utilizados en cada escenario.

No todos los requisitos son necesarios para ejecutar todos los notebooks. Se recomienda comenzar por el escenario que se desea validar y comprobar sus celdas de inicialización.

## Configuración

1. Copiar el fichero de ejemplo:

   ```bash
   cp .env.example .env
   ```

2. Completar únicamente las variables requeridas por el escenario.
3. Autenticarse en los proveedores y clústeres correspondientes.
4. Abrir Jupyter desde la raíz del repositorio:

   ```bash
   jupyter lab
   ```

5. Ejecutar el notebook seleccionado de principio a fin y revisar las validaciones mostradas.

## Orden de ejecución recomendado

Los notebooks están numerados para sugerir una progresión, pero son escenarios independientes salvo cuando se indica una dependencia explícita:

1. Despliegue y acceso a Vault.
2. Autenticación de pipelines y cargas de trabajo.
3. Integraciones con aplicaciones y motores de secretos.
4. Consumo y sincronización de secretos.
5. Gobierno, revocación y migración.
6. Replicación, auditoría, observabilidad y rendimiento.

## Seguridad

- No guardar tokens, claves, contraseñas ni credenciales cloud en el repositorio.
- Mantener el fichero `.env` fuera del control de versiones.
- Utilizar identidades y políticas con el mínimo privilegio necesario.
- Ejecutar primero en cuentas, suscripciones y clústeres aislados.
- Revisar las celdas de limpieza, revocación, rotación y eliminación antes de ejecutarlas.
- Revocar las credenciales temporales y eliminar los recursos de la PoC al finalizar.

## Alcance

El contenido está orientado a demostración y validación técnica.

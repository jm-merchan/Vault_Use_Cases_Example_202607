# Evaluación de la variante RHEL 9

Informe generado: 2026-09-25T13:11:57.522293+00:00

23 correctos, 0 fallidos, 0 bloqueados; 0 pendientes.

Cada estado procede de ejecutar el notebook completo con nbclient: celdas %%bash, comandos CLI y comprobaciones activas. La implementación evaluada se registra como bash-cli en results.json. La validación estática se registra por separado.

| Notebook | Resultado | Duración (s) |
|---|---|---|
| [1_Deploy_Vault_AWS.ipynb](../notebooks/1_Deploy_Vault_AWS.ipynb) | passed | 55.6 |
| [2_GHA_Vault_OIDC.ipynb](../notebooks/2_GHA_Vault_OIDC.ipynb) | passed | 20.5 |
| [3A_JBOSS_WASS_Agent.ipynb](../notebooks/3A_JBOSS_WASS_Agent.ipynb) | passed | 28.4 |
| [3B_JBOSS_DB_Engine_Agent.ipynb](../notebooks/3B_JBOSS_DB_Engine_Agent.ipynb) | passed | 49.0 |
| [4_VSO_CSI.ipynb](../notebooks/4_VSO_CSI.ipynb) | passed | 156.6 |
| [5_Secret_Sync_AWS_IRSA.ipynb](../notebooks/5_Secret_Sync_AWS_IRSA.ipynb) | passed | 12.1 |
| [5_Secret_Sync_AWS_IRSA_AssumeRole.ipynb](../notebooks/5_Secret_Sync_AWS_IRSA_AssumeRole.ipynb) | passed | 12.0 |
| [5_Secret_Sync_AWS_WIF_Doormat.ipynb](../notebooks/5_Secret_Sync_AWS_WIF_Doormat.ipynb) | passed | 15.5 |
| [5_Secret_Sync_AWS_static_account.ipynb](../notebooks/5_Secret_Sync_AWS_static_account.ipynb) | passed | 12.9 |
| [5_Secret_Sync_Azure_CLI_SPN.ipynb](../notebooks/5_Secret_Sync_Azure_CLI_SPN.ipynb) | passed | 7.4 |
| [5_Secret_Sync_Azure_Terraform_SPN.ipynb](../notebooks/5_Secret_Sync_Azure_Terraform_SPN.ipynb) | passed | 30.3 |
| [5_Secret_Sync_Azure_Terraform_WIF.ipynb](../notebooks/5_Secret_Sync_Azure_Terraform_WIF.ipynb) | passed | 31.7 |
| [6_Oracle_DB_Engine.ipynb](../notebooks/6_Oracle_DB_Engine.ipynb) | passed | 68.8 |
| [7_Secret_Migrate_AWS.ipynb](../notebooks/7_Secret_Migrate_AWS.ipynb) | passed | 50.8 |
| [7_Secret_Migrate_Azure.ipynb](../notebooks/7_Secret_Migrate_Azure.ipynb) | passed | 46.9 |
| [8_RBAC_Revoke_Namespace.ipynb](../notebooks/8_RBAC_Revoke_Namespace.ipynb) | passed | 32.5 |
| [9_VAULT_PR.ipynb](../notebooks/9_VAULT_PR.ipynb) | passed | 18.4 |
| [10_PR_config_tasks.ipynb](../notebooks/10_PR_config_tasks.ipynb) | passed | 74.1 |
| [11_Audit_logs_k8s.ipynb](../notebooks/11_Audit_logs_k8s.ipynb) | passed | 4.2 |
| [12_K8S_Engine_Github.ipynb](../notebooks/12_K8S_Engine_Github.ipynb) | passed | 173.8 |
| [13_Grafana_Prometheus_Vault_Telemetry.ipynb](../notebooks/13_Grafana_Prometheus_Vault_Telemetry.ipynb) | passed | 59.7 |
| [14_Vault_Benchmark_Kubernetes_AppRole_KV.ipynb](../notebooks/14_Vault_Benchmark_Kubernetes_AppRole_KV.ipynb) | passed | 117.5 |
| [_Backup_VSO_Openshift.ipynb](../notebooks/_Backup_VSO_Openshift.ipynb) | passed | 21.6 |

## Alcance de la adaptación

- Diez VMs RHEL 9: seis primarias, tres secundarias y una de aplicación. Servicios auxiliares en el EKS existente.
- NLB TCP y certificados Let’s Encrypt instalados directamente en Vault; API 443/8200 y PR 8201. Pruebas adicionales: [NLB/PR y cert auth](../load-balancing/17_NLB_LetsEncrypt_PR.ipynb), [doble FQDN](../load-balancing/16_Dual_FQDN.ipynb) y [AAP](../aap/15_AAP_Vault_AppRole_OIDC.ipynb).
- El caso originalmente estático de AWS usa ahora un rol dedicado, según la instrucción del usuario. No se crean usuarios IAM.
- El complemento llamado OpenShift verifica las dos modalidades JWT/VSO en el EKS disponible. No acredita una ejecución de SCC en OpenShift.
- Estado, tokens, certificados privados y copias ejecutadas se guardan localmente y se excluyen de Git.
- Los recursos permanecen desplegados para continuar la demo.
- GitHub read: [ejecución real](https://github.com/jm-merchan/Vault_Use_Cases_Example_202607/actions/runs/36135438761).
- GitHub engine: [ejecución real](https://github.com/jm-merchan/Vault_Use_Cases_Example_202607/actions/runs/36136589045).

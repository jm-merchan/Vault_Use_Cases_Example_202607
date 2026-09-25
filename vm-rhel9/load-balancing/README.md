# Vault en VMs: NLB TCP y TLS hasta Vault

Los endpoints conservan sus URLs. Los NLB tienen listeners **TCP**, sin certificados ACM ni terminación TLS:

| FQDN | Puertos del NLB → Vault | Destinos |
|---|---|---|
| `vault-vm.jose-merchan.sbx.hashidemos.io` | 443 → 8200, 8200 → 8200, 8201 → 8201 | Líder del primario |
| `vault-vm-apps.jose-merchan.sbx.hashidemos.io` | 443 → 8200, 8200 → 8200 | Activo y cinco performance standbys |
| `vault-vm-secondary.jose-merchan.sbx.hashidemos.io` | 443 → 8200, 8200 → 8200, 8201 → 8201 | Líder del secundario; NLB privado |

Son tres NLB independientes: TCP no permite seleccionar el backend mediante el hostname HTTP. El NLB de aplicaciones distribuye **conexiones TCP mediante flow hashing**, no peticiones HTTP en round robin. Una conexión persistente puede atender muchas peticiones en el mismo nodo. Cross-zone está habilitado; stickiness y preservación de IP de cliente están desactivadas. Vault ve la IP del NLB; esto evita problemas de hairpin cuando las propias VMs usan el endpoint.

El health check HTTPS usa 8200 y acepta únicamente HTTP 200. Administración y PR consultan `/v1/sys/health`; aplicaciones consulta `/v1/sys/health?perfstandbyok=true`. Los checks no terminan el TLS del tráfico de usuarios. Una elección de líder puede producir errores transitorios hasta que se actualicen los destinos saludables; no se promete ausencia de errores durante failover. El NLB también puede hacer fail-open si todos los destinos están enfermos.

## Certificados y nombres de nodo

Vault sirve una cadena de **Let’s Encrypt**, emitida por DNS-01 en Route 53. SAN:

- `vault-vm.jose-merchan.sbx.hashidemos.io`
- `vault-vm-apps.jose-merchan.sbx.hashidemos.io`
- `vault-vm-secondary.jose-merchan.sbx.hashidemos.io`
- `*.vm-vault.jose-merchan.sbx.hashidemos.io`

Caducidad de la emisión del 25 de septiembre de 2026: **24 de diciembre de 2026**. La cadena completa y la clave se instalan en `/etc/vault.d/tls/server.pem` y `server.key`, propiedad de Vault y modo 0600. El certificado incluye los FQDN propios que son alias de los balanceadores; no se puede emitir un certificado para el nombre `*.elb.amazonaws.com` propiedad de AWS.

Cada nodo tiene un FQDN de diagnóstico que resuelve a su IP pública (`primary-0.vm-vault...`) y otro que resuelve a su IP privada (`primary-0-internal.vm-vault...`). Ambos están cubiertos por el wildcard. `api_addr` y `retry_join` usan los nombres privados; Prometheus también usa nombres individuales privados, para obtener métricas de cada nodo sin repartir el scraping entre miembros. El acceso directo por IP a 8200 no pasa validación de nombre: se debe usar el FQDN.

La CA de certificados de **cliente** de la prueba es independiente de Let’s Encrypt. El método `cert` de Vault comprueba ese certificado, limita el CN y entrega una política de solo lectura. Los NLB dejan llegar el handshake original a Vault.

Renovar desde una terminal con Doormat vigente:

```bash
cd vm-rhel9/load-balancing
bash renew-public-certificates.sh
```

El script usa `certbot renew`, despliega la cadena y clave y recarga Vault con SIGHUP si el HCL no cambia. No hay temporizador desatendido: la demo utiliza sesiones personales Doormat temporales. Para operación permanente se debe programar esta tarea desde una identidad de servicio con permisos DNS y de despliegue adecuados. Los comandos y las claves permanecen separados: los archivos sensibles están en `.state` y `$HOME/.vault-demo/letsencrypt-vm`, fuera del repositorio versionado.

## Performance Replication mediante balanceador

La API de bootstrap y el canal de replicación son distintos:

```bash
export VAULT_ADDR=https://vault-vm.jose-merchan.sbx.hashidemos.io
vault write sys/replication/performance/primary/enable \
  primary_cluster_addr=https://vault-vm.jose-merchan.sbx.hashidemos.io:8201

# En el secundario, con una credencial de administración local y el token de activación:
vault write sys/replication/performance/secondary/update-primary \
  token="$ACTIVATION_TOKEN" \
  primary_api_addr=https://vault-vm.jose-merchan.sbx.hashidemos.io \
  ca_file=/etc/pki/tls/certs/ca-bundle.crt
```

`update-primary` conserva el almacenamiento; no se usa `disable` ni se vuelve a inicializar Raft. El notebook muestra la obtención y uso de las credenciales sin imprimir sus valores.

El canal 8201 usa los certificados mTLS que **genera y administra Vault**, no el certificado de Let’s Encrypt de la API. Cada `cluster_addr` permanece como `https://<IP-privada-del-nodo>:8201`. Eso mantiene Raft y request forwarding directos dentro de cada clúster.

Cada clúster tiene su propio security group de 8201 con regla self. El grupo compartido ya no permite 8201 entre VMs de clústeres diferentes; sí permite el tráfico que llega desde el SG del NLB. El NLB primario público admite PR desde la VPC y desde las IP públicas de salida de los secundarios; **8201 no está abierto a todo Internet**. El NLB secundario es interno. En un cliente con interconexión privada se usarían NLB internos y los CIDR/SG de esa interconexión.

En las nueve VMs se habilitan estas cabeceras, en el nivel raíz de `/etc/vault.d/vault.hcl`:

```hcl
enable_response_header_hostname     = true
enable_response_header_raft_node_id = true
```

Las respuestas incluyen `X-Vault-Hostname` y `X-Vault-Raft-Node-ID`. El script de instalación reinicia secuencialmente los nodos si cambia el HCL; una recarga de certificados no basta para activar estos parámetros.

Se omite `resolver_discover_servers`, conservando su [valor predeterminado `true`](https://developer.hashicorp.com/vault/docs/configuration/replication). La recomendación anterior de desactivarlo procedía de un workaround histórico y se retira: el [artículo de IBM](https://www.ibm.com/support/pages/vault-replication-issues-aws-auto-scaling-groups) indica que el defecto descrito se corrigió en 1.13.3, 1.12.7 y 1.11.11. No se presenta ese workaround como requisito para Vault 2.1.1+ent.

```bash
curl -sS -D - -o /dev/null \
  'https://vault-vm-apps.jose-merchan.sbx.hashidemos.io/v1/sys/health?perfstandbyok=true' \
  | grep -i '^x-vault-'
```

Vault puede seguir mostrando IP de nodos en `known_primary_cluster_addrs` e intentar contactarlas durante el descubrimiento. Eso no prueba que la conexión de replicación establecida sea directa. La evaluación bloquea esas rutas directas, reinicia el líder secundario, comprueba `stream-wals`/`ready` y encuentra un socket establecido hacia una IP del NLB en 8201.

Con el valor predeterminado, la prueba del 25-09-2026 recuperó el stream aproximadamente 121 segundos después de la primera solicitud de WAL del nuevo líder secundario. Durante la espera se observaron intentos TCP a IP de nodos bloqueadas por los SG. La reconexión terminó automáticamente por NLB. Es una observación de esta topología, no una garantía de RTO ni una identificación del defecto histórico corregido.

## Notebooks, comandos y evidencia

- [17_NLB_LetsEncrypt_PR.ipynb](17_NLB_LetsEncrypt_PR.ipynb): emisión, instalación gradual, Terraform, PR, aislamiento y login con certificado. [Comandos Bash equivalentes](17_NLB_LetsEncrypt_PR.sh).
- [16_Dual_FQDN.ipynb](16_Dual_FQDN.ipynb): selección del líder, reparto de lecturas entre seis nodos, UI y TLS. [Bash](16_Dual_FQDN.sh).
- [client-cert-results.json](client-cert-results.json): login con certificado, lectura autorizada y pruebas negativas en ambos puertos/FQDN.
- [pr-nlb-results.json](pr-nlb-results.json): aislamiento de las nueve rutas directas y reconexión PR por NLB.
- [results.json](results.json): destinos sanos y distribución de lecturas corroborada con auditoría local.
- [response-headers-results.json](response-headers-results.json): las dos cabeceras en las nueve VMs y en ambos FQDN/puertos; ausencia del override del resolver y verificación de los peers de `retry_join`. Se regenera con [verify-response-headers.sh](verify-response-headers.sh).
- [nlb-evaluation.json](nlb-evaluation.json): resumen de la migración, notebooks, integraciones y límites de la validación.
- [Ejecución de los 23 notebooks](../reports/EVALUATION.md) y [AAP AppRole/OIDC](../aap/evaluation.json).

Terraform está en [nlb.tf](../terraform/infrastructure/nlb.tf), [applications.tf](../terraform/infrastructure/applications.tf) y [main.tf](../terraform/infrastructure/main.tf). Se retiraron el ALB y sus certificados ACM exclusivos de esta versión VM. Los balanceadores de AAP y de los servicios Kubernetes son independientes.

## Integraciones

AAP AppRole/OIDC, Vault Agent/WildFly, VSO, CSI, los dos workflows GitHub, importación AWS/Azure y benchmark usan `VAULT_APPLICATION_ADDR`. Los 18 notebooks de integración seleccionan explícitamente este endpoint. El issuer global OIDC/WIF conserva la URL administrativa para mantener la confianza de AWS y Azure. El cambio de balanceador y certificado no cambia las URLs ni audiencias.

[check-integration-endpoints.sh](check-integration-endpoints.sh) comprueba las configuraciones desplegadas y genera [integration-endpoints.json](integration-endpoints.json). En Secrets Sync la transferencia sigue siendo Vault → AWS/Azure; el FQDN de aplicaciones sirve para configurar y probar el caso.

## ALB y autenticación con certificados

ALB termina TLS. Su modo denominado **mTLS passthrough** reenvía el certificado en una cabecera HTTP; no transporta la sesión TLS original. Vault soporta certificados reenviados por un proxy de confianza, pero el proxy debe validar el certificado y hay que proteger y configurar explícitamente esa confianza. Por tanto, es posible diseñar autenticación `cert` detrás de ALB con verificación/cabeceras, pero no equivale a passthrough TCP y no sirve para PR 8201. Esta demo usa NLB y no confía en cabeceras de certificado.

El ejemplo original de Kubernetes tiene anotación `aws-load-balancer-type: nlb`, con puertos TCP 443 → 8200 y 8201 → 8201; por eso puede entregar el certificado del cliente a Vault directamente.

Fuentes: [AWS ALB mTLS](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/mutual-authentication.html), [Vault cert auth y proxies](https://developer.hashicorp.com/vault/docs/auth/cert), [Vault PR y balanceadores](https://developer.hashicorp.com/vault/tutorials/monitoring/monitor-replication#port-traffic-consideration-with-load-balancer), [API de PR](https://developer.hashicorp.com/vault/api-docs/system/replication/replication-performance).

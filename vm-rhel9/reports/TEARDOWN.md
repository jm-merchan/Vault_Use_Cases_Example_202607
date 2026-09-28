# Retirada de los recursos — 25 de septiembre de 2026

La infraestructura de la demo está retirada. Se conservan el código, los notebooks, las ramas GitHub, el workspace HCP Terraform y el paquete de instalación de AAP. Los informes de evaluación y acceso anteriores son históricos; sus endpoints ya no están desplegados.

## Resultado verificado

- Once VMs terminadas: seis Vault primarias, tres secundarias, una de aplicación y una de AAP. Sin discos, grupos de seguridad ni roles IAM de la variante VM activos.
- Terraform local: 83 recursos de infraestructura VM y 16 de AAP eliminados. Los ocho estados locales de infraestructura e integraciones quedan vacíos.
- Retirados los NLB de Vault y de los servicios auxiliares, el ALB de AAP, sus DNS y los certificados ACM gestionados por Terraform.
- Kubernetes: eliminados los seis namespaces `vm-*`, los releases Helm `vm-vso` y `vm-csi`, sus CRD y el ClusterRoleBinding del reviewer.
- AWS: retirados los roles, políticas, proveedor OIDC y secretos de los escenarios VM.
- Azure: eliminados los tres grupos de recursos, sus aplicaciones y service principals; purgados los tres Key Vaults.
- Después de verificar la retirada anterior, HCP Terraform eliminó los **75 recursos** de `eks-infra-vcs`. El estado final tiene **0 recursos gestionados**. AWS confirma que `eks-infra-dev` y su VPC ya no existen.

[Ejecución HCP Terraform completada](https://app.terraform.io/app/jose-merchan/workspaces/eks-infra-vcs/runs/run-y47MfAeTeiYqVVz1). Aplicación terminada el 25-09-2026 a las 14:42:50 UTC.

Durante el vaciado de los nodos se retiraron los PDB de CoreDNS y EBS CSI, ambos con cero desalojos permitidos. Solo quedaban componentes del sistema; el borrado de la infraestructura continuó en la misma ejecución de HCP Terraform.

## Borrado diferido de KMS

Las claves KMS de Vault y EKS están en `PendingDeletion`, desactivadas y programadas para eliminación el **25 de octubre de 2026**. No se afirma que ya se hayan purgado físicamente. Sus identificadores y fechas devueltas por AWS están en [TEARDOWN.json](TEARDOWN.json).

## Paquete de AAP y código conservado

`aap/install.sh` usa por defecto el archivo `ansible-automation-platform-containerized-setup-bundle-2.7-1.1-x86_64.tar.gz` situado en la raíz de `vm-rhel9/`. Se mantiene el argumento opcional para indicar otra ruta. README y notebook actualizados; no se ha vuelto a instalar AAP durante la retirada.

SHA-256 verificado: `12343d643503d61fb0353f9af167a8f6cf0e6e53a5f7b206c1900fb4f9610863`. Sintaxis Bash verificada. El paquete permanece local y está excluido de Git.

Los estados y datos privados de ejecuciones anteriores se conservan en `.state/` como evidencia; no acreditan recursos actualmente desplegados. Los logs de retirada están en `.state/cleanup/`.

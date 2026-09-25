# Acceso a la variante VM

Vault: https://vault-vm.jose-merchan.sbx.hashidemos.io/ui/

Aplicaciones: https://vault-vm-apps.jose-merchan.sbx.hashidemos.io (activo y performance standbys).

Login: método Token, namespace vacío (root). El token vigente está en `.state/primary-init.json`.

Desde `vm-rhel9`, copiarlo al portapapeles de macOS sin imprimirlo:

```bash
jq -r '.root_token' .state/primary-init.json | pbcopy
```

SSH: usuario `ec2-user`, clave `.state/id_ed25519`; usar `sudo -i` dentro de la VM.

| Nodo | IP pública | Comando desde vm-rhel9 |
|---|---|---|
| app | 51.102.241.71 | `ssh -i .state/id_ed25519 ec2-user@51.102.241.71` |
| primary-0 | 63.177.229.10 | `ssh -i .state/id_ed25519 ec2-user@63.177.229.10` |
| primary-1 | 3.120.206.137 | `ssh -i .state/id_ed25519 ec2-user@3.120.206.137` |
| primary-2 | 3.68.224.135 | `ssh -i .state/id_ed25519 ec2-user@3.68.224.135` |
| primary-3 | 63.185.114.176 | `ssh -i .state/id_ed25519 ec2-user@63.185.114.176` |
| primary-4 | 63.176.59.22 | `ssh -i .state/id_ed25519 ec2-user@63.176.59.22` |
| primary-5 | 18.157.77.61 | `ssh -i .state/id_ed25519 ec2-user@18.157.77.61` |
| secondary-0 | 63.189.6.251 | `ssh -i .state/id_ed25519 ec2-user@63.189.6.251` |
| secondary-1 | 63.187.42.61 | `ssh -i .state/id_ed25519 ec2-user@63.187.42.61` |
| secondary-2 | 18.159.141.153 | `ssh -i .state/id_ed25519 ec2-user@18.159.141.153` |

SSH está limitado a la IP pública del operador registrada en el despliegue.

Durante la conversión a Bash se sustituyeron accidentalmente las diez VMs al cambiar el orden de subredes. Estas son las IP posteriores a esa sustitución; el token de bootstrap también se regeneró. El notebook de despliegue conserva ahora el orden registrado y bloquea planes con destrucciones o sustituciones.

# Validación documental — 25-09-2026

**Resultado: comprobaciones locales correctas.** Se revisaron el README principal, la documentación de ejecución de la variante VM y las instrucciones de sus 26 notebooks. No se desplegaron recursos ni se repitieron pruebas funcionales: la infraestructura ya estaba retirada.

## Comprobaciones

| Alcance | Resultado |
|---|---|
| 10 documentos Markdown, incluido este informe | Revisados; estado histórico y prerrequisitos aclarados. |
| 26 notebooks VM | Esquema válido; 23 casos del mapa más AAP y los dos complementos de balanceo. |
| 126 celdas operativas y 27 bloques Bash documentados | Sintaxis correcta con `bash -n`; los comandos no se ejecutaron. |
| 45 archivos Bash y un bloque YAML documentado | Sintaxis correcta. |
| 118 enlaces locales | Destino y anclas Markdown válidos; sin enlaces a archivos ignorados. |
| 23 notebooks principales y sus copias ejecutadas históricas | Código operativo idéntico. |
| 25 notebooks previamente versionados | Celdas de código, metadatos de ejecución y salidas sin cambios respecto a Git; solo cambió Markdown. |
| Generador de notebooks | En un directorio temporal, reproduce el contenido de los 23 notebooks y sus 23 copias Bash; IDs de celda excluidos de la comparación. |
| Generador de informes | Comprobado con datos históricos y una evaluación posterior ficticia en un directorio temporal; mantiene el aviso fechado de retirada y no afirma disponibilidad actual. |
| Cobertura, sintaxis Python y formato Terraform | `scripts/validate.py`: 23/23, sin errores. |

Detalle reproducible: [documentation-validation.json](documentation-validation.json). Desde `vm-rhel9`, ejecutar `.venv/bin/python scripts/validate_docs.py`. Es una comprobación local: recopila referencias externas pero no hace peticiones de red ni ejecuta infraestructura. Las pruebas del generador se hicieron aparte con copias temporales.

## Referencias externas

Se comprobaron las 16 referencias públicas de producto: 13 devolvieron HTTP 200. Las tres páginas de documentación Red Hat devolvieron 403 al cliente HTTP automatizado, pero pudieron recuperarse mediante la herramienta de navegación con sus títulos y contenido. No se detectaron páginas 404. El detalle y las URLs están en [documentation-external-links.json](documentation-external-links.json).

No se utilizó el acceso a HCP Terraform/GitHub ni la disponibilidad de los endpoints retirados como condición para validar esta documentación. Las URLs de ejecuciones y jobs son referencias históricas; una respuesta HTTP de una página de documentación tampoco acredita una instalación funcional.

## Correcciones

- [EXECUTION.md](../EXECUTION.md) concentra preparación, autenticación, estado antiguo, dependencias de los 23 casos, ejecución de los tres complementos, acceso y orden de retirada.
- Los README, instrucciones de notebooks y reportes distinguen resultados históricos de un nuevo despliegue. El generador mantiene esa distinción al regenerar informes.
- AAP usa el bundle situado en `vm-rhel9/`; se documentan el manifiesto independiente, la espera del instalador y los IDs obtenidos del nuevo controller. La tabla histórica coincide con los jobs 26–30 de `evaluation.json`.
- El ejemplo de PR dirige explícitamente `update-primary` al secundario y emplea su credencial. El notebook 17 requiere PR activa después de 1 → 9 → 10.
- Los 23 casos siguen mostrando Bash, Vault CLI, AWS CLI, Azure CLI y curl. El generador conserva las correcciones documentales sin cambiar sus operaciones.
- La regla genérica `*backup*` ocultaba las dos fuentes VM de `_Backup_VSO_Openshift`; se añadieron excepciones específicas en `vm-rhel9/.gitignore`. No se incorporaron archivos privados.
- Se documenta que `cleanup.py` es parcial y que EKS se retira al final mediante HCP Terraform.

La guía de redespliegue ha sido revisada contra el código y validada estáticamente. No se afirma que se haya vuelto a ejecutar de principio a fin después de la retirada. Las pruebas funcionales conservadas siguen siendo las de [EVALUATION.md](EVALUATION.md), anteriores al destroy.

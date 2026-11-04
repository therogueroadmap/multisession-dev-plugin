# Tests

Las pruebas usan Pester 3.4.0 sobre PowerShell 7. Para correr un archivo:

```powershell
pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests\Dashboard.Tests.ps1'
```

Para correr toda la suite, usa `-Path tests`.

## Dependencias opcionales

### node

`node` (version 18 o superior) es una dependencia opcional de test. Los `It` de
`tests\Dashboard.Tests.ps1` que ejecutan el bloque puro de `assets\dashboard.html`
(entre `// == puro:inicio ==` y `// == puro:fin ==`) lo usan para evaluar las funciones
sin navegador. Son 9 en las tareas 2a y 2b y 6 en la tarea 3.

Sin `node` esos `It` se omiten con `-Skip:$noNode` y el resto de la suite corre igual.
Para comprobar la version instalada:

```powershell
node --version
```

### python

Los `It` que levantan el servidor del dashboard (`scripts\dashboard\server.py`) con las
fixtures de `tests\fixtures\dashboard` requieren `python`; sin el se omiten con `-Skip:$noPython`.

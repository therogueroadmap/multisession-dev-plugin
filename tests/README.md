# Tests

Las pruebas usan Pester 3.4.0 sobre PowerShell 7. Para correr un archivo:

```powershell
pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests\Dashboard.Tests.ps1'
```

There are two ways to run the suite:

```powershell
# Quick (about 2 min): skips the end-to-end driver tests, tagged Slow
pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests -ExcludeTag Slow'
# Full (about 7-8 min): for the close
pwsh -NoProfile -Command 'Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester -Path tests'
```

To run only the slow part, use `-Tag Slow` (about 5 min). The tests that wait for the decision deadline use the `PLAN_DRIVER_AWAIT_DECISION_SECONDS` hook (seconds, tests only) instead of waiting minutes.

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

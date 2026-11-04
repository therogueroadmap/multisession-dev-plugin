[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    # Tope de sesiones de esta corrida. 0 = automatico (Fase 4, M12): se deriva
    # del plan como (niveles pendientes + cierre pendiente) x (1 + NoProgressRetries);
    # sin plan o sin niveles conocidos, 30. Un valor > 0 se respeta tal cual.
    [ValidateRange(0, 1000)]
    [int]$MaxIterations = 0,

    [int]$Port = 8787,

    # Minutos sin peticiones antes de que el servidor del dashboard se apague solo.
    [ValidateRange(1, 10080)]
    [int]$DashboardIdleMinutes = 120,

    [string]$PlanFile,

    [string]$WorkDir,

    [string]$BranchName,

    # Trabaja sobre la rama ya activa en lugar de crear una nueva desde
    # develop/main/master en el bootstrap. Exige working tree limpio. Ignora -BranchName.
    [switch]$UseCurrentBranch,

    # Si no hay senal de progreso (CPU, stdout, stderr, .controller-state.json)
    # durante este tiempo, la sesion se considera colgada. No hay forma de
    # desbloquearla desde afuera (corre en -p con el perfil de permisos plan,
    # sin stdin abierto), asi que se mata el proceso y el driver PARA con un
    # reporte de la causa.
    [int]$LivenessTimeoutMinutes = 30,

    [int]$LivenessPollSeconds = 30,

    # Techo de espera de tareas en background de "claude -p"
    # (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS; su default interno es 600000 ms y
    # cortaba niveles cuyo implementer tardaba mas de 10 min). 0 = esperar
    # indefinidamente: el watchdog de inactividad (LivenessTimeoutMinutes) queda
    # como unica autoridad de corte. El techo mide tiempo total, no inactividad.
    # Si no se pasa y la variable ya existe en el entorno, se hereda.
    [int]$BackgroundWaitCeilingMs = 0,

    # Reintentos del mismo paso cuando una sesion no avanza el checkpoint
    # (CONTINUE sin avance, o sin marca y sin otra senal). Agotados, el driver
    # para: BLOCKED si la sesion dijo CONTINUE, FAILED si no emitio marca.
    [ValidateRange(0, 10)]
    [int]$NoProgressRetries = 1,

    # Modelo de todas las sesiones headless (--model). Vacio se rechaza al
    # arrancar: si no, la sesion corre y New-SessionTelemetry falla despues.
    [ValidateNotNullOrEmpty()]
    [string]$Model = 'claude-opus-5-5',

    # Effort de las sesiones de nivel (bootstrap/continue) y de la sesion de
    # cierre. Bajar el de cierre es arriesgado: la revision final es la ultima
    # compuerta antes de DONE (sesion 6ad16ad4).
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$LevelEffort = 'high',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$CloseEffort = 'high',

    # Reintentos por sesion ante fallos transitorios (red, 5xx, 429, sesion
    # colgada), con --resume. 0 desactiva el reintento. No consumen el
    # presupuesto de sesiones ni incrementan el numero de sesion.
    [ValidateRange(0, 10)]
    [int]$MaxTransientRetries = 2,

    # Espera en segundos antes del intento k (indice k-1; el ultimo valor se
    # repite si hay mas reintentos que valores).
    [ValidateRange(0, 86400)]
    [int[]]$RetryBackoffSeconds = @(60, 300),

    # Webhook opcional (compatible con ntfy) para el aviso al terminar. Vacio
    # lo omite. La URL completa no se guarda en el status.
    [string]$NotifyUrl = '',

    # Ola 2b (A2/A5): minutos que dura una pausa antes de cerrar como STOPPED (pausa_vencida). 0 = sin plazo.
    [ValidateRange(0, 1440)]
    [int]$AwaitDecisionMinutes = 480,

    # Ola 2b (A5): tope de costo en USD; 0 = sin tope. 2b lo publica y lo edita; 2c lo aplica (DO-8).
    [ValidateRange(0, 1000)]
    [double]$MaxCostUsd = 0,

    # Ola 3 (D8): restituye --dangerously-skip-permissions en lugar del perfil plan. Nunca por entorno ni por el canal.
    [switch]$UnsafeSkipPermissions,
    # Ola 6 (DT-22..24): servidores MCP que ven las sesiones, por su nombre en "claude mcp list".
    # Vacio = ninguno (--strict-mcp-config). '*' = todos los globales. Con nombres, el resto se oculta
    # con --disallowedTools; requiere -UnsafeSkipPermissions. Nunca por entorno ni por el canal.
    [string[]]$AllowMcp = @(),

    # Omite el toast de Windows del aviso final (los tests lo usan siempre).
    [switch]$NoToast
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $scriptRoot 'modules'
$assetsDir = Join-Path (Split-Path -Parent $scriptRoot) 'assets'

Import-Module (Join-Path $modulesDir 'StatusLine.psm1') -Force
Import-Module (Join-Path $modulesDir 'LogReader.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverStatus.psm1') -Force
Import-Module (Join-Path $modulesDir 'PlanProgress.psm1') -Force
Import-Module (Join-Path $modulesDir 'HttpDashboard.psm1') -Force
Import-Module (Join-Path $modulesDir 'GitWorkspace.psm1') -Force
Import-Module (Join-Path $modulesDir 'WorkspaceLayout.psm1') -Force
Import-Module (Join-Path $modulesDir 'ProcessLauncher.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverInterrupt.psm1') -Force
Import-Module (Join-Path $modulesDir 'SessionStream.psm1') -Force
Import-Module (Join-Path $modulesDir 'SessionRetry.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverNotify.psm1') -Force
Import-Module (Join-Path $modulesDir 'GitSummary.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverControl.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverOpen.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverProfile.psm1') -Force
Import-Module (Join-Path $modulesDir 'PlanTasks.psm1') -Force
Import-Module (Join-Path $modulesDir 'DriverMcp.psm1') -Force

# Ola 3 (D8): permisos de las sesiones. Por defecto el perfil plan (--settings); con
# -UnsafeSkipPermissions vuelve el flag de permisos saltados, que solo aparece en esta rama.
# El perfil se valida aqui; si es invalido, el bucle principal cierra FAILED perfil_invalido
# antes de lanzar nada.
$profilePath = Resolve-DriverProfile -ScriptRoot $scriptRoot
$profileCheck = if ($UnsafeSkipPermissions) { $null } else { Test-DriverProfile -Path $profilePath }
$permissionArgs = if ($UnsafeSkipPermissions) { @('--dangerously-skip-permissions') } else { @('--settings', $profilePath) }
if ($UnsafeSkipPermissions) { Write-Warning 'Permisos: sin restricciones (-UnsafeSkipPermissions)' }

# 'sum' si total_cost_usd no acumula entre intentos de --resume; 'lastAttempt' si acumula (lo decide el paso Q, PA-9)
$notifyCostMode = 'sum'

# Ventana (lineas no vacias al final del log) donde se busca la ultima marca
# PLAN_STATUS. Tolera texto colgante debajo de la marca sin aceptar una marca
# perdida muy arriba de un log largo.
$PLAN_STATUS_TAIL_LINES = 50

$CLOSE_PROMPT_TEMPLATE = @'
No actives el skill caveman ni ningún modo de compresión de salida en esta
sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa
normal.

El plan de implementación __PLAN__ ya tiene todos sus niveles implementados.

Corre ÚNICAMENTE la revisión final del código completo: despacha un reviewer
read-only con modelo Opus sobre toda la implementación y escribe sus findings
en el archivo __MARKER__. NO ejecutes finishing-a-development-branch ni hagas
merge, push ni PR: esa fase es interactiva y la hará un humano después.

Esta sesión corre en modo headless, sin supervisión humana:
[AUTOPILOT: full], incluida autorización previa para "git commit".

Nadie leerá ni responderá preguntas durante esta sesión. Si llegas a una
decisión de diseño abierta, a una ambigüedad del plan o a cualquier punto que
necesite una respuesta humana, NO la formules como pregunta en prosa: termina
con la marca PLAN_STATUS: BLOCKED: <la decisión o pregunta, en una sola línea>.

Espera a que el reviewer termine (despáchalo en primer plano) y a que
__MARKER__ esté escrito antes de emitir PLAN_STATUS: COMPLETE.

El archivo __MARKER__ debe seguir este formato, porque el dashboard lo lee:

**Veredicto:** <texto breve del veredicto>

| # | Severidad | Ubicación | Descripción | Fix sugerido |
|---|---|---|---|---|
| 1 | MINOR | <archivo:línea> | <descripción en una línea> | <fix sugerido> |

La celda Severidad lleva exactamente CRITICAL, IMPORTANT o MINOR, en mayúsculas
y sin otro texto. Una fila por finding. Si no hay findings, deja la tabla solo
con el encabezado. Puedes agregar secciones de detalle debajo de la tabla.

Al terminar, agrega como última línea de tu respuesta EXACTAMENTE una de estas
marcas (nada más en esa línea):

PLAN_STATUS: COMPLETE
  (la revisión final terminó y los findings quedaron escritos en __MARKER__)

PLAN_STATUS: BLOCKED: <motivo breve>
  (la revisión encontró algo que impide cerrar)
'@

$repoRoot = Resolve-RepoRoot -ProjectPath $ProjectPath -WorkDir $WorkDir
if ($WorkDir) {
    if (-not (Test-Path -LiteralPath $repoRoot)) {
        throw "El subproyecto -WorkDir resuelto a '$repoRoot' no existe."
    }
    if (-not (Test-GitRepo -RepoRoot $repoRoot)) {
        throw "El subproyecto -WorkDir '$repoRoot' no es un repositorio git."
    }
}
else {
    # M7 (corto plazo): sin -WorkDir, ProjectPath debe ser un repo git. Se valida
    # antes de crear carpetas: una raiz multi-repo aborta nombrando sus repos.
    Assert-ProjectIsRepo -ProjectPath $repoRoot
}
$plansDir = Join-Path $ProjectPath 'docs\superpowers\plans'
if (-not (Test-Path -LiteralPath $plansDir)) {
    New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
}

# Resolucion endurecida de -PlanFile (ver docs/specs/2026-09-12-plan-session-driver-design.md, 1.1):
# - sin -PlanFile: autodetecta si hay exactamente 1 .md en $plansDir; con 2+ falla temprano
#   (antes: autodetectaba en silencio, solo afectaba el progreso del dashboard); con 0, sin cambios.
# - con -PlanFile de nombre pelado (sin separador de carpeta): se resuelve dentro de $plansDir.
# - con -PlanFile de ruta con carpeta o absoluta: sin cambios (relativa a $ProjectPath, o tal cual).
if (-not $PlanFile) {
    $candidates = Get-ChildItem -LiteralPath $plansDir -Filter '*.md' -File -ErrorAction SilentlyContinue
    if ($candidates.Count -eq 1) {
        $PlanFile = $candidates[0].FullName
    }
    elseif ($candidates.Count -gt 1) {
        $candidateNames = ($candidates | ForEach-Object { $_.Name }) -join ', '
        throw "Hay multiples planes en '$plansDir': $candidateNames. Especifica -PlanFile <nombre> para indicar cual arrancar o continuar."
    }
}
elseif ([System.IO.Path]::IsPathRooted($PlanFile)) {
    # ruta absoluta: se usa tal cual
}
elseif ($PlanFile -notmatch '[\\/]') {
    # nombre pelado, sin carpeta: se resuelve dentro de docs\superpowers\plans
    $PlanFile = Join-Path $plansDir $PlanFile
}
else {
    # ruta relativa con carpeta: comportamiento original, relativa a ProjectPath
    $PlanFile = Join-Path $ProjectPath $PlanFile
}

if ($PlanFile -and -not (Test-Path -LiteralPath $PlanFile)) {
    throw "El plan '-PlanFile' resuelto a '$PlanFile' no existe. Verifica la ruta o el nombre del archivo."
}

# Ruta del plan antes de Copy-PlanIfMissing: su carpeta es candidata a guardar
# un checkpoint perdido (fix 3, en el bloque bootstrap).
$originalPlanFile = $PlanFile

# Fix 4 del tercer modo de fallo: sin -WorkDir, un plan fuera del repo haria que
# la sesion guardara el checkpoint junto al plan, donde el driver no lo ve.
# Se rechaza antes de publicar el status y abrir el dashboard.
if (-not $WorkDir -and $PlanFile) {
    Assert-PlanInsideRepo -RepoRoot $repoRoot -PlanFilePath $PlanFile
}

$effectivePlansDir = Get-EffectivePlansDir -RepoRoot $repoRoot
if (-not (Test-Path -LiteralPath $effectivePlansDir)) {
    New-Item -ItemType Directory -Path $effectivePlansDir -Force | Out-Null
}
if ($WorkDir -and $PlanFile) {
    $PlanFile = Copy-PlanIfMissing -PlanFilePath $PlanFile -DestPlansDir $effectivePlansDir
}

$statusPath = Join-Path $effectivePlansDir '.driver-status.json'
$controllerStatePath = Join-Path $effectivePlansDir '.controller-state.json'
$logsDir = Join-Path $effectivePlansDir '.driver-logs'
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

# Ola 2b: una orden pendiente de otra corrida (o su .tmp a medio escribir) no debe
# aplicarse a esta. Se borra antes de crear el status y de lanzar el dashboard.
$controlPath = Join-Path $effectivePlansDir '.driver-control.json'
foreach ($orphanControl in @($controlPath, "$controlPath.tmp")) {
    if (Test-Path -LiteralPath $orphanControl) {
        try {
            Remove-Item -LiteralPath $orphanControl -Force -ErrorAction Stop
            Write-Host 'Se borró una orden pendiente de una corrida anterior (.driver-control.json).'
        }
        catch { Write-Warning "No se pudo borrar la orden pendiente '$orphanControl': $($_.Exception.Message)" }
    }
}

# Ola 2c (A6): gancho de prueba. Existe para las pruebas de punta a punta; en uso normal no se define.
# PLAN_DRIVER_OPEN_LOG es la ruta absoluta de un .jsonl donde A6 registra el comando en lugar de abrir nada.
$openRecordPath = $null
if ($env:PLAN_DRIVER_OPEN_LOG) {
    if (-not [IO.Path]::IsPathRooted($env:PLAN_DRIVER_OPEN_LOG) -or -not $env:PLAN_DRIVER_OPEN_LOG.EndsWith('.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PLAN_DRIVER_OPEN_LOG invalido: $($env:PLAN_DRIVER_OPEN_LOG)"
    }
    $openRecordPath = $env:PLAN_DRIVER_OPEN_LOG
}

# Marcador de cierre: su existencia distingue el modo "close" del "done".
$finalReviewMarkerPath = $null
$planRelativeForPrompt = $PlanFile
if ($PlanFile) {
    $planLeaf = [System.IO.Path]::GetFileNameWithoutExtension($PlanFile)
    $finalReviewMarkerPath = Join-Path $effectivePlansDir ".final-review-$planLeaf.md"
    $planRelativeForPrompt = Get-PathRelativeTo -BasePath $repoRoot -FullPath $PlanFile
}

# Ruta relativa del marcador para el prompt de cierre (el proyecto puede tener espacios).
$markerRelativeForPrompt = if ($finalReviewMarkerPath) {
    'docs\superpowers\plans\' + [System.IO.Path]::GetFileName($finalReviewMarkerPath)
}
else { $null }

# Prompt de nivel: mismo para bootstrap y continue. Cada sesión es de contexto
# limpio, así que nombra el plan explícitamente cuando se conoce.
$LEVEL_PROMPT = if ($PlanFile) {
    @"
No actives el skill caveman ni ningún modo de compresión de salida en esta
sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa
normal.

Ejecuta el plan de implementación $planRelativeForPrompt con la skill
my-subagent-driven-development, pero ejecuta ÚNICAMENTE el próximo nivel de
dependencia pendiente (búscalo en .controller-state.json; si no existe
checkpoint, empieza por el primer nivel). Completa su ciclo de review/fix,
actualiza el checkpoint y detente sin empezar el siguiente nivel.

Límite de re-revisiones: cada tarea admite como máximo 3 re-revisiones después
de su primera revisión. Los revisores juzgan contra la spec de la tarea, su
criterio de hecho y los riesgos aceptados del plan; un hallazgo fuera de ese
alcance se registra como concern, no como fix. Si después de la tercera
re-revisión solo quedan hallazgos de ese tipo, no despaches otro fix: cierra la
tarea como DONE_WITH_CONCERNS y registra esos hallazgos en el campo concerns de
la tarea en .controller-state.json. Si queda un hallazgo que incumple la spec o
el criterio de hecho, emite PLAN_STATUS: BLOCKED: <motivo>. Esta regla
prevalece sobre las instrucciones de la skill.

Cada vez que despaches un subagente, empieza su ``description`` con el código
de la tarea del plan (por ejemplo, «T4 implementar transiciones» o «T4 revisión
de calidad»). Si el despacho no corresponde a una tarea, no pongas código.

Esta sesión corre en modo headless, sin supervisión humana:
[AUTOPILOT: full], incluida autorización previa para "git commit".

Nadie leerá ni responderá preguntas durante esta sesión. Si llegas a una
decisión de diseño abierta, a una ambigüedad del plan o a cualquier punto que
necesite una respuesta humana, NO la formules como pregunta en prosa: termina
con la marca PLAN_STATUS: BLOCKED: <la decisión o pregunta, en una sola línea>.

Corre la verificación de cierre del nivel (la suite completa) en primer plano,
nunca en background, y espera su resultado. Emite PLAN_STATUS: CONTINUE solo
después de que esa verificación termine en verde y de que el checkpoint
.controller-state.json esté actualizado. Si la verificación falla y no puedes
corregirla, emite PLAN_STATUS: BLOCKED: <motivo>.

Al terminar, agrega como última línea de tu respuesta EXACTAMENTE una de estas
marcas (nada más en esa línea):

PLAN_STATUS: CONTINUE
  (terminaste el nivel sin problemas; el driver decide si quedan más)

PLAN_STATUS: BLOCKED: <motivo breve>
  (hay algo que requiere una decisión humana antes de seguir)
"@
}
else {
    @'
No actives el skill caveman ni ningún modo de compresión de salida en esta
sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa
normal.

Continuar con la próxima sesión, ejecutando ÚNICAMENTE el próximo nivel de
dependencia pendiente con my-subagent-driven-development y deteniéndote sin
empezar el siguiente.

Límite de re-revisiones: cada tarea admite como máximo 3 re-revisiones después
de su primera revisión. Los revisores juzgan contra la spec de la tarea, su
criterio de hecho y los riesgos aceptados del plan; un hallazgo fuera de ese
alcance se registra como concern, no como fix. Si después de la tercera
re-revisión solo quedan hallazgos de ese tipo, no despaches otro fix: cierra la
tarea como DONE_WITH_CONCERNS y registra esos hallazgos en el campo concerns de
la tarea en .controller-state.json. Si queda un hallazgo que incumple la spec o
el criterio de hecho, emite PLAN_STATUS: BLOCKED: <motivo>. Esta regla
prevalece sobre las instrucciones de la skill.

Cada vez que despaches un subagente, empieza su `description` con el código
de la tarea del plan (por ejemplo, «T4 implementar transiciones» o «T4 revisión
de calidad»). Si el despacho no corresponde a una tarea, no pongas código.

Esta sesión corre en modo headless, sin supervisión humana:
[AUTOPILOT: full], incluida autorización previa para "git commit".

Nadie leerá ni responderá preguntas durante esta sesión. Si llegas a una
decisión de diseño abierta, a una ambigüedad del plan o a cualquier punto que
necesite una respuesta humana, NO la formules como pregunta en prosa: termina
con la marca PLAN_STATUS: BLOCKED: <la decisión o pregunta, en una sola línea>.

Corre la verificación de cierre del nivel (la suite completa) en primer plano,
nunca en background, y espera su resultado. Emite PLAN_STATUS: CONTINUE solo
después de que esa verificación termine en verde y de que el checkpoint
.controller-state.json esté actualizado. Si la verificación falla y no puedes
corregirla, emite PLAN_STATUS: BLOCKED: <motivo>.

Al terminar, agrega como última línea de tu respuesta EXACTAMENTE una de estas
marcas (nada más en esa línea):

PLAN_STATUS: CONTINUE
PLAN_STATUS: BLOCKED: <motivo breve>
'@
}

$CLOSE_PROMPT = $null
if ($PlanFile) {
    $CLOSE_PROMPT = $CLOSE_PROMPT_TEMPLATE.Replace('__PLAN__', $planRelativeForPrompt).Replace('__MARKER__', $markerRelativeForPrompt)
}

# D7: archivado del status previo y herencia del historial. $iterBase es el
# numero de sesion con el que arranca esta corrida (0 si no hereda).
$iterBase = 0
try { $firstDecision = Get-PlanBootstrapDecision -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath -FinalReviewMarkerPath $finalReviewMarkerPath } catch { Write-Warning "No se pudo calcular la decision inicial: $($_.Exception.Message)"; $firstDecision = [pscustomobject]@{ Mode = 'bootstrap' } }
try { $archive = Save-DriverStatusArchive -StatusPath $statusPath } catch { Write-Warning "No se pudo archivar el status previo: $($_.Exception.Message)"; $archive = $null }
$inherit = $false
if ($archive -and $archive.Readable) {
    try { $inherit = Test-DriverStatusInheritable -Previous $archive.Previous -PlanFile $PlanFile -CurrentBranch (Get-CurrentBranch -RepoRoot $repoRoot) -FirstMode $firstDecision.Mode } catch { Write-Warning "No se pudo evaluar la herencia del historial: $($_.Exception.Message)"; $inherit = $false }
}
$previousRun = $null
if ($archive) {
    $previousRun = [pscustomobject]@{
        file         = $archive.RelativePath
        globalStatus = $(if ($archive.Readable) { $archive.Previous.globalStatus } else { $null })
        inherited    = $inherit
    }
}
# La creacion del status no va en try: si falla, el driver no puede seguir.
$newStatus = New-DriverStatus -StatusPath $statusPath -ProjectPath $ProjectPath -PlanFile $PlanFile -HeartbeatSeconds $LivenessPollSeconds -PreviousRun $previousRun -InheritFrom $(if ($inherit) { $archive.Previous } else { $null })
if ($inherit) {
    $iterBase = Get-DriverStatusMaxIter -Status $newStatus
    Write-Host "Historial heredado de la corrida anterior ($($archive.RelativePath)); las sesiones siguen desde la $($iterBase + 1)."
}
elseif ($archive) {
    Write-Host "Status anterior archivado en $($archive.RelativePath)."
}

# Fase 1b (B-4): try/finally exterior. Un Ctrl+C (PipelineStoppedException) corta
# el script en cualquier punto; el finally cierra el arbol de claude y deja el
# status en STOPPED en vez de RUNNING. Las variables de la sesion en curso se
# inicializan aqui para que el finally las vea aunque el bucle no haya empezado.
# El cuerpo no se reindenta (el archivo ya tiene un try sin indentar en Push-Location).
# $driverFailed marca que el catch exterior ya trato un fallo del driver (y guarda su mensaje).
$proc = $null; $launch = $null; $sessionId = $null; $logPath = $null; $streamPath = $null; $errLogPath = $null; $sessionEffort = $LevelEffort; $driverFailed = $false; $driverError = $null
$dashboard = $null
# Ola 2b: estado del canal de control (pausa pedida, causa del final, valores capturados al lanzar cada intento).
$pauseRequested = $false; $pauseActionId = $null; $pauseSince = $null; $pauseDeadline = $null; $finalCause = $null
$attemptModel = $Model; $attemptLivenessMinutes = $LivenessTimeoutMinutes; $controlToken = $null
# Ola 2c: estado de la espera de decision (AWAITING) y texto de A1 pendiente para la sesion nueva.
# Gancho de prueba: existe para las pruebas de punta a punta; en uso normal no se define.
# PLAN_DRIVER_AWAIT_WITHOUT_DASHBOARD=1 permite AWAITING aunque no haya dashboard (PC-1).
$awaitSince = $null; $awaitDeadline = $null; $awaitBlock = $null; $awaitContext = $null; $awaitDecision = $null
$pendingDecisionText = $null
$answerFallbackText = $null
try {

# Ola 3 (I7): publica el bloque tasks (Dependency Map cruzado con el checkpoint) en cada punto
# donde se publica levelTaskCounts. Nunca corta el bucle: un fallo solo deja un aviso.
function Publish-DriverTasks {
    try {
        $block = Get-PlanTasks -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath
        if ($null -ne $block) { Set-DriverStatusBlock -StatusPath $statusPath -Name tasks -Value $block | Out-Null }
    }
    catch { Write-Warning "No se pudo publicar tasks: $($_.Exception.Message)" }
}

# Publica el pipeline de niveles en el dashboard desde el arranque: totalLevels y
# levelTaskCounts se derivan solo del plan (no requieren .controller-state.json),
# asi el encabezado muestra todos los niveles como "pendiente" antes de la primera
# sesion, en vez de caer al modo sesiones hasta que un nivel complete. currentLevel
# sale del controller-state si ya existe (reanudacion); si no, queda null y no se
# abre entrada en levelHistory.
$initialProgress = Get-PlanProgress -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath
Set-DriverStatusProgress -StatusPath $statusPath -TotalLevels $initialProgress.TotalLevels -CurrentLevel $initialProgress.CurrentLevel -LevelTaskCounts $initialProgress.LevelTaskCounts | Out-Null
Publish-DriverTasks

# Fase 4 (M12): presupuesto de sesiones. Un -MaxIterations explicito (> 0) se
# respeta; con 0 se deriva del plan: (niveles pendientes + cierre pendiente) x
# (1 + NoProgressRetries), el peor caso antes de que M9 pare el driver. Se
# calcula una sola vez: en una reanudacion solo cuenta lo pendiente.
if ($MaxIterations -gt 0) {
    $sessionBudget = $MaxIterations
    $budgetSource = 'explicito'
}
elseif ($PlanFile -and $null -ne $initialProgress.TotalLevels -and [int]$initialProgress.TotalLevels -gt 0) {
    $budgetState = Get-ControllerStateInfo -ControllerStatePath $controllerStatePath -PlanFilePath $PlanFile
    $budgetCompleted = if ($null -ne $budgetState -and $budgetState.SamePlan) { [int]$budgetState.CompletedCount } else { 0 }
    $budgetCloseDone = [bool]($finalReviewMarkerPath -and (Test-Path -LiteralPath $finalReviewMarkerPath))
    $sessionBudget = Get-SessionBudget -TotalLevels $initialProgress.TotalLevels -CompletedLevels $budgetCompleted -FinalReviewDone $budgetCloseDone -NoProgressRetries $NoProgressRetries
    $budgetSource = 'auto'
}
else {
    $sessionBudget = 30
    $budgetSource = 'fallback'
}
Write-Host "Presupuesto de sesiones: $sessionBudget ($budgetSource)"
Write-Host "Modelo: $Model; effort nivel/cierre: $LevelEffort/$CloseEffort"

# Ola 2a: limits y params se publican en cuanto se conoce el presupuesto. Ola 2b: y
# otra vez tras cada set-params del dashboard (A5), por eso viven en una funcion.
# maxCostUsd solo se publica y se edita: el tope lo aplica 2c.
function Publish-DriverLimits {
    try {
        Set-DriverStatusBlock -StatusPath $statusPath -Name limits -Value ([ordered]@{
                sessionBudget = $sessionBudget; budgetSource = $budgetSource; iterBase = $iterBase;
                maxTransientRetries = $MaxTransientRetries; noProgressRetries = $NoProgressRetries;
                maxCostUsd = $MaxCostUsd; awaitDecisionMinutes = $AwaitDecisionMinutes }) | Out-Null
        Set-DriverStatusBlock -StatusPath $statusPath -Name params -Value ([ordered]@{
                model = $Model; levelEffort = $LevelEffort; closeEffort = $CloseEffort;
                retryBackoffSeconds = @($RetryBackoffSeconds); livenessTimeoutMinutes = $LivenessTimeoutMinutes }) | Out-Null
    }
    catch { Write-Warning "No se pudieron publicar limits y params: $($_.Exception.Message)" }
}
Publish-DriverLimits

# Ola 3 (D8): modo de permisos de la corrida, una vez al arrancar. Con perfil invalido no se escribe el bloque.
try {
    if ($UnsafeSkipPermissions -or $profileCheck.ok) {
        Set-DriverStatusBlock -StatusPath $statusPath -Name permissions -Value ([ordered]@{ mode = $(if ($UnsafeSkipPermissions) { 'unsafe' } else { 'profile' }); profile = $(if ($UnsafeSkipPermissions) { $null } else { 'plan' }) }) | Out-Null
    }
}
catch { Write-Warning "No se pudo publicar permissions: $($_.Exception.Message)" }

$dashboard = $null
# Gancho de prueba: existe para las pruebas de punta a punta; en uso normal no se define.
if ($env:PLAN_DRIVER_NO_DASHBOARD -eq '1') {
    Write-Host 'Dashboard desactivado (PLAN_DRIVER_NO_DASHBOARD=1).'
}
else {
    try {
        # Ola 2b: token del canal de control, por corrida; viaja al servidor por el entorno, no por la linea de comandos.
        try { $controlToken = Get-DriverControlToken } catch { $controlToken = $null }
        if ([string]::IsNullOrEmpty($controlToken)) { $controlToken = $null }
        $dashboard = Start-DriverDashboard -StatusPath $statusPath -LogsDir $logsDir -AssetsDir $assetsDir -Port $Port -IdleMinutes $DashboardIdleMinutes -ControlToken $controlToken
        if ($null -eq $dashboard) {
            Write-Host 'El driver continua sin dashboard (requiere python en el PATH).'
        }
        else {
            if ($dashboard.Port -ne $Port) {
                Write-Host "Puerto $Port no disponible (posible rango reservado por Windows); se usa $($dashboard.Port)."
            }
            # Esta URL lleva el token en el fragmento (#t=): solo va a la consola y al navegador.
            $dashboardUrlWithToken = if ($controlToken) { "http://127.0.0.1:$($dashboard.Port)/#t=$controlToken" } else { "http://127.0.0.1:$($dashboard.Port)/" }
            Write-Host "Dashboard: $dashboardUrlWithToken"
            try {
                Start-Process $dashboardUrlWithToken
            }
            catch {
                Write-Host "No se pudo abrir el navegador automaticamente. Abre $dashboardUrlWithToken manualmente."
            }
        }
    }
    catch {
        Write-Host "No se pudo iniciar el dashboard local: $($_.Exception.Message)"
        Write-Host "El driver continua sin dashboard."
        $dashboard = $null
    }
}
# Ola 2b: el canal solo queda habilitado si el driver lanzo el servidor con token.
try { Set-DriverStatusBlock -StatusPath $statusPath -Name control -Value ([ordered]@{ enabled = [bool]($dashboard -and $controlToken); last = $null }) | Out-Null }
catch { Write-Warning "No se pudo publicar el bloque control: $($_.Exception.Message)" }

$baseBranch = $null
$iter = $iterBase
$finalStatus = $null
$finalReason = $null
# Fase 2 (M9): sesiones seguidas sin avance del checkpoint, y si la rama de
# trabajo ya se preparo en esta corrida (un reintento puede volver a bootstrap).
$noProgressStreak = 0
$branchReadyThisRun = $false

# Cada sesion headless de "claude" debe correr con cwd = $ProjectPath (el
# repo objetivo), no con el cwd del proceso que lanzo este script -- de lo
# contrario CLAUDE.md, git status y todo el contexto del proyecto quedan
# resueltos contra el directorio equivocado.
Push-Location -LiteralPath $repoRoot
try {
# Gancho de prueba: existe para las pruebas de punta a punta; en uso normal no se define.
# PLAN_DRIVER_CLAUDE_PATH solo se acepta si es un .ps1 existente (el claude falso de las pruebas).
$claudePath = $env:PLAN_DRIVER_CLAUDE_PATH
if ($claudePath) {
    if (($claudePath -notlike '*.ps1') -or -not (Test-Path -LiteralPath $claudePath -PathType Leaf)) {
        throw "PLAN_DRIVER_CLAUDE_PATH invalido (debe ser un .ps1 existente): $claudePath"
    }
    $claudePath = (Resolve-Path -LiteralPath $claudePath).ProviderPath
    Write-Host "Usando claude de prueba: $claudePath"
}
else {
    $claudePath = (Get-Command claude -ErrorAction SilentlyContinue).Source
}
if (-not $claudePath) { $claudePath = 'claude' }

# Un .ps1 de prueba se lanza con el mismo pwsh que corre el driver.
$claudeFile = $claudePath
$claudePrefixArgs = @()
if ($claudePath -like '*.ps1') {
    $claudeFile = (Get-Process -Id $PID).Path
    $claudePrefixArgs = @('-NoProfile', '-NonInteractive', '-File', $claudePath)
}

# Ola 6 (DT-22..24): MCP que ven las sesiones. El inventario ("claude mcp list") solo corre en
# Unsafe con una lista que no es '*'. Con el plan invalido, el bucle cierra FAILED antes de lanzar.
$mcpPlan = Get-DriverMcpPlan -AllowMcp $AllowMcp -ProfileMode (-not $UnsafeSkipPermissions) -GetInventory { Invoke-McpInventory -File $claudeFile -PrefixArgs $claudePrefixArgs }
$mcpArgs = [string[]]@($mcpPlan.args)
if ($mcpPlan.warning) { Write-Warning $mcpPlan.warning }
if ($mcpPlan.ok) {
    $mcpLine = "MCP: $($mcpPlan.status.mode)"
    if ($mcpPlan.status.mode -eq 'allowlist') { $mcpLine += " (permitidos: $(@($mcpPlan.status.allowed) -join ', '); bloqueados: $($mcpPlan.status.blocked))" }
    Write-Host $mcpLine
    try { Set-DriverStatusBlock -StatusPath $statusPath -Name mcp -Value $mcpPlan.status | Out-Null }
    catch { Write-Warning "No se pudo publicar mcp: $($_.Exception.Message)" }
}

$bgCeiling = Resolve-BackgroundCeilingEnv -BoundValue $BackgroundWaitCeilingMs -HasBound $PSBoundParameters.ContainsKey('BackgroundWaitCeilingMs') -InheritedValue $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
Write-Host "Techo de background de claude -p: $($bgCeiling.Value) ms ($($bgCeiling.Source))"

function Get-LivenessFingerprint {
    # Desde la Fase 4 (M4) "claude -p" corre con --output-format stream-json:
    # stdout (el .stream.jsonl) crece durante toda la sesion y su tamano es una
    # senal de progreso real. Se combina igual con el tiempo de CPU del proceso,
    # el tamano de stderr y el mtime de .controller-state.json (que
    # my-subagent-driven-development actualiza al cerrar cada nivel). Cualquiera
    # de las cuatro senales cambiando cuenta como progreso.
    param($Proc, [string]$LogPath, [string]$ErrLogPath, [string]$ControllerStatePath)

    $Proc.Refresh()
    $cpuTicks = $Proc.TotalProcessorTime.Ticks
    $outSize = if (Test-Path -LiteralPath $LogPath) { (Get-Item -LiteralPath $LogPath).Length } else { 0 }
    $errSize = if (Test-Path -LiteralPath $ErrLogPath) { (Get-Item -LiteralPath $ErrLogPath).Length } else { 0 }
    $stateStamp = if ($ControllerStatePath -and (Test-Path -LiteralPath $ControllerStatePath)) { (Get-Item -LiteralPath $ControllerStatePath).LastWriteTimeUtc.Ticks } else { 0 }
    return "$cpuTicks|$outSize|$errSize|$stateStamp"
}

function Save-SessionStreamLog {
    # Fase 4 (M4/M13): lee el stream-json de la sesion, escribe el .log derivado
    # (texto final de la sesion, o el texto del asistente si no hubo evento
    # result) y devuelve la telemetria del evento. Un error de E/S no debe tumbar
    # el driver: deja el .log vacio y la telemetria con solo modelo/effort, y la
    # sesion se clasifica como sin marca.
    # Con -WithStream (D1) devuelve { Telemetry; Stream } para clasificar el fallo;
    # sin el, solo la telemetria (la llamada de OnSessionInterrupted no cambia).
    param([string]$StreamPath, [string]$LogPath, [string]$Model, [string]$Effort, [switch]$WithStream)

    $stream = $null
    try { $stream = Read-SessionStream -Path $StreamPath } catch { $stream = $null }
    $logText = if ($null -ne $stream) { Get-SessionLogText -Stream $stream } else { '' }
    try { Set-Content -LiteralPath $LogPath -Value $logText -Encoding utf8 } catch { }
    $streamTelemetry = if ($null -ne $stream) { $stream.Telemetry } else { $null }
    $telemetryObject = New-SessionTelemetry -Model $Model -Effort $Effort -StreamTelemetry $streamTelemetry
    if ($WithStream) { return [pscustomobject]@{ Telemetry = $telemetryObject; Stream = $stream } }
    return $telemetryObject
}

function Publish-DriverPhase {
    # Ola 2a: publica el bloque phase. Sin -Decision recalcula la decision (tras
    # una sesion). Nunca lanza: un fallo de status no debe tumbar el driver.
    param($Decision = $null)
    try {
        if ($null -eq $Decision) { $Decision = Get-PlanBootstrapDecision -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath -FinalReviewMarkerPath $finalReviewMarkerPath }
        $completedBy = $null
        switch ($Decision.CompletedBy) { 'completed_levels' { $completedBy = 'levels' } 'current_level' { $completedBy = 'current_level' } }
        Set-DriverStatusBlock -StatusPath $statusPath -Name phase -Value ([ordered]@{
                mode = $Decision.Mode; completedBy = $completedBy;
                finalReviewFile = $(if ($finalReviewMarkerPath) { Get-FinalReviewPublishName -Path $finalReviewMarkerPath } else { $null });
                finalReviewExists = [bool]($finalReviewMarkerPath -and (Test-Path -LiteralPath $finalReviewMarkerPath)) }) | Out-Null
    }
    catch { Write-Warning "No se pudo publicar la fase: $($_.Exception.Message)" }
}

function Publish-DriverGit {
    # Ola 2a: publica el bloque git. Get-GitSummary nunca lanza; el try cubre la
    # escritura del status.
    param([AllowNull()][string]$BaseBranch)
    try {
        $summary = Get-GitSummary -RepoRoot $repoRoot -BaseBranch $BaseBranch
        Set-DriverStatusBlock -StatusPath $statusPath -Name git -Value $summary | Out-Null
    }
    catch { Write-Warning "No se pudo publicar el estado de git: $($_.Exception.Message)" }
}

# Ola 2b: canal de control del dashboard (A2 pausa, A3 detener, A5 parametros). Las
# funciones asignan las variables del driver con $script: y ninguna lanza salvo
# PipelineStoppedException (Ctrl+C).
function Register-DriverControlAction {
    # Registra una orden procesada (aplicada o rechazada) en actions[] y control.last.
    param($Order, [string]$Result, [string]$Detail)
    try {
        Add-DriverStatusAction -StatusPath $statusPath -Entry (New-DriverControlEntry -Order $Order -Result $Result -Detail $Detail -Iter $iter) | Out-Null
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { Write-Warning "No se pudo registrar la accion de control: $($_.Exception.Message)" }
}

function Set-DriverRunParams {
    # Aplica un set-params ya validado por Read-DriverControl. Devuelve las claves aplicadas.
    param([Parameter(Mandatory = $true)] $Params)

    # Copia de lo vigente: los atributos de validacion de los parametros validan otra vez al
    # asignar; si un valor falla se restaura todo y la orden se rechaza completa.
    $before = @{
        Model = $script:Model; LevelEffort = $script:LevelEffort; CloseEffort = $script:CloseEffort
        MaxTransientRetries = $script:MaxTransientRetries; RetryBackoffSeconds = @($script:RetryBackoffSeconds)
        LivenessTimeoutMinutes = $script:LivenessTimeoutMinutes; MaxCostUsd = $script:MaxCostUsd
        AwaitDecisionMinutes = $script:AwaitDecisionMinutes
    }
    $applied = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($key in @($Params.Keys)) {
            $value = $Params[$key]
            switch -CaseSensitive ($key) {
                'model' { $script:Model = [string]$value }
                'levelEffort' { $script:LevelEffort = [string]$value }
                'closeEffort' { $script:CloseEffort = [string]$value }
                'maxTransientRetries' { $script:MaxTransientRetries = [int]$value }
                'retryBackoffSeconds' { $script:RetryBackoffSeconds = @([int]$value) }
                'livenessTimeoutMinutes' { $script:LivenessTimeoutMinutes = [int]$value }
                'maxCostUsd' { $script:MaxCostUsd = [double]$value }
                'awaitDecisionMinutes' { $script:AwaitDecisionMinutes = [int]$value }
                default { throw "parametro no permitido: $key" }
            }
            $applied.Add([string]$key)
        }
    }
    catch {
        # Restaura y relanza todo (tambien Ctrl+C): el llamador decide.
        $script:Model = $before.Model; $script:LevelEffort = $before.LevelEffort; $script:CloseEffort = $before.CloseEffort
        $script:MaxTransientRetries = $before.MaxTransientRetries; $script:RetryBackoffSeconds = $before.RetryBackoffSeconds
        $script:LivenessTimeoutMinutes = $before.LivenessTimeoutMinutes; $script:MaxCostUsd = $before.MaxCostUsd
        $script:AwaitDecisionMinutes = $before.AwaitDecisionMinutes
        throw
    }

    # PB-6: con una pausa activa, el plazo se recalcula desde el inicio de la pausa.
    if ($applied.Contains('awaitDecisionMinutes') -and $null -ne $script:pauseSince) {
        $script:pauseDeadline = Get-DriverControlDeadline -Since $script:pauseSince -Minutes $script:AwaitDecisionMinutes
        try {
            $newBlock = [ordered]@{
                since = $script:pauseSince.ToString('o')
                deadline = $(if ($null -ne $script:pauseDeadline) { $script:pauseDeadline.ToString('o') } else { $null })
                actionId = $script:pauseActionId
            }
            Set-DriverStatusLiveState -StatusPath $statusPath -State PAUSED -Reason 'En pausa (dashboard)' -Block $newBlock | Out-Null
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { Write-Warning "No se pudo republicar la pausa con el plazo nuevo: $($_.Exception.Message)" }
    }

    # Ola 2c: igual para la espera de decision; el plazo se recalcula desde que empezo la espera.
    if ($applied.Contains('awaitDecisionMinutes') -and $null -ne $script:awaitSince -and $null -ne $script:awaitBlock) {
        $script:awaitDeadline = Get-DriverControlDeadline -Since $script:awaitSince -Minutes $script:AwaitDecisionMinutes
        try {
            $script:awaitBlock.deadline = $(if ($null -ne $script:awaitDeadline) { $script:awaitDeadline.ToString('o') } else { $null })
            Set-DriverStatusLiveState -StatusPath $statusPath -State AWAITING -Reason "Esperando decisión: $($script:awaitContext.Reason)" -Block $script:awaitBlock | Out-Null
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { Write-Warning "No se pudo republicar la espera con el plazo nuevo: $($_.Exception.Message)" }
    }

    Publish-DriverLimits
    return $applied.ToArray()
}

function Test-DriverAwaitEnabled {
    # La espera de decision exige plazo mayor que 0 y canal de control (dashboard con token) o el gancho de prueba (PC-1).
    return [bool](($AwaitDecisionMinutes -gt 0) -and ((($null -ne $dashboard) -and $controlToken) -or $env:PLAN_DRIVER_AWAIT_WITHOUT_DASHBOARD -eq '1'))
}

function Test-DriverCostCap {
    # DO-8: devuelve $null o el motivo del tope si el costo de esta corrida ya lo alcanza.
    if ($MaxCostUsd -le 0) { return $null }
    try {
        $cost = Get-DriverRunCost -Status (Get-DriverStatus -StatusPath $statusPath) -IterBase $iterBase
        if ($cost -ge $MaxCostUsd) {
            $costText = ([double]$cost).ToString('0.00', [cultureinfo]::InvariantCulture)
            $capText = ([double]$MaxCostUsd).ToString('0.00', [cultureinfo]::InvariantCulture)
            return "Tope de costo alcanzado: $costText USD de $capText USD"
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { Write-Warning "No se pudo comprobar el tope de costo: $($_.Exception.Message)" }
    return $null
}

function Invoke-DriverOpenOrder {
    # A6: abre carpeta, log o terminal con argumentos en arreglo. Devuelve { Ok; Detail }.
    param([Parameter(Mandatory = $true)] $Order, [Parameter(Mandatory = $true)][string]$State)

    try {
        $target = [string]$Order.Params['target']
        # PC-5: sin kill confirmado la sesion anterior puede seguir viva; folder y log siguen permitidos.
        if ($State -eq 'awaiting' -and $target -ceq 'terminal' -and $null -ne $script:awaitContext -and -not $script:awaitContext.KillConfirmed) {
            return [pscustomobject]@{ Ok = $false; Detail = 'terminal no disponible para la sesión en curso' }
        }
        $hist = @()
        try { $hist = @(@((Get-DriverStatus -StatusPath $statusPath).history) | Where-Object { $null -ne $_ }) }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { $hist = @() }
        $iterArg = $null
        if ($Order.Params.Contains('iter')) { $iterArg = [int]$Order.Params['iter'] }
        # PC-9: vigilancia y backoff comparten el id de la sesion que puede reanudarse con --resume.
        $runningId = $null
        if ($State -in @('watch', 'between')) { $runningId = $sessionId }

        $cmd = Resolve-DriverOpenCommand -Target $target -ProjectPath $repoRoot -LogsDir $logsDir -History $hist -Iter $iterArg `
            -RunningSessionId $runningId -WtPath (Get-Command wt.exe -ErrorAction SilentlyContinue).Source -PwshPath (Get-Process -Id $PID).Path
        if (-not $cmd.Ok) { return $cmd }

        $opened = if ($openRecordPath) { Invoke-DriverOpen -Command $cmd -RecordPath $openRecordPath } else { Invoke-DriverOpen -Command $cmd }
        if ($opened.Ok) { return [pscustomobject]@{ Ok = $true; Detail = "abierto: $target" } }
        return $opened
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        Write-Warning "No se pudo abrir desde el dashboard: $($_.Exception.Message)"
        return [pscustomobject]@{ Ok = $false; Detail = "no se pudo abrir: $($_.Exception.Message)" }
    }
}

function Invoke-DriverControlPoint {
    # Lee y procesa una orden del dashboard. Devuelve $null o la senal de la orden
    # aplicada: 'pause', 'resume', 'stop', 'set-params', 'open' o, en la espera de
    # decision, 'decided' (answer o retry).
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('watch', 'between', 'paused', 'awaiting')]
        [string]$State
    )

    try {
        $order = Read-DriverControl -Path $controlPath
        if ($null -eq $order) { return $null }

        if (-not $order.Valid) {
            Register-DriverControlAction -Order $order -Result 'rejected' -Detail $order.Detail
            return $null
        }
        $awaitingOrigin = ''
        if ($State -eq 'awaiting' -and $null -ne $script:awaitContext) { $awaitingOrigin = [string]$script:awaitContext.Origin }
        if (-not (Test-DriverControlAllowed -Action $order.Action -State $State -AwaitingOrigin $awaitingOrigin)) {
            $place = switch ($State) { 'watch' { 'con una sesión en curso' } 'between' { 'entre sesiones' } 'awaiting' { 'esperando decisión' } default { 'en pausa' } }
            Register-DriverControlAction -Order $order -Result 'rejected' -Detail "$($order.Action) no es válida $place"
            return $null
        }
        if ($State -eq 'awaiting') {
            # PC-3: defensa en profundidad; con un lanzador .cmd o .bat el shell reinterpretaria el texto.
            if ($order.Action -ceq 'answer' -and $claudeFile -match '\.(cmd|bat)$') {
                Register-DriverControlAction -Order $order -Result 'rejected' -Detail 'respuesta no admitida: claude se lanza por un .cmd o .bat'
                return $null
            }
            # PC-5: acciones fuera de lo permitido al entrar (kill sin confirmar).
            if ($null -eq $script:awaitBlock -or -not (@($script:awaitBlock.allowed) -ccontains $order.Action)) {
                Register-DriverControlAction -Order $order -Result 'rejected' -Detail 'la sesión anterior puede seguir viva: detén la corrida'
                return $null
            }
        }

        $signal = $null
        $detail = ''
        $result = 'applied'
        try {
            switch -CaseSensitive ($order.Action) {
                'pause' {
                    if ($State -eq 'watch') {
                        if ($script:pauseRequested) { $detail = 'pausa ya pedida' }
                        else { $detail = 'pausa al terminar la sesión en curso' }
                    }
                    else { $detail = 'en pausa' }
                    if (-not $script:pauseRequested) {
                        $script:pauseRequested = $true
                        $script:pauseActionId = $order.Id
                    }
                    $signal = 'pause'
                }
                'resume' { $detail = 'reanudada'; $signal = 'resume' }
                'stop' { $detail = 'detenida'; $signal = 'stop' }
                'set-params' {
                    $keys = @(Set-DriverRunParams -Params $order.Params)
                    $detail = 'aplicados: ' + ($keys -join ', ')
                    $signal = 'set-params'
                }
                'open' {
                    $r = Invoke-DriverOpenOrder -Order $order -State $State
                    $detail = [string]$r.Detail
                    if ($r.Ok) { $signal = 'open' } else { $result = 'rejected' }
                }
                'answer' {
                    # A1 (solo llega en awaiting). El tope se comprueba antes de lanzar un intento (DO-8).
                    if ($script:awaitContext.AnswerMode -ceq 'resume') {
                        $capReason = Test-DriverCostCap
                        if ($capReason) { $result = 'rejected'; $detail = 'tope de costo alcanzado' }
                        else {
                            $script:awaitDecision = @{ Kind = 'answer-resume'; Text = [string]$order.Params['text'] }
                            $detail = 'respuesta enviada a la sesión (--resume)'
                            $signal = 'decided'
                        }
                    }
                    elseif (($iter - $iterBase) -ge $sessionBudget) { $result = 'rejected'; $detail = 'sin presupuesto de sesiones' }
                    else {
                        $script:awaitDecision = @{ Kind = 'answer-new'; Text = [string]$order.Params['text'] }
                        $detail = 'respuesta en una sesión nueva'
                        $signal = 'decided'
                    }
                }
                'retry' {
                    if ([string]$order.Params['mode'] -ceq 'session') {
                        # El tope manda sobre la reanudabilidad: un origen tope_costo se rechaza por el tope sin volver a medirlo.
                        if ($script:awaitContext.Origin -ceq 'tope_costo') { $result = 'rejected'; $detail = 'tope de costo alcanzado' }
                        elseif (-not $script:awaitContext.Resumable) { $result = 'rejected'; $detail = 'la sesión no es reanudable' }
                        else {
                            $capReason = Test-DriverCostCap
                            if ($capReason) { $result = 'rejected'; $detail = 'tope de costo alcanzado' }
                            else {
                                $script:awaitDecision = @{ Kind = 'retry-session'; Text = $null }
                                $detail = 'reintento de la sesión (--resume)'
                                $signal = 'decided'
                            }
                        }
                    }
                    else {
                        $capReason = $null
                        if ($script:awaitContext.Origin -ceq 'tope_costo') { $capReason = Test-DriverCostCap }
                        if ($capReason) { $result = 'rejected'; $detail = 'tope de costo alcanzado' }
                        elseif (($iter - $iterBase) -ge $sessionBudget) { $result = 'rejected'; $detail = 'sin presupuesto de sesiones' }
                        else {
                            $script:awaitDecision = @{ Kind = 'retry-level'; Text = $null }
                            $detail = 'reintento del nivel con sesión nueva'
                            $signal = 'decided'
                        }
                    }
                }
            }
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch {
            Register-DriverControlAction -Order $order -Result 'rejected' -Detail "error al aplicar: $($_.Exception.Message)"
            return $null
        }

        Register-DriverControlAction -Order $order -Result $result -Detail $detail
        return $signal
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        Write-Warning "No se pudo procesar el control del dashboard: $($_.Exception.Message)"
        return $null
    }
}

function Enter-DriverPause {
    # A2: publica PAUSED y espera una orden o el plazo. Devuelve 'resume', 'stop' o 'expired'.
    $since = Get-Date
    $script:pauseSince = $since
    $script:pauseDeadline = Get-DriverControlDeadline -Since $since -Minutes $AwaitDecisionMinutes
    $savedReason = $null
    try { $savedReason = (Get-DriverStatus -StatusPath $statusPath).reason }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { $savedReason = $null }

    $deadlineText = if ($null -ne $script:pauseDeadline) { $script:pauseDeadline.ToString('o') } else { $null }
    $block = [ordered]@{ since = $since.ToString('o'); deadline = $deadlineText; actionId = $script:pauseActionId }
    Write-Host "En pausa (dashboard). Plazo: $(if ($deadlineText) { $deadlineText } else { 'sin plazo' })."

    $r = Wait-DriverPause -StatusPath $statusPath -Block $block -Reason 'En pausa (dashboard)' -HeartbeatSeconds $LivenessPollSeconds `
        -GetDeadline { $script:pauseDeadline } -OnTick { Invoke-DriverControlPoint -State paused }

    $script:pauseRequested = $false; $script:pauseActionId = $null; $script:pauseSince = $null; $script:pauseDeadline = $null
    if ($r -ceq 'resume') {
        try { Set-DriverStatusLiveState -StatusPath $statusPath -State RUNNING -Reason $savedReason | Out-Null }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { Write-Warning "No se pudo publicar RUNNING al reanudar: $($_.Exception.Message)" }
        Write-Host 'Reanudado desde el dashboard.'
    }
    return $r
}

function Invoke-DriverBetweenPoint {
    # Punto entre sesiones o intentos. Sin -Signal lee el control; con la senal de la
    # espera de un reintento la procesa. Devuelve { Stop; Paused }; Stop trae el final
    # (Status, Reason, Cause) si hay que cerrar la corrida.
    param([AllowNull()][string]$Signal = $null)

    $result = [pscustomobject]@{ Stop = $null; Paused = $false }
    $stopByDashboard = [pscustomobject]@{ Status = 'STOPPED'; Reason = 'Detenido desde el dashboard'; Cause = 'dashboard' }
    try {
        if ([string]::IsNullOrEmpty($Signal)) { $Signal = Invoke-DriverControlPoint -State between }
        if ($Signal -ceq 'stop') {
            $result.Stop = $stopByDashboard
            return $result
        }
        if ($Signal -ceq 'pause' -or $script:pauseRequested) {
            $r = Enter-DriverPause
            $result.Paused = $true
            if ($r -ceq 'stop') { $result.Stop = $stopByDashboard }
            elseif ($r -ceq 'expired') {
                $result.Stop = [pscustomobject]@{ Status = 'STOPPED'; Reason = "Pausa vencida: sin reanudar en $AwaitDecisionMinutes min"; Cause = 'pausa_vencida' }
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { Write-Warning "No se pudo procesar el punto de control entre sesiones: $($_.Exception.Message)" }
    return $result
}

function Enter-DriverAwaiting {
    # Ola 2c: publica AWAITING y espera una decision del dashboard o el plazo.
    # Devuelve { Kind; Text } con Kind 'expired', 'stop', 'answer-resume', 'answer-new', 'retry-session' o 'retry-level'.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('BLOCKED', 'FAILED', 'tope_costo')][string]$Origin,
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [AllowNull()]$Cause = $null,
        [Parameter(Mandatory = $true)][bool]$Resumable,
        [Parameter(Mandatory = $true)][ValidateSet('resume', 'new')][string]$AnswerMode,
        [Parameter(Mandatory = $true)][bool]$KillConfirmed
    )

    $since = Get-Date
    $script:awaitSince = $since
    $script:awaitDeadline = Get-DriverControlDeadline -Since $since -Minutes $AwaitDecisionMinutes
    $allowed = [string[]]@(Get-DriverAwaitingAllowed -Origin $Origin -KillConfirmed $KillConfirmed)
    # PC-3: con un lanzador .cmd o .bat no se admite la respuesta libre.
    if ($claudeFile -match '\.(cmd|bat)$') { $allowed = [string[]]@($allowed | Where-Object { $_ -ne 'answer' }) }
    $script:awaitBlock = New-DriverAwaitingBlock -Since $since -Deadline $script:awaitDeadline -Origin $Origin -Reason $Reason -Cause $Cause `
        -Iter $iter -SessionId $sessionId -Resumable $Resumable -Allowed $allowed
    $script:awaitContext = [pscustomobject]@{ Origin = $Origin; Reason = $Reason; Resumable = $Resumable; AnswerMode = $AnswerMode; KillConfirmed = $KillConfirmed }
    $script:awaitDecision = $null

    $deadlineText = if ($null -ne $script:awaitDeadline) { $script:awaitDeadline.ToString('o') } else { $null }
    try { Set-DriverStatusLiveState -StatusPath $statusPath -State AWAITING -Reason "Esperando decisión: $Reason" -Block $script:awaitBlock | Out-Null }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { Write-Warning "No se pudo publicar AWAITING: $($_.Exception.Message)" }
    Write-Host "Esperando decisión ($Origin). Plazo: $(if ($deadlineText) { $deadlineText } else { 'sin plazo' })."

    # D5: aviso al entrar en la espera. El plazo va delante porque Format-DriverNotification recorta el motivo.
    try {
        $summary = Get-DriverNotificationSummary -Status (Get-DriverStatus -StatusPath $statusPath) -CostMode $notifyCostMode
        $awaitUrl = if ($dashboard) { "http://localhost:$($dashboard.Port)/" } else { $null }
        $awaitNote = if ($null -ne $script:awaitDeadline) { "Esperando decisión (vence $($script:awaitDeadline.ToString('HH:mm'))): $Reason" } else { "Esperando decisión (sin plazo): $Reason" }
        $n = Send-DriverNotification -Status AWAITING -Reason $awaitNote -PlanFile $PlanFile -Sessions $summary.Sessions -CostUsd $summary.CostUsd -Duration $summary.Duration -DashboardUrl $awaitUrl -NotifyUrl $NotifyUrl -NoToast:$NoToast
        Set-DriverStatusNotification -StatusPath $statusPath -Notification $n | Out-Null
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch { Write-Warning "No se pudo enviar el aviso de espera: $($_.Exception.Message)" }

    $r = Wait-DriverPause -StatusPath $statusPath -State AWAITING -ExitSignals @('decided', 'stop') -Block $script:awaitBlock `
        -Reason "Esperando decisión: $Reason" -HeartbeatSeconds $LivenessPollSeconds -GetDeadline { $script:awaitDeadline } `
        -OnTick { Invoke-DriverControlPoint -State awaiting }

    $picked = $script:awaitDecision
    $script:awaitSince = $null; $script:awaitDeadline = $null; $script:awaitBlock = $null; $script:awaitContext = $null; $script:awaitDecision = $null

    if ($r -ceq 'decided' -and $null -ne $picked) {
        # PC-14: la decision queda en actions[]; el motivo vuelve a nulo.
        try { Set-DriverStatusLiveState -StatusPath $statusPath -State RUNNING -Reason $null | Out-Null }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch { Write-Warning "No se pudo publicar RUNNING al salir de la espera: $($_.Exception.Message)" }
        Write-Host "Decisión recibida desde el dashboard: $($picked.Kind)."
        return [pscustomobject]@{ Kind = [string]$picked.Kind; Text = $picked.Text }
    }
    if ($r -ceq 'stop') { return [pscustomobject]@{ Kind = 'stop'; Text = $null } }
    return [pscustomobject]@{ Kind = 'expired'; Text = $null }
}

function Invoke-DriverAwaitPoint {
    # Ola 2c: punto de entrada comun de BLOCKED, FAILED y tope de costo. Devuelve 'final'
    # ($finalStatus, $finalReason y $finalCause ya fijados), 'resume' (intento preparado en
    # $attemptArgs) o 'new' (sesion nueva desde el checkpoint).
    param(
        [Parameter(Mandatory = $true)][ValidateSet('BLOCKED', 'FAILED', 'tope_costo')][string]$Origin,
        [Parameter(Mandatory = $true)][ValidateSet('BLOCKED', 'FAILED', 'STOPPED')][string]$Status,
        [AllowNull()][AllowEmptyString()][string]$Reason,
        # Sin tipo: una causa nula debe seguir nula (PC-4).
        [AllowNull()]$Cause = $null,
        [Parameter(Mandatory = $true)][bool]$Resumable,
        [Parameter(Mandatory = $true)][ValidateSet('resume', 'new')][string]$AnswerMode,
        [Parameter(Mandatory = $true)][bool]$KillConfirmed
    )

    $capCause = $(if ($Origin -eq 'tope_costo') { 'tope_costo' } else { $null })
    if (-not (Test-DriverAwaitEnabled)) {
        $script:finalStatus = $Status; $script:finalReason = $Reason; $script:finalCause = $capCause
        return 'final'
    }

    $a = Enter-DriverAwaiting -Origin $Origin -Reason $Reason -Cause $Cause -Resumable $Resumable -AnswerMode $AnswerMode -KillConfirmed $KillConfirmed
    switch -CaseSensitive ($a.Kind) {
        'expired' {
            $script:finalStatus = $Status
            $script:finalReason = "$Reason (sin decisión en $AwaitDecisionMinutes min)"
            $script:finalCause = $(if ($Origin -eq 'tope_costo') { 'tope_costo' } else { $Cause })
            return 'final'
        }
        'stop' {
            $script:finalStatus = 'STOPPED'; $script:finalReason = 'Detenido desde el dashboard'; $script:finalCause = 'dashboard'
            return 'final'
        }
    }

    # Decision aplicada: el estado final provisional del llamador ya no vale.
    $script:finalStatus = $null; $script:finalReason = $null; $script:finalCause = $null
    $script:answerFallbackText = $null
    switch -CaseSensitive ($a.Kind) {
        'answer-new' { $script:pendingDecisionText = $a.Text; $script:noProgressStreak = 0; return 'new' }
        'retry-level' { $script:noProgressStreak = 0; return 'new' }
    }

    if ($a.Kind -ceq 'answer-resume') {
        $resumePrompt = Get-DriverAnswerPrompt -Text $a.Text
        # Respaldo D1: si el --resume no existe, la sesion nueva debe llevar la respuesta.
        $script:answerFallbackText = $a.Text
        $script:priorCause = 'respuesta_usuario'
    }
    else {
        $resumePrompt = Get-ResumePrompt
        $script:priorCause = $Cause
    }
    # Prepara el intento (misma forma que el reintento D1: un set-params aplicado en la espera vale para el intento).
    $script:sessionEffort = if ($decision.Mode -eq 'close') { $CloseEffort } else { $LevelEffort }
    $script:claudeArgs = @('-p', $promptText) + $permissionArgs + $mcpArgs + @('--model', $Model, '--effort', $script:sessionEffort, '--output-format', 'stream-json', '--verbose', '--session-id', $sessionId)
    $script:resumedSessionId = $sessionId
    $script:attemptArgs = ConvertTo-RetryClaudeArgs -Arguments $script:claudeArgs -Prompt $resumePrompt -SessionFlag '--resume' -SessionValue $sessionId
    $script:attempt = $attempt + 1
    return 'resume'
}

while (($iter - $iterBase) -lt $sessionBudget) {
    if ($profileCheck -and -not $profileCheck.ok) { $finalStatus = 'FAILED'; $finalReason = "perfil de permisos inválido: $($profileCheck.reason)"; $finalCause = 'perfil_invalido'; Write-Host $finalReason; break }
    if (-not $mcpPlan.ok) { $finalStatus = 'FAILED'; $finalReason = $mcpPlan.reason; $finalCause = $mcpPlan.cause; Write-Host $finalReason; break }
    try { Set-DriverStatusHeartbeat -StatusPath $statusPath | Out-Null } catch { Write-Warning "No se pudo escribir el heartbeat del driver: $($_.Exception.Message)" }
    # Ola 2b (P1): punto entre sesiones al inicio de la iteracion (pausa pedida, detener).
    $between = Invoke-DriverBetweenPoint
    if ($between.Stop) { $finalStatus = $between.Stop.Status; $finalReason = $between.Stop.Reason; $finalCause = $between.Stop.Cause; break }
    # Ola 2c (DO-8): el tope de costo se comprueba antes de lanzar cada sesion.
    $capReason = Test-DriverCostCap
    if ($capReason) {
        $ap = Invoke-DriverAwaitPoint -Origin tope_costo -Status STOPPED -Reason $capReason -Cause 'tope_costo' -Resumable $false -AnswerMode new -KillConfirmed $true
        if ($ap -eq 'final') { break }
    }
    $decision = Get-PlanBootstrapDecision -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath -FinalReviewMarkerPath $finalReviewMarkerPath
    Publish-DriverPhase -Decision $decision

    if ($decision.Mode -eq 'bootstrap') {
        # Fix 3 (compatibilidad): un checkpoint con avance de este plan fuera de la
        # carpeta efectiva (raiz del proyecto o junto al -PlanFile original) indica
        # que el driver no ve el avance real. Abortar con la ruta en vez de crear
        # la rama otra vez y fallar con "la rama ya existe".
        $originalPlanDir = if ($originalPlanFile) { Split-Path -Parent $originalPlanFile } else { $null }
        $strayState = Find-StrayControllerState -PlanFilePath $PlanFile -EffectivePlansDir $effectivePlansDir -CandidateDirs @($plansDir, $originalPlanDir)
        if ($strayState) {
            throw "Hay un checkpoint con avance de este plan en '$strayState', fuera de la carpeta que lee el driver ('$effectivePlansDir'). Para reanudar, copia ese .controller-state.json a '$effectivePlansDir' y relanza con el mismo comando."
        }

        if ($branchReadyThisRun) {
            # Reintento (M9) de una sesion bootstrap que no escribio checkpoint: la
            # rama ya se preparo en esta corrida. No se crea ni se retoma (y no se
            # exige working tree limpio): solo se verifica que sigue activa. La
            # racha de sesiones sin avance acota estas re-entradas.
            $expectedBranch = (Get-DriverStatus -StatusPath $statusPath).workBranch
            $currentBranch = Get-CurrentBranch -RepoRoot $repoRoot
            if ($currentBranch -ne $expectedBranch) {
                throw "El repo '$repoRoot' esta en '$currentBranch' pero se esperaba la rama de trabajo '$expectedBranch'. Aborta para no commitear en la rama equivocada."
            }
            Write-Host "Reintento en bootstrap: la rama de trabajo $expectedBranch ya esta preparada en esta corrida"
        }
        elseif ($UseCurrentBranch) {
            $workBranch = Use-CurrentWorkBranch -RepoRoot $repoRoot
            Set-DriverStatusBranch -StatusPath $statusPath -WorkBranch $workBranch | Out-Null
            Write-Host "Rama de trabajo existente: $workBranch"
            $branchReadyThisRun = $true
        }
        else {
            # Fix 2, solo al arranque ($iter aun vale $iterBase): si la rama del plan ya
            # existe y el checkpoint es cold-start del mismo plan, la sesion 1 se
            # corto antes de cerrar el nivel 0 y se retoma la rama. La re-entrada
            # dentro de la corrida la cubre $branchReadyThisRun (M9), arriba.
            $workBranch = Get-PlanBranchName -PlanFilePath $PlanFile -Override $BranchName
            $stateInfo = Get-ControllerStateInfo -ControllerStatePath $controllerStatePath -PlanFilePath $PlanFile
            $branchAction = Resolve-BootstrapBranchAction -RepoRoot $repoRoot -Branch $workBranch -StateInfo $stateInfo -IsFirstIteration ($iter -eq $iterBase)
            if ($branchAction -eq 'resume') {
                Resume-WorkBranch -RepoRoot $repoRoot -Branch $workBranch | Out-Null
                Set-DriverStatusBranch -StatusPath $statusPath -WorkBranch $workBranch | Out-Null
                Write-Host "Rama de trabajo existente retomada (checkpoint cold-start del plan): $workBranch"
            }
            else {
                $baseBranch = Initialize-WorkBranch -RepoRoot $repoRoot -Branch $workBranch
                Set-DriverStatusBranch -StatusPath $statusPath -WorkBranch $workBranch | Out-Null
                Write-Host "Rama de trabajo creada: $workBranch"
            }
            $branchReadyThisRun = $true
        }
    }
    elseif ($decision.Mode -ne 'done') {
        $statusBranch = (Get-DriverStatus -StatusPath $statusPath).workBranch
        $expectedBranch = $statusBranch
        if (-not $expectedBranch) {
            $expectedBranch = Get-PlanBranchName -PlanFilePath $PlanFile -Override $BranchName
        }
        $currentBranch = Get-CurrentBranch -RepoRoot $repoRoot
        if ($currentBranch -ne $expectedBranch) {
            throw "El repo '$repoRoot' esta en '$currentBranch' pero se esperaba la rama de trabajo '$expectedBranch'. Aborta para no commitear en la rama equivocada."
        }
        # La rama quedo verificada: si una sesion posterior deja el checkpoint
        # ilegible o en cold-start, la re-entrada en bootstrap la verifica en vez
        # de intentar crearla. Se persiste cuando el status no la traia (status
        # de una version anterior), porque esa guarda la lee de ahi.
        if (-not $statusBranch) {
            Set-DriverStatusBranch -StatusPath $statusPath -WorkBranch $expectedBranch | Out-Null
        }
        $branchReadyThisRun = $true
    }

    if (-not $baseBranch) { try { $baseBranch = Resolve-WorkspaceBaseBranch -RepoRoot $repoRoot } catch { $baseBranch = $null } }
    Publish-DriverGit -BaseBranch $baseBranch

    if ($decision.Mode -eq 'done') {
        $finalStatus = 'DONE'
        $finalReason = 'plan completo; niveles y revisión final realizados. Pendiente el handoff humano de integración.'
        break
    }

    # D2: el plan esta completo segun current_level aunque completed_levels no lo
    # refleje; se publica el avance como completo y se pasa a cierre. No se escribe
    # el checkpoint.
    if ($decision.Mode -eq 'close' -and $decision.CompletedBy -eq 'current_level') {
        $d2Text = "Plan completo según current_level (completed_levels $($decision.CompletedCount)/$($decision.TotalLevels)): pasa a cierre"
        Write-Host $d2Text
        try { Set-DriverStatusProgress -StatusPath $statusPath -TotalLevels $decision.TotalLevels -CurrentLevel $decision.TotalLevels -LevelTaskCounts $initialProgress.LevelTaskCounts | Out-Null }
        catch { Write-Warning "No se pudo publicar el avance completo (D2): $($_.Exception.Message)" }
        Publish-DriverTasks
        try { Set-DriverStatusReason -StatusPath $statusPath -Reason $d2Text | Out-Null }
        catch { Write-Warning "No se pudo publicar el motivo de D2: $($_.Exception.Message)" }
    }

    $iter++
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    Write-Host "== Sesion $iter (modo: $($decision.Mode)) =="
    $promptText = if ($decision.Mode -eq 'close') { $CLOSE_PROMPT } else { $LEVEL_PROMPT }
    # Ola 2c (A1): la decision del usuario sobre un bloqueo viaja como seccion final del prompt de la sesion nueva.
    if ($pendingDecisionText) { $promptText = Add-DriverDecisionSection -Prompt $promptText -Text $pendingDecisionText; $pendingDecisionText = $null }
    # Fase 2 (M3/M9): checkpoint antes de la sesion, para medir si avanzo.
    $stateBefore = if ($PlanFile) { Get-ControllerStateInfo -ControllerStatePath $controllerStatePath -PlanFilePath $PlanFile } else { $null }
    $sessionId = [guid]::NewGuid().ToString()
    $sessionEffort = if ($decision.Mode -eq 'close') { $CloseEffort } else { $LevelEffort }
    # --output-format stream-json exige --verbose en modo -p.
    $claudeArgs = @('-p', $promptText) + $permissionArgs + $mcpArgs + @('--model', $Model, '--effort', $sessionEffort, '--output-format', 'stream-json', '--verbose', '--session-id', $sessionId)

    # Ola 1b (D1): estado de los intentos de esta sesion. Un reintento no toca $iter
    # ni el presupuesto de sesiones: lo acota $MaxTransientRetries.
    $stopLoop = $false
    $attempt = 0
    $priorCause = $null
    $answerFallbackText = $null
    $resumedSessionId = $null
    $attemptArgs = $claudeArgs
    $reasonBeforeRetry = $null
    $retryReasonSet = $false

    # Abre el bucle de intentos (D1); cierra mas abajo, antes de Get-PlanProgress.
    # El cuerpo no se reindenta, como el try exterior del archivo.
    while ($true) {
    if ($attempt -eq 0) {
        $logPath = Join-Path $logsDir "session-$iter-$timestamp.log"
        $errLogPath = Join-Path $logsDir "session-$iter-$timestamp.err.log"
        # Fase 4 (M4): stdout crudo (JSONL). El .log se deriva al terminar.
        $streamPath = Join-Path $logsDir "session-$iter-$timestamp.stream.jsonl"
    }
    else {
        # Reintento k: el sello propio evita sobrescribir el log de un reintento de una corrida anterior.
        $attemptStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logPath = Join-Path $logsDir "session-$iter-r$attempt-$attemptStamp.log"
        $errLogPath = Join-Path $logsDir "session-$iter-r$attempt-$attemptStamp.err.log"
        $streamPath = Join-Path $logsDir "session-$iter-r$attempt-$attemptStamp.stream.jsonl"
    }

    # Se lanza con Start-HeadlessProcess (ProcessStartInfo.ArgumentList) y NO con
    # Start-Process -ArgumentList: este ultimo une el array con espacios sin
    # entrecomillar, y partia el prompt multipalabra (la sesion recibia "-p Ejecuta"
    # y descartaba el resto). El launcher pasa cada arg verbatim y redirige stdout/
    # stderr a los mismos archivos que consume el watchdog de liveness.
    # Ola 2b (PB-9): el modelo y el corte por inactividad se capturan al lanzar; un set-params aplica al intento siguiente.
    $attemptModel = $Model; $attemptLivenessMinutes = $LivenessTimeoutMinutes
    $attemptStartedAt = Get-Date
    $launch = Start-HeadlessProcess -FilePath $claudeFile -ArgumentList (@($claudePrefixArgs) + @($attemptArgs)) -StdoutPath $streamPath -StderrPath $errLogPath -WorkingDirectory $repoRoot -Environment $bgCeiling.Env
    $proc = $launch.Process
    Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter $iter -SessionId $sessionId -StreamFile (Split-Path -Leaf $streamPath) -ErrFile (Split-Path -Leaf $errLogPath) -LivenessTimeoutMinutes $attemptLivenessMinutes -Attempt $attempt | Out-Null
    try { Set-DriverStatusHeartbeat -StatusPath $statusPath | Out-Null } catch { Write-Warning "No se pudo escribir el heartbeat del driver: $($_.Exception.Message)" }

    # Watchdog de vida: mientras cambie la huella (CPU/stdout/stderr/controller-state)
    # se resetea el contador; si queda identica durante $LivenessTimeoutMinutes
    # minutos seguidos, se considera colgada.
    $lastFingerprint = Get-LivenessFingerprint -Proc $proc -LogPath $streamPath -ErrLogPath $errLogPath -ControllerStatePath $controllerStatePath
    $lastProgressAt = Get-Date
    $hung = $false
    $dashboardStop = $false

    while (-not $proc.HasExited) {
        # Ola 2b (DO-5): ticks de 1 s para leer el control; el heartbeat y la huella siguen la cadencia de LivenessPollSeconds.
        for ($tick = 0; $tick -lt [Math]::Max(1, $LivenessPollSeconds); $tick++) {
            Start-Sleep -Seconds 1
            if ($proc.HasExited) { break }
            if ((Invoke-DriverControlPoint -State watch) -eq 'stop') { $dashboardStop = $true; break }
        }
        if ($proc.HasExited -or $dashboardStop) { break }

        $currentFingerprint = Get-LivenessFingerprint -Proc $proc -LogPath $streamPath -ErrLogPath $errLogPath -ControllerStatePath $controllerStatePath
        if ($currentFingerprint -ne $lastFingerprint) {
            $lastFingerprint = $currentFingerprint
            $lastProgressAt = Get-Date
        }
        # El heartbeat se escribe en cada vuelta, cambie o no la huella: es una sola
        # escritura atomica con el latido del driver y el ultimo progreso observado.
        try { Set-DriverStatusHeartbeat -StatusPath $statusPath -LastProgressAt $lastProgressAt | Out-Null } catch { Write-Warning "No se pudo actualizar la senal de vida: $($_.Exception.Message)" }
        if (((Get-Date) - $lastProgressAt).TotalMinutes -ge $attemptLivenessMinutes) {
            $hung = $true
            break
        }
    }

    # Ola 2b (A3): detener desde el dashboard con una sesion en curso. El cleanup mata el arbol,
    # agrega el evento con causa dashboard y escribe STOPPED; el finally exterior ya lo ve final.
    if ($dashboardStop) {
        Write-Host "Sesion $iter detenida desde el dashboard."
        $null = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -GlobalStatus STOPPED -Reason 'Detenido desde el dashboard' -Cause 'dashboard' `
            -LogFile (Split-Path -Leaf $logPath) -StreamFile (Split-Path -Leaf $streamPath) -ErrFile (Split-Path -Leaf $errLogPath) `
            -OnSessionInterrupted { if ($launch) { $null = & $launch.Cleanup }; Save-SessionStreamLog -StreamPath $streamPath -LogPath $logPath -Model $attemptModel -Effort $sessionEffort }
        $finalStatus = 'STOPPED'; $finalReason = 'Detenido desde el dashboard'; $finalCause = 'dashboard'
        $stopLoop = $true
        break
    }

    if ($hung) {
        Write-Host "Sesion $iter sin progreso en $attemptLivenessMinutes minutos -- se considera colgada, sin desbloqueo posible."
        $kill = Stop-ProcessTree -ProcessId $proc.Id
        if ($kill.Method -eq 'Stop-Process') {
            Write-Host "taskkill fallo -- usando Stop-Process como fallback (no mata el arbol de procesos, solo el proceso principal)."
        }
        elseif ($kill.Method -eq 'failed') {
            Write-Host "taskkill y Stop-Process fallaron: $($kill.Message)"
        }
        $proc.WaitForExit(10000) | Out-Null
        # Solo se acepta el kill si taskkill /T mato el arbol: Stop-Process no mata los hijos.
        $killedOk = $proc.HasExited -and $kill.Method -eq 'taskkill'
        if (-not $killedOk) {
            Write-Host "El kill de la sesion colgada no confirma el arbol (taskkill fallo o el proceso sigue vivo): no se reintenta para no lanzar dos sesiones a la vez."
        }
        $attemptSeconds = ((Get-Date) - $attemptStartedAt).TotalSeconds
        & $launch.Cleanup
        $saved = Save-SessionStreamLog -StreamPath $streamPath -LogPath $logPath -Model $attemptModel -Effort $sessionEffort -WithStream

        $exitCode = -1
        $cause = 'colgada'
        $outcome = $null
        # La causa 'colgada' no sale de Resolve-SessionOutcome: la fija el driver.
        $failureInput = [pscustomobject]@{ Cause = 'colgada' }
        $errTailLines = @(Get-LogTail -Path $errLogPath -MaxLines $PLAN_STATUS_TAIL_LINES)
    }
    else {
        $proc.WaitForExit()
        $killedOk = $true
        $attemptSeconds = ((Get-Date) - $attemptStartedAt).TotalSeconds
        $exitCode = $proc.ExitCode
        # WaitForExit() NO garantiza que la salida este en disco: Cleanup espera las
        # copias de stdout/stderr y cierra los archivos antes de leer la cola del log.
        & $launch.Cleanup
        # Fase 4 (M4): el .log derivado tiene el mismo contenido que en modo texto;
        # Get-LogTail y Resolve-SessionOutcome no cambian.
        $saved = Save-SessionStreamLog -StreamPath $streamPath -LogPath $logPath -Model $attemptModel -Effort $sessionEffort -WithStream

        # La marca se busca en la cola del log (ultima marca valida en las ultimas
        # $PLAN_STATUS_TAIL_LINES lineas no vacias), no solo en la ultima linea.
        # Resolve-SessionOutcome aplica tambien la compuerta de cierre: una sesion
        # "close" que declara DONE sin marcador de revision final se degrada a
        # BLOCKED; una re-corrida reintenta el cierre (Get-PlanBootstrapDecision
        # vuelve a modo "close" al ver que falta el marcador).
        $tailLines = @(Get-LogTail -Path $logPath -MaxLines $PLAN_STATUS_TAIL_LINES)
        $markerExists = [bool]($finalReviewMarkerPath -and (Test-Path -LiteralPath $finalReviewMarkerPath))

        # Fase 2 (M3/M9): evidencia para clasificar la sesion. En "close" el avance
        # es el marcador de revision final; en los niveles, el checkpoint. Sin plan
        # no se mide ($null) y se conserva el comportamiento anterior.
        $advanced = $null
        if ($PlanFile) {
            if ($decision.Mode -eq 'close') {
                $advanced = $markerExists
            }
            else {
                $stateAfter = Get-ControllerStateInfo -ControllerStatePath $controllerStatePath -PlanFilePath $PlanFile
                $advanced = Test-CheckpointAdvanced -Before $stateBefore -After $stateAfter
            }
        }
        $errTailLines = @(Get-LogTail -Path $errLogPath -MaxLines $PLAN_STATUS_TAIL_LINES)

        $outcome = Resolve-SessionOutcome -ExitCode $exitCode -TailLines $tailLines -Mode $decision.Mode -FinalReviewMarkerExists $markerExists -MarkerRelativePath $markerRelativeForPrompt -Advanced $advanced -ErrTailLines $errTailLines -NoProgressStreak $noProgressStreak -NoProgressRetries $NoProgressRetries
        $cause = $outcome.Cause
        $failureInput = $outcome
    }
    # Cubre el cierre de los dos caminos (colgada y normal).
    try { Set-DriverStatusHeartbeat -StatusPath $statusPath | Out-Null } catch { Write-Warning "No se pudo escribir el heartbeat del driver: $($_.Exception.Message)" }

    $telemetry = $saved.Telemetry
    $stream = $saved.Stream

    # Ola 1b (D1): clasifica el fallo (permanente, transitorio o ninguno) una vez por intento.
    $failure = Get-SessionFailureKind -Outcome $failureInput -StreamSummary $stream -ErrLogTail $errTailLines
    # Sin kill confirmado no se reintenta: un segundo claude --resume correria junto al primero sobre el mismo repo.
    $canRetry = ($failure.Kind -eq 'transient') -and ($attempt -lt $MaxTransientRetries) -and $killedOk
    $stopsByD1 = ($failure.Kind -eq 'permanent') -or ($failure.Kind -eq 'transient' -and -not $canRetry)

    Add-DriverStatusEvent -StatusPath $statusPath -Iter $iter -ExitCode $exitCode -PlanStatus $(if ($outcome) { $outcome.PlanStatusForEvent } else { $null }) -LogPath (Split-Path -Leaf $logPath) -SessionId $sessionId -PlanStatusReason $(if ($outcome) { $outcome.PlanStatusReasonForEvent } else { $null }) -Cause $cause -Telemetry $telemetry -StreamFile (Split-Path -Leaf $streamPath) -ErrFile (Split-Path -Leaf $errLogPath) -Attempt $attempt -FailureKind $(if ($failure.Kind -ne 'none') { $failure.Kind } else { $null }) -FailureMatch $failure.Match -ResumedSessionId $resumedSessionId -PriorCause $priorCause -TransientRetries $(if ($stopsByD1) { $attempt } else { $null }) | Out-Null
    Publish-DriverPhase
    Publish-DriverGit -BaseBranch $baseBranch

    if ($canRetry) {
        # Ola 2b (P2): punto entre intentos; una pausa pedida durante la sesion entra aqui y hace de espera (PB-8).
        $between = Invoke-DriverBetweenPoint
        if ($between.Stop) { $finalStatus = $between.Stop.Status; $finalReason = $between.Stop.Reason; $finalCause = $between.Stop.Cause; $stopLoop = $true; break }
        $k = $attempt + 1
        # Si la sesion a reanudar ya no existe, el intento pasa a sesion nueva: no hay nada que esperar.
        $resumeMissing = ($attempt -gt 0 -and $resumedSessionId -and (Test-ResumeSessionMissing -ExitCode $exitCode -DurationSeconds $attemptSeconds -StreamSummary $stream -ErrLogTail $errTailLines))
        $delay = if ($resumeMissing) { 0 } else { Get-RetryDelaySeconds -Attempt $k -Schedule $RetryBackoffSeconds }
        if (-not $retryReasonSet) {
            # PA-10: se guarda el motivo previo (p.ej. el de D2) para restaurarlo tras la espera.
            try { $reasonBeforeRetry = (Get-DriverStatus -StatusPath $statusPath).reason } catch { $reasonBeforeRetry = $null }
            $retryReasonSet = $true
        }
        $retryText = "Reintento $k/$MaxTransientRetries en $delay s ($cause)"
        Write-Host $retryText
        try { Set-DriverStatusReason -StatusPath $statusPath -Reason $retryText | Out-Null } catch { Write-Warning "No se pudo publicar el motivo del reintento: $($_.Exception.Message)" }
        # La espera acaba siempre al cumplirse $delay; Ctrl+C cae en el finally exterior (STOPPED).
        # Ola 2b: la espera corta en ticks de 1 s para leer el control; el heartbeat late cada LivenessPollSeconds (el primer tick late).
        $script:retryHeartbeatAt = [datetime]::MinValue
        $waitSignal = Wait-RetryBackoff -Seconds $(if ($between.Paused) { 0 } else { $delay }) -PollSeconds 1 -OnTick {
            if (((Get-Date) - $script:retryHeartbeatAt).TotalSeconds -ge $LivenessPollSeconds) {
                $script:retryHeartbeatAt = Get-Date
                # Un fallo del heartbeat no debe impedir leer el control en este tick.
                try { Set-DriverStatusHeartbeat -StatusPath $statusPath | Out-Null }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch { Write-Warning "No se pudo escribir el heartbeat del driver: $($_.Exception.Message)" }
            }
            Invoke-DriverControlPoint -State between
        }
        if ($waitSignal) {
            $between = Invoke-DriverBetweenPoint -Signal $waitSignal
            if ($between.Stop) { $finalStatus = $between.Stop.Status; $finalReason = $between.Stop.Reason; $finalCause = $between.Stop.Cause; $stopLoop = $true; break }
        }

        # Ola 2c (DO-8, PC-16): el tope tambien se comprueba antes de lanzar un reintento.
        $capReason = Test-DriverCostCap
        if ($capReason) {
            $ap = Invoke-DriverAwaitPoint -Origin tope_costo -Status STOPPED -Reason $capReason -Cause 'tope_costo' -Resumable $false -AnswerMode new -KillConfirmed $true
            if ($ap -eq 'final') { $stopLoop = $true; break }
            break
        }

        # Ola 2b (PB-9): un set-params aplica al intento siguiente; el effort y los argumentos se recalculan.
        $sessionEffort = if ($decision.Mode -eq 'close') { $CloseEffort } else { $LevelEffort }
        $claudeArgs = @('-p', $promptText) + $permissionArgs + $mcpArgs + @('--model', $Model, '--effort', $sessionEffort, '--output-format', 'stream-json', '--verbose', '--session-id', $sessionId)

        if ($resumeMissing) {
            # Respaldo: la sesion a reanudar no existe; el intento k usa una sesion nueva y el prompt original.
            $sessionId = [guid]::NewGuid().ToString()
            $resumedSessionId = $null
            if ($answerFallbackText) { $promptText = Add-DriverDecisionSection -Prompt $promptText -Text $answerFallbackText; $answerFallbackText = $null }
            $attemptArgs = ConvertTo-RetryClaudeArgs -Arguments $claudeArgs -Prompt $promptText -SessionFlag '--session-id' -SessionValue $sessionId
            Write-Host "La sesion a reanudar no existe: el intento $k usa una sesion nueva."
        }
        else {
            $resumedSessionId = $sessionId
            $attemptArgs = ConvertTo-RetryClaudeArgs -Arguments $claudeArgs -Prompt (Get-ResumePrompt) -SessionFlag '--resume' -SessionValue $sessionId
        }
        try { Set-DriverStatusReason -StatusPath $statusPath -Reason $reasonBeforeRetry | Out-Null } catch { Write-Warning "No se pudo restaurar el motivo previo al reintento: $($_.Exception.Message)" }
        $priorCause = $cause
        $attempt = $k
        continue
    }

    if ($hung) {
        $finalStatus = 'FAILED'
        $finalReason = "sesion $iter colgada: sin progreso durante $attemptLivenessMinutes minutos, sin mecanismo de desbloqueo disponible"
        # Ola 2c: con la espera habilitada el usuario decide; si no, Invoke-DriverAwaitPoint deja el final de siempre.
        $ap = Invoke-DriverAwaitPoint -Origin FAILED -Status FAILED -Reason $finalReason -Cause 'colgada' -Resumable ([bool]$sessionId -and $killedOk) -AnswerMode new -KillConfirmed $killedOk
        if ($ap -eq 'resume') { continue }
        if ($ap -eq 'new') { break }
        $stopLoop = $true
        break
    }

    if ($advanced -eq $true) { $noProgressStreak = 0 }
    elseif ($outcome.CountsAsNoProgress) { $noProgressStreak++ }

    if ($outcome.IsRetry) {
        Write-Host "Sesion $iter sin avance ($($outcome.Cause)) -- se reintenta el mismo paso."
    }
    elseif ($outcome.Cause -eq 'sin_marca_con_avance') {
        Write-Host "Sesion $iter sin marca PLAN_STATUS pero con avance del checkpoint -- se continua."
    }

    $sessionDecision = $outcome.Decision
    if ($outcome.CloseGateApplied) {
        Write-Host "Cierre invalido: la sesion declaro DONE pero falta el marcador de revision final -- se degrada a BLOCKED."
    }
    $d1Note = if ($stopsByD1) { " ($($failure.Kind), reintentos: $attempt)" } else { '' }
    Write-Host "Resultado sesion $iter -> $($sessionDecision.GlobalStatus) $($sessionDecision.Reason)$d1Note"

    if (-not $sessionDecision.ShouldContinue) {
        if ($sessionDecision.GlobalStatus -in @('BLOCKED', 'FAILED')) {
            # Ola 2c (PC-4): un BLOCKED del modelo (sin compuerta de cierre) admite --resume; el de una regla del driver, sesion nueva.
            $fromModel = ($outcome.PlanStatusForEvent -ceq 'BLOCKED') -and -not $outcome.CloseGateApplied
            $resumable = [bool]$sessionId -and $killedOk
            $ap = Invoke-DriverAwaitPoint -Origin $sessionDecision.GlobalStatus -Status $sessionDecision.GlobalStatus -Reason $sessionDecision.Reason -Cause $cause -Resumable $resumable -AnswerMode $(if ($fromModel -and $resumable) { 'resume' } else { 'new' }) -KillConfirmed $killedOk
            if ($ap -eq 'resume') { continue }
            if ($ap -eq 'new') { break }
            $stopLoop = $true
            break
        }
        $finalStatus = $sessionDecision.GlobalStatus
        $finalReason = $sessionDecision.Reason
        $stopLoop = $true
        break
    }
    break
    }
    # Fin del bucle de intentos (D1).
    if ($stopLoop) { break }

    $progress = Get-PlanProgress -PlanFilePath $PlanFile -ControllerStatePath $controllerStatePath
    $progressLevel = $progress.CurrentLevel
    # D2 persistente: si la iteracion cerro por current_level, no se vuelve a publicar el nivel del checkpoint.
    if ($decision.Mode -eq 'close' -and $decision.CompletedBy -eq 'current_level') { $progressLevel = $decision.TotalLevels }
    Set-DriverStatusProgress -StatusPath $statusPath -TotalLevels $progress.TotalLevels -CurrentLevel $progressLevel -LevelTaskCounts $progress.LevelTaskCounts | Out-Null
    Publish-DriverTasks
    # Ola 2b (P3): punto entre sesiones al final de la iteracion (pausa pedida, detener).
    $between = Invoke-DriverBetweenPoint
    if ($between.Stop) { $finalStatus = $between.Stop.Status; $finalReason = $between.Stop.Reason; $finalCause = $between.Stop.Cause; break }
}
}
catch {
    # Un Ctrl+C nunca es un fallo del driver: se relanza para que lo trate el
    # finally exterior (STOPPED), sin registrarlo como FAILED.
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
    # Si la excepcion llego con claude vivo (p.ej. Set-DriverStatusCurrentSession
    # agoto sus reintentos tras el lanzamiento), se mata su arbol aqui: con el
    # status ya en FAILED el finally exterior no limpia, y quedaria un claude con
    # permisos saltados sin supervision.
    if ($proc -and -not $proc.HasExited) { $null = Stop-ProcessTree -ProcessId $proc.Id }
    # Cualquier excepcion no controlada dentro del loop (p.ej. "claude" no
    # resoluble en PATH) no debe dejar .driver-status.json congelado en
    # RUNNING para siempre -- se marca FAILED con la causa antes de salir.
    $finalStatus = 'FAILED'
    $finalReason = "error no controlado del driver: $($_.Exception.Message)"
    # Evita dejar una "sesion en curso" fantasma en el dashboard tras un
    # crash del driver. Ya estamos manejando la excepcion original -- un
    # fallo acá no debe taparla, por eso va en su propio try/catch mudo.
    try { Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter $iter -SessionId $null | Out-Null } catch { }
}
finally {
    Pop-Location
}

if (-not $finalStatus) {
    $finalStatus = 'STOPPED_MAX_ITERATIONS'
    $finalReason = "se alcanzaron las $sessionBudget sesiones ($budgetSource) sin recibir PLAN_STATUS: COMPLETE"
}

Set-DriverStatusFinal -StatusPath $statusPath -GlobalStatus $finalStatus -Reason $finalReason -Cause $finalCause | Out-Null

Write-Host ''
Write-Host "=== Resultado final: $finalStatus ==="
if ($finalReason) {
    Write-Host "Motivo: $finalReason"
}

if ($finalStatus -eq 'DONE') {
    Write-Host ''
    Write-Host '--- Handoff a sesion interactiva humana ---'
    Write-Host 'El plan termino todos sus niveles y la revisión final del código completo.'
    if ($markerRelativeForPrompt) {
        Write-Host "Revisa los findings en: $markerRelativeForPrompt"
    }
    Write-Host 'Para la integración de la rama (merge/push/PR), lanza una sesión interactiva:'
    Write-Host "  cd `"$repoRoot`" ; claude"
    Write-Host '  y pide: "Ejecuta finishing-a-development-branch para este plan."'
}

if ($dashboard) {
    Write-Host "Dashboard disponible en http://localhost:$($dashboard.Port)/ hasta $DashboardIdleMinutes min sin uso (se apaga solo)."
}
}
catch {
    # Una excepcion fuera del bucle no debe quedar rotulada como Ctrl+C: si no es
    # PipelineStoppedException se marca FAILED antes de dejar pasar el error.
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
    $driverFailed = $true; $driverError = $_.Exception.Message
    try { Set-DriverStatusFinal -StatusPath $statusPath -GlobalStatus FAILED -Reason "error no controlado del driver: $($_.Exception.Message)" | Out-Null } catch { }
    throw
}
finally {
    # Idempotente: solo actua si el status sigue en RUNNING (Ctrl+C a medias).
    # Todo en try/catch mudo: un fallo de limpieza no debe tapar la excepcion original.
    try {
        $interrupt = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc `
            -GlobalStatus $(if ($driverFailed) { 'FAILED' } else { 'STOPPED' }) `
            -Reason $(if ($driverFailed) { "error no controlado del driver: $driverError" } else { 'Interrumpido con Ctrl+C' }) `
            -Cause $(if ($driverFailed) { 'error_driver' } else { 'manual' }) `
            -LogFile $(if ($logPath) { Split-Path -Leaf $logPath } else { $null }) `
            -StreamFile $(if ($streamPath) { Split-Path -Leaf $streamPath } else { $null }) `
            -ErrFile $(if ($errLogPath) { Split-Path -Leaf $errLogPath } else { $null }) `
            -OnSessionInterrupted {
                if ($launch) { $null = & $launch.Cleanup }
                Save-SessionStreamLog -StreamPath $streamPath -LogPath $logPath -Model $attemptModel -Effort $sessionEffort
            }
        if ($interrupt.Action -eq 'stopped') {
            if ($driverFailed) {
                Write-Host "El driver fallo: $driverError. Status $(if ($interrupt.StopWritten) { 'FAILED' } else { 'sin escribir (no se pudo escribir el estado FAILED)' }); el arbol de claude quedo cerrado si habia proceso vivo."
            }
            else {
                if (-not $interrupt.StopWritten) {
                    Write-Host 'Interrumpido con Ctrl+C, pero no se pudo escribir STOPPED: el status sigue en RUNNING; revisa permisos o bloqueos de .driver-status.json.'
                }
                # KilledPid es nulo si no habia proceso vivo o si no se logro cerrarlo.
                elseif ($null -ne $interrupt.KilledPid) {
                    Write-Host "Interrumpido con Ctrl+C: status STOPPED; el arbol de claude quedo cerrado (pid $($interrupt.KilledPid))."
                }
                elseif ($null -eq $proc) {
                    Write-Host 'Interrumpido con Ctrl+C: status STOPPED; no habia proceso de claude vivo.'
                }
                elseif (-not $proc.HasExited) {
                    Write-Host "Interrumpido con Ctrl+C: status STOPPED; ATENCION: claude sigue vivo (pid $($proc.Id)), cierralo a mano."
                }
                else {
                    Write-Host 'Interrumpido con Ctrl+C: status STOPPED; claude ya habia terminado.'
                }
            }
            if ($dashboard) {
                Write-Host "Dashboard disponible en http://localhost:$($dashboard.Port)/ hasta $DashboardIdleMinutes min sin uso (se apaga solo)."
            }
        }
    }
    catch { }

    # Ola 1b (D5): aviso al terminar. Un unico punto de enganche, despues del cleanup
    # y en su propio try: un fallo del aviso no cambia el estado ni tapa la excepcion original.
    try {
        $endStatus = Get-DriverStatus -StatusPath $statusPath
        if (Test-DriverNotificationDue -Status $endStatus) {
            $summary = Get-DriverNotificationSummary -Status $endStatus -CostMode $notifyCostMode
            $dashboardUrl = if ($dashboard) { "http://localhost:$($dashboard.Port)/" } else { $null }
            $notification = Send-DriverNotification -Status $endStatus.globalStatus -Reason $endStatus.reason -PlanFile $endStatus.planFile -Sessions $summary.Sessions -CostUsd $summary.CostUsd -Duration $summary.Duration -DashboardUrl $dashboardUrl -NotifyUrl $NotifyUrl -NoToast:$NoToast
            try { Set-DriverStatusNotification -StatusPath $statusPath -Notification $notification | Out-Null } catch { Write-Warning "No se pudo registrar el aviso en el status: $($_.Exception.Message)" }
            Write-Host "Aviso final: toast $($notification.toast), webhook $($notification.webhook)."
        }
    }
    catch { Write-Warning "No se pudo enviar el aviso final: $($_.Exception.Message)" }
}

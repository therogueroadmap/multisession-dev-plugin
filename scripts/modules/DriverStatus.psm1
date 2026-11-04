function Write-DriverStatusFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        $Status
    )

    $tmpPath = "$StatusPath.tmp"
    $Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmpPath -Encoding utf8

    # El lector Python puede tener el archivo abierto y el reemplazo falla en esa
    # ventana: 3 intentos separados por 50 ms. Si los 3 fallan la excepcion se
    # propaga (el status anterior queda intacto; el watchdog ya la captura).
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Move-Item -Force -LiteralPath $tmpPath -Destination $StatusPath -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                # Descarta el .tmp huerfano antes de propagar el fallo
                Remove-Item -LiteralPath $tmpPath -ErrorAction SilentlyContinue
                throw
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-DriverUtcStamp {
    param([Parameter(Mandatory = $true)][datetime]$Value)

    # Hora UTC con milisegundos y Z, cultura invariante: forma estable del bloque driver.
    $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
}

function Test-JsonDateKindSupport {
    # pwsh 7.5+ admite -DateKind; funcion aparte para que Pester la sustituya.
    [bool]((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind'))
}

function ConvertFrom-DriverJson {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    # Cada escritura del status pasa por ConvertFrom-Json y ConvertTo-Json. Con
    # -DateKind String (pwsh 7.5+) las fechas ISO no se convierten a [datetime] y
    # se reescriben tal cual (con su Z). En versiones anteriores se parsea normal y
    # se reinsertan desde el texto crudo las dos fechas del bloque driver.
    if (Test-JsonDateKindSupport) { return ($Text | ConvertFrom-Json -DateKind String -ErrorAction Stop) }

    $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    if ($null -ne $parsed -and $parsed.PSObject.Properties['driver'] -and $null -ne $parsed.driver) {
        foreach ($key in 'processStartedAt', 'heartbeatAt') {
            if ($Text -match ('"' + $key + '"\s*:\s*"([^"]*)"') -and $parsed.driver.PSObject.Properties[$key]) {
                $parsed.driver.$key = $Matches[1]
            }
        }
    }
    return $parsed
}

function Read-DriverStatusForWrite {
    param([Parameter(Mandatory = $true)][string]$StatusPath)

    ConvertFrom-DriverJson -Text (Get-Content -LiteralPath $StatusPath -Raw)
}

function New-DriverStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,
        [string]$PlanFile,
        [int]$HeartbeatSeconds = 30,
        # Corrida previa archivada: objeto con file, globalStatus, inherited.
        $PreviousRun = $null,
        # Status previo ya parseado: se heredan history y levelHistory.
        $InheritFrom = $null
    )

    $now = (Get-Date).ToString('o')

    # En un resume (proceso relanzado sobre un estado existente) se conserva el
    # workBranch persistido por el bootstrap previo: sin esto, el guard de rama
    # en modo continue leeria $null y abortaria un resume legitimo. Un bootstrap
    # nuevo lo vuelve a fijar despues via Set-DriverStatusBranch.
    $existingBranch = $null
    if (Test-Path -LiteralPath $StatusPath) {
        try {
            $prev = Read-DriverStatusForWrite -StatusPath $StatusPath
            if ($prev.PSObject.Properties.Name -contains 'workBranch') {
                $existingBranch = $prev.workBranch
            }
        }
        catch {
            $existingBranch = $null
        }
    }

    $processStartedAt = $null
    try {
        $processStartedAt = Get-DriverUtcStamp -Value (Get-Process -Id $PID -ErrorAction Stop).StartTime
    }
    catch {
        $processStartedAt = $null
    }

    $history = @()
    $levelHistory = @()
    if ($null -ne $InheritFrom) {
        if ($null -ne $InheritFrom.history) { $history = @($InheritFrom.history) }
        if ($null -ne $InheritFrom.levelHistory) { $levelHistory = @($InheritFrom.levelHistory) }
    }

    $status = [ordered]@{
        projectPath     = $ProjectPath
        planFile        = $PlanFile
        workBranch      = $existingBranch
        startedAt       = $now
        updatedAt       = $now
        globalStatus    = 'RUNNING'
        reason          = $null
        totalLevels     = $null
        currentLevel    = $null
        levelTaskCounts = $null
        levelHistory    = $levelHistory
        currentSession  = $null
        history         = $history
        driver          = [ordered]@{
            pid              = $PID
            processStartedAt = $processStartedAt
            heartbeatAt      = Get-DriverUtcStamp -Value (Get-Date)
            heartbeatSeconds = $HeartbeatSeconds
        }
        previousRun     = $PreviousRun
    }

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Get-DriverStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath
    )

    Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
}

function Add-DriverStatusEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [int]$Iter,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [AllowNull()]
        [string]$PlanStatus,
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [Parameter(Mandatory = $true)]
        [string]$SessionId,
        # Sin tipo [string]: si se deja sin pasar debe quedar $null, no ''.
        [AllowNull()]
        $PlanStatusReason,
        # Fase 2: causa clasificada por Resolve-SessionOutcome (o 'colgada').
        # Sin tipo por la misma razon que PlanStatusReason.
        [AllowNull()]
        $Cause,
        # Fase 4 (M13): objeto de New-SessionTelemetry (modelo, effort, coste,
        # tokens...). Opcional: los eventos de un driver viejo no lo traen.
        [AllowNull()]
        $Telemetry,
        # Ola 1b: nombres de archivo (sin ruta) del stream-json y del stderr de la
        # sesion. Sin tipo por la misma razon que PlanStatusReason.
        [AllowNull()]
        $StreamFile,
        [AllowNull()]
        $ErrFile,
        # Ola 1b (D1): datos del reintento. Sin tipo [string] en los de texto, por
        # la misma razon que PlanStatusReason: $null no debe pasar a ''.
        [int]$Attempt = 0,
        [AllowNull()]
        $FailureKind = $null,
        [AllowNull()]
        $FailureMatch = $null,
        [AllowNull()]
        $ResumedSessionId = $null,
        [AllowNull()]
        $PriorCause = $null,
        [AllowNull()]
        [System.Nullable[int]]$TransientRetries = $null
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $event = [pscustomobject]@{
        iter             = $Iter
        timestamp        = (Get-Date).ToString('o')
        exitCode         = $ExitCode
        planStatus       = $PlanStatus
        planStatusReason = $PlanStatusReason
        cause            = $Cause
        logPath          = $LogPath
        streamFile       = $StreamFile
        errFile          = $ErrFile
        sessionId        = $SessionId
        telemetry        = $Telemetry
        attempt          = $Attempt
        failureKind      = $FailureKind
        failureMatch     = $FailureMatch
        resumedSessionId = $ResumedSessionId
        priorCause       = $PriorCause
    }
    # transientRetries solo se agrega si llega (0 se escribe).
    if ($null -ne $TransientRetries) {
        $event | Add-Member -NotePropertyName transientRetries -NotePropertyValue ([int]$TransientRetries)
    }

    $status.history = @($status.history) + $event
    $status.updatedAt = $event.timestamp
    $status.currentSession = $null

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusCurrentSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [int]$Iter,
        [AllowNull()]
        [string]$SessionId,
        # Ola 1b: sin tipo [string] en los de archivo para que $null no pase a ''.
        [AllowNull()]
        $StreamFile,
        [AllowNull()]
        $ErrFile,
        [AllowNull()]
        [System.Nullable[int]]$LivenessTimeoutMinutes,
        # Ola 1b (D1): numero de intento de la sesion (0 = sesion original).
        [int]$Attempt = 0
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $now = (Get-Date).ToString('o')

    if ([string]::IsNullOrEmpty($SessionId)) {
        $status.currentSession = $null
    }
    else {
        $status.currentSession = [pscustomobject]@{
            iter                   = $Iter
            sessionId              = $SessionId
            startedAt              = $now
            streamFile             = $StreamFile
            errFile                = $ErrFile
            lastProgressAt         = $now
            livenessTimeoutMinutes = $LivenessTimeoutMinutes
            attempt                = $Attempt
        }
    }
    $status.updatedAt = $now

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusLiveness {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [datetime]$LastProgressAt
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    if ($null -eq $status.currentSession) { return $status }

    $value = $LastProgressAt.ToString('o')
    if ($status.currentSession.PSObject.Properties['lastProgressAt']) {
        $status.currentSession.lastProgressAt = $value
    }
    else {
        # Status de un driver viejo: la propiedad no existe todavia.
        $status.currentSession | Add-Member -NotePropertyName lastProgressAt -NotePropertyValue $value -Force
    }
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusFinal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('DONE', 'BLOCKED', 'FAILED', 'STOPPED', 'STOPPED_MAX_ITERATIONS')]
        [string]$GlobalStatus,
        # Sin tipo: [string] convertiria $null en '' y el JSON quedaria con
        # "reason": "" en vez de null (inconsistente con planStatusReason).
        [AllowNull()]
        $Reason,
        # Causa raiz opcional (p.ej. 'dashboard', 'pausa_vencida'); sin tipo por la
        # misma razon que Reason. Sin Cause no se crea ni se toca la clave cause.
        [AllowNull()]
        $Cause = $null
    )

    if ([string]::IsNullOrEmpty([string]$Reason)) { $Reason = $null } else { $Reason = [string]$Reason }

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $now = (Get-Date).ToString('o')
    $status.globalStatus = $GlobalStatus
    $status.reason = $Reason
    $status.updatedAt = $now
    if (-not [string]::IsNullOrEmpty([string]$Cause)) {
        if ($status.PSObject.Properties['cause']) {
            $status.cause = [string]$Cause
        }
        else {
            $status | Add-Member -NotePropertyName cause -NotePropertyValue ([string]$Cause) -Force
        }
    }
    # PAUSED y AWAITING solo existen mientras dura ese estado: el final los borra.
    foreach ($live in 'paused', 'awaiting') {
        if ($status.PSObject.Properties[$live]) { $status.PSObject.Properties.Remove($live) }
    }
    if ($status.PSObject.Properties['driver'] -and $null -ne $status.driver) {
        # Ultima actualizacion del latido: el estado final cierra la corrida.
        $status.driver.heartbeatAt = Get-DriverUtcStamp -Value (Get-Date)
    }

    $history = @($status.levelHistory)
    for ($i = 0; $i -lt $history.Count; $i++) {
        if ($null -eq $history[$i].completedAt) {
            $history[$i].completedAt = $now
        }
    }
    $status.levelHistory = $history

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [AllowNull()]
        [System.Nullable[int]]$TotalLevels,
        [AllowNull()]
        [System.Nullable[int]]$CurrentLevel,
        [AllowNull()]
        [object[]]$LevelTaskCounts
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $previousCurrentLevel = $status.currentLevel
    $now = (Get-Date).ToString('o')

    $status.totalLevels = $TotalLevels
    $status.currentLevel = $CurrentLevel
    $status.levelTaskCounts = $LevelTaskCounts
    $status.updatedAt = $now

    if ($null -ne $CurrentLevel) {
        $history = @($status.levelHistory)
        $existing = $history | Where-Object { $_.level -eq $CurrentLevel }

        if ($null -eq $previousCurrentLevel) {
            if (-not $existing) {
                $history += [pscustomobject]@{ level = $CurrentLevel; enteredAt = $now; completedAt = $null }
            }
        }
        elseif ($CurrentLevel -ne $previousCurrentLevel) {
            for ($i = 0; $i -lt $history.Count; $i++) {
                if ($history[$i].level -eq $previousCurrentLevel -and $null -eq $history[$i].completedAt) {
                    $history[$i].completedAt = $now
                }
            }
            if (-not $existing) {
                $history += [pscustomobject]@{ level = $CurrentLevel; enteredAt = $now; completedAt = $null }
            }
        }

        $status.levelHistory = $history
    }

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [AllowNull()]
        [string]$WorkBranch
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    if (-not ($status.PSObject.Properties.Name -contains 'workBranch')) {
        $status | Add-Member -NotePropertyName 'workBranch' -NotePropertyValue $null -Force
    }
    $status.workBranch = $WorkBranch
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusHeartbeat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [datetime]$LastProgressAt
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $now = Get-Date

    if ($status.PSObject.Properties['driver'] -and $null -ne $status.driver) {
        $status.driver.heartbeatAt = Get-DriverUtcStamp -Value $now
    }

    if ($PSBoundParameters.ContainsKey('LastProgressAt') -and $null -ne $status.currentSession) {
        $value = $LastProgressAt.ToString('o')
        if ($status.currentSession.PSObject.Properties['lastProgressAt']) {
            $status.currentSession.lastProgressAt = $value
        }
        else {
            # Status de un driver viejo: la propiedad no existe todavia.
            $status.currentSession | Add-Member -NotePropertyName lastProgressAt -NotePropertyValue $value -Force
        }
    }
    $status.updatedAt = $now.ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusReason {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        # Sin tipo por la misma razon que en Set-DriverStatusFinal.
        [AllowNull()]
        $Reason = $null
    )

    if ([string]::IsNullOrEmpty([string]$Reason)) { $Reason = $null } else { $Reason = [string]$Reason }

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $status.reason = $Reason
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Set-DriverStatusNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        # Sin tipo: objeto con sentAt, toast, webhook y webhookHost (C6).
        [Parameter(Mandatory = $true)]
        $Notification
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    if ($status.PSObject.Properties['notification']) {
        $status.notification = $Notification
    }
    else {
        # Status de un driver viejo: la propiedad no existe todavia.
        $status | Add-Member -NotePropertyName notification -NotePropertyValue $Notification -Force
    }
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

# Escribe un bloque entero del status (limits, params, phase, git, control, tasks, permissions o mcp). Si la clave ya
# existe se reemplaza completa, sin mezclar campos; en un status de un driver viejo
# se agrega. No toca globalStatus, reason ni los otros bloques. Una sola escritura:
# puede lanzar si Write-DriverStatusFile agota sus intentos (el driver la envuelve en try).
function Set-DriverStatusBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('limits', 'params', 'phase', 'git', 'control', 'tasks', 'permissions', 'mcp')]
        [string]$Name,
        # Sin tipo: objeto u ordered del bloque completo.
        [Parameter(Mandatory = $true)]
        $Value
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    if ($status.PSObject.Properties[$Name]) {
        $status.$Name = $Value
    }
    else {
        # Status de un driver viejo: la propiedad no existe todavia.
        $status | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

# Publica un estado vivo no final: RUNNING, PAUSED o AWAITING. PAUSED y AWAITING
# llevan su bloque (paused / awaiting) y borran el del otro; RUNNING borra ambos.
# Una sola escritura. No toca driver, history, currentSession ni otros bloques.
function Set-DriverStatusLiveState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('RUNNING', 'PAUSED', 'AWAITING')]
        [string]$State,
        # Sin tipo por la misma razon que en Set-DriverStatusFinal.
        [AllowNull()]
        $Reason = $null,
        [AllowNull()]
        $Block = $null
    )

    if ($State -ne 'RUNNING' -and $null -eq $Block) {
        throw "$State exige -Block"
    }
    if ([string]::IsNullOrEmpty([string]$Reason)) { $Reason = $null } else { $Reason = [string]$Reason }

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath
    $status.globalStatus = $State
    $status.reason = $Reason

    $keep = $null
    $drop = @('paused', 'awaiting')
    if ($State -eq 'PAUSED') { $keep = 'paused' }
    elseif ($State -eq 'AWAITING') { $keep = 'awaiting' }
    foreach ($name in $drop) {
        if ($name -ne $keep -and $status.PSObject.Properties[$name]) {
            $status.PSObject.Properties.Remove($name)
        }
    }
    if ($null -ne $keep) {
        if ($status.PSObject.Properties[$keep]) {
            $status.$keep = $Block
        }
        else {
            $status | Add-Member -NotePropertyName $keep -NotePropertyValue $Block -Force
        }
    }
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

$script:MaxActions = 200

# Agrega una orden procesada a actions[] (maximo 200, se descartan las mas viejas) y
# fija control.last con los campos de la entrada. Conserva control.enabled; si el
# bloque control no existe lo crea con enabled = $false. Una sola escritura.
function Add-DriverStatusAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        # Sin tipo: entrada de C7 (ordered u objeto).
        [Parameter(Mandatory = $true)]
        $Entry
    )

    $status = Read-DriverStatusForWrite -StatusPath $StatusPath

    $existing = @()
    if ($status.PSObject.Properties['actions'] -and $null -ne $status.actions) {
        $existing = @($status.actions)
    }
    $all = @($existing) + @($Entry)
    if ($all.Count -gt $script:MaxActions) {
        $all = @($all[($all.Count - $script:MaxActions)..($all.Count - 1)])
    }
    if ($status.PSObject.Properties['actions']) {
        $status.actions = $all
    }
    else {
        $status | Add-Member -NotePropertyName actions -NotePropertyValue $all -Force
    }

    function Get-EntryField($name) {
        if ($Entry -is [System.Collections.IDictionary]) { return $Entry[$name] }
        if ($null -ne $Entry.PSObject.Properties[$name]) { return $Entry.$name }
        return $null
    }
    $last = [ordered]@{
        id        = Get-EntryField 'id'
        action    = Get-EntryField 'action'
        result    = Get-EntryField 'result'
        detail    = Get-EntryField 'detail'
        appliedAt  = Get-EntryField 'appliedAt'
    }

    if (-not $status.PSObject.Properties['control'] -or $null -eq $status.control) {
        $control = [ordered]@{ enabled = $false; last = $last }
        if ($status.PSObject.Properties['control']) { $status.control = $control }
        else { $status | Add-Member -NotePropertyName control -NotePropertyValue $control -Force }
    }
    elseif ($status.control.PSObject.Properties['last']) {
        $status.control.last = $last
    }
    else {
        $status.control | Add-Member -NotePropertyName last -NotePropertyValue $last -Force
    }
    $status.updatedAt = (Get-Date).ToString('o')

    Write-DriverStatusFile -StatusPath $StatusPath -Status $status
    return $status
}

function Save-DriverStatusArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath
    )

    if (-not (Test-Path -LiteralPath $StatusPath)) { return $null }

    $file = Get-Item -LiteralPath $StatusPath
    $runsDir = Join-Path (Split-Path -Parent $file.FullName) '.driver-runs'
    if (-not (Test-Path -LiteralPath $runsDir)) {
        New-Item -ItemType Directory -Path $runsDir -Force | Out-Null
    }

    $previous = $null
    try {
        $previous = ConvertFrom-DriverJson -Text (Get-Content -LiteralPath $StatusPath -Raw)
    }
    catch {
        $previous = $null
    }
    $readable = ($null -ne $previous)

    $stampFormat = 'yyyyMMdd-HHmmss'
    if ($readable) {
        $started = $null
        $startedRaw = if ($previous.PSObject.Properties['startedAt']) { $previous.startedAt } else { $null }
        try {
            if ($startedRaw -is [datetime]) { $started = $startedRaw.ToLocalTime() }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$startedRaw)) {
                $started = ([datetimeoffset]::Parse([string]$startedRaw, [cultureinfo]::InvariantCulture)).LocalDateTime
            }
        }
        catch {
            $started = $null
        }
        if ($null -eq $started) { $started = $file.LastWriteTime }

        $planFile = if ($previous.PSObject.Properties['planFile']) { [string]$previous.planFile } else { '' }
        $leaf = if ([string]::IsNullOrWhiteSpace($planFile)) { 'sin-plan' } else { [IO.Path]::GetFileNameWithoutExtension($planFile) }
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'sin-plan' }
        $baseName = $started.ToString($stampFormat, [cultureinfo]::InvariantCulture) + '-' + $leaf
    }
    else {
        $baseName = $file.LastWriteTime.ToString($stampFormat, [cultureinfo]::InvariantCulture) + '-ilegible'
    }

    $name = "$baseName.json"
    $suffix = 2
    while (Test-Path -LiteralPath (Join-Path $runsDir $name)) {
        $name = "$baseName-$suffix.json"
        $suffix++
    }

    $dest = Join-Path $runsDir $name
    Copy-Item -LiteralPath $StatusPath -Destination $dest -ErrorAction Stop

    [pscustomobject]@{
        RelativePath = '.driver-runs/' + $name
        FullPath     = $dest
        Readable     = $readable
        Previous     = if ($readable) { $previous } else { $null }
    }
}

# Clave comparable de una ruta de plan: ruta completa, con \ como separador y sin separador final.
# Devuelve '' si la ruta esta vacia o no se puede resolver.
function ConvertTo-DriverPlanPathKey {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return '' }
    $full = $full.Replace('/', '\')
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-DriverStatusInheritable {
    param(
        [AllowNull()]
        $Previous,
        [AllowNull()]
        [string]$PlanFile,
        [AllowNull()]
        [string]$CurrentBranch,
        [string]$FirstMode
    )

    if ($null -eq $Previous) { return $false }
    if ([string]::IsNullOrWhiteSpace($PlanFile)) { return $false }
    if ($FirstMode -eq 'bootstrap') { return $false }

    $prevPlan = if ($Previous.PSObject.Properties['planFile']) { [string]$Previous.planFile } else { '' }
    $prevKey = ConvertTo-DriverPlanPathKey -Path $prevPlan
    $planKey = ConvertTo-DriverPlanPathKey -Path $PlanFile
    if ([string]::IsNullOrEmpty($prevKey) -or -not [string]::Equals($prevKey, $planKey, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $prevBranch = if ($Previous.PSObject.Properties['workBranch']) { [string]$Previous.workBranch } else { '' }
    if ([string]::IsNullOrWhiteSpace($prevBranch)) { return $false }

    return [string]::Equals($prevBranch, [string]$CurrentBranch, [StringComparison]::Ordinal)
}

function Get-DriverStatusMaxIter {
    param([Parameter(Mandatory = $true)]$Status)

    $max = 0
    foreach ($entry in @($Status.history)) {
        if ($null -eq $entry) { continue }
        $iter = $entry.iter
        if (($iter -is [int] -or $iter -is [long]) -and $iter -gt $max) { $max = [int]$iter }
    }
    return $max
}

Export-ModuleMember -Function New-DriverStatus, Get-DriverStatus, Add-DriverStatusEvent, Set-DriverStatusFinal, Set-DriverStatusProgress, Set-DriverStatusCurrentSession, Set-DriverStatusLiveness, Set-DriverStatusBranch, Set-DriverStatusHeartbeat, Set-DriverStatusReason, Set-DriverStatusNotification, Save-DriverStatusArchive, Test-DriverStatusInheritable, Get-DriverStatusMaxIter, Set-DriverStatusBlock, Set-DriverStatusLiveState, Add-DriverStatusAction, Test-JsonDateKindSupport, ConvertFrom-DriverJson

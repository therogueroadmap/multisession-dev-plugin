function Get-PlanProgress {
    param(
        [AllowNull()]
        [string]$PlanFilePath,
        [AllowNull()]
        [string]$ControllerStatePath
    )

    $totalLevels = $null
    $currentLevel = $null
    $levelTaskCounts = $null

    if ($PlanFilePath -and (Test-Path -LiteralPath $PlanFilePath)) {
        try {
            $content = Get-Content -LiteralPath $PlanFilePath -Raw
            $levels = New-Object System.Collections.Generic.List[int]
            # Solo cuenta filas de la seccion "## Dependency Map": otras tablas del plan
            # (p.ej. decisiones con numero de tarea en la ultima columna) inflaban totalLevels.
            # Si el plan no tiene esa seccion se escanea todo el archivo (compatibilidad).
            $inMap = $false
            $hasMapHeading = $content -match '(?im)^##\s+Dependency Map\b'
            foreach ($line in ($content -split "`r?`n")) {
                if ($hasMapHeading) {
                    if ($line -match '^##\s+Dependency Map\b') { $inMap = $true; continue }
                    if ($line -match '^##\s') { $inMap = $false }
                    if (-not $inMap) { continue }
                }
                if ($line -match '^\|.*\|\s*(\d+)\s*\|\s*$') {
                    $levels.Add([int]$Matches[1])
                }
            }
            if ($levels.Count -gt 0) {
                $maxLevel = ($levels | Measure-Object -Maximum).Maximum
                $totalLevels = $maxLevel + 1

                $counts = New-Object 'int[]' $totalLevels
                foreach ($lvl in $levels) {
                    $counts[$lvl]++
                }
                $levelTaskCounts = $counts
            }
        }
        catch {
            $totalLevels = $null
            $levelTaskCounts = $null
        }
    }

    if ($ControllerStatePath -and (Test-Path -LiteralPath $ControllerStatePath)) {
        try {
            $state = Get-Content -LiteralPath $ControllerStatePath -Raw | ConvertFrom-Json
            if ($null -ne $state.completed_levels) {
                $currentLevel = @($state.completed_levels).Count
            }
            else {
                $currentLevel = 0
            }
        }
        catch {
            $currentLevel = $null
        }
    }

    return [pscustomobject]@{
        TotalLevels     = $totalLevels
        CurrentLevel    = $currentLevel
        LevelTaskCounts = $levelTaskCounts
    }
}

# Construye la decision de arranque con la forma fija de cinco propiedades.
# Los parametros sin tipo conservan $null (un [int] lo convertiria en 0).
function New-BootstrapDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        $CompletedBy = $null,
        $CompletedCount = $null,
        $TotalLevels = $null
    )

    return [pscustomobject]@{
        Mode           = $Mode
        Reason         = $Reason
        CompletedBy    = $CompletedBy
        CompletedCount = $CompletedCount
        TotalLevels    = $TotalLevels
    }
}

function Get-PlanBootstrapDecision {
    param(
        [AllowNull()]
        [string]$PlanFilePath,
        [AllowNull()]
        [string]$ControllerStatePath,
        [AllowNull()]
        [string]$FinalReviewMarkerPath
    )

    if ([string]::IsNullOrEmpty($PlanFilePath)) {
        return New-BootstrapDecision -Mode 'continue' -Reason 'sin -PlanFilePath resuelto'
    }

    if ([string]::IsNullOrEmpty($ControllerStatePath) -or -not (Test-Path -LiteralPath $ControllerStatePath)) {
        return New-BootstrapDecision -Mode 'bootstrap' -Reason 'no existe estado previo'
    }

    try {
        $state = Get-Content -LiteralPath $ControllerStatePath -Raw | ConvertFrom-Json
        $completedCount = if ($null -ne $state.completed_levels) { @($state.completed_levels).Count } else { 0 }
        $currentLevel = if ($null -ne $state.current_level) { [int]$state.current_level } else { 0 }
    }
    catch {
        return New-BootstrapDecision -Mode 'bootstrap' -Reason 'estado ilegible o invalido'
    }

    if ($completedCount -eq 0 -and $currentLevel -eq 0) {
        return New-BootstrapDecision -Mode 'bootstrap' -Reason 'estado cold-start' -CompletedCount $completedCount
    }

    $statePlanName = if ($state.plan) { Split-Path -Leaf $state.plan } else { $null }
    $targetPlanName = Split-Path -Leaf $PlanFilePath

    if ($statePlanName -ne $targetPlanName) {
        return New-BootstrapDecision -Mode 'bootstrap' -Reason 'plan distinto al del estado' -CompletedCount $completedCount
    }

    # Avance real sobre el mismo plan: distinguir continue / close / done.
    $progress = Get-PlanProgress -PlanFilePath $PlanFilePath -ControllerStatePath $ControllerStatePath
    $total = $progress.TotalLevels

    if ($null -eq $total) {
        return New-BootstrapDecision -Mode 'continue' -Reason 'total de niveles indeterminado' -CompletedCount $completedCount
    }

    # Plan completo (D2): completed_levels gana; current_level >= total tambien
    # lo completa cuando completed_levels quedo corto.
    $completedBy = $null
    if ($completedCount -ge $total) {
        $completedBy = 'completed_levels'
    }
    elseif ($currentLevel -ge $total) {
        $completedBy = 'current_level'
    }

    if ($null -eq $completedBy) {
        return New-BootstrapDecision -Mode 'continue' -Reason 'continuando plan existente con avance' -CompletedCount $completedCount -TotalLevels $total
    }

    $markerExists = (-not [string]::IsNullOrEmpty($FinalReviewMarkerPath)) -and (Test-Path -LiteralPath $FinalReviewMarkerPath)
    if ($markerExists) {
        return New-BootstrapDecision -Mode 'done' -Reason 'plan completo y cierre realizado' -CompletedBy $completedBy -CompletedCount $completedCount -TotalLevels $total
    }

    $closeReason = if ($completedBy -eq 'current_level') { 'plan completo segun current_level, cierre pendiente' } else { 'niveles completos, cierre pendiente' }
    return New-BootstrapDecision -Mode 'close' -Reason $closeReason -CompletedBy $completedBy -CompletedCount $completedCount -TotalLevels $total
}

# Lectura del checkpoint en su formato actual (plan, completed_levels,
# current_level), sin migrarlo. $null si falta o es ilegible. SamePlan usa la
# misma regla de leaf que Get-PlanBootstrapDecision.
function Get-ControllerStateInfo {
    param(
        [AllowNull()]
        [string]$ControllerStatePath,
        [Parameter(Mandatory = $true)]
        [string]$PlanFilePath
    )

    if ([string]::IsNullOrEmpty($ControllerStatePath) -or -not (Test-Path -LiteralPath $ControllerStatePath)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $ControllerStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $completedCount = if ($null -ne $state.completed_levels) { @($state.completed_levels).Count } else { 0 }
        $currentLevel = if ($null -ne $state.current_level) { [int]$state.current_level } else { 0 }
    }
    catch {
        return $null
    }

    $statePlanName = if ($state.plan) { Split-Path -Leaf $state.plan } else { $null }
    $samePlan = ($null -ne $statePlanName) -and ($statePlanName -eq (Split-Path -Leaf $PlanFilePath))

    return [pscustomobject]@{
        SamePlan       = $samePlan
        HasProgress    = ($completedCount -gt 0 -or $currentLevel -gt 0)
        CompletedCount = $completedCount
        CurrentLevel   = $currentLevel
    }
}

# Fix 3 (compatibilidad): en bootstrap, busca en las carpetas candidatas un
# checkpoint con avance de este mismo plan que no esta en la carpeta efectiva
# (lo dejo una version anterior del driver o una sesion lanzada desde la
# raiz). Devuelve su ruta, o $null.
function Find-StrayControllerState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlanFilePath,
        [Parameter(Mandatory = $true)]
        [string]$EffectivePlansDir,
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CandidateDirs
    )

    $effective = [System.IO.Path]::GetFullPath($EffectivePlansDir).TrimEnd('\', '/')
    foreach ($dir in @($CandidateDirs)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
        if ($full.Equals($effective, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $candidate = Join-Path $full '.controller-state.json'
        $info = Get-ControllerStateInfo -ControllerStatePath $candidate -PlanFilePath $PlanFilePath
        if ($info -and $info.SamePlan -and $info.HasProgress) { return $candidate }
    }
    return $null
}

# Fase 2 (M3/M9): la sesion avanzo si el checkpoint de este plan tiene mas
# niveles completados que antes de lanzarla. Before y After son salidas de
# Get-ControllerStateInfo ($null si faltaba o era ilegible). Un Before de otro
# plan cuenta como 0; un After ausente o de otro plan nunca es avance. Solo se
# mira CompletedCount: el skill actualiza completed_levels y current_level juntos.
function Test-CheckpointAdvanced {
    param(
        [AllowNull()]
        $Before,
        [AllowNull()]
        $After
    )

    if ($null -eq $After -or -not $After.SamePlan) { return $false }
    $beforeCount = if ($null -ne $Before -and $Before.SamePlan) { [int]$Before.CompletedCount } else { 0 }
    return ([int]$After.CompletedCount -gt $beforeCount)
}

# Fase 4 (M12): presupuesto de sesiones del driver. Cada nivel pendiente y el
# cierre consumen al menos una sesion y como maximo 1 + NoProgressRetries antes
# de que M9 pare el driver (Test-CheckpointAdvanced mide niveles completados).
# Es el peor caso del camino que no para por otro motivo. Sin niveles conocidos
# (plan sin Dependency Map o ilegible) devuelve el fallback.
function Get-SessionBudget {
    param(
        [AllowNull()]
        $TotalLevels,
        [Parameter(Mandatory = $true)]
        [int]$CompletedLevels,
        [Parameter(Mandatory = $true)]
        [bool]$FinalReviewDone,
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 10)]
        [int]$NoProgressRetries,
        [int]$Fallback = 30
    )

    if ($null -eq $TotalLevels -or [int]$TotalLevels -le 0) { return $Fallback }

    $pending = [Math]::Max([int]$TotalLevels - $CompletedLevels, 0)
    if (-not $FinalReviewDone) { $pending++ }
    return ([Math]::Max($pending, 1) * (1 + $NoProgressRetries))
}

function Get-FinalReviewPublishName {
    # Nombre del archivo de revision final que el dashboard puede servir, o $null.
    # El \w de .NET acepta marcas combinantes (\p{Mn}) y conectores (\p{Pc} salvo "_") que el \w
    # de Python no admite, y el $ de .NET acepta un salto de linea final; se rechazan aqui.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $leaf = Split-Path -Leaf $Path
    if (($leaf -cmatch '^\.final-review-[\w.\-]+\.md$') -and ($leaf -cnotmatch '\p{Mn}') -and ($leaf -cnotmatch '[\p{Pc}-[_]]') -and (-not $leaf.Contains("`n"))) { return $leaf }
    return $null
}

Export-ModuleMember -Function Get-PlanProgress, Get-PlanBootstrapDecision, Get-ControllerStateInfo, Find-StrayControllerState, Test-CheckpointAdvanced, Get-SessionBudget, Get-FinalReviewPublishName

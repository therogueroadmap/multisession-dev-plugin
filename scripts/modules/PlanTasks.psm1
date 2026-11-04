# PlanTasks: lista de tareas del plan para el bloque "tasks" del status (Ola 3).
#
# Las filas salen de la seccion "## Dependency Map" del plan (id, titulo y nivel) y se cruzan
# con el checkpoint del controller (estado, commit y fix_commits) por una clave normalizada.
# No toca PlanProgress.psm1: las dos lecturas del mapa conviven con el mismo criterio de fila.

$script:MaxTasks = 100
$script:MaxTitleLength = 200
$script:MaxFixCommits = 10
$script:MaxStatusLength = 40
$script:HashPattern = '^[0-9a-fA-F]{7,40}\z'

# Clave de cruce entre el mapa del plan y el checkpoint. '' si no queda clave.
# "Task 1", "T1", "T1: nombre", "task  1" y " TASK 1 " dan '1'; "Task T0a" y "TASK 0A" dan '0a'.
function ConvertTo-PlanTaskKey {
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $t = $Text
    $colon = $t.IndexOf(':')
    if ($colon -ge 0) { $t = $t.Substring(0, $colon) }

    $t = $t -replace '[`*]', ''
    $t = ($t.Trim().ToLowerInvariant()) -replace '\s', ''

    if ($t.StartsWith('task')) { $t = $t.Substring(4) }
    if ($t -match '^t\d') { $t = $t.Substring(1) }

    return $t
}

# Estado del checkpoint al vocabulario del contrato: done, in_progress, pending o blocked.
# Un valor desconocido se publica tal cual (recortado); vacio, nulo o no texto vale pending.
function ConvertTo-PlanTaskStatus {
    param(
        [AllowNull()]
        $Value
    )

    if ($Value -isnot [string]) { return 'pending' }

    $s = $Value.Trim()
    if ($s.Length -eq 0) { return 'pending' }

    switch ($s.ToUpperInvariant()) {
        { $_ -in 'DONE', 'DONE_WITH_CONCERNS', 'COMPLETE', 'COMPLETED' } { return 'done' }
        { $_ -in 'IN_PROGRESS', 'IN-PROGRESS', 'RUNNING' } { return 'in_progress' }
        'PENDING' { return 'pending' }
        { $_ -in 'BLOCKED', 'NEEDS_CONTEXT', 'FAILED' } { return 'blocked' }
    }

    if ($s.Length -gt $script:MaxStatusLength) { $s = $s.Substring(0, $script:MaxStatusLength) }
    return $s
}

# Propiedad de un objeto leido de JSON sin fallar si falta o el objeto no es un objeto.
function Get-PlanTaskProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# Titulo recortado a 200 caracteres sin partir un par sustituto.
function Limit-PlanTaskTitle {
    param([string]$Title)

    if ($Title.Length -le $script:MaxTitleLength) { return $Title }
    $cut = $script:MaxTitleLength
    if ([char]::IsHighSurrogate($Title[$cut - 1])) { $cut-- }
    return $Title.Substring(0, $cut)
}

# Filas validas del Dependency Map: lista de @{ id; title; level }. Vacia si no hay seccion
# o filas (a diferencia de Get-PlanProgress, no escanea todo el archivo).
function Read-PlanMapRows {
    param([string]$Content)

    $rows = New-Object System.Collections.Generic.List[object]
    if ($Content -notmatch '(?im)^##\s+Dependency Map\b') { return , $rows }

    $inMap = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^##\s+Dependency Map\b') { $inMap = $true; continue }
        if ($line -match '^##\s') { $inMap = $false }
        if (-not $inMap) { continue }

        if ($line -notmatch '^\|.*\|\s*(\d+)\s*\|\s*$') { continue }
        $level = 0
        if (-not [int]::TryParse($Matches[1], [ref]$level)) { continue }

        $inner = $line.Trim()
        $inner = $inner.Substring(1, $inner.Length - 2)
        $cells = @([regex]::Split($inner, '(?<!\\)\|'))
        $first = ($cells[0] -replace '\\\|', '|').Trim()
        if ($first.Length -eq 0) { continue }

        $colon = $first.IndexOf(':')
        if ($colon -ge 0) {
            $id = $first.Substring(0, $colon).Trim()
            $title = $first.Substring($colon + 1).Trim()
        }
        else {
            $id = $first
            $title = $first
        }
        if ((ConvertTo-PlanTaskKey -Text $id) -eq '') { continue }

        $rows.Add([ordered]@{ id = $id; title = (Limit-PlanTaskTitle -Title $title); level = $level })
    }

    # La coma evita que la lista se desenrolle (o desaparezca si esta vacia) al salir.
    return , $rows
}

# Bloque "tasks" del status, o $null si no hay Dependency Map con filas validas o el
# checkpoint existe pero no se puede leer. Checkpoint ausente o de otro plan: todas pending.
function Get-PlanTasks {
    param(
        [AllowNull()]
        [string]$PlanFilePath,
        [AllowNull()]
        [string]$ControllerStatePath
    )

    if ([string]::IsNullOrEmpty($PlanFilePath) -or -not (Test-Path -LiteralPath $PlanFilePath)) { return $null }

    try {
        $content = Get-Content -LiteralPath $PlanFilePath -Raw -ErrorAction Stop
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrEmpty($content)) { return $null }

    $rows = Read-PlanMapRows -Content $content
    if ($rows.Count -eq 0) { return $null }

    # Entradas del checkpoint por clave normalizada (si dos normalizan igual, gana la primera).
    $entries = @{}
    if (-not [string]::IsNullOrEmpty($ControllerStatePath) -and (Test-Path -LiteralPath $ControllerStatePath)) {
        try {
            $state = Get-Content -LiteralPath $ControllerStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return $null
        }

        # Misma regla de leaf que Get-ControllerStateInfo: otro plan no aporta estados.
        $statePlan = Get-PlanTaskProperty -Object $state -Name 'plan'
        $samePlan = $false
        if ($statePlan -is [string] -and $statePlan.Length -gt 0) {
            $samePlan = ((Split-Path -Leaf $statePlan) -eq (Split-Path -Leaf $PlanFilePath))
        }

        $stateTasks = Get-PlanTaskProperty -Object $state -Name 'tasks'
        if ($samePlan -and $null -ne $stateTasks) {
            foreach ($prop in $stateTasks.PSObject.Properties) {
                $key = ConvertTo-PlanTaskKey -Text $prop.Name
                if ($key.Length -gt 0 -and -not $entries.ContainsKey($key)) { $entries[$key] = $prop.Value }
            }
        }
    }

    $truncated = $rows.Count -gt $script:MaxTasks
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($row in ($rows | Select-Object -First $script:MaxTasks)) {
        $entry = $entries[(ConvertTo-PlanTaskKey -Text $row.id)]

        $commit = $null
        $fix = New-Object System.Collections.Generic.List[string]
        $status = 'pending'
        if ($null -ne $entry) {
            $status = ConvertTo-PlanTaskStatus -Value (Get-PlanTaskProperty -Object $entry -Name 'status')

            $c = Get-PlanTaskProperty -Object $entry -Name 'commit'
            if ($c -is [string] -and $c -match $script:HashPattern) { $commit = $c }

            $fc = Get-PlanTaskProperty -Object $entry -Name 'fix_commits'
            if ($null -ne $fc) {
                foreach ($h in @($fc)) {
                    if ($fix.Count -ge $script:MaxFixCommits) { break }
                    if ($h -is [string] -and $h -match $script:HashPattern) { $fix.Add($h) }
                }
            }
        }

        $items.Add([ordered]@{
                id         = $row.id
                title      = $row.title
                level      = [int]$row.level
                status     = $status
                commit     = $commit
                fixCommits = [string[]]$fix.ToArray()
            })
    }

    $block = [ordered]@{ items = $items.ToArray() }
    if ($truncated) { $block['truncated'] = $true }
    $block['updatedAt'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    return $block
}

Export-ModuleMember -Function Get-PlanTasks, ConvertTo-PlanTaskKey, ConvertTo-PlanTaskStatus

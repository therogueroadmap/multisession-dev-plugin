# DriverControl: canal de control del dashboard hacia el driver (Ola 2b).
#
# El servidor del dashboard escribe una orden en .driver-control.json (una sola a
# la vez) y el driver la lee en cada tick. Este modulo concentra todo lo que se
# puede probar sin lanzar el driver: leer y validar la orden, la matriz de validez
# por estado, la entrada de actions[], el plazo de la pausa y el bucle de pausa.
# El token del canal nunca se escribe en el status ni en los archivos de control.

# Sin -Force, como DriverInterrupt: el driver y los tests ya importan DriverStatus con -Force antes.
Import-Module (Join-Path $PSScriptRoot 'DriverStatus.psm1')

# Ultimo id devuelto por Read-DriverControl: si el borrado del archivo fallo, la
# misma orden no se procesa dos veces (PB-15).
$script:LastControlId = $null

# Hash (SHA256 hex) del ultimo texto rechazado sin id valido cuyo borrado fallo: el
# mismo texto no se reporta dos veces y no llena actions[] mientras el archivo persista.
$script:LastRejectedHash = $null

# Fallos de lectura consecutivos. Un bloqueo transitorio se reintenta en el tick
# siguiente; al llegar a este tope se rechaza para no dejar al servidor en 409 sin fin.
$script:ControlReadFailures = 0
$script:ControlReadFailureLimit = 3

$script:ControlActions = @('pause', 'resume', 'stop', 'set-params', 'answer', 'retry', 'open')
$script:ControlSetParamsKeys = @('model', 'levelEffort', 'closeEffort', 'maxTransientRetries', 'retryBackoffSeconds', 'livenessTimeoutMinutes', 'maxCostUsd', 'awaitDecisionMinutes')
$script:ControlEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
$script:ControlRetryModes = @('session', 'level')
$script:ControlOpenTargets = @('folder', 'log', 'terminal')
$script:ControlAnswerMaxLength = 4000
$script:ControlAnswerLogLength = 500

function Get-DriverControlToken {
    # 32 bytes aleatorios en hexadecimal minusculas (64 caracteres).
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Propiedad de un objeto JSON con nombre sensible a mayusculas; $null si falta.
function Get-ControlProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ceq $Name) { return $p }
    }
    return $null
}

# Entero estricto: int, long o un double sin parte decimal. Un booleano o un texto no cuentan.
function ConvertTo-ControlInt {
    param($Value, [int]$Min, [int]$Max)

    if ($Value -is [bool] -or $null -eq $Value) { return $null }
    $number = $null
    if ($Value -is [int] -or $Value -is [long]) { $number = [long]$Value }
    elseif ($Value -is [double]) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -ne [Math]::Floor($Value) -or [Math]::Abs($Value) -gt 1e9) { return $null }
        $number = [long]$Value
    }
    else { return $null }
    if ($number -lt $Min -or $number -gt $Max) { return $null }
    return [int]$number
}

# Valida y normaliza el valor de una clave de set-params. Devuelve @{ Ok; Value }.
function Test-ControlParamValue {
    param([string]$Key, $Value)

    $fail = @{ Ok = $false; Value = $null }
    switch -CaseSensitive ($Key) {
        'model' {
            if ($Value -is [string] -and ($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9.\-\[\]]{0,63}\z')) { return @{ Ok = $true; Value = [string]$Value } }
            return $fail
        }
        { $_ -ceq 'levelEffort' -or $_ -ceq 'closeEffort' } {
            if ($Value -is [string] -and ($script:ControlEfforts -ccontains $Value)) { return @{ Ok = $true; Value = [string]$Value } }
            return $fail
        }
        'maxTransientRetries' { $n = ConvertTo-ControlInt -Value $Value -Min 0 -Max 5 }
        'retryBackoffSeconds' { $n = ConvertTo-ControlInt -Value $Value -Min 10 -Max 3600 }
        'livenessTimeoutMinutes' { $n = ConvertTo-ControlInt -Value $Value -Min 5 -Max 240 }
        'awaitDecisionMinutes' { $n = ConvertTo-ControlInt -Value $Value -Min 0 -Max 1440 }
        'maxCostUsd' {
            if ($Value -is [bool] -or $null -eq $Value) { return $fail }
            if (($Value -is [int] -or $Value -is [long] -or $Value -is [double]) -and -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value) -and [double]$Value -ge 0 -and [double]$Value -le 1000) {
                return @{ Ok = $true; Value = [double]$Value }
            }
            return $fail
        }
        default { return $fail }
    }
    if ($null -eq $n) { return $fail }
    return @{ Ok = $true; Value = [int]$n }
}

# Valida el texto de una respuesta del usuario (2c). $null si es valido; si no, el
# motivo. El orden de las comprobaciones es parte del contrato: responde la primera que falla.
function Test-DriverAnswerText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'texto vacío' }
    if ($Text.Length -gt $script:ControlAnswerMaxLength) { return "texto demasiado largo (máx. $($script:ControlAnswerMaxLength))" }

    # Surrogate suelto: un high seguido de un low es un par valido y se salta.
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ([char]::IsHighSurrogate($c) -and ($i + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
            $i++
            continue
        }
        if ([char]::IsSurrogate($c)) { return 'carácter no permitido' }
    }
    foreach ($c in $Text.ToCharArray()) {
        if ([char]::IsControl($c) -and $c -ne "`t" -and $c -ne "`n" -and $c -ne "`r") { return 'carácter de control no permitido' }
    }
    foreach ($c in $Text.ToCharArray()) {
        $code = [int]$c
        if (($code -ge 0x202A -and $code -le 0x202E) -or ($code -ge 0x2066 -and $code -le 0x2069)) { return 'carácter no permitido' }
    }
    if ($Text.IndexOf('PLAN_STATUS', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'la respuesta no puede contener PLAN_STATUS' }
    return $null
}

# Fin de linea unico para los textos que viajan en un prompt.
function ConvertTo-ControlLf {
    param([string]$Text)

    return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

# Prompt de A1 (--resume): el prefijo sin caveman de Get-ResumePrompt y la respuesta del usuario.
function Get-DriverAnswerPrompt {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = @(
        'No actives el skill caveman ni ningún modo de compresión de salida en esta'
        'sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa'
        'normal.'
        ''
        "El usuario responde a tu bloqueo: $(ConvertTo-ControlLf -Text $Text). Continúa desde donde quedaste y termina con la línea PLAN_STATUS como siempre."
    )
    return ($lines -join "`n")
}

# A1 con sesion nueva: la decision va como seccion al final del prompt original.
function Add-DriverDecisionSection {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Text
    )

    return ($Prompt + "`n`n" + "Decisión del usuario: $(ConvertTo-ControlLf -Text $Text)")
}

# Acciones que admite el estado AWAITING (PC-5). Sin kill confirmado no hay sesion que reanudar ni reintentar.
function Get-DriverAwaitingAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('BLOCKED', 'FAILED', 'tope_costo')]
        [string]$Origin,
        [Parameter(Mandatory = $true)]
        [bool]$KillConfirmed
    )

    if (-not $KillConfirmed) { return [string[]]@('stop', 'set-params', 'open') }
    if ($Origin -ceq 'BLOCKED') { return [string[]]@('answer', 'retry', 'stop', 'set-params', 'open') }
    return [string[]]@('retry', 'stop', 'set-params', 'open')
}

# Bloque awaiting del status (C1), con las claves en el orden del contrato.
function New-DriverAwaitingBlock {
    param(
        [Parameter(Mandatory = $true)][datetime]$Since,
        [Nullable[datetime]]$Deadline = $null,
        [Parameter(Mandatory = $true)][string]$Origin,
        [AllowNull()]$Reason,
        [AllowNull()]$Cause,
        [Parameter(Mandatory = $true)][int]$Iter,
        [AllowNull()]$SessionId,
        [Parameter(Mandatory = $true)][bool]$Resumable,
        [Parameter(Mandatory = $true)][string[]]$Allowed
    )

    $deadlineText = $null
    if ($null -ne $Deadline) { $deadlineText = ([datetime]$Deadline).ToString('o') }
    return [ordered]@{
        since     = $Since.ToString('o')
        deadline  = $deadlineText
        origin    = $Origin
        reason    = $(if ($null -eq $Reason) { $null } else { [string]$Reason })
        cause     = $(if ($null -eq $Cause) { $null } else { [string]$Cause })
        iter      = $Iter
        sessionId = $(if ($null -eq $SessionId) { $null } else { [string]$SessionId })
        resumable = [bool]$Resumable
        allowed   = [string[]]@($Allowed)
    }
}

# Coste de esta corrida (PC-6): suma telemetry.costUsd de las entradas de history con
# iter > IterBase. Lo que falta o no es numerico cuenta 0. Nunca lanza.
function Get-DriverRunCost {
    param(
        [AllowNull()]$Status,
        [int]$IterBase = 0
    )

    $sum = [double]0
    try {
        $hist = Get-ControlProperty -Object $Status -Name 'history'
        if ($null -eq $hist -or $null -eq $hist.Value) { return $sum }
        foreach ($entry in @($hist.Value)) {
            $pIter = Get-ControlProperty -Object $entry -Name 'iter'
            if ($null -eq $pIter -or -not ($pIter.Value -is [int] -or $pIter.Value -is [long])) { continue }
            if ([long]$pIter.Value -le $IterBase) { continue }
            $tele = Get-ControlProperty -Object $entry -Name 'telemetry'
            if ($null -eq $tele) { continue }
            $pCost = Get-ControlProperty -Object $tele.Value -Name 'costUsd'
            if ($null -eq $pCost) { continue }
            $v = $pCost.Value
            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $sum += [double]$v }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        # Nunca lanza: devuelve lo acumulado.
    }
    return $sum
}

function New-ControlRejection {
    param($Id, $Action, $RequestedAt, [string]$Detail)

    [pscustomobject]@{ Id = $Id; Action = $Action; Params = $null; RequestedAt = $RequestedAt; Valid = $false; Detail = $Detail }
}

# Borra el archivo de control con 3 intentos de 50 ms. $true si quedo borrado.
function Remove-ControlFile {
    param([string]$Path)

    $deleted = $false
    for ($attempt = 1; $attempt -le 3 -and -not $deleted; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -ErrorAction Stop
            $deleted = $true
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 50 }
        }
    }
    if (-not $deleted) {
        Write-Warning "Read-DriverControl: no se pudo borrar '$Path'; se reintentara sin repetir la orden."
    }
    return $deleted
}

# Hash SHA256 en hexadecimal de los bytes UTF-8 del texto.
function Get-ControlTextHash {
    param([AllowNull()][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Rechazo sin id valido: no se repite el mismo texto mientras su borrado siga fallando.
function New-UnidentifiedControlRejection {
    param([string]$Text, [bool]$Deleted, $Action, $RequestedAt, [string]$Detail)

    $hash = Get-ControlTextHash -Text $Text
    if ($hash -ceq $script:LastRejectedHash) {
        if ($Deleted) { $script:LastRejectedHash = $null }
        return $null
    }
    # Si el borrado funciono no hay nada que deduplicar: un texto igual, enviado de nuevo, es otra orden.
    $script:LastRejectedHash = if ($Deleted) { $null } else { $hash }
    return (New-ControlRejection -Id $null -Action $Action -RequestedAt $RequestedAt -Detail $Detail)
}

# Lee la orden pendiente y la borra. $null si no hay archivo (o ya se devolvio ese id).
# Nunca lanza: lo que no se puede leer vuelve como orden con Valid = $false.
function Read-DriverControl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        # Sin archivo no queda nada pendiente: el estado de fallos y de rechazos sin id caduca.
        $script:ControlReadFailures = 0
        $script:LastRejectedHash = $null
        return $null
    }

    $id = $null
    $action = $null
    $requestedAt = $null
    try {
        # La lectura va en su propio try: un bloqueo transitorio (antivirus, indexador) no
        # es una orden ilegible. Se reintenta en el tick siguiente y solo tras
        # ControlReadFailureLimit fallos seguidos se rechaza, para no dejar al servidor en 409 sin fin.
        $text = $null
        try {
            $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            $script:ControlReadFailures++
            if ($script:ControlReadFailures -lt $script:ControlReadFailureLimit) { return $null }
            $script:ControlReadFailures = 0
            $readError = $_.Exception.Message
            Remove-ControlFile -Path $Path | Out-Null
            return (New-ControlRejection -Id $null -Action $null -RequestedAt $null -Detail "orden ilegible: $readError")
        }
        $script:ControlReadFailures = 0

        # El borrado va antes de validar: una orden rechazada tampoco debe repetirse.
        $deleted = Remove-ControlFile -Path $Path

        $obj = $null
        try {
            $obj = ConvertFrom-DriverJson -Text $text
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            $obj = $null
        }
        if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
            return (New-UnidentifiedControlRejection -Text $text -Deleted $deleted -Action $null -RequestedAt $null -Detail 'orden ilegible (JSON inválido)')
        }

        $pId = Get-ControlProperty -Object $obj -Name 'id'
        $pAction = Get-ControlProperty -Object $obj -Name 'action'
        $pParams = Get-ControlProperty -Object $obj -Name 'params'
        $pRequested = Get-ControlProperty -Object $obj -Name 'requestedAt'

        if ($null -ne $pAction -and $null -ne $pAction.Value) { $action = [string]$pAction.Value }
        if ($null -ne $pRequested -and $null -ne $pRequested.Value) {
            if ($pRequested.Value -is [datetime]) { $requestedAt = $pRequested.Value.ToString('o') }
            else { $requestedAt = [string]$pRequested.Value }
        }

        $idText = $null
        if ($null -ne $pId -and $pId.Value -is [string]) { $idText = $pId.Value }
        if ($null -eq $idText -or -not ($idText -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z')) {
            return (New-UnidentifiedControlRejection -Text $text -Deleted $deleted -Action $action -RequestedAt $requestedAt -Detail 'orden sin id')
        }
        $id = $idText

        # Orden ya devuelta cuyo borrado fallo: no se repite (PB-15).
        if ($id -ceq $script:LastControlId) { return $null }
        $script:LastControlId = $id

        if ($null -eq $action -or -not ($script:ControlActions -ccontains $action)) {
            return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "acción desconocida: $action")
        }
        $given = @()
        if ($null -ne $pParams -and $null -ne $pParams.Value) {
            if ($pParams.Value -isnot [pscustomobject]) {
                return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'parámetro inválido: params')
            }
            $given = @($pParams.Value.PSObject.Properties)
        }

        $params = [ordered]@{}
        if ($action -ceq 'set-params') {
            if ($given.Count -eq 0) {
                return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'set-params sin parámetros')
            }
            foreach ($p in $given) {
                if (-not ($script:ControlSetParamsKeys -ccontains $p.Name)) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "parámetro no permitido: $($p.Name)")
                }
                $checked = Test-ControlParamValue -Key $p.Name -Value $p.Value
                if (-not $checked.Ok) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "parámetro inválido: $($p.Name)")
                }
                $params[$p.Name] = $checked.Value
            }
        }
        elseif ($action -ceq 'answer' -or $action -ceq 'retry' -or $action -ceq 'open') {
            $schema = switch -CaseSensitive ($action) {
                'answer' { @('text') }
                'retry' { @('mode') }
                default { @('target', 'iter') }
            }
            foreach ($p in $given) {
                if (-not ($schema -ccontains $p.Name)) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "parámetro no permitido: $($p.Name)")
                }
            }
            $paramsObject = if ($null -ne $pParams) { $pParams.Value } else { $null }
            if ($action -ceq 'answer') {
                $pText = Get-ControlProperty -Object $paramsObject -Name 'text'
                if ($null -eq $pText -or $pText.Value -isnot [string]) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'parámetro inválido: text')
                }
                $why = Test-DriverAnswerText -Text $pText.Value
                if ($null -ne $why) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "parámetro inválido: text ($why)")
                }
                $params['text'] = $pText.Value
            }
            elseif ($action -ceq 'retry') {
                $pMode = Get-ControlProperty -Object $paramsObject -Name 'mode'
                if ($null -eq $pMode -or $pMode.Value -isnot [string] -or -not ($script:ControlRetryModes -ccontains $pMode.Value)) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'parámetro inválido: mode')
                }
                $params['mode'] = [string]$pMode.Value
            }
            else {
                $pTarget = Get-ControlProperty -Object $paramsObject -Name 'target'
                if ($null -eq $pTarget -or $pTarget.Value -isnot [string] -or -not ($script:ControlOpenTargets -ccontains $pTarget.Value)) {
                    return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'parámetro inválido: target')
                }
                $params['target'] = [string]$pTarget.Value
                $pIter = Get-ControlProperty -Object $paramsObject -Name 'iter'
                if ($null -ne $pIter) {
                    $iterValue = ConvertTo-ControlInt -Value $pIter.Value -Min 1 -Max 100000
                    if ($null -eq $iterValue) {
                        return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail 'parámetro inválido: iter')
                    }
                    $params['iter'] = [int]$iterValue
                }
            }
        }
        elseif ($given.Count -gt 0) {
            return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "parámetro no permitido: $($given[0].Name)")
        }

        return [pscustomobject]@{ Id = $id; Action = $action; Params = $params; RequestedAt = $requestedAt; Valid = $true; Detail = $null }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        return (New-ControlRejection -Id $id -Action $action -RequestedAt $requestedAt -Detail "orden ilegible: $($_.Exception.Message)")
    }
}

# Matriz de validez de C5. Estados: watch (sesion en curso), between (entre sesiones
# o backoff), paused, awaiting.
function Test-DriverControlAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [ValidateSet('watch', 'between', 'paused', 'awaiting')]
        [string]$State,
        [string]$AwaitingOrigin
    )

    switch -CaseSensitive ($Action) {
        'pause' { return ($State -eq 'watch' -or $State -eq 'between') }
        'resume' { return ($State -eq 'paused') }
        'stop' { return $true }
        'set-params' { return $true }
        'answer' { return ($State -eq 'awaiting' -and $AwaitingOrigin -ceq 'BLOCKED') }
        'retry' { return ($State -eq 'awaiting') }
        'open' { return $true }
        default { return $false }
    }
}

# Entrada de actions[] (C7). Order puede ser una orden valida o rechazada.
function New-DriverControlEntry {
    param(
        [AllowNull()]
        $Order,
        [Parameter(Mandatory = $true)]
        [ValidateSet('applied', 'rejected')]
        [string]$Result,
        [AllowNull()]
        [string]$Detail = $null,
        [AllowNull()]
        $Iter = $null
    )

    $id = $null
    $action = $null
    $requestedAt = $null
    $params = $null
    if ($null -ne $Order) {
        $id = $Order.Id
        $action = $Order.Action
        $requestedAt = $Order.RequestedAt
        $params = $Order.Params
    }
    if ($null -eq $params) { $params = [ordered]@{} }
    # PC-10: el texto de una respuesta no se guarda entero en actions[]: primeros caracteres y largo original.
    if ($action -ceq 'answer') {
        $pText = Get-ControlProperty -Object $params -Name 'text'
        if ($params -is [System.Collections.IDictionary] -and $params.Contains('text')) { $textValue = $params['text'] }
        elseif ($null -ne $pText) { $textValue = $pText.Value }
        else { $textValue = $null }
        if ($textValue -is [string]) {
            $shown = $textValue
            if ($textValue.Length -gt $script:ControlAnswerLogLength) {
                $cut = $script:ControlAnswerLogLength
                # Si el corte cae entre un high y un low surrogate, el par no se parte.
                if ([char]::IsHighSurrogate($textValue[$cut - 1])) { $cut-- }
                $shown = $textValue.Substring(0, $cut) + '…'
            }
            $params = [ordered]@{ text = $shown; textLength = $textValue.Length }
        }
    }
    if ($null -eq $Detail) { $Detail = '' }
    if ($null -ne $Iter) { $Iter = [int]$Iter }

    return [ordered]@{
        id          = $id
        action      = $action
        params      = $params
        origin      = 'dashboard'
        requestedAt = $requestedAt
        appliedAt   = (Get-Date).ToString('o')
        result      = $Result
        detail      = $Detail
        iter        = $Iter
    }
}

# Plazo de la pausa: $null si Minutes es 0 (sin plazo); si no, Since + Minutes.
function Get-DriverControlDeadline {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Since,
        [Parameter(Mandatory = $true)]
        [int]$Minutes
    )

    if ($Minutes -le 0) { return $null }
    return $Since.AddMinutes($Minutes)
}

# Bucle de pausa: publica State (PAUSED por omision, AWAITING en 2c) y espera en ticks.
# OnTick procesa las ordenes y devuelve una de ExitSignals ('resume' o 'stop' por
# omision) cuando toca salir; GetDeadline devuelve el plazo vigente
# ($null = sin plazo). Salidas: una de ExitSignals o 'expired' (llego el plazo). Sin
# plazo solo sale por una orden o por Ctrl+C (PipelineStoppedException); es el
# comportamiento pedido con awaitDecisionMinutes = 0. No publica RUNNING ni el
# final: lo hace quien llama.
function Wait-DriverPause {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        $Block,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [Parameter(Mandatory = $true)]
        [int]$HeartbeatSeconds,
        [Parameter(Mandatory = $true)]
        [scriptblock]$GetDeadline,
        [Parameter(Mandatory = $true)]
        [scriptblock]$OnTick,
        [int]$TickMilliseconds = 1000,
        [ValidateSet('PAUSED', 'AWAITING')]
        [string]$State = 'PAUSED',
        [string[]]$ExitSignals = @('resume', 'stop')
    )

    $published = $false
    try {
        Set-DriverStatusLiveState -StatusPath $StatusPath -State $State -Reason $Reason -Block $Block | Out-Null
        $published = $true
    }
    catch {
        Write-Warning ("Wait-DriverPause: no se pudo publicar {0}: {1}" -f $State, $_.Exception.Message)
    }

    $lastBeat = Get-Date
    while ($true) {
        Start-Sleep -Milliseconds $TickMilliseconds

        $signal = $null
        try {
            $signal = & $OnTick
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            Write-Warning ("Wait-DriverPause: OnTick fallo: {0}" -f $_.Exception.Message)
            $signal = $null
        }
        foreach ($item in @($signal)) {
            if ($item -is [string] -and ($ExitSignals -ccontains $item)) {
                return $item
            }
        }

        if (((Get-Date) - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastBeat = Get-Date
            try {
                Set-DriverStatusHeartbeat -StatusPath $StatusPath | Out-Null
            }
            catch {
                Write-Warning ("Wait-DriverPause: no se pudo escribir el heartbeat: {0}" -f $_.Exception.Message)
            }
            if (-not $published) {
                try {
                    Set-DriverStatusLiveState -StatusPath $StatusPath -State $State -Reason $Reason -Block $Block | Out-Null
                    $published = $true
                }
                catch {
                    Write-Warning ("Wait-DriverPause: no se pudo publicar {0}: {1}" -f $State, $_.Exception.Message)
                }
            }
        }

        $deadline = $null
        try {
            $deadline = & $GetDeadline
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            Write-Warning ("Wait-DriverPause: GetDeadline fallo: {0}" -f $_.Exception.Message)
        }
        if ($null -ne $deadline -and (Get-Date) -ge [datetime]$deadline) {
            return 'expired'
        }
    }
}

Export-ModuleMember -Function Get-DriverControlToken, Read-DriverControl, Test-DriverControlAllowed, New-DriverControlEntry, Get-DriverControlDeadline, Wait-DriverPause, Test-DriverAnswerText, Get-DriverAnswerPrompt, Add-DriverDecisionSection, Get-DriverAwaitingAllowed, New-DriverAwaitingBlock, Get-DriverRunCost

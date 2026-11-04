# Ola 1b (D1): reintento de sesiones que fallan por causas transitorias.
# Este modulo no lanza procesos: clasifica el fallo, calcula la espera, arma el
# prompt y los argumentos de claude del reintento y duerme entre intentos
# (Wait-RetryBackoff, la unica funcion con efecto). El driver decide cuando usarlo.
#
# Criterio (DR-1): solo se reintenta si la causa de la sesion es exit_no_cero o
# colgada (cualquier otra causa -> 'none').
#  - permanente: la autenticacion, el credito o el modelo estan mal y reintentar
#    no sirve: apiErrorStatus 401 o 403, "invalid api key", "authentication",
#    "/login", "not logged in", "credit balance", o "model" junto a "not found",
#    "invalid" o "not available". Se revisa el subtype y el texto del ultimo result
#    (este solo si la sesion termino con error y el ultimo result no fue success) y la cola del err.log, sin
#    distinguir mayusculas.
#  - transitorio: cualquier otro exit_no_cero o colgada. Las senales 429, 5xx,
#    overloaded, ECONNRESET y stream idle solo se informan en Match como dato; no
#    son condicion para reintentar.

# Patrones permanentes, en orden de prioridad (gana el primero que coincide).
# Los dos primeros miran ApiErrorStatus; el resto, el texto linea por linea.
$script:PermanentPatterns = @(
    [pscustomobject]@{ Name = 'http_401';          Status = 401;   Regex = $null }
    [pscustomobject]@{ Name = 'http_403';          Status = 403;   Regex = $null }
    [pscustomobject]@{ Name = 'invalid_api_key';   Status = $null; Regex = 'invalid api key' }
    [pscustomobject]@{ Name = 'authentication';    Status = $null; Regex = 'authentication' }
    [pscustomobject]@{ Name = 'login';             Status = $null; Regex = '/login' }
    [pscustomobject]@{ Name = 'not_logged_in';     Status = $null; Regex = 'not logged in' }
    [pscustomobject]@{ Name = 'credit_balance';    Status = $null; Regex = 'credit balance' }
    # 'model' y ('not found' | 'invalid' | 'not available') en la misma linea, en cualquier orden.
    [pscustomobject]@{ Name = 'model_unavailable'; Status = $null; Regex = '^(?=.*model)(?=.*(?:not found|invalid|not available))' }
)

# Senales informativas de un fallo transitorio, en orden (solo dato, no condicion).
$script:TransientSignals = @(
    [pscustomobject]@{ Name = 'http_429';   Regex = '\b429\b' }
    [pscustomobject]@{ Name = 'http_5xx';   Regex = $null }
    [pscustomobject]@{ Name = 'overloaded'; Regex = 'overloaded' }
    [pscustomobject]@{ Name = 'econnreset'; Regex = 'econnreset' }
    [pscustomobject]@{ Name = 'stream_idle'; Regex = 'stream idle' }
)

# Lineas a revisar: subtype, ResultText (solo si la sesion termino con error y el
# ultimo result no fue success, porque Telemetry.isError es agregado) y la cola del
# err.log, partidas por saltos de linea.
function Get-FailureTextLines {
    param($StreamSummary, $ErrLogTail)

    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $StreamSummary) {
        if (-not [string]::IsNullOrEmpty([string]$StreamSummary.Subtype)) {
            $lines.Add([string]$StreamSummary.Subtype)
        }
        if ($StreamSummary.Telemetry.isError -eq $true -and [string]$StreamSummary.Subtype -ne 'success' -and -not [string]::IsNullOrEmpty([string]$StreamSummary.ResultText)) {
            foreach ($l in ([string]$StreamSummary.ResultText -split "\r?\n")) { $lines.Add($l) }
        }
    }
    foreach ($l in @($ErrLogTail)) {
        if ($null -ne $l) { $lines.Add([string]$l) }
    }
    return , $lines
}

function Get-SessionFailureKind {
    param(
        [Parameter(Mandatory = $true)]
        $Outcome,
        [AllowNull()]
        $StreamSummary = $null,
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()]
        [string[]]$ErrLogTail = $null
    )

    $cause = $Outcome.Cause
    if ($cause -ne 'exit_no_cero' -and $cause -ne 'colgada') {
        return [pscustomobject]@{ Kind = 'none'; Match = $null }
    }

    $status = $null
    if ($null -ne $StreamSummary -and $null -ne $StreamSummary.ApiErrorStatus) {
        $parsed = 0
        if ([int]::TryParse(([string]$StreamSummary.ApiErrorStatus), [ref]$parsed)) { $status = $parsed }
    }
    $lines = Get-FailureTextLines -StreamSummary $StreamSummary -ErrLogTail $ErrLogTail

    foreach ($p in $script:PermanentPatterns) {
        if ($null -ne $p.Status) {
            if ($status -eq $p.Status) { return [pscustomobject]@{ Kind = 'permanent'; Match = $p.Name } }
            continue
        }
        foreach ($line in $lines) {
            if ($line -match ('(?i)' + $p.Regex)) {
                return [pscustomobject]@{ Kind = 'permanent'; Match = $p.Name }
            }
        }
    }

    foreach ($sig in $script:TransientSignals) {
        if ($sig.Name -eq 'http_5xx') {
            if ($null -ne $status -and $status -ge 500 -and $status -le 599) {
                return [pscustomobject]@{ Kind = 'transient'; Match = $sig.Name }
            }
            continue
        }
        if ($sig.Name -eq 'http_429' -and $status -eq 429) {
            return [pscustomobject]@{ Kind = 'transient'; Match = $sig.Name }
        }
        foreach ($line in $lines) {
            if ($line -match ('(?i)' + $sig.Regex)) {
                return [pscustomobject]@{ Kind = 'transient'; Match = $sig.Name }
            }
        }
    }

    return [pscustomobject]@{ Kind = 'transient'; Match = $null }
}

# Espera antes del intento k: si hay mas intentos que valores, se usa el ultimo.
function Get-RetryDelaySeconds {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$Attempt,
        [AllowNull()][AllowEmptyCollection()]
        [int[]]$Schedule = $null
    )

    $values = @($Schedule)
    if ($values.Count -eq 0) { return 0 }
    $index = [Math]::Min($Attempt - 1, $values.Count - 1)
    return [int]$values[$index]
}

# La sesion a reanudar ya no existe: exit distinto de 0 en menos de 60 s con
# "no conversation found" o "session not found" en el err.log o en el result.
function Test-ResumeSessionMissing {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,
        [AllowNull()]
        $StreamSummary = $null,
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()]
        [string[]]$ErrLogTail = $null
    )

    if ($ExitCode -eq 0 -or $DurationSeconds -ge 60) { return $false }

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($ErrLogTail)) { if ($null -ne $l) { $texts.Add([string]$l) } }
    if ($null -ne $StreamSummary -and $null -ne $StreamSummary.ResultText) {
        $texts.Add([string]$StreamSummary.ResultText)
    }
    foreach ($t in $texts) {
        if ($t -match '(?i)no conversation found|session not found') { return $true }
    }
    return $false
}

# Prompt del reintento con --resume: la linea de caveman de los prompts actuales,
# una linea en blanco y RESUME_PROMPT.
function Get-ResumePrompt {
    $lines = @(
        'No actives el skill caveman ni ningún modo de compresión de salida en esta',
        'sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa',
        'normal.',
        '',
        'La sesión anterior se interrumpió por un error transitorio. Continúa exactamente donde quedaste y termina con la línea PLAN_STATUS como siempre.'
    )
    return ($lines -join "`n")
}

# Copia de los argumentos de claude con otro prompt (el que sigue a -p) y otra
# bandera de sesion (--session-id o --resume, la que exista). No modifica la entrada.
function ConvertTo-RetryClaudeArgs {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [ValidateSet('--session-id', '--resume')]
        [string]$SessionFlag,
        [Parameter(Mandatory = $true)]
        [string]$SessionValue
    )

    $out = [string[]]@($Arguments)
    $pIndex = [Array]::IndexOf($out, '-p')
    if ($pIndex -lt 0 -or $pIndex + 1 -ge $out.Length) {
        throw "ConvertTo-RetryClaudeArgs: falta '-p' con su prompt en los argumentos."
    }

    $flagIndex = -1
    for ($i = 0; $i -lt $out.Length - 1; $i++) {
        if ($i -eq $pIndex + 1) { continue }
        if ($out[$i] -eq '--session-id' -or $out[$i] -eq '--resume') { $flagIndex = $i; break }
    }
    if ($flagIndex -lt 0) {
        throw "ConvertTo-RetryClaudeArgs: falta el par '--session-id' o '--resume' en los argumentos."
    }

    $out[$pIndex + 1] = $Prompt
    $out[$flagIndex] = $SessionFlag
    $out[$flagIndex + 1] = $SessionValue
    return $out
}

# Espera Seconds llamando a OnTick al menos una vez y despues de cada siesta. Cada
# siesta dura min(PollSeconds, lo que falta). Un fallo de OnTick se informa y la
# espera sigue (Ctrl+C se relanza). Termina siempre al cumplirse Seconds.
function Wait-RetryBackoff {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds,
        [Parameter(Mandatory = $true)]
        [int]$PollSeconds,
        [Parameter(Mandatory = $true)]
        [scriptblock]$OnTick
    )

    $poll = [Math]::Max(1, $PollSeconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            # La senal la usa el driver de 2b: si OnTick emite 'stop' o 'pause' la
            # espera se corta y se devuelve ese texto. Cualquier otra salida se descarta.
            $signal = & $OnTick
            foreach ($item in @($signal)) {
                if ($item -is [string] -and ($item -ceq 'stop' -or $item -ceq 'pause')) {
                    return $item
                }
            }
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            Write-Warning ("Wait-RetryBackoff: OnTick fallo: {0}" -f $_.Exception.Message)
        }

        $remaining = $Seconds - $sw.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        $nap = [Math]::Min([double]$poll, $remaining)
        Start-Sleep -Milliseconds ([int][Math]::Ceiling($nap * 1000))
    }
}

Export-ModuleMember -Function Get-SessionFailureKind, Get-RetryDelaySeconds, Test-ResumeSessionMissing, Get-ResumePrompt, ConvertTo-RetryClaudeArgs, Wait-RetryBackoff

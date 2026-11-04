function Test-PlanStatusLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Line
    )

    if ($null -eq $Line) { $Line = '' }

    if ($Line -match '^PLAN_STATUS: CONTINUE\s*$') {
        return [pscustomobject]@{ IsValid = $true; Status = 'CONTINUE'; Reason = $null }
    }
    if ($Line -match '^PLAN_STATUS: COMPLETE\s*$') {
        return [pscustomobject]@{ IsValid = $true; Status = 'COMPLETE'; Reason = $null }
    }
    if ($Line -match '^PLAN_STATUS: BLOCKED: (.+)$') {
        return [pscustomobject]@{ IsValid = $true; Status = 'BLOCKED'; Reason = $Matches[1].Trim() }
    }
    return [pscustomobject]@{ IsValid = $false; Status = $null; Reason = $null }
}

function Resolve-DriverDecision {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LastLine
    )

    if ($null -eq $LastLine) { $LastLine = '' }

    if ($ExitCode -ne 0) {
        return [pscustomobject]@{
            GlobalStatus   = 'FAILED'
            Reason         = "exit code $ExitCode"
            ShouldContinue = $false
        }
    }

    $parsed = Test-PlanStatusLine -Line $LastLine

    if (-not $parsed.IsValid) {
        return [pscustomobject]@{
            GlobalStatus   = 'FAILED'
            Reason         = 'no emitio marca PLAN_STATUS reconocible'
            ShouldContinue = $false
        }
    }

    switch ($parsed.Status) {
        'COMPLETE' {
            return [pscustomobject]@{ GlobalStatus = 'DONE'; Reason = $null; ShouldContinue = $false }
        }
        'BLOCKED' {
            return [pscustomobject]@{ GlobalStatus = 'BLOCKED'; Reason = $parsed.Reason; ShouldContinue = $false }
        }
        'CONTINUE' {
            return [pscustomobject]@{ GlobalStatus = 'RUNNING'; Reason = $null; ShouldContinue = $true }
        }
    }
}

# Ultima marca PLAN_STATUS valida dentro de un conjunto de lineas (la cola del
# log, ver Get-LogTail). Recorre de abajo hacia arriba: con varias marcas gana
# la ultima en orden de archivo, que es el estado final de la sesion.
function Find-LastPlanStatusLine {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    if ($null -ne $Lines) {
        for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
            $parsed = Test-PlanStatusLine -Line $Lines[$i]
            if ($parsed.IsValid) {
                return [pscustomobject]@{ IsValid = $true; Status = $parsed.Status; Reason = $parsed.Reason; Line = $Lines[$i] }
            }
        }
    }
    return [pscustomobject]@{ IsValid = $false; Status = $null; Reason = $null; Line = $null }
}

# M10: la ultima linea de la sesion es una pregunta en prosa (termina en "?"
# tras quitar cierres de markdown o puntuacion).
function Test-ProseQuestion {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $trimmed = $Line.TrimEnd([char[]]@(' ', "`t", '*', '_', '`', ')', ']', '"', "'"))
    return $trimmed.EndsWith('?')
}

# Decision post-sesion del driver: campos del evento de history, decision global
# y compuerta de cierre. Una sesion de modo "close" que declara DONE pero no
# dejo escrito el marcador de revision final no debe reportarse como DONE -- el
# handoff humano apuntaria a un archivo inexistente. Se degrada a BLOCKED con
# motivo explicito; una re-corrida del driver reintenta el cierre.
#
# Fase 2 (M3, M9, M10): con la evidencia de la sesion (avance del checkpoint,
# cola de err.log, racha de sesiones sin avance) clasifica la causa y aplica la
# politica: continuar, reintentar el mismo paso o parar. Con los defaults
# (Advanced = $null) el resultado es el de antes de la Fase 2.
function Resolve-SessionOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$TailLines,

        [Parameter(Mandatory = $true)]
        [ValidateSet('bootstrap', 'continue', 'close')]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [bool]$FinalReviewMarkerExists,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$MarkerRelativePath,

        # $true / $false si se pudo medir el avance; $null si no (sin plan).
        [AllowNull()]
        $Advanced = $null,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ErrTailLines,

        # Sesiones seguidas sin avance ANTERIORES a esta.
        [ValidateRange(0, 1000)]
        [int]$NoProgressStreak = 0,

        [ValidateRange(0, 10)]
        [int]$NoProgressRetries = 1
    )

    $found = Find-LastPlanStatusLine -Lines $TailLines
    $planStatusForEvent = if ($found.IsValid) { $found.Status } else { $null }
    $planStatusReasonForEvent = if ($found.IsValid -and $found.Status -eq 'BLOCKED') { $found.Reason } else { $null }
    $line = if ($found.IsValid) { $found.Line } else { '' }

    $decision = Resolve-DriverDecision -ExitCode $ExitCode -LastLine $line

    $gateApplied = $false
    if ($Mode -eq 'close' -and $decision.GlobalStatus -eq 'DONE' -and -not $FinalReviewMarkerExists) {
        $decision.GlobalStatus = 'BLOCKED'
        $decision.Reason = "la sesion de cierre declaro DONE pero no escribio el marcador de revision final ($MarkerRelativePath)"
        $decision.ShouldContinue = $false
        $gateApplied = $true
    }

    $cause = $null
    $countsAsNoProgress = $false
    $isRetry = $false
    $advancedKnown = $Advanced -is [bool]
    $attempt = $NoProgressStreak + 1
    $canRetry = $NoProgressStreak -lt $NoProgressRetries

    if ($ExitCode -ne 0) {
        $cause = 'exit_no_cero'
    }
    elseif ($found.IsValid) {
        if ($found.Status -eq 'CONTINUE' -and $advancedKnown -and -not $Advanced) {
            $cause = 'continue_sin_avance'
            $countsAsNoProgress = $true
            if ($canRetry) {
                $decision.GlobalStatus = 'RUNNING'
                $decision.ShouldContinue = $true
                $decision.Reason = "la sesion emitio CONTINUE sin avanzar el checkpoint; reintento $attempt de $NoProgressRetries"
                $isRetry = $true
            }
            else {
                $decision.GlobalStatus = 'BLOCKED'
                $decision.ShouldContinue = $false
                $decision.Reason = "la sesion emitio CONTINUE sin avanzar el checkpoint en $attempt sesiones seguidas; revisa el log de la ultima sesion"
            }
        }
    }
    elseif ($advancedKnown) {
        $lastLine = if ($null -ne $TailLines -and $TailLines.Count -gt 0) { $TailLines[$TailLines.Count - 1] } else { $null }
        $bgCut = @($ErrTailLines | Where-Object { $_ -and $_.Contains('Background tasks still running') }).Count -gt 0

        if ($Advanced) {
            $cause = 'sin_marca_con_avance'
            $decision.GlobalStatus = 'RUNNING'
            $decision.ShouldContinue = $true
            $decision.Reason = 'sin marca PLAN_STATUS, pero el checkpoint avanzo: se continua'
        }
        elseif ($bgCut) {
            $cause = 'truncada_background'
            $decision.GlobalStatus = 'FAILED'
            $decision.ShouldContinue = $false
            $decision.Reason = 'sesion truncada por el techo de background de claude -p (err.log: "Background tasks still running"); relanza con -BackgroundWaitCeilingMs 0'
        }
        elseif (Test-ProseQuestion -Line $lastLine) {
            $question = if ($lastLine.Length -gt 200) { $lastLine.Substring(0, 200) } else { $lastLine }
            $cause = 'pregunta_sin_marca'
            $decision.GlobalStatus = 'BLOCKED'
            $decision.ShouldContinue = $false
            $decision.Reason = "la sesion termino con una pregunta en vez de PLAN_STATUS: $question"
        }
        else {
            $cause = 'indeterminado'
            $countsAsNoProgress = $true
            if ($canRetry) {
                $decision.GlobalStatus = 'RUNNING'
                $decision.ShouldContinue = $true
                $decision.Reason = "sin marca PLAN_STATUS ni avance del checkpoint; reintento $attempt de $NoProgressRetries"
                $isRetry = $true
            }
            else {
                $decision.GlobalStatus = 'FAILED'
                $decision.ShouldContinue = $false
                $decision.Reason = "sin marca PLAN_STATUS ni avance del checkpoint en $attempt sesiones seguidas"
            }
        }
    }

    return [pscustomobject]@{
        PlanStatusForEvent       = $planStatusForEvent
        PlanStatusReasonForEvent = $planStatusReasonForEvent
        Decision                 = $decision
        CloseGateApplied         = $gateApplied
        Cause                    = $cause
        CountsAsNoProgress       = $countsAsNoProgress
        IsRetry                  = $isRetry
    }
}

Export-ModuleMember -Function Test-PlanStatusLine, Resolve-DriverDecision, Find-LastPlanStatusLine, Resolve-SessionOutcome, Test-ProseQuestion

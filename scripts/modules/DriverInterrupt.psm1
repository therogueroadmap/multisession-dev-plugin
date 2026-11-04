# DriverInterrupt: limpieza del driver ante Ctrl+C (B-4), aislada para poder
# probarla sin lanzar el driver completo.
#
# Invoke-DriverInterruptCleanup corre dentro de un finally del driver: cada paso
# va en su propio try/catch porque un fallo (p.ej. Write-DriverStatusFile lanza
# si el reemplazo atomico falla 3 veces) no debe impedir los pasos siguientes.
# Es idempotente: solo actua si el estado global sigue vivo (RUNNING, PAUSED o
# AWAITING), asi no pisa un estado final ya escrito. No toca el servidor del dashboard.
# Tambien lo usa el driver cuando falla por su cuenta: con -GlobalStatus FAILED
# deja FAILED (y la causa indicada) en lugar de STOPPED.

# Sin -Force: el driver y los tests ya importan DriverStatus con -Force antes.
Import-Module (Join-Path $PSScriptRoot 'DriverStatus.psm1')

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    # Nunca lanza: devuelve el metodo que funciono o 'failed' con el motivo.
    try {
        & taskkill /PID $ProcessId /T /F *> $null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Method = 'taskkill'; Message = $null }
        }
    }
    catch {
        # taskkill no disponible: se prueba Stop-Process.
    }

    try {
        # Solo el proceso principal: Stop-Process no mata el arbol.
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        return [pscustomobject]@{ Method = 'Stop-Process'; Message = $null }
    }
    catch {
        return [pscustomobject]@{ Method = 'failed'; Message = $_.Exception.Message }
    }
}

function Invoke-DriverInterruptCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [AllowNull()]
        [System.Diagnostics.Process]$Process,
        # Nombre de archivo sin ruta.
        [AllowNull()]
        [string]$LogFile,
        # Sin tipo [string]: $null no debe pasar a '' en lo persistido.
        [AllowNull()]
        $StreamFile,
        [AllowNull()]
        $ErrFile,
        [AllowNull()]
        [scriptblock]$OnSessionInterrupted,
        [scriptblock]$KillTree = { param($ProcessId) Stop-ProcessTree -ProcessId $ProcessId },
        [ValidateSet('STOPPED', 'FAILED')]
        [string]$GlobalStatus = 'STOPPED',
        [string]$Reason = 'Interrumpido con Ctrl+C',
        [string]$Cause = 'manual',
        # Espera tras KillTree antes de dar el proceso por vivo.
        [int]$ExitWaitMilliseconds = 10000
    )

    $result = [pscustomobject]@{ Action = 'skipped'; KilledPid = $null; EventAdded = $false; StopWritten = $false }

    # 1. Idempotencia: sin estado vivo (RUNNING, PAUSED o AWAITING) no se escribe ni se mata nada.
    $status = $null
    try {
        if (Test-Path -LiteralPath $StatusPath) {
            $status = Get-DriverStatus -StatusPath $StatusPath
        }
    }
    catch {
        $status = $null
    }
    if ($null -eq $status -or @('RUNNING', 'PAUSED', 'AWAITING') -notcontains $status.globalStatus) {
        return $result
    }

    $session = $status.currentSession
    $telemetry = $null

    # 2. Proceso: claude corre sin consola y no recibe el Ctrl+C; el finally lo
    # encuentra vivo y mata el arbol. KillTree solo si sigue vivo (pudo salir
    # por su cuenta).
    if ($null -ne $Process) {
        try {
            if (-not $Process.HasExited) {
                # KilledPid solo se fija si el proceso termino de verdad; si no, se avisa.
                $k = & $KillTree $Process.Id
                $exited = $Process.WaitForExit($ExitWaitMilliseconds)
                if ($exited) {
                    $result.KilledPid = $Process.Id
                }
                else {
                    $detalle = ''
                    if ($null -ne $k -and $null -ne $k.PSObject.Properties['Message'] -and -not [string]::IsNullOrEmpty($k.Message)) {
                        $detalle = " Motivo: $($k.Message)"
                    }
                    Write-Warning "El proceso $($Process.Id) sigue vivo tras intentar cerrarlo.$detalle"
                }
            }
        }
        catch {
            Write-Warning "No se pudo terminar el proceso: $($_.Exception.Message)"
        }

        # La telemetria se captura aunque el proceso ya haya salido.
        if ($null -ne $session) {
            try {
                if ($null -ne $OnSessionInterrupted) { $telemetry = & $OnSessionInterrupted }
            }
            catch {
                $telemetry = $null
            }
        }
    }

    # 3. Evento de la sesion interrumpida (Add-DriverStatusEvent deja
    # currentSession en nulo) o, sin sesion en curso, solo se limpia el marcador.
    try {
        if ($null -ne $session -and -not [string]::IsNullOrEmpty($LogFile)) {
            # Intento de la sesion en curso: entero >= 0 dentro de Int32 (pwsh 7 lee JSON como Int64); otro valor da 0.
            $attempt = 0
            if ($null -ne $session.PSObject.Properties['attempt'] -and ($session.attempt -is [int] -or $session.attempt -is [long]) -and $session.attempt -ge 0 -and $session.attempt -le [int]::MaxValue) {
                $attempt = [int]$session.attempt
            }
            Add-DriverStatusEvent -StatusPath $StatusPath -Iter ([int]$session.iter) -ExitCode -1 -PlanStatus $null -LogPath $LogFile -SessionId ([string]$session.sessionId) -PlanStatusReason $null -Cause $Cause -Telemetry $telemetry -StreamFile $StreamFile -ErrFile $ErrFile -Attempt $attempt | Out-Null
            $result.EventAdded = $true
        }
        else {
            Set-DriverStatusCurrentSession -StatusPath $StatusPath -Iter 0 -SessionId $null | Out-Null
        }
    }
    catch {
        Write-Warning "No se pudo registrar el evento de interrupcion: $($_.Exception.Message)"
    }

    # 4. Estado final.
    try {
        Set-DriverStatusFinal -StatusPath $StatusPath -GlobalStatus $GlobalStatus -Reason $Reason -Cause $Cause | Out-Null
        $result.StopWritten = $true
    }
    catch {
        Write-Warning "No se pudo escribir el estado ${GlobalStatus}: $($_.Exception.Message)"
    }
    $result.Action = 'stopped'

    return $result
}

Export-ModuleMember -Function Stop-ProcessTree, Invoke-DriverInterruptCleanup

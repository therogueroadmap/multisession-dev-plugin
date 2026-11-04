# HttpDashboard: lanza y detiene el servidor Python del dashboard (scripts/dashboard/server.py).
#
# El servidor es un proceso aparte que sobrevive al driver; publica su puerto y su pid en
# <carpeta del status>\.driver-dashboard.json cuando ya escucha.

# Stop-ProcessTree vive en DriverInterrupt.
Import-Module (Join-Path $PSScriptRoot 'DriverInterrupt.psm1')

function Stop-DriverDashboard {
    [CmdletBinding()]
    param(
        # No puede llamarse $Pid: $PID es una variable automatica de solo lectura y
        # PowerShell no distingue mayusculas.
        [Parameter(Mandatory = $true)]
        [Alias('Pid')]
        [int]$ProcessId
    )

    # Un proceso ya muerto no es error. No se borra .driver-dashboard.json: aqui no se
    # conoce su ruta; el siguiente Start-DriverDashboard lo borra.
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch {}
    Wait-Process -Id $ProcessId -Timeout 5 -ErrorAction SilentlyContinue
}

function Read-DriverDashboardInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $info = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $null }
    if ($null -eq $info -or $null -eq $info.port -or $null -eq $info.pid) { return $null }
    return $info
}

function Get-DriverDashboardServerLogs {
    param([Parameter(Mandatory = $true)][string]$StatusPath)

    # Un par de archivos por plan (el nombre deriva de la ruta del status): el reemplazo
    # de un servidor previo del mismo plan ya libero los suyos antes de reabrirlos.
    $hash = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($StatusPath.ToLowerInvariant()))
    ).Substring(0, 12).ToLowerInvariant()
    $tmp = [IO.Path]::GetTempPath()
    return [pscustomobject]@{
        Out = Join-Path $tmp "driver-dashboard-$hash.out.log"
        Err = Join-Path $tmp "driver-dashboard-$hash.err.log"
    }
}

function Start-DriverDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,

        [Parameter(Mandatory = $true)]
        [string]$LogsDir,

        [Parameter(Mandatory = $true)]
        [string]$AssetsDir,

        [int]$Port = 8787,

        [int]$IdleMinutes = 120,

        [string]$ServerScript,

        [string]$PythonCommand = 'python',

        [int]$StartupTimeoutSeconds = 10,

        # Ola 2b: token del canal de control (64 hex). Viaja por el entorno del hijo
        # (DRIVER_DASHBOARD_TOKEN), nunca por la linea de comandos. Sin token el canal
        # queda deshabilitado en el servidor.
        [string]$ControlToken
    )

    if (-not $ServerScript) {
        $pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ServerScript = Join-Path $pluginRoot 'scripts\dashboard\server.py'
    }

    $infoPath = Join-Path (Split-Path -Parent $StatusPath) '.driver-dashboard.json'

    # Reemplazo de un servidor previo del mismo plan: solo se mata si el pid esta vivo y
    # es un python con server.py en la linea de comandos (el pid puede haberse reciclado).
    $previous = Read-DriverDashboardInfo -Path $infoPath
    if ($previous) {
        $prevPid = [int]$previous.pid
        $proc = Get-Process -Id $prevPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -like 'python*') {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$prevPid" -ErrorAction SilentlyContinue
            if ($cim -and $cim.CommandLine -and $cim.CommandLine.Contains('server.py')) {
                Stop-DriverDashboard -ProcessId $prevPid
            }
        }
    }
    # Siempre se borra: si no, la espera de abajo leeria el archivo viejo.
    Remove-Item -LiteralPath $infoPath -Force -ErrorAction SilentlyContinue

    $python = Get-Command $PythonCommand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) {
        Write-Warning ("No se encontro '$PythonCommand' en el PATH: el driver sigue sin dashboard. " +
            "El alias de la Microsoft Store (WindowsApps\python.exe) no es un python real: instala Python o " +
            "desactiva el alias en Configuracion > Aplicaciones > Configuracion avanzada de aplicaciones > " +
            "Alias de ejecucion de aplicaciones.")
        return $null
    }

    if (-not (Test-Path -LiteralPath $ServerScript)) {
        Write-Warning "No existe el servidor del dashboard '$ServerScript': el driver sigue sin dashboard."
        return $null
    }

    # Una sola cadena con cada valor entre comillas: "Start-Process -ArgumentList @(...)"
    # une el array sin entrecomillar y parte las rutas con espacios (mismo problema que
    # motivo ProcessLauncher.psm1). La barra final de un directorio se quita porque una
    # '\' antes de la comilla de cierre la escapa.
    $statusArg = $StatusPath.TrimEnd('\')
    $logsArg = $LogsDir.TrimEnd('\')
    $assetsArg = $AssetsDir.TrimEnd('\')
    $argLine = "`"$ServerScript`" --status `"$statusArg`" --logs `"$logsArg`" --assets `"$assetsArg`" " +
        "--port $Port --idle-minutes $IdleMinutes --driver-pid $PID"

    # Redirigir a archivos (no tuberias): el servidor sobrevive al driver y escribir en
    # una tuberia cuyo lector murio lo tumbaria. Los logs van a %TEMP% y el cwd es la
    # carpeta de server.py: el servidor vive hasta IdleMinutes despues del driver y, con
    # archivos abiertos o el cwd dentro del plan, bloquearia borrar .driver-logs o
    # 'git worktree remove'.
    $serverLogs = Get-DriverDashboardServerLogs -StatusPath $StatusPath
    $outLog = $serverLogs.Out
    $errLog = $serverLogs.Err
    # Con $null la variable se quita del entorno del hijo: no hereda un token del driver.
    $serverEnv = @{ DRIVER_DASHBOARD_TOKEN = $(if ($ControlToken) { $ControlToken } else { $null }) }
    try {
        $launched = Start-Process -FilePath $python.Source -ArgumentList $argLine -WindowStyle Hidden -PassThru `
            -WorkingDirectory (Split-Path -Parent $ServerScript) -Environment $serverEnv `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -ErrorAction Stop
    }
    catch {
        Write-Warning ("No se pudo lanzar el servidor del dashboard: $($_.Exception.Message). " +
            "El driver sigue sin dashboard.")
        return $null
    }

    # Espera acotada por StartupTimeoutSeconds: si el servidor ni publica ni sale, se mata.
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ($true) {
        $info = Read-DriverDashboardInfo -Path $infoPath
        if ($info) {
            return [pscustomobject]@{ Port = [int]$info.port; Pid = [int]$info.pid }
        }
        if ($launched.HasExited) {
            $tail = ''
            if (Test-Path -LiteralPath $errLog) {
                $tail = (Get-Content -LiteralPath $errLog -Tail 5 -ErrorAction SilentlyContinue) -join ' | '
            }
            Write-Warning ("El servidor del dashboard salio con codigo $($launched.ExitCode) antes de publicar su puerto. " +
                "stderr: $tail. Si 'python' es el alias de la Microsoft Store (WindowsApps\python.exe), " +
                "instala Python o desactiva el alias.")
            return $null
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    }

    $null = Stop-ProcessTree -ProcessId $launched.Id
    Write-Warning "El servidor del dashboard no publico su puerto en $StartupTimeoutSeconds s: se detuvo y el driver sigue sin dashboard."
    return $null
}

Export-ModuleMember -Function Start-DriverDashboard, Stop-DriverDashboard

# Levanta el servidor real del dashboard (scripts/dashboard/server.py) sobre un status y un stream de
# fixture, para los tests de contrato y para Playwright. Devuelve Port, Pid, Url, StatusPath, LogsDir y
# BusyPort. Con -Wait se queda vivo hasta que muera el servidor.
param(
    [Parameter(Mandatory)][ValidateSet('RUNNING', 'BLOCKED', 'FAILED', 'STOPPED', 'DONE', 'LEGACY')][string]$State,
    [Parameter(Mandatory)][string]$Root,
    [switch]$Rebase,     # desplaza las fechas para que la ultima actividad sea "hace 40 s"
    [switch]$Wait        # se queda vivo (para Playwright): el servidor ve vivo a --driver-pid
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module "$repo\scripts\modules\HttpDashboard.psm1" -Force

$Root = [IO.Path]::GetFullPath($Root)
$logsDir = Join-Path $Root 'plans\.driver-logs'
$statusPath = Join-Path $Root 'plans\.driver-status.json'
if (Test-Path -LiteralPath $logsDir) { Remove-Item -LiteralPath $logsDir -Recurse -Force }
$null = New-Item -ItemType Directory -Path $logsDir -Force

$fixtures = Join-Path $repo 'tests\fixtures'
$streamPath = Join-Path $logsDir 'session-3-20261015-154320.stream.jsonl'
Copy-Item -LiteralPath (Join-Path $fixtures "dashboard\status-$($State.ToLowerInvariant()).json") -Destination $statusPath -Force
Copy-Item -LiteralPath (Join-Path $fixtures 'stream-dashboard-ola1.jsonl') -Destination $streamPath -Force
Copy-Item -LiteralPath (Join-Path $fixtures 'dashboard\session-3-20261015-154320.log') -Destination $logsDir -Force
Copy-Item -LiteralPath (Join-Path $fixtures 'dashboard\session-3-20261015-154320.err.log') -Destination $logsDir -Force

# Solo en DONE: la revision final que el servidor resuelve por planFile (.final-review-<plan sin .md>.md junto al status),
# con 2 hallazgos MINOR, para que el panel Pendiente de integrar muestre "Lista para integrar".
if ($State -eq 'DONE') {
    $planFile = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).planFile
    $reviewName = '.final-review-' + [IO.Path]::GetFileNameWithoutExtension($planFile) + '.md'
    $review = @(
        '# Revision final (demo)', '',
        '**Veredicto:** Aprobada con observaciones menores', '',
        '| Severidad | Ubicacion | Descripcion |',
        '|---|---|---|',
        '| MINOR | demo/a.ps1 | Nombre poco claro |',
        '| MINOR | demo/b.ps1 | Comentario desactualizado |'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $statusPath) $reviewName), $review, [Text.UTF8Encoding]::new($false))
}

if ($Rebase) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $anchor = [DateTimeOffset]::Parse('2026-10-15T20:21:00Z', $inv, [Globalization.DateTimeStyles]::AssumeUniversal)
    $delta = ([DateTimeOffset]::UtcNow.AddSeconds(-40)) - $anchor

    $shiftIso = {
        param($m)
        $text = $m.Value
        if ($text.EndsWith('Z')) {
            $dt = [DateTimeOffset]::Parse($text, $inv, [Globalization.DateTimeStyles]::AssumeUniversal)
            return ($dt + $delta).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $inv)
        }
        return ([DateTimeOffset]::Parse($text, $inv) + $delta).ToString('o', $inv)
    }

    $stream = [IO.File]::ReadAllText($streamPath)
    $stream = [regex]::Replace($stream, '"timestamp":"(\d{4}-\d\d-\d\dT[0-9:.]+(?:Z|[+-]\d\d:\d\d))"', {
        param($m)
        $iso = [regex]::Match($m.Value, '\d{4}-\d\d-\d\dT[0-9:.]+(?:Z|[+-]\d\d:\d\d)')
        '"timestamp":"' + (& $shiftIso $iso) + '"'
    })
    $stream = [regex]::Replace($stream, '"end_time":(\d{13})', {
        param($m)
        '"end_time":' + ([int64]$m.Groups[1].Value + [int64]$delta.TotalMilliseconds)
    })
    $stream = [regex]::Replace($stream, '"resetsAt":(\d{10})', {
        param($m)
        '"resetsAt":' + ([int64]$m.Groups[1].Value + [int64]$delta.TotalSeconds)
    })
    [IO.File]::WriteAllText($streamPath, $stream, $utf8)

    $status = [IO.File]::ReadAllText($statusPath)
    $status = [regex]::Replace($status, '\d{4}-\d\d-\d\dT[0-9:.]+(?:Z|[+-]\d\d:\d\d)', $shiftIso)
    [IO.File]::WriteAllText($statusPath, $status, $utf8)
}

# Se ocupa un puerto para forzar el respaldo 20000-29999 del servidor (como en un equipo con 8787 tomado).
$busy = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$busy.Start()
try {
    $busyPort = $busy.LocalEndpoint.Port
    $idle = if ($Wait) { 30 } else { 2 }
    $h = Start-DriverDashboard -StatusPath $statusPath -LogsDir $logsDir -AssetsDir "$repo\assets" `
        -Port $busyPort -IdleMinutes $idle
}
finally { $busy.Stop() }
if ($null -eq $h) { throw 'el servidor del dashboard no arranco (revisa python en el PATH y los warnings anteriores)' }

$result = [pscustomobject]@{
    Port       = $h.Port
    Pid        = $h.Pid
    Url        = "http://127.0.0.1:$($h.Port)/"
    StatusPath = $statusPath
    LogsDir    = $logsDir
    BusyPort   = $busyPort
}
$result

if ($Wait) {
    Write-Host "Dashboard demo ($State): $($result.Url)"
    try {
        while (Get-Process -Id $h.Pid -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
    }
    finally { Stop-DriverDashboard -ProcessId $h.Pid }
}

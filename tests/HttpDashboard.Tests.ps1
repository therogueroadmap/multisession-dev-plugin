$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\HttpDashboard.psm1') -Force

$fakeServer = Join-Path $moduleRoot 'tests\fixtures\fake-dashboard\server.py'
$noPython = -not (Get-Command python -ErrorAction SilentlyContinue)
$script:statusPaths = New-Object System.Collections.Generic.List[string]

# Crea una carpeta de plan propia (con espacio en el nombre) con assets y .driver-logs.
function New-PlanDir {
    $dir = Join-Path $TestDrive ('plans dir ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # Los logs del servidor van a %TEMP% (fuera de TestDrive): se anotan para borrarlos al final.
    $script:statusPaths.Add((Join-Path $dir '.driver-status.json'))
    New-Item -ItemType Directory -Path (Join-Path $dir 'assets') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir '.driver-logs') -Force | Out-Null
    return [pscustomobject]@{
        Dir    = $dir
        Status = Join-Path $dir '.driver-status.json'
        Logs   = Join-Path $dir '.driver-logs'
        Assets = Join-Path $dir 'assets'
        Info   = Join-Path $dir '.driver-dashboard.json'
    }
}

Describe 'Start-DriverDashboard / Stop-DriverDashboard' {
    AfterAll {
        $module = Get-Module HttpDashboard
        foreach ($s in $script:statusPaths) {
            $logs = & $module { Get-DriverDashboardServerLogs -StatusPath $args[0] } $s
            Remove-Item -LiteralPath $logs.Out, $logs.Err -Force -ErrorAction SilentlyContinue
        }
    }
    It 'lanza el servidor y devuelve Port y Pid de .driver-dashboard.json' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        try {
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
                -Port 8787 -IdleMinutes 120 -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            $h.Port | Should Be 8787
            (Get-Process -Id $h.Pid -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty

            $a = Get-Content -LiteralPath (Join-Path $p.Dir 'fake-server-args.json') -Raw | ConvertFrom-Json
            $a.status | Should Be $p.Status
            $a.logs | Should Be $p.Logs
            $a.assets | Should Be $p.Assets
            $a.port | Should Be 8787
            $a.idle_minutes | Should Be 120
            $a.driver_pid | Should Be $PID
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'el servidor no bloquea la carpeta del plan: cwd en la carpeta de server.py y logs fuera de .driver-logs' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        try {
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            $a = Get-Content -LiteralPath (Join-Path $p.Dir 'fake-server-args.json') -Raw | ConvertFrom-Json
            $a.cwd.TrimEnd('\') | Should Be (Split-Path -Parent $fakeServer)
            # Con el servidor vivo, .driver-logs se puede borrar (git worktree remove no choca).
            { Remove-Item -LiteralPath $p.Logs -Recurse -Force -ErrorAction Stop } | Should Not Throw
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'sin python avisa y devuelve null' {
        $p = New-PlanDir
        $r = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
            -ServerScript $fakeServer -PythonCommand 'python-inexistente-xyz' `
            -WarningVariable w -WarningAction SilentlyContinue
        $r | Should BeNullOrEmpty
        ($w -join ' ') | Should Match 'python'
    }

    It 'sin server.py avisa y devuelve null' -Skip:$noPython {
        $p = New-PlanDir
        $missing = Join-Path $p.Dir 'no-existe\server.py'
        $r = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
            -ServerScript $missing -WarningVariable w -WarningAction SilentlyContinue
        $r | Should BeNullOrEmpty
        ($w -join ' ').Contains($missing) | Should Be $true
    }

    It 'reemplaza un servidor previo del mismo plan' -Skip:$noPython {
        $p = New-PlanDir
        $h1 = $null
        $h2 = $null
        try {
            $h1 = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h1 | Should Not BeNullOrEmpty
            $h2 = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h2 | Should Not BeNullOrEmpty
            (Get-Process -Id $h1.Pid -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
            (Get-Process -Id $h2.Pid -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        }
        finally {
            if ($h1) { Stop-Process -Id $h1.Pid -Force -ErrorAction SilentlyContinue }
            if ($h2) { Stop-Process -Id $h2.Pid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'no mata un pid vivo que no es server.py' -Skip:$noPython {
        $p = New-PlanDir
        $other = $null
        $h = $null
        try {
            $other = Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile -Command Start-Sleep 60' -PassThru -WindowStyle Hidden
            Set-Content -LiteralPath $p.Info -Value (@{ port = 1; pid = $other.Id } | ConvertTo-Json) -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            (Get-Process -Id $other.Id -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
            if ($other) { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'ignora un .driver-dashboard.json con pid muerto' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        try {
            Set-Content -LiteralPath $p.Info -Value (@{ port = 1; pid = 999999 } | ConvertTo-Json) -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            $h.Pid | Should Not Be 999999
            (Get-Process -Id $h.Pid -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'si el servidor no publica a tiempo, lo mata y devuelve null' -Skip:$noPython {
        $p = New-PlanDir
        try {
            $env:FAKE_DASHBOARD_MODE = 'silent'
            $r = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
                -ServerScript $fakeServer -StartupTimeoutSeconds 2 `
                -WarningVariable w -WarningAction SilentlyContinue
            $r | Should BeNullOrEmpty
            ($w -join ' ') | Should Not BeNullOrEmpty
            Start-Sleep -Milliseconds 500
            $left = @(Get-CimInstance Win32_Process |
                Where-Object { $_.Name -like 'python*' -and $_.CommandLine -and $_.CommandLine.Contains($p.Status) })
            $left.Count | Should Be 0
        }
        finally {
            Remove-Item Env:\FAKE_DASHBOARD_MODE -ErrorAction SilentlyContinue
            Get-CimInstance Win32_Process |
                Where-Object { $_.Name -like 'python*' -and $_.CommandLine -and $_.CommandLine.Contains($p.Status) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'si el servidor sale con error, devuelve null y el aviso trae su stderr' -Skip:$noPython {
        $p = New-PlanDir
        try {
            $env:FAKE_DASHBOARD_MODE = 'crash'
            $r = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
                -ServerScript $fakeServer -WarningVariable w -WarningAction SilentlyContinue
            $r | Should BeNullOrEmpty
            ($w -join ' ') | Should Match 'fallo simulado del servidor'
        }
        finally {
            Remove-Item Env:\FAKE_DASHBOARD_MODE -ErrorAction SilentlyContinue
        }
    }

    It 'Stop-DriverDashboard detiene el proceso y tolera un pid ya muerto' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        try {
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            Stop-DriverDashboard -ProcessId $h.Pid
            (Get-Process -Id $h.Pid -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
            { Stop-DriverDashboard -ProcessId $h.Pid } | Should Not Throw
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'arranca el server.py real sin -ServerScript y responde 200 en /status.json' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        $busy = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $busy.Start()
        try {
            $busyPort = $busy.LocalEndpoint.Port
            @{ globalStatus = 'RUNNING'; history = @() } | ConvertTo-Json | Set-Content -LiteralPath $p.Status -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
                -Port $busyPort -IdleMinutes 5
            $h | Should Not BeNullOrEmpty
            if ($h.Port -eq $busyPort -or $h.Port -lt 20000 -or $h.Port -gt 29999) {
                throw "el puerto ocupado $busyPort no bloqueo el bind: el servidor publico en $($h.Port). server.py usa SO_EXCLUSIVEADDRUSE en server.py:78-86; revisa ese bind."
            }
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($h.Port)/status.json" -NoProxy -SkipHttpErrorCheck -TimeoutSec 5
            $r.StatusCode | Should Be 200
            ($r.Content | ConvertFrom-Json).globalStatus | Should Be 'RUNNING'
        }
        finally {
            if ($h) { Stop-DriverDashboard -ProcessId $h.Pid }
            $busy.Stop()
        }
    }

    It '2b: con -ControlToken el canal queda habilitado por el entorno, sin el token en la linea de comandos ni en .driver-dashboard.json' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        $tok = 'ab' * 32
        try {
            @{ globalStatus = 'RUNNING'; history = @() } | ConvertTo-Json | Set-Content -LiteralPath $p.Status -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -IdleMinutes 5 -ControlToken $tok
            $h | Should Not BeNullOrEmpty
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($h.Port)/control/pause" -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 5 `
                -ContentType 'application/json' -Body '{}' -Headers @{ Origin = "http://127.0.0.1:$($h.Port)"; 'X-Control-Token' = $tok }
            $r.StatusCode | Should Be 202
            $order = Get-Content -LiteralPath (Join-Path $p.Dir '.driver-control.json') -Raw | ConvertFrom-Json
            $order.action | Should Be 'pause'

            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($h.Pid)"
            $cim.CommandLine.Contains($tok) | Should Be $false
            (Get-Content -LiteralPath $p.Info -Raw).Contains($tok) | Should Be $false
        }
        finally {
            if ($h) { Stop-DriverDashboard -ProcessId $h.Pid }
        }
    }

    It '2b: sin -ControlToken el canal queda deshabilitado aunque el driver tenga DRIVER_DASHBOARD_TOKEN' -Skip:$noPython {
        $p = New-PlanDir
        $h = $null
        $tok = 'cd' * 32
        $saved = $env:DRIVER_DASHBOARD_TOKEN
        try {
            $env:DRIVER_DASHBOARD_TOKEN = $tok
            @{ globalStatus = 'RUNNING'; history = @() } | ConvertTo-Json | Set-Content -LiteralPath $p.Status -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -IdleMinutes 5
            $h | Should Not BeNullOrEmpty
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($h.Port)/control/pause" -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 5 `
                -ContentType 'application/json' -Body '{}' -Headers @{ Origin = "http://127.0.0.1:$($h.Port)"; 'X-Control-Token' = $tok }
            $r.StatusCode | Should Be 403
            ($r.Content | ConvertFrom-Json).error | Should Be 'control deshabilitado'
            (Test-Path -LiteralPath (Join-Path $p.Dir '.driver-control.json')) | Should Be $false
        }
        finally {
            $env:DRIVER_DASHBOARD_TOKEN = $saved
            if ($h) { Stop-DriverDashboard -ProcessId $h.Pid }
        }
    }

    It 'no mata un python vivo cuya linea de comandos no contiene server.py' -Skip:$noPython {
        $p = New-PlanDir
        $other = $null
        $h = $null
        try {
            $other = Start-Process -FilePath (Get-Command python).Source -ArgumentList '-c "import time; time.sleep(60)"' -PassThru -WindowStyle Hidden
            Set-Content -LiteralPath $p.Info -Value (@{ port = 1; pid = $other.Id } | ConvertTo-Json) -Encoding utf8
            $h = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets -ServerScript $fakeServer
            $h | Should Not BeNullOrEmpty
            (Get-Process -Id $other.Id -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        }
        finally {
            if ($h) { Stop-Process -Id $h.Pid -Force -ErrorAction SilentlyContinue }
            if ($other) { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'si el servidor no publica a tiempo, mata tambien sus hijos' -Skip:$noPython {
        $p = New-PlanDir
        $childPid = $null
        try {
            $env:FAKE_DASHBOARD_MODE = 'silent_child'
            $r = Start-DriverDashboard -StatusPath $p.Status -LogsDir $p.Logs -AssetsDir $p.Assets `
                -ServerScript $fakeServer -StartupTimeoutSeconds 3 `
                -WarningVariable w -WarningAction SilentlyContinue
            $r | Should BeNullOrEmpty
            $pidFile = Join-Path $p.Dir 'fake-child.pid'
            if (-not (Test-Path -LiteralPath $pidFile)) {
                throw "el servidor falso no escribio ${pidFile}: el modo silent_child no lanzo su hijo."
            }
            $childPid = [int](Get-Content -LiteralPath $pidFile -Raw)
            $stop = [DateTime]::UtcNow.AddSeconds(5)
            while ((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $stop) {
                Start-Sleep -Milliseconds 200
            }
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        }
        finally {
            Remove-Item Env:\FAKE_DASHBOARD_MODE -ErrorAction SilentlyContinue
            if ($childPid) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
            Get-CimInstance Win32_Process |
                Where-Object { $_.Name -like 'python*' -and $_.CommandLine -and $_.CommandLine.Contains($p.Status) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }
}

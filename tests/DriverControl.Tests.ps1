$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverStatus.psm1') -Force
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverControl.psm1') -Force

Describe 'DriverControl' {
    $validId = '11111111-1111-4111-8111-111111111111'

    function New-ControlDir {
        param([string]$Name)
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    function Write-ControlFile {
        param([string]$Path, $Object)
        $Object | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function Reset-LastControlId {
        & (Get-Module DriverControl) { $script:LastControlId = $null; $script:LastRejectedHash = $null; $script:ControlReadFailures = 0 }
    }

    It 'Read-DriverControl sin archivo devuelve null' {
        $dir = New-ControlDir 'sin-archivo'
        Reset-LastControlId
        Read-DriverControl -Path (Join-Path $dir '.driver-control.json') | Should BeNullOrEmpty
    }

    It 'Read-DriverControl lee una orden valida, la borra y conserva requestedAt como texto' {
        $dir = New-ControlDir 'valida'
        $path = Join-Path $dir '.driver-control.json'
        Write-ControlFile $path @{ id = $validId; action = 'pause'; params = @{}; requestedAt = '2026-10-27T20:00:00.000000+00:00' }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Id | Should Be $validId
        $o.Action | Should Be 'pause'
        @($o.Params.Keys).Count | Should Be 0
        ($o.RequestedAt -is [string]) | Should Be $true
        $o.RequestedAt | Should Match '2026-10-27T20:00:00'
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'Read-DriverControl con JSON invalido rechaza y borra el archivo' {
        $dir = New-ControlDir 'json-invalido'
        $path = Join-Path $dir '.driver-control.json'
        Set-Content -LiteralPath $path -Value '{no json' -Encoding utf8
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $false
        $o.Detail | Should Be 'orden ilegible (JSON inválido)'
        $o.Id | Should BeNullOrEmpty
        Test-Path -LiteralPath $path | Should Be $false

        # Los sub-casos (a) y (b) bloquean el archivo de verdad (FileStream) en vez de usar Mock:
        # en Pester 3.4.0 un Mock -ModuleName de Get-Content o Remove-Item sobrevive al It y
        # rompe los tests siguientes. El bloqueo se libera en finally.
        $reset = { $script:LastControlId = $null; $script:LastRejectedHash = $null; $script:ControlReadFailures = 0 }

        # (b) Borrado que falla de forma persistente (archivo abierto para lectura compartida):
        # el mismo texto rechazado se reporta una vez y despues vuelve null.
        $pathB = Join-Path (New-ControlDir 'json-invalido-borrado-falla') '.driver-control.json'
        Set-Content -LiteralPath $pathB -Value '{no json' -Encoding utf8
        & (Get-Module DriverControl) $reset
        $lockB = [System.IO.File]::Open($pathB, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $first = Read-DriverControl -Path $pathB 3>$null
            $first.Valid | Should Be $false
            $first.Detail | Should Be 'orden ilegible (JSON inválido)'
            Test-Path -LiteralPath $pathB | Should Be $true
            Read-DriverControl -Path $pathB 3>$null | Should BeNullOrEmpty
            Read-DriverControl -Path $pathB 3>$null | Should BeNullOrEmpty
        }
        finally { $lockB.Dispose() }

        # (a) Lectura bloqueada (acceso exclusivo): dos fallos devuelven null (el siguiente
        # tick reintenta) y el tercero rechaza.
        $pathA = Join-Path (New-ControlDir 'lectura-bloqueada') '.driver-control.json'
        Set-Content -LiteralPath $pathA -Value '{"id":"x"}' -Encoding utf8
        & (Get-Module DriverControl) $reset
        $lockA = [System.IO.File]::Open($pathA, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            Read-DriverControl -Path $pathA 3>$null | Should BeNullOrEmpty
            Read-DriverControl -Path $pathA 3>$null | Should BeNullOrEmpty
            $third = Read-DriverControl -Path $pathA 3>$null
            $third.Valid | Should Be $false
            $third.Detail | Should Match '^orden ilegible: '
            $third.Id | Should BeNullOrEmpty
            # El contador se reinicio tras el rechazo: el siguiente fallo vuelve a ser null.
            Read-DriverControl -Path $pathA 3>$null | Should BeNullOrEmpty
            & (Get-Module DriverControl) { $script:ControlReadFailures } | Should Be 1
        }
        finally { $lockA.Dispose() }
        # Con el bloqueo liberado la lectura funciona y el contador vuelve a 0.
        $after = Read-DriverControl -Path $pathA 3>$null
        $after.Valid | Should Be $false
        $after.Detail | Should Be 'orden sin id'
        & (Get-Module DriverControl) { $script:ControlReadFailures } | Should Be 0
    }

    It '1a-5: Read-DriverControl con la rama anterior a 7.5 (Mock) lee la misma orden' {
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $false }
        $dir = New-ControlDir 'valida-rama-vieja'
        $path = Join-Path $dir '.driver-control.json'
        Write-ControlFile $path @{ id = $validId; action = 'pause'; params = @{}; requestedAt = '2026-10-27T20:00:00.000000+00:00' }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Id | Should Be $validId
        $o.Action | Should Be 'pause'
        ($o.RequestedAt -is [string]) | Should Be $true
        # Con esta rama el texto sale en hora local; el instante es el mismo.
        ([datetimeoffset]::Parse($o.RequestedAt)).UtcDateTime | Should Be ([datetime]::SpecifyKind([datetime]'2026-10-27T20:00:00', [System.DateTimeKind]::Utc))
        Test-Path -LiteralPath $path | Should Be $false
        Assert-MockCalled -ModuleName DriverStatus Test-JsonDateKindSupport
    }

    It '1a-5: Read-DriverControl con JSON invalido en la rama anterior a 7.5 sigue rechazando' {
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $false }
        $dir = New-ControlDir 'json-invalido-rama-vieja'
        $path = Join-Path $dir '.driver-control.json'
        Set-Content -LiteralPath $path -Value '{no json' -Encoding utf8
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $false
        $o.Detail | Should Be 'orden ilegible (JSON inválido)'
        $o.Id | Should BeNullOrEmpty
        Test-Path -LiteralPath $path | Should Be $false
    }

    It '1a-5: una sola copia de la lectura de fechas en los modulos' {
        $modDir = Join-Path $moduleRoot 'scripts\modules'
        $files = @(Get-ChildItem -LiteralPath $modDir -Filter '*.psm1')
        $defs = @($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'function ConvertFrom-DriverJson' })
        $defs.Count | Should Be 1
        $defs[0].Name | Should Be 'DriverStatus.psm1'
        $dateKind = @($files | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '-DateKind' })
        $dateKind.Count | Should Be 1
        $dateKind[0].Name | Should Be 'DriverStatus.psm1'
        $control = Get-Content -LiteralPath (Join-Path $modDir 'DriverControl.psm1') -Raw
        $control.Contains('ConvertFrom-DriverJson -Text $text') | Should Be $true
        $control.Contains('DateKind') | Should Be $false
        $control.Contains('PSVersionTable') | Should Be $false
    }

    It 'Read-DriverControl rechaza acciones desconocidas y parametros fuera del esquema' {
        $dir = New-ControlDir 'rechazos'
        $path = Join-Path $dir '.driver-control.json'
        $cases = @(
            @{ Order = @{ id = $validId; action = 'x'; params = @{} }; Detail = 'acción desconocida: x' }
            @{ Order = @{ id = $validId; action = 'PAUSE'; params = @{} }; Detail = 'acción desconocida: PAUSE' }
            @{ Order = @{ id = 'ABC'; action = 'pause'; params = @{} }; Detail = 'orden sin id' }
            @{ Order = @{ id = "$validId`n"; action = 'pause'; params = @{} }; Detail = 'orden sin id' }
            @{ Order = @{ id = $validId; action = 'pause'; params = @{ a = 1 } }; Detail = 'parámetro no permitido: a' }
            @{ Order = @{ id = $validId; action = 'set-params'; params = @{} }; Detail = 'set-params sin parámetros' }
            @{ Order = @{ id = $validId; action = 'set-params'; params = ([ordered]@{ model = 'ok'; maxTransientRetries = 6 }) }; Detail = 'parámetro inválido: maxTransientRetries' }
            @{ Order = @{ id = $validId; action = 'set-params'; params = @{ foo = 1 } }; Detail = 'parámetro no permitido: foo' }
            @{ Order = @{ id = $validId; action = 'set-params'; params = @{ awaitDecisionMinutes = 1.5 } }; Detail = 'parámetro inválido: awaitDecisionMinutes' }
            @{ Order = @{ action = 'pause'; params = @{} }; Detail = 'orden sin id' }
        )
        foreach ($c in $cases) {
            Write-ControlFile $path $c.Order
            Reset-LastControlId
            $o = Read-DriverControl -Path $path
            $o.Valid | Should Be $false
            $o.Detail | Should Be $c.Detail
            $o.Params | Should BeNullOrEmpty
            Test-Path -LiteralPath $path | Should Be $false
        }
    }

    It 'Read-DriverControl normaliza los tipos de set-params' {
        $dir = New-ControlDir 'tipos'
        $path = Join-Path $dir '.driver-control.json'
        $params = [ordered]@{
            model = 'claude-x'; levelEffort = 'low'; closeEffort = 'max'; maxTransientRetries = 2
            retryBackoffSeconds = 60; livenessTimeoutMinutes = 20; maxCostUsd = 12; awaitDecisionMinutes = 480
        }
        Write-ControlFile $path ([ordered]@{ id = $validId; action = 'set-params'; params = $params; requestedAt = '2026-10-27T20:00:00.000000+00:00' })
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        ($o.Params.maxCostUsd -is [double]) | Should Be $true
        ($o.Params.retryBackoffSeconds -is [int]) | Should Be $true
        ($o.Params.model -is [string]) | Should Be $true
        (@($o.Params.Keys) -join ',') | Should Be (@($params.Keys) -join ',')
    }

    It 'Read-DriverControl no devuelve dos veces la misma orden' {
        $dir = New-ControlDir 'repetida'
        $path = Join-Path $dir '.driver-control.json'
        $order = @{ id = $validId; action = 'pause'; params = @{} }
        Write-ControlFile $path $order
        Reset-LastControlId
        (Read-DriverControl -Path $path).Valid | Should Be $true
        Write-ControlFile $path $order
        Read-DriverControl -Path $path | Should BeNullOrEmpty
        Test-Path -LiteralPath $path | Should Be $false
        Write-ControlFile $path @{ id = '22222222-2222-4222-8222-222222222222'; action = 'stop'; params = @{} }
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Action | Should Be 'stop'
    }

    It 'Test-DriverControlAllowed cubre la matriz completa' {
        $matrix = [ordered]@{
            'pause'      = @{ watch = $true;  between = $true;  paused = $false; awaiting = $false }
            'resume'     = @{ watch = $false; between = $false; paused = $true;  awaiting = $false }
            'stop'       = @{ watch = $true;  between = $true;  paused = $true;  awaiting = $true }
            'set-params' = @{ watch = $true;  between = $true;  paused = $true;  awaiting = $true }
            'answer'     = @{ watch = $false; between = $false; paused = $false; awaiting = $false }
            'retry'      = @{ watch = $false; between = $false; paused = $false; awaiting = $true }
            'open'       = @{ watch = $true;  between = $true;  paused = $true;  awaiting = $true }
        }
        foreach ($action in $matrix.Keys) {
            foreach ($state in 'watch', 'between', 'paused', 'awaiting') {
                $got = Test-DriverControlAllowed -Action $action -State $state
                if ($got -ne $matrix[$action][$state]) { throw "matriz: $action/$state devolvio $got" }
            }
        }
        Test-DriverControlAllowed -Action 'answer' -State 'awaiting' | Should Be $false
        Test-DriverControlAllowed -Action 'answer' -State 'awaiting' -AwaitingOrigin 'BLOCKED' | Should Be $true
        Test-DriverControlAllowed -Action 'answer' -State 'awaiting' -AwaitingOrigin 'FAILED' | Should Be $false
        Test-DriverControlAllowed -Action 'x' -State 'watch' | Should Be $false
        { Test-DriverControlAllowed -Action 'pause' -State 'otro' } | Should Throw 'State'
    }

    It 'New-DriverControlEntry arma la entrada con origin dashboard y claves en orden' {
        $order = [pscustomobject]@{ Id = $validId; Action = 'set-params'; Params = ([ordered]@{ model = 'claude-x' }); RequestedAt = '2026-10-27T20:00:00.000000+00:00'; Valid = $true; Detail = $null }
        $e = New-DriverControlEntry -Order $order -Result applied -Iter 3
        (@($e.Keys) -join ',') | Should Be 'id,action,params,origin,requestedAt,appliedAt,result,detail,iter'
        $e.origin | Should Be 'dashboard'
        $e.result | Should Be 'applied'
        $e.iter | Should Be 3
        $e.id | Should Be $validId
        $e.appliedAt | Should Not BeNullOrEmpty

        $dir = New-ControlDir 'entrada-invalida'
        $path = Join-Path $dir '.driver-control.json'
        Set-Content -LiteralPath $path -Value '{no json' -Encoding utf8
        Reset-LastControlId
        $bad = Read-DriverControl -Path $path
        $e2 = New-DriverControlEntry -Order $bad -Result rejected -Detail 'x'
        @($e2.params.Keys).Count | Should Be 0
        $e2.id | Should BeNullOrEmpty
        $e2.detail | Should Be 'x'
        $e2.result | Should Be 'rejected'
    }

    It 'Get-DriverControlToken devuelve 64 hex distintos en cada llamada' {
        $a = Get-DriverControlToken
        $b = Get-DriverControlToken
        ($a -cmatch '^[0-9a-f]{64}$') | Should Be $true
        ($b -cmatch '^[0-9a-f]{64}$') | Should Be $true
        $a | Should Not Be $b
    }

    It 'Get-DriverControlDeadline: 0 sin plazo y N minutos desde Since' {
        Get-DriverControlDeadline -Since (Get-Date) -Minutes 0 | Should BeNullOrEmpty
        $d = Get-DriverControlDeadline -Since (Get-Date '2026-10-27T20:00:00') -Minutes 30
        $d.ToString('HH:mm:ss') | Should Be '20:30:00'
    }

    It 'Wait-DriverPause publica PAUSED con el bloque y vuelve con resume' {
        $path = Join-Path $TestDrive 'wait-resume.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        $seen = @{ N = 0; Status = $null }
        $tick = {
            $seen.N++
            if ($seen.N -eq 1) { $seen.Status = Get-DriverStatus -StatusPath $path; return $null }
            if ($seen.N -eq 3) { return 'resume' }
        }.GetNewClosure()
        $r = Wait-DriverPause -StatusPath $path -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a1' }) -Reason 'En pausa (dashboard)' -HeartbeatSeconds 60 -GetDeadline { $null } -OnTick $tick -TickMilliseconds 100
        $r | Should Be 'resume'
        $seen.N | Should Be 3
        $seen.Status.globalStatus | Should Be 'PAUSED'
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'PAUSED'
        $s.reason | Should Be 'En pausa (dashboard)'
        $s.paused.actionId | Should Be 'a1'
    }

    It 'Wait-DriverPause vuelve con stop e ignora otras senales' {
        $path = Join-Path $TestDrive 'wait-stop.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        $seen = @{ N = 0 }
        $tick = {
            $seen.N++
            if ($seen.N -eq 1) { return 'set-params' }
            if ($seen.N -eq 2) { return 'stop' }
        }.GetNewClosure()
        $r = Wait-DriverPause -StatusPath $path -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a1' }) -Reason 'r' -HeartbeatSeconds 60 -GetDeadline { $null } -OnTick $tick -TickMilliseconds 50
        $r | Should Be 'stop'
        $seen.N | Should Be 2
    }

    It 'Wait-DriverPause vence con el plazo y escribe heartbeat' {
        $path = Join-Path $TestDrive 'wait-expired.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        $initial = (Get-DriverStatus -StatusPath $path).driver.heartbeatAt
        $dl = (Get-Date).AddSeconds(1.5)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Wait-DriverPause -StatusPath $path -Block ([ordered]@{ since = 's'; deadline = 'd'; actionId = 'a1' }) -Reason 'r' -HeartbeatSeconds 1 -GetDeadline { $dl }.GetNewClosure() -OnTick { $null } -TickMilliseconds 100
        $sw.Stop()
        $r | Should Be 'expired'
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 1.4
        $sw.Elapsed.TotalSeconds | Should BeLessThan 4
        (Get-DriverStatus -StatusPath $path).driver.heartbeatAt | Should Not Be $initial
    }

    It 'Wait-DriverPause tolera un OnTick que lanza y sin plazo no vence' {
        $path = Join-Path $TestDrive 'wait-throws.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        $seen = @{ N = 0 }
        $tick = {
            $seen.N++
            if ($seen.N -le 3) { throw 'fallo de prueba' }
            if ($seen.N -eq 6) { return 'resume' }
        }.GetNewClosure()
        $out = @{ R = $null }
        { $out.R = Wait-DriverPause -StatusPath $path -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a1' }) -Reason 'r' -HeartbeatSeconds 60 -GetDeadline { $null } -OnTick $tick -TickMilliseconds 50 3>$null } | Should Not Throw
        $out.R | Should Be 'resume'
        $seen.N | Should Be 6
    }

    It '2c: Read-DriverControl acepta answer, retry y open con params normalizados' {
        $path = Join-Path (New-ControlDir '2c-acepta') '.driver-control.json'

        Write-ControlFile $path @{ id = $validId; action = 'answer'; params = @{ text = "usa A`nsigue" } }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Params.text | Should Be "usa A`nsigue"

        Write-ControlFile $path @{ id = $validId; action = 'retry'; params = @{ mode = 'level' } }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Params.mode | Should Be 'level'

        Write-ControlFile $path @{ id = $validId; action = 'open'; params = @{ target = 'log'; iter = 2 } }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Params.target | Should Be 'log'
        ($o.Params.iter -is [int]) | Should Be $true
        $o.Params.iter | Should Be 2

        Write-ControlFile $path @{ id = $validId; action = 'open'; params = @{ target = 'folder' } }
        Reset-LastControlId
        $o = Read-DriverControl -Path $path
        $o.Valid | Should Be $true
        $o.Params.target | Should Be 'folder'
        $o.Params.Contains('iter') | Should Be $false
    }

    It '2c: Read-DriverControl rechaza answer, retry y open fuera del esquema con el detalle exacto' {
        $path = Join-Path (New-ControlDir '2c-rechaza') '.driver-control.json'
        $cases = @(
            @{ Action = 'answer'; Params = @{}; Detail = 'parámetro inválido: text' }
            @{ Action = 'answer'; Params = @{ text = 'PLAN_STATUS: COMPLETE' }; Detail = 'parámetro inválido: text (la respuesta no puede contener PLAN_STATUS)' }
            @{ Action = 'answer'; Params = ([ordered]@{ text = 'x'; a = 1 }); Detail = 'parámetro no permitido: a' }
            @{ Action = 'retry'; Params = @{ mode = 'Session' }; Detail = 'parámetro inválido: mode' }
            @{ Action = 'open'; Params = @{ target = 'shell' }; Detail = 'parámetro inválido: target' }
            @{ Action = 'open'; Params = ([ordered]@{ target = 'log'; iter = 0 }); Detail = 'parámetro inválido: iter' }
            @{ Action = 'open'; Params = ([ordered]@{ target = 'log'; iter = 1.5 }); Detail = 'parámetro inválido: iter' }
        )
        foreach ($c in $cases) {
            Write-ControlFile $path @{ id = $validId; action = $c.Action; params = $c.Params }
            Reset-LastControlId
            $o = Read-DriverControl -Path $path
            $o.Valid | Should Be $false
            $o.Detail | Should Be $c.Detail
            $o.Params | Should BeNullOrEmpty
        }
    }

    It '2c: Test-DriverAnswerText aplica las reglas en orden' {
        Test-DriverAnswerText -Text 'usa A' | Should BeNullOrEmpty
        Test-DriverAnswerText -Text "a`tb`r`nc" | Should BeNullOrEmpty
        Test-DriverAnswerText -Text ('a' * 4000) | Should BeNullOrEmpty
        Test-DriverAnswerText -Text ([char]::ConvertFromUtf32(0x1F600) * 2000) | Should BeNullOrEmpty
        Test-DriverAnswerText -Text $null | Should Be 'texto vacío'
        Test-DriverAnswerText -Text '' | Should Be 'texto vacío'
        Test-DriverAnswerText -Text "  `n" | Should Be 'texto vacío'
        Test-DriverAnswerText -Text ('a' * 4001) | Should Be 'texto demasiado largo (máx. 4000)'
        Test-DriverAnswerText -Text "x$([char]0xD800)" | Should Be 'carácter no permitido'
        Test-DriverAnswerText -Text "a$([char]0)b" | Should Be 'carácter de control no permitido'
        Test-DriverAnswerText -Text "$([char]27)[31m" | Should Be 'carácter de control no permitido'
        Test-DriverAnswerText -Text "x$([char]0x202E)y" | Should Be 'carácter no permitido'
        Test-DriverAnswerText -Text "x$([char]0x2066)y" | Should Be 'carácter no permitido'
        Test-DriverAnswerText -Text 'ver PLAN_STATUS' | Should Be 'la respuesta no puede contener PLAN_STATUS'
    }

    It 'S2: Test-DriverAnswerText rechaza PLAN_STATUS sin distinguir mayusculas' {
        foreach ($t in 'plan_status', 'Plan_Status: x', 'ver PLAN_status') {
            Test-DriverAnswerText -Text $t | Should Be 'la respuesta no puede contener PLAN_STATUS'
        }
    }

    It '2c: Get-DriverAnswerPrompt y Add-DriverDecisionSection con la forma exacta' {
        Import-Module (Join-Path $moduleRoot 'scripts\modules\SessionRetry.psm1') -Force
        $expected = @(
            'No actives el skill caveman ni ningún modo de compresión de salida en esta'
            'sesión: es una corrida automatizada cuya salida queda en logs, y necesita prosa'
            'normal.'
            ''
            "El usuario responde a tu bloqueo: usa A`nsigue. Continúa desde donde quedaste y termina con la línea PLAN_STATUS como siempre."
        ) -join "`n"
        $p = Get-DriverAnswerPrompt -Text "usa A`r`nsigue"
        ($p -ceq $expected) | Should Be $true

        $resume = (Get-ResumePrompt) -split "`n"
        $mine = $p -split "`n"
        for ($i = 0; $i -lt 3; $i++) { ($mine[$i] -ceq $resume[$i]) | Should Be $true }

        (Add-DriverDecisionSection -Prompt 'P' -Text 'D') | Should Be "P`n`nDecisión del usuario: D"
    }

    It '2c: Get-DriverAwaitingAllowed por origen y kill' {
        (Get-DriverAwaitingAllowed -Origin BLOCKED -KillConfirmed $true) -join ',' | Should Be 'answer,retry,stop,set-params,open'
        (Get-DriverAwaitingAllowed -Origin FAILED -KillConfirmed $true) -join ',' | Should Be 'retry,stop,set-params,open'
        (Get-DriverAwaitingAllowed -Origin tope_costo -KillConfirmed $true) -join ',' | Should Be 'retry,stop,set-params,open'
        (Get-DriverAwaitingAllowed -Origin BLOCKED -KillConfirmed $false) -join ',' | Should Be 'stop,set-params,open'
    }

    It '2c: New-DriverAwaitingBlock con las claves de C1 en orden' {
        $b = New-DriverAwaitingBlock -Since (Get-Date '2026-10-28T20:00:00') -Deadline (Get-Date '2026-10-29T04:00:00') -Origin BLOCKED -Reason 'r' -Cause $null -Iter 3 -SessionId 'g' -Resumable $true -Allowed @('answer')
        (@($b.Keys) -join ',') | Should Be 'since,deadline,origin,reason,cause,iter,sessionId,resumable,allowed'
        $b.deadline | Should Match '2026-10-29T04:00:00'
        $b.since | Should Match '2026-10-28T20:00:00'
        $b.origin | Should Be 'BLOCKED'
        $b.iter | Should Be 3
        $b.resumable | Should Be $true
        ($b.allowed -is [array]) | Should Be $true
        ($b | ConvertTo-Json) | Should Match '"allowed": \['

        $n = New-DriverAwaitingBlock -Since (Get-Date '2026-10-28T20:00:00') -Origin FAILED -Reason 'r' -Cause 'exit_no_cero' -Iter 1 -SessionId $null -Resumable $false -Allowed @('stop')
        $n.deadline | Should BeNullOrEmpty
        $n.resumable | Should Be $false
    }

    It '2c: Get-DriverRunCost suma solo esta corrida y tolera faltantes' {
        $status = [pscustomobject]@{ history = @(
                [pscustomobject]@{ iter = 1; telemetry = [pscustomobject]@{ costUsd = 0.5 } }
                [pscustomobject]@{ iter = 2; telemetry = [pscustomobject]@{ costUsd = 0.25 } }
                [pscustomobject]@{ iter = 2; telemetry = [pscustomobject]@{ costUsd = 0.25 } }
                [pscustomobject]@{ iter = 3 }
                [pscustomobject]@{ iter = 4; telemetry = [pscustomobject]@{ costUsd = 'x' } }
            )
        }
        Get-DriverRunCost -Status $status -IterBase 0 | Should Be 1.0
        Get-DriverRunCost -Status $status -IterBase 1 | Should Be 0.5
        Get-DriverRunCost -Status ([pscustomobject]@{}) -IterBase 0 | Should Be 0
    }

    It '2c: New-DriverControlEntry recorta el texto de answer a 500 caracteres' {
        $order = [pscustomobject]@{ Id = $validId; Action = 'answer'; Params = ([ordered]@{ text = ('a' * 800) }); RequestedAt = 'r'; Valid = $true; Detail = $null }
        $e = New-DriverControlEntry -Order $order -Result applied -Iter 1
        $e.params.text.Length | Should Be 501
        $e.params.text | Should Be (('a' * 500) + '…')
        $e.params.textLength | Should Be 800

        $short = [pscustomobject]@{ Id = $validId; Action = 'answer'; Params = ([ordered]@{ text = 'corto' }); RequestedAt = 'r'; Valid = $true; Detail = $null }
        $e2 = New-DriverControlEntry -Order $short -Result applied
        $e2.params.text | Should Be 'corto'
        $e2.params.textLength | Should Be 5

        $retry = [pscustomobject]@{ Id = $validId; Action = 'retry'; Params = ([ordered]@{ mode = 'level' }); RequestedAt = 'r'; Valid = $true; Detail = $null }
        (New-DriverControlEntry -Order $retry -Result applied).params.mode | Should Be 'level'

        $pair = ('a' * 499) + [char]0xD83D + [char]0xDE00 + 'b'
        $edge = [pscustomobject]@{ Id = $validId; Action = 'answer'; Params = ([ordered]@{ text = $pair }); RequestedAt = 'r'; Valid = $true; Detail = $null }
        $e3 = New-DriverControlEntry -Order $edge -Result applied
        $e3.params.text.Length | Should Be 500
        $e3.params.text | Should Be (('a' * 499) + '…')
        $e3.params.textLength | Should Be 502
    }

    It '2c: Wait-DriverPause con -State AWAITING publica AWAITING y sale con la senal elegida' {
        $path = Join-Path $TestDrive 'wait-awaiting.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        $seen = @{ N = 0; Status = $null }
        $tick = {
            $seen.N++
            if ($seen.N -eq 1) { $seen.Status = Get-DriverStatus -StatusPath $path; return 'resume' }
            if ($seen.N -eq 2) { return 'decided' }
        }.GetNewClosure()
        $r = Wait-DriverPause -StatusPath $path -State AWAITING -ExitSignals @('decided', 'stop') -Block ([ordered]@{ since = 's'; deadline = $null; origin = 'BLOCKED' }) -Reason 'Esperando decisión' -HeartbeatSeconds 60 -GetDeadline { $null } -OnTick $tick -TickMilliseconds 50
        $r | Should Be 'decided'
        $seen.N | Should Be 2
        $seen.Status.globalStatus | Should Be 'AWAITING'
        $seen.Status.awaiting.origin | Should Be 'BLOCKED'
    }
}

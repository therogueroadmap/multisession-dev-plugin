$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\WorkspaceLayout.psm1') -Force
Import-Module (Join-Path $moduleRoot 'scripts\modules\PlanProgress.psm1') -Force
Import-Module (Join-Path $moduleRoot 'scripts\modules\StatusLine.psm1') -Force

Describe 'plan-session-driver (integracion de layout)' {
    It 'RepoRoot sin WorkDir es ProjectPath; con WorkDir es el subproyecto' {
        Resolve-RepoRoot -ProjectPath 'C:\c' -WorkDir $null | Should Be 'C:\c'
        Resolve-RepoRoot -ProjectPath 'C:\c' -WorkDir 'web' | Should Be (Join-Path 'C:\c' 'web')
    }
    It 'materializa el plan del contenedor en el subproyecto solo si falta' {
        $container = Join-Path $TestDrive 'cont'
        $srcPlansDir = Join-Path $container 'docs\superpowers\plans'
        New-Item -ItemType Directory -Path $srcPlansDir -Force | Out-Null
        $src = Join-Path $srcPlansDir 'b.md'
        Set-Content -LiteralPath $src -Value 'PLAN' -Encoding utf8
        $repoRoot = Join-Path $container 'web'
        $destDir = Get-EffectivePlansDir -RepoRoot $repoRoot
        $dest = Copy-PlanIfMissing -PlanFilePath $src -DestPlansDir $destDir
        $dest | Should Be (Join-Path $destDir 'b.md')
        (Test-Path -LiteralPath $dest) | Should Be $true
        Get-PathRelativeTo -BasePath $repoRoot -FullPath $dest | Should Be 'docs\superpowers\plans\b.md'
    }
    It 'el script se parsea sin errores de sintaxis' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }
    It 'declara -BackgroundWaitCeilingMs con default 0' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BackgroundWaitCeilingMs' }
        $param | Should Not BeNullOrEmpty
        $param.DefaultValue.Extent.Text | Should Be '0'
    }
    It 'usa Get-LogTail, Resolve-SessionOutcome y Resolve-BackgroundCeilingEnv, y ya no Get-LastNonEmptyLine' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        ($commands -contains 'Get-LogTail') | Should Be $true
        ($commands -contains 'Resolve-SessionOutcome') | Should Be $true
        ($commands -contains 'Resolve-BackgroundCeilingEnv') | Should Be $true
        ($commands -contains 'Get-LastNonEmptyLine') | Should Be $false
    }
    It 'pasa -Environment a Start-HeadlessProcess' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $launch = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-HeadlessProcess' }, $true))
        $launch.Count | Should Be 1
        $params = @($launch[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        ($params -contains 'Environment') | Should Be $true
    }
    It 'cablea las validaciones de layout de la Fase 3' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($name in @('Assert-ProjectIsRepo', 'Assert-PlanInsideRepo', 'Find-StrayControllerState', 'Resolve-BootstrapBranchAction', 'Resume-WorkBranch', 'Get-ControllerStateInfo')) {
            ($commands -contains $name) | Should Be $true
        }
    }
    It 'conserva Use-CurrentWorkBranch e Initialize-WorkBranch en el bootstrap' {
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        ($commands -contains 'Use-CurrentWorkBranch') | Should Be $true
        ($commands -contains 'Initialize-WorkBranch') | Should Be $true
    }
    It 'aborta al arranque si el plan esta fuera del repo sin -WorkDir (punta a punta)' {
        $repo = Join-Path $TestDrive 'e2e-repo'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q | Out-Null
        $planDir = Join-Path $TestDrive 'e2e-otro\docs\superpowers\plans'
        New-Item -ItemType Directory -Path $planDir -Force | Out-Null
        $plan = Join-Path $planDir '2026-10-06-e2e.md'
        Set-Content -LiteralPath $plan -Value '# plan' -Encoding utf8
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $pwshPath = (Get-Process -Id $PID).Path

        $out = & $pwshPath -NoProfile -File $script -ProjectPath $repo -PlanFile $plan -Port 18787 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out.Contains('fuera') | Should Be $true
        $out.Contains('Mueve') | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo 'docs\superpowers\plans\.driver-status.json')) | Should Be $false
    }
    It 'aborta al arranque en una raiz multi-repo sin -WorkDir y nombra los repos (punta a punta)' {
        $root = Join-Path $TestDrive 'e2e-multi'
        foreach ($r in @('repoalfa', 'repobeta')) {
            $p = Join-Path $root $r
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            git -C $p init -q | Out-Null
        }
        $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
        $pwshPath = (Get-Process -Id $PID).Path

        $out = & $pwshPath -NoProfile -File $script -ProjectPath $root -Port 18787 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out.Contains('repoalfa') | Should Be $true
        $out.Contains('repobeta') | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'docs')) | Should Be $false
    }
}

Describe 'plan-session-driver (Fase 2: contrato de estado de sesion)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    It 'declara -NoProgressRetries con default 1' {
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'NoProgressRetries' }
        $param | Should Not BeNullOrEmpty
        $param.DefaultValue.Extent.Text | Should Be '1'
    }

    It 'mide el avance y pasa la evidencia a Resolve-SessionOutcome' {
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        ($commands -contains 'Test-CheckpointAdvanced') | Should Be $true
        $call = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-SessionOutcome' }, $true))
        $call.Count | Should Be 1
        $params = @($call[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        foreach ($p in @('Advanced', 'ErrTailLines', 'NoProgressStreak', 'NoProgressRetries')) {
            ($params -contains $p) | Should Be $true
        }
    }

    It 'pasa -Cause en todas las llamadas a Add-DriverStatusEvent' {
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-DriverStatusEvent' }, $true))
        $calls.Count | Should Be 1
        foreach ($c in $calls) {
            $params = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
            ($params -contains 'Cause') | Should Be $true
        }
    }

    It 'tolera la re-entrada en bootstrap con la rama ya preparada en la corrida' {
        $text | Should Match '\$branchReadyThisRun = \$false'
        $text | Should Match 'if \(\$branchReadyThisRun\)'
        ([regex]::Matches($text, '\$branchReadyThisRun = \$true')).Count | Should Be 3
    }

    It 'la guarda de rama de continue/close deja la rama lista y persistida para una re-entrada en bootstrap' {
        $text | Should Match '(?s)elseif \(\$decision\.Mode -ne ''done''\) \{\s*\$statusBranch = \(Get-DriverStatus -StatusPath \$statusPath\)\.workBranch\s*\$expectedBranch = \$statusBranch'
        $text | Should Match '(?s)Aborta para no commitear en la rama equivocada\."\s*\}\s*(#[^\n]*\s*)*if \(-not \$statusBranch\) \{\s*Set-DriverStatusBranch -StatusPath \$statusPath -WorkBranch \$expectedBranch \| Out-Null\s*\}\s*\$branchReadyThisRun = \$true'
    }

    It 'los tres prompts piden BLOCKED en vez de preguntas y verificacion en primer plano' {
        ([regex]::Matches($text, 'NO la formules como pregunta en prosa')).Count | Should Be 3
        ([regex]::Matches($text, 'en primer plano')).Count | Should Be 3
    }

    It 'compatibilidad M9 (regla 4): checkpoint en formato viejo, CONTINUE sin tocarlo -> reintento y luego BLOCKED' {
        $dir = Join-Path $TestDrive 'compat-m9'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $plan = Join-Path $dir '2026-09-20-viejo.md'
        Set-Content -LiteralPath $plan -Value @'
# Viejo Implementation Plan

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 1: Foo | none | 0 |
| Task 2: Bar | Task 1 | 1 |
| Task 3: Baz | Task 2 | 2 |
'@
        $state = Join-Path $dir '.controller-state.json'
        Set-Content -LiteralPath $state -Value ('{"plan": "' + $plan.Replace('\', '\\') + '", "completed_levels": [0], "current_level": 1}')

        $decision = Get-PlanBootstrapDecision -PlanFilePath $plan -ControllerStatePath $state -FinalReviewMarkerPath (Join-Path $dir '.final-review-2026-09-20-viejo.md')
        $decision.Mode | Should Be 'continue'

        $before = Get-ControllerStateInfo -ControllerStatePath $state -PlanFilePath $plan
        $after = Get-ControllerStateInfo -ControllerStatePath $state -PlanFilePath $plan
        $advanced = Test-CheckpointAdvanced -Before $before -After $after
        $advanced | Should Be $false

        $o1 = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $advanced -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o1.IsRetry | Should Be $true
        $o1.Decision.ShouldContinue | Should Be $true

        $o2 = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $advanced -ErrTailLines @() -NoProgressStreak 1 -NoProgressRetries 1
        $o2.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o2.Cause | Should Be 'continue_sin_avance'
    }
}

Describe 'plan-session-driver (Fase 4: parametrizacion y telemetria)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-DriverParam([string]$Name) {
        return ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    }

    function Get-CallParams($Call) {
        return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    }

    It 'el script se parsea sin errores' {
        $errors.Count | Should Be 0
    }

    It 'M12: -MaxIterations tiene default 0 (automatico) y ValidateRange(0, 1000)' {
        $p = Get-DriverParam 'MaxIterations'
        $p.DefaultValue.Extent.Text | Should Be '0'
        ($p.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(0, 1000\)'
    }

    It 'M11: declara -Model, -LevelEffort y -CloseEffort con sus defaults y ValidateSet' {
        (Get-DriverParam 'Model').DefaultValue.Extent.Text | Should Be "'claude-opus-5-5'"
        # -Model '' se rechaza al arrancar, no despues de correr la sesion.
        ((Get-DriverParam 'Model').Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateNotNullOrEmpty\(\)'
        foreach ($name in @('LevelEffort', 'CloseEffort')) {
            $p = Get-DriverParam $name
            $p.DefaultValue.Extent.Text | Should Be "'high'"
            ($p.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match "ValidateSet\('low', 'medium', 'high', 'xhigh', 'max'\)"
        }
    }

    It 'M11/M4: los args usan modelo y effort parametrizados y stream-json con verbose' {
        $text | Should Not Match "'--model', 'claude-opus-5-5', '--effort', 'high'"
        $text | Should Match "'--model', \`$Model, '--effort', \`$sessionEffort, '--output-format', 'stream-json', '--verbose'"
        $text | Should Match "\`$sessionEffort = if \(\`$decision\.Mode -eq 'close'\) \{ \`$CloseEffort \} else \{ \`$LevelEffort \}"
    }

    It 'M12: el bucle usa el presupuesto resuelto con Get-SessionBudget' {
        $text | Should Not Match 'while \(\$iter -lt \$MaxIterations\)'
        $text | Should Match 'while \(\(\$iter - \$iterBase\) -lt \$sessionBudget\)'
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        ($commands -contains 'Get-SessionBudget') | Should Be $true
        $text | Should Match 'Presupuesto de sesiones: \$sessionBudget \(\$budgetSource\)'
        $text | Should Match 'se alcanzaron las \$sessionBudget sesiones \(\$budgetSource\)'
    }

    It 'M4: stdout va al .stream.jsonl y el watchdog lo vigila' {
        $text | Should Match 'session-\$iter-\$timestamp\.stream\.jsonl'
        $text | Should Match '-StdoutPath \$streamPath'
        $text | Should Not Match 'Get-LivenessFingerprint -Proc \$proc -LogPath \$logPath'
        @([regex]::Matches($text, 'Get-LivenessFingerprint -Proc \$proc -LogPath \$streamPath')).Count | Should Be 2
    }

    It 'M4: importa SessionStream y deriva el .log en ambos caminos (normal, colgada e interrupcion B-4)' {
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'SessionStream\.psm1'\) -Force"
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Save-SessionStreamLog' }, $true))
        # Cuatro: colgada, normal, OnSessionInterrupted del finally y la de A3 (detener desde el dashboard).
        $calls.Count | Should Be 4
    }

    It 'M13: pasa -Telemetry en todas las llamadas a Add-DriverStatusEvent' {
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-DriverStatusEvent' }, $true))
        $calls.Count | Should Be 1
        foreach ($c in $calls) {
            ((Get-CallParams $c) -contains 'Telemetry') | Should Be $true
        }
    }
}

Describe 'Invoke-DriverInterruptCleanup (B-4)' {
    Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverStatus.psm1') -Force
    Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverInterrupt.psm1') -Force

    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = (Get-Command powershell).Source }

    function New-TestStatus {
        param([string]$Name)
        $path = Join-Path $TestDrive "$Name.json"
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' | Out-Null
        return $path
    }

    function Test-ProcessAlive {
        param([int]$ProcessId)
        return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
    }

    It 'con sesion en curso y proceso vivo: mata, registra cause manual y deja STOPPED' {
        $statusPath = New-TestStatus 'live'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 2 -SessionId 's-2' -StreamFile 'a.stream.jsonl' -ErrFile 'a.err.log' | Out-Null
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
        try {
            $rec = @{ Pid = $null }
            $kill = { param($ProcessId) $rec.Pid = $ProcessId; Stop-Process -Id $ProcessId -Force }.GetNewClosure()
            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'a.log' -StreamFile 'a.stream.jsonl' -ErrFile 'a.err.log' -KillTree $kill -OnSessionInterrupted { [pscustomobject]@{ model = 'm' } }

            $rec.Pid | Should Be $proc.Id
            $proc.HasExited | Should Be $true
            $s = Get-DriverStatus -StatusPath $statusPath
            $e = @($s.history)[-1]
            $e.iter | Should Be 2
            $e.cause | Should Be 'manual'
            $e.exitCode | Should Be -1
            $e.streamFile | Should Be 'a.stream.jsonl'
            $e.errFile | Should Be 'a.err.log'
            $e.logPath | Should Be 'a.log'
            $e.telemetry.model | Should Be 'm'
            $s.globalStatus | Should Be 'STOPPED'
            $s.reason | Should Be 'Interrumpido con Ctrl+C'
            $s.currentSession | Should BeNullOrEmpty
            $r.Action | Should Be 'stopped'
            $r.KilledPid | Should Be $proc.Id
            $r.EventAdded | Should Be $true
            $r.StopWritten | Should Be $true
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'con status PAUSED o AWAITING tambien limpia y escribe la causa' {
        $paused = New-TestStatus 'paused'
        Set-DriverStatusLiveState -StatusPath $paused -State PAUSED -Reason 'En pausa (dashboard)' -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a' }) | Out-Null
        $r = Invoke-DriverInterruptCleanup -StatusPath $paused -Process $null -LogFile 'p.log'
        $r.Action | Should Be 'stopped'
        $s = Get-DriverStatus -StatusPath $paused
        $s.globalStatus | Should Be 'STOPPED'
        $s.reason | Should Be 'Interrumpido con Ctrl+C'
        $s.cause | Should Be 'manual'
        ($null -eq $s.PSObject.Properties['paused']) | Should Be $true

        $awaiting = New-TestStatus 'awaiting'
        $raw = Get-Content -LiteralPath $awaiting -Raw | ConvertFrom-Json
        $raw.globalStatus = 'AWAITING'
        $raw | Add-Member -NotePropertyName awaiting -NotePropertyValue ([pscustomobject]@{ since = 's'; origin = 'BLOCKED' }) -Force
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $awaiting -Encoding utf8
        $r2 = Invoke-DriverInterruptCleanup -StatusPath $awaiting -Process $null -LogFile 'a.log'
        $r2.Action | Should Be 'stopped'
        $s2 = Get-DriverStatus -StatusPath $awaiting
        $s2.globalStatus | Should Be 'STOPPED'
        $s2.reason | Should Be 'Interrumpido con Ctrl+C'
        $s2.cause | Should Be 'manual'
        ($null -eq $s2.PSObject.Properties['awaiting']) | Should Be $true
    }

    It 'status ya final: no hace nada' {
        $statusPath = New-TestStatus 'final'
        Set-DriverStatusFinal -StatusPath $statusPath -GlobalStatus DONE | Out-Null
        $before = Get-Content -LiteralPath $statusPath -Raw
        $rec = @{ Called = $false }
        $kill = { param($ProcessId) $rec.Called = $true }.GetNewClosure()
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
        try {
            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'x.log' -KillTree $kill

            $r.Action | Should Be 'skipped'
            $r.KilledPid | Should BeNullOrEmpty
            $r.EventAdded | Should Be $false
            $rec.Called | Should Be $false
            (Test-ProcessAlive $proc.Id) | Should Be $true
            (Get-DriverStatus -StatusPath $statusPath).globalStatus | Should Be 'DONE'
            (Get-Content -LiteralPath $statusPath -Raw) | Should Be $before
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'proceso ya terminado: no llama a KillTree, si llama a OnSessionInterrupted' {
        $statusPath = New-TestStatus 'exited'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 3 -SessionId 's-3' | Out-Null
        $marker = Join-Path $TestDrive 'marker.txt'
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        try {
            $proc.WaitForExit()
            $rec = @{ Called = $false }
            $kill = { param($ProcessId) $rec.Called = $true }.GetNewClosure()
            $onInt =  { Set-Content -LiteralPath $marker -Value 'x'; $null }.GetNewClosure()

            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'b.log' -KillTree $kill -OnSessionInterrupted $onInt

            (Test-Path -LiteralPath $marker) | Should Be $true
            $rec.Called | Should Be $false
            $r.KilledPid | Should BeNullOrEmpty
            $r.EventAdded | Should Be $true
            $s = Get-DriverStatus -StatusPath $statusPath
            @($s.history)[-1].cause | Should Be 'manual'
            @($s.history)[-1].iter | Should Be 3
            $s.globalStatus | Should Be 'STOPPED'
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'D1: la interrupcion de un reintento registra el attempt de la sesion en curso' {
        $statusPath = New-TestStatus 'retry-attempt'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 3 -SessionId 's-3' -Attempt 2 | Out-Null
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        try {
            $proc.WaitForExit()
            $kill = { param($ProcessId) }
            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'session-3-r2-20261027-101010.log' -KillTree $kill -OnSessionInterrupted { $null }

            $r.EventAdded | Should Be $true
            $ev = @((Get-DriverStatus -StatusPath $statusPath).history)[-1]
            $ev.iter | Should Be 3
            $ev.attempt | Should Be 2
            $ev.cause | Should Be 'manual'
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }

        # Driver viejo: currentSession sin la clave attempt -> el evento registra attempt 0.
        $noAttDir = Join-Path $TestDrive 'retry-sin-attempt'
        New-Item -ItemType Directory -Path $noAttDir -Force | Out-Null
        $noAttPath = Join-Path $noAttDir 'status.json'
        New-DriverStatus -StatusPath $noAttPath -ProjectPath 'C:\p' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $noAttPath -Iter 3 -SessionId 's-3' -Attempt 2 | Out-Null
        $raw = Get-Content -LiteralPath $noAttPath -Raw | ConvertFrom-Json
        $raw.currentSession.PSObject.Properties.Remove('attempt')
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $noAttPath -Encoding utf8
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        try {
            $proc.WaitForExit()
            $kill = { param($ProcessId) }
            $r = Invoke-DriverInterruptCleanup -StatusPath $noAttPath -Process $proc -LogFile 'session-3-r1-20261027-101010.log' -KillTree $kill -OnSessionInterrupted { $null }
            $r.EventAdded | Should Be $true
            $ev = @((Get-DriverStatus -StatusPath $noAttPath).history)[-1]
            $ev.attempt | Should Be 0
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }

        # attempt de texto ("2") no es entero: el evento registra attempt 0.
        $txtDir = Join-Path $TestDrive 'retry-attempt-texto'
        New-Item -ItemType Directory -Path $txtDir -Force | Out-Null
        $txtPath = Join-Path $txtDir 'status.json'
        New-DriverStatus -StatusPath $txtPath -ProjectPath 'C:\p' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $txtPath -Iter 3 -SessionId 's-3' -Attempt 2 | Out-Null
        $raw = Get-Content -LiteralPath $txtPath -Raw | ConvertFrom-Json
        $raw.currentSession.attempt = '2'
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $txtPath -Encoding utf8
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        try {
            $proc.WaitForExit()
            $kill = { param($ProcessId) }
            $r = Invoke-DriverInterruptCleanup -StatusPath $txtPath -Process $proc -LogFile 'session-3-r1-20261027-101011.log' -KillTree $kill -OnSessionInterrupted { $null }
            $r.EventAdded | Should Be $true
            $ev = @((Get-DriverStatus -StatusPath $txtPath).history)[-1]
            $ev.attempt | Should Be 0
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'sin sesion en curso: STOPPED sin evento' {
        $statusPath = New-TestStatus 'nosession'

        $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $null -LogFile 'c.log'

        $s = Get-DriverStatus -StatusPath $statusPath
        @($s.history).Count | Should Be 0
        $r.EventAdded | Should Be $false
        $r.Action | Should Be 'stopped'
        $s.globalStatus | Should Be 'STOPPED'
        $s.currentSession | Should BeNullOrEmpty
    }

    It 'un fallo de OnSessionInterrupted no impide el evento ni el STOPPED' {
        $statusPath = New-TestStatus 'onfail'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 4 -SessionId 's-4' | Out-Null
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
        try {
            $proc.WaitForExit()

            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'd.log' -OnSessionInterrupted { throw 'x' }

            $r.EventAdded | Should Be $true
            $s = Get-DriverStatus -StatusPath $statusPath
            @($s.history)[-1].telemetry | Should BeNullOrEmpty
            @($s.history)[-1].cause | Should Be 'manual'
            $s.globalStatus | Should Be 'STOPPED'
        }
        finally {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'con sesion en curso pero sin LogFile: STOPPED sin evento y currentSession limpio' {
        $statusPath = New-TestStatus 'nolog'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 5 -SessionId 's-5' | Out-Null

        $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $null -LogFile $null

        $s = Get-DriverStatus -StatusPath $statusPath
        $r.EventAdded | Should Be $false
        $r.Action | Should Be 'stopped'
        @($s.history).Count | Should Be 0
        $s.currentSession | Should BeNullOrEmpty
        $s.globalStatus | Should Be 'STOPPED'
    }

    It 'si KillTree no logra cerrar el proceso, KilledPid queda nulo y avisa' {
        $statusPath = New-TestStatus 'nokill'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 4 -SessionId 's-4' | Out-Null
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
        try {
            $kill = { param($ProcessId) }

            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'd.log' -KillTree $kill -WarningVariable w -WarningAction SilentlyContinue

            $r.KilledPid | Should BeNullOrEmpty
            ($w -join ' ') | Should Match "$($proc.Id)"
            $r.Action | Should Be 'stopped'
            (Test-ProcessAlive $proc.Id) | Should Be $true
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'StopWritten es true cuando se escribe STOPPED' {
        $statusPath = New-TestStatus 'stopwritten'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 1 -SessionId 's-1' | Out-Null

        $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $null -LogFile 'a.log'

        $r.StopWritten | Should Be $true
        (Get-DriverStatus -StatusPath $statusPath).globalStatus | Should Be 'STOPPED'
    }

    It 'Seg. 1: si Set-DriverStatusFinal falla, StopWritten es false y avisa' {
        $statusPath = New-TestStatus 'stopfail'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 1 -SessionId 's-1' | Out-Null
        # Handle sin FileShare.Delete: el reemplazo atomico falla los 3 intentos (como en DriverStatus.Tests).
        $handle = [IO.File]::Open($statusPath, 'Open', 'Read', 'Read')
        try {
            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $null -LogFile 'a.log' -WarningVariable w -WarningAction SilentlyContinue
        }
        finally {
            $handle.Dispose()
        }

        $r.StopWritten | Should Be $false
        $r.Action | Should Be 'stopped'
        ($w -join ' ') | Should Match 'No se pudo escribir el estado STOPPED'
        (Get-DriverStatus -StatusPath $statusPath).globalStatus | Should Be 'RUNNING'
    }

    It 'Seg. 3: con -GlobalStatus FAILED, -Reason y -Cause escribe FAILED y el evento con esa causa' {
        $statusPath = New-TestStatus 'failed'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 4 -SessionId 's-4' | Out-Null

        $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $null -LogFile 'd.log' -GlobalStatus FAILED -Reason 'error no controlado del driver: x' -Cause 'error_driver'

        $s = Get-DriverStatus -StatusPath $statusPath
        $s.globalStatus | Should Be 'FAILED'
        $s.reason | Should Be 'error no controlado del driver: x'
        @($s.history)[-1].cause | Should Be 'error_driver'
        $r.EventAdded | Should Be $true
        $r.StopWritten | Should Be $true
    }

    It 'Seg. 3: -GlobalStatus rechaza un estado fuera de STOPPED y FAILED' {
        $statusPath = New-TestStatus 'badstatus'

        # Should Throw sin mensaje falla en Pester 3.4 sobre PS7; con mensaje esperado funciona.
        { Invoke-DriverInterruptCleanup -StatusPath $statusPath -GlobalStatus DONE } | Should Throw 'STOPPED,FAILED'
    }

    It 'Seg. 5b: si el proceso sigue vivo tras KillTree, el aviso incluye el Message de KillTree' {
        $statusPath = New-TestStatus 'nokillmsg'
        Set-DriverStatusCurrentSession -StatusPath $statusPath -Iter 5 -SessionId 's-5' | Out-Null
        $proc = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
        try {
            $kill = { param($ProcessId) [pscustomobject]@{ Method = 'failed'; Message = 'motivo simulado' } }

            $r = Invoke-DriverInterruptCleanup -StatusPath $statusPath -Process $proc -LogFile 'e.log' -KillTree $kill -ExitWaitMilliseconds 200 -WarningVariable w -WarningAction SilentlyContinue

            ($w -join ' ') | Should Match 'sigue vivo'
            ($w -join ' ') | Should Match 'Motivo: motivo simulado'
            $r.KilledPid | Should BeNullOrEmpty
            (Test-ProcessAlive $proc.Id) | Should Be $true
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'F3: el comentario describe que claude corre sin consola' {
        $t = Get-Content -LiteralPath (Join-Path $moduleRoot 'scripts\modules\DriverInterrupt.psm1') -Raw
        $t | Should Match 'claude corre sin consola'
        $t | Should Not Match 'comparte consola'
    }

    It 'Stop-ProcessTree mata el arbol completo' {
        $pidFile = Join-Path $TestDrive 'child.pid'
        $parentScript = Join-Path $TestDrive 'parent-tree.ps1'
        Set-Content -LiteralPath $parentScript -Encoding utf8 -Value @"
`$c = Start-Process -FilePath '$pwshPath' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -WindowStyle Hidden
Set-Content -LiteralPath '$pidFile' -Value `$c.Id
Start-Sleep 120
"@
        $parent = Start-Process -FilePath $pwshPath -ArgumentList '-NoProfile', '-File', $parentScript -PassThru -WindowStyle Hidden
        $childPid = $null
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and $null -eq $childPid) {
                if (Test-Path -LiteralPath $pidFile) {
                    $txt = (Get-Content -LiteralPath $pidFile -Raw)
                    if ($txt -and $txt.Trim() -match '^\d+$') { $childPid = [int]$txt.Trim() }
                }
                if ($null -eq $childPid) { Start-Sleep -Milliseconds 100 }
            }
            $childPid | Should Not BeNullOrEmpty

            $r = Stop-ProcessTree -ProcessId $parent.Id

            $r.Method | Should Be 'taskkill'
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline -and ((Test-ProcessAlive $parent.Id) -or (Test-ProcessAlive $childPid))) {
                Start-Sleep -Milliseconds 100
            }
            (Test-ProcessAlive $parent.Id) | Should Be $false
            (Test-ProcessAlive $childPid) | Should Be $false
        }
        finally {
            if ($null -ne $parent) { Stop-Process -Id $parent.Id -Force -ErrorAction SilentlyContinue }
            if ($null -ne $childPid) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'Stop-ProcessTree con un pid inexistente no lanza y devuelve failed o Stop-Process' {
        { Stop-ProcessTree -ProcessId 999999 | Out-Null } | Should Not Throw
        $r = Stop-ProcessTree -ProcessId 999999
        $r.Method | Should Not Be 'taskkill'
    }
}

Describe 'plan-session-driver (Ola 1b: dashboard Python, I1, I2, B-4, D-A3)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-DriverParam([string]$Name) {
        return ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    }

    function Get-CallParams($Call) {
        return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    }

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    It 'el script se parsea sin errores' {
        $errors.Count | Should Be 0
    }

    It 'declara -DashboardIdleMinutes con default 120' {
        $p = Get-DriverParam 'DashboardIdleMinutes'
        $p | Should Not BeNullOrEmpty
        $p.DefaultValue.Extent.Text | Should Be '120'
        ($p.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(1, 10080\)'
    }

    It 'importa DriverInterrupt.psm1' {
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'DriverInterrupt\.psm1'\) -Force"
    }

    It 'lanza el dashboard con Start-DriverDashboard pasando -Port e -IdleMinutes, y ya no usa el HttpListener' {
        $calls = Get-DriverCalls 'Start-DriverDashboard'
        $calls.Count | Should Be 1
        $p = Get-CallParams $calls[0]
        ($p -contains 'Port') | Should Be $true
        ($p -contains 'IdleMinutes') | Should Be $true
        (Get-DriverCalls 'Start-DriverHttpListener').Count | Should Be 0
        (Get-DriverCalls 'Stop-DriverHttpListener').Count | Should Be 0
        (Get-DriverCalls 'Stop-DriverDashboard').Count | Should Be 0
    }

    It 'I1: no queda Start-Sleep -Seconds 10 y el mensaje final anuncia el apagado por inactividad' {
        $text | Should Not Match 'Start-Sleep\s+-Seconds\s+10'
        $text | Should Match 'sin uso'
    }

    It 'I2: la llamada de lanzamiento a Set-DriverStatusCurrentSession pasa StreamFile, ErrFile y LivenessTimeoutMinutes' {
        $calls = @(Get-DriverCalls 'Set-DriverStatusCurrentSession' | Where-Object { $_.Extent.Text -match '-SessionId\s+\$sessionId\b' })
        $calls.Count | Should Be 1
        $p = Get-CallParams $calls[0]
        foreach ($name in @('StreamFile', 'ErrFile', 'LivenessTimeoutMinutes')) {
            ($p -contains $name) | Should Be $true
        }
    }

    It 'I2: Set-DriverStatusHeartbeat con -LastProgressAt se llama dentro del bucle while del watchdog' {
        $calls = @(Get-DriverCalls 'Set-DriverStatusHeartbeat' | Where-Object { (Get-CallParams $_) -contains 'LastProgressAt' })
        $calls.Count | Should Be 1
        $node = $calls[0].Parent
        $inWatchdog = $false
        while ($node) {
            if ($node -is [System.Management.Automation.Language.WhileStatementAst] -and $node.Condition.Extent.Text -match 'HasExited') {
                $inWatchdog = $true
                break
            }
            $node = $node.Parent
        }
        $inWatchdog | Should Be $true
    }

    It 'todas las llamadas a Add-DriverStatusEvent pasan StreamFile y ErrFile' {
        $calls = Get-DriverCalls 'Add-DriverStatusEvent'
        $calls.Count | Should Be 1
        foreach ($c in $calls) {
            $p = Get-CallParams $c
            ($p -contains 'StreamFile') | Should Be $true
            ($p -contains 'ErrFile') | Should Be $true
        }
    }

    It 'B-4: Invoke-DriverInterruptCleanup se llama dentro de un bloque finally y el camino colgada usa Stop-ProcessTree' {
        # Dos llamadas (2b): la del finally exterior y la de A3 (detener desde el dashboard), fuera de todo finally.
        $calls = Get-DriverCalls 'Invoke-DriverInterruptCleanup'
        $calls.Count | Should Be 2
        $inFinallyFlags = @()
        foreach ($call in $calls) {
            $node = $call.Parent
            $inFinally = $false
            while ($node) {
                if ($node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Finally -and
                    $node.Finally.Extent.StartOffset -le $call.Extent.StartOffset -and
                    $node.Finally.Extent.EndOffset -ge $call.Extent.EndOffset) {
                    $inFinally = $true
                    break
                }
                $node = $node.Parent
            }
            $inFinallyFlags += $inFinally
        }
        @($inFinallyFlags | Where-Object { $_ }).Count | Should Be 1
        $outside = @($calls | Where-Object { $_.Extent.Text -match "-Cause\s+'dashboard'" })
        $outside.Count | Should Be 1
        $outside[0].Extent.Text | Should Match "-Cause\s+'dashboard'"
        # Dos llamadas: el camino colgada y el catch del bucle (ver el It siguiente).
        (Get-DriverCalls 'Stop-ProcessTree').Count | Should Be 2
        # Por AST: el aviso de texto y los comentarios no son CommandAst.
        (Get-DriverCalls 'taskkill').Count | Should Be 0
    }

    It 'el catch del bucle mata el arbol de claude si sigue vivo, antes de tocar el status' {
        # Tras FAILED el finally no limpia (Invoke-DriverInterruptCleanup solo actua con
        # RUNNING): sin esto quedaria un claude con permisos saltados sin supervision.
        $catch = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CatchClauseAst] -and
                    $n.Body.Extent.Text -match '\$finalReason = "error no controlado del driver' }, $true))
        $catch.Count | Should Be 1
        $kills = @($catch[0].Body.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-ProcessTree' }, $true))
        $kills.Count | Should Be 1
        $guard = $kills[0].Parent
        while ($guard -and -not ($guard -is [System.Management.Automation.Language.IfStatementAst])) { $guard = $guard.Parent }
        $guard | Should Not BeNullOrEmpty
        $guard.Clauses[0].Item1.Extent.Text | Should Match 'HasExited'
        $sets = @($catch[0].Body.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-DriverStatusCurrentSession' }, $true))
        $sets.Count | Should Be 1
        $kills[0].Extent.StartOffset | Should BeLessThan $sets[0].Extent.StartOffset
    }

    It 'B-4: los catch del script relanzan PipelineStoppedException' {
        # Por AST: un catch cuenta si contiene un if cuya condicion menciona
        # PipelineStoppedException y cuya clausula tiene un throw sin expresion (relanzar).
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $rethrows = @($catches | Where-Object {
                $c = $_
                $ifs = @($c.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))
                @($ifs | Where-Object {
                        $ifAst = $_
                        $hit = $false
                        foreach ($clause in $ifAst.Clauses) {
                            if ($clause.Item1.Extent.Text -match 'PipelineStoppedException') {
                                $bareThrows = @($clause.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] -and $null -eq $n.Pipeline }, $true))
                                if ($bareThrows.Count -gt 0) { $hit = $true }
                            }
                        }
                        $hit
                    }).Count -gt 0
            })
        $rethrows.Count | Should Be 2
    }

    It 'D-A3: la linea del codigo de tarea esta en las dos variantes del prompt de nivel, despues del ancla' {
        $o = [string][char]0xF3
        $anchorMarker = ([string][char]0xDA) + 'NICAMENTE el pr' + $o + 'ximo nivel'
        $line = 'Cada vez que despaches un subagente, empieza su `description` con el c{o}digo de la tarea del plan (por ejemplo, ' +
            [string][char]0xAB + 'T4 implementar transiciones' + [string][char]0xBB + ' o ' + [string][char]0xAB + 'T4 revisi{o}n de calidad' + [string][char]0xBB +
            '). Si el despacho no corresponde a una tarea, no pongas c{o}digo.'
        $line = $line.Replace('{o}', $o)
        $headless = 'Esta sesi' + $o + 'n corre en modo headless'

        $strings = @($ast.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                    $n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                    $n.Value.Contains($anchorMarker) }, $true))
        $strings.Count | Should Be 2
        foreach ($s in $strings) {
            $v = $s.Value -replace '\s+', ' '
            $anchor = if ($v.Contains('detente sin empezar el siguiente nivel.')) { 'detente sin empezar el siguiente nivel.' } else { 'empezar el siguiente.' }
            $iAnchor = $v.IndexOf($anchor, [System.StringComparison]::Ordinal)
            $iLine = $v.IndexOf($line, [System.StringComparison]::Ordinal)
            $iHeadless = $v.IndexOf($headless, [System.StringComparison]::Ordinal)
            $iAnchor | Should Not Be -1
            $iLine | Should Not Be -1
            $iHeadless | Should Not Be -1
            ($iLine -gt $iAnchor) | Should Be $true
            ($iLine -lt $iHeadless) | Should Be $true
        }
    }

    It 'DT-19: el limite de re-revisiones esta en las dos variantes del prompt de nivel, entre el ancla y el modo headless' {
        $o = [string][char]0xF3
        $anchorMarker = ([string][char]0xDA) + 'NICAMENTE el pr' + $o + 'ximo nivel'
        $limite = 'L' + [string][char]0xED + 'mite de re-revisiones'
        $headless = 'Esta sesi' + $o + 'n corre en modo headless'
        $requeridos = @(
            ('como m' + [string][char]0xE1 + 'ximo 3 re-revisiones'),
            'DONE_WITH_CONCERNS',
            'campo concerns',
            'prevalece sobre las instrucciones de la skill'
        )

        $strings = @($ast.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                    $n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                    $n.Value.Contains($anchorMarker) }, $true))
        $strings.Count | Should Be 2
        foreach ($s in $strings) {
            $v = $s.Value -replace '\s+', ' '
            $anchor = if ($v.Contains('detente sin empezar el siguiente nivel.')) { 'detente sin empezar el siguiente nivel.' } else { 'empezar el siguiente.' }
            $iAnchor = $v.IndexOf($anchor, [System.StringComparison]::Ordinal)
            $iLimite = $v.IndexOf($limite, [System.StringComparison]::Ordinal)
            $iHeadless = $v.IndexOf($headless, [System.StringComparison]::Ordinal)
            $iAnchor | Should Not Be -1
            $iLimite | Should Not Be -1
            $iHeadless | Should Not Be -1
            ($iLimite -gt $iAnchor) | Should Be $true
            ($iLimite -lt $iHeadless) | Should Be $true
            foreach ($r in $requeridos) { $v.Contains($r) | Should Be $true }
        }
    }
}

Describe 'plan-session-driver (Ola 1c: seguimientos de 1b)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-CallParams($Call) {
        return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    }

    function Get-OuterTry {
        $tries = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $n.Finally -and
                    @($n.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-DriverInterruptCleanup' }, $true)).Count -gt 0
                }, $true))
        if ($tries.Count -ne 1) { throw "se esperaba 1 try exterior con el cleanup en el finally, hay $($tries.Count)" }
        return $tries[0]
    }

    function Get-DriverFailedAssignments($Root, [string]$ValueText) {
        return @($Root.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'driverFailed' -and
                    $n.Right.Extent.Text -eq $ValueText
                }, $true))
    }

    It 'inicializa $driverFailed en $false antes del try exterior y lo pone en $true en el catch exterior' {
        $try = Get-OuterTry
        $inits = Get-DriverFailedAssignments $ast '$false'
        $inits.Count | Should Be 1
        ($inits[0].Extent.StartOffset -lt $try.Extent.StartOffset) | Should Be $true

        $sets = @()
        foreach ($c in $try.CatchClauses) { $sets += Get-DriverFailedAssignments $c.Body '$true' }
        $sets.Count | Should Be 1
    }

    It 'el finally pasa -GlobalStatus, -Reason y -Cause al cleanup, condicionados por $driverFailed' {
        $try = Get-OuterTry
        $call = @($try.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-DriverInterruptCleanup' }, $true))[0]
        $els = @($call.CommandElements)
        foreach ($name in 'GlobalStatus', 'Reason', 'Cause') {
            $idx = -1
            for ($i = 0; $i -lt $els.Count; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $name) { $idx = $i; break }
            }
            if ($idx -lt 0) { throw "falta el parametro -$name en la llamada al cleanup" }
            $arg = if ($null -ne $els[$idx].Argument) { $els[$idx].Argument } else { $els[$idx + 1] }
            $arg.Extent.Text | Should Match '\$driverFailed'
        }
    }

    It 'los mensajes de Ctrl+C solo estan en la rama sin $driverFailed' {
        $try = Get-OuterTry
        $stoppedIf = @($try.Finally.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -eq "`$interrupt.Action -eq 'stopped'"
                }, $true))
        $stoppedIf.Count | Should Be 1
        $body = $stoppedIf[0].Clauses[0].Item2

        $ifs = @($body.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -match '\$driverFailed' -and
                    $n.Parent -isnot [System.Management.Automation.Language.CommandAst] -and
                    $n.Parent -isnot [System.Management.Automation.Language.SubExpressionAst]
                }, $true) | Where-Object { $_.Parent -eq $body })
        $ifs.Count | Should Be 1
        $if = $ifs[0]
        if ($null -eq $if.ElseClause) { throw 'el if de $driverFailed no tiene else' }

        $isNegated = $if.Clauses[0].Item1.Extent.Text -match '^\s*-not\s'
        $ctrlcBranch = if ($isNegated) { $if.Clauses[0].Item2 } else { $if.ElseClause }
        $failBranch = if ($isNegated) { $if.ElseClause } else { $if.Clauses[0].Item2 }

        $isString = { param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
            $n.Value.Contains('Interrumpido con Ctrl+C') }

        @($failBranch.FindAll($isString, $true)).Count | Should Be 0

        $all = @($body.FindAll($isString, $true))
        $all.Count | Should BeGreaterThan 0
        foreach ($s in $all) {
            $inside = ($s.Extent.StartOffset -ge $ctrlcBranch.Extent.StartOffset) -and ($s.Extent.EndOffset -le $ctrlcBranch.Extent.EndOffset)
            if (-not $inside) { throw "mensaje de Ctrl+C fuera de la rama sin driverFailed: $($s.Extent.Text)" }
        }
    }

    It 'Seg. 1: el finally consulta StopWritten y tiene el mensaje de STOPPED no escrito' {
        $text | Should Match '\$interrupt\.StopWritten'
        $text | Should Match 'no se pudo escribir STOPPED'
    }
}

Describe 'plan-session-driver (Ola 1a-driver: D2 y D7)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-CallParams($Call) {
        return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    }

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    function Get-OuterTry {
        $tries = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $n.Finally -and
                    @($n.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-DriverInterruptCleanup' }, $true)).Count -gt 0
                }, $true))
        if ($tries.Count -ne 1) { throw "se esperaba 1 try exterior con el cleanup en el finally, hay $($tries.Count)" }
        return $tries[0]
    }

    function Get-ParamArgText($Call, [string]$Name) {
        $els = @($Call.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
                $arg = if ($null -ne $els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] }
                return $arg.Extent.Text
            }
        }
        throw "falta el parametro -$Name"
    }

    function Test-InTryWithWarningCatch($Node) {
        $n = $Node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.TryStatementAst]) {
                $inBody = ($Node.Extent.StartOffset -ge $n.Body.Extent.StartOffset) -and ($Node.Extent.EndOffset -le $n.Body.Extent.EndOffset)
                if ($inBody) {
                    foreach ($c in $n.CatchClauses) {
                        $w = @($c.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Write-Warning' }, $true))
                        if ($w.Count -gt 0) { return $true }
                    }
                }
            }
            $n = $n.Parent
        }
        return $false
    }

    function Get-NearestWhile($Node) {
        $n = $Node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.WhileStatementAst]) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    function Test-IfBetween($Node, $Stop) {
        $n = $Node.Parent
        while ($n -and $n -ne $Stop) {
            if ($n -is [System.Management.Automation.Language.IfStatementAst]) { return $true }
            $n = $n.Parent
        }
        return $false
    }

    It 'D7: antes del try exterior decide el primer modo, archiva el status previo, evalua la herencia y crea el status, en ese orden' {
        $decision = @(Get-DriverCalls 'Get-PlanBootstrapDecision')[0]
        $archive = @(Get-DriverCalls 'Save-DriverStatusArchive')[0]
        $inherit = @(Get-DriverCalls 'Test-DriverStatusInheritable')[0]
        $create = @(Get-DriverCalls 'New-DriverStatus')[0]
        $decision | Should Not BeNullOrEmpty
        $archive | Should Not BeNullOrEmpty
        $inherit | Should Not BeNullOrEmpty
        $create | Should Not BeNullOrEmpty
        ($decision.Extent.StartOffset -lt $archive.Extent.StartOffset) | Should Be $true
        ($archive.Extent.StartOffset -lt $inherit.Extent.StartOffset) | Should Be $true
        ($inherit.Extent.StartOffset -lt $create.Extent.StartOffset) | Should Be $true
        ($create.Extent.StartOffset -lt (Get-OuterTry).Extent.StartOffset) | Should Be $true
    }

    It 'D7: New-DriverStatus recibe HeartbeatSeconds, PreviousRun e InheritFrom' {
        $calls = Get-DriverCalls 'New-DriverStatus'
        $calls.Count | Should Be 1
        $p = Get-CallParams $calls[0]
        foreach ($name in @('HeartbeatSeconds', 'PreviousRun', 'InheritFrom')) {
            ($p -contains $name) | Should Be $true
        }
        (Get-ParamArgText $calls[0] 'HeartbeatSeconds') | Should Be '$LivenessPollSeconds'
    }

    It 'D7: el archivado y la herencia son tolerantes a fallo' {
        foreach ($name in @('Save-DriverStatusArchive', 'Test-DriverStatusInheritable')) {
            $calls = Get-DriverCalls $name
            $calls.Count | Should Be 1
            (Test-InTryWithWarningCatch $calls[0]) | Should Be $true
        }
    }

    It 'D7: heartbeat sin condicion al inicio de cada iteracion, tras Set-DriverStatusCurrentSession, en cada vuelta del watchdog y tras Save-SessionStreamLog' {
        $calls = Get-DriverCalls 'Set-DriverStatusHeartbeat'
        $calls.Count | Should Be 5

        $sessionCalls = @()
        $attemptCalls = @()
        $watchdogCalls = @()
        $tickCalls = @()
        foreach ($c in $calls) {
            # La quinta llamada va dentro del argumento -OnTick de Wait-RetryBackoff.
            $inWait = $false
            $p = $c.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Wait-RetryBackoff') { $inWait = $true; break }
                $p = $p.Parent
            }
            if ($inWait) { $tickCalls += $c; continue }

            $w = Get-NearestWhile $c
            if ($null -eq $w) { throw 'heartbeat fuera de un while' }
            (Test-IfBetween $c $w) | Should Be $false
            if ($w.Condition.Extent.Text -match 'HasExited') { $watchdogCalls += $c }
            elseif ($w.Condition.Extent.Text -match '\(\$iter - \$iterBase\) -lt \$sessionBudget') { $sessionCalls += $c }
            elseif ($w.Condition.Extent.Text -eq '$true') { $attemptCalls += $c }
            else { throw "heartbeat en un while inesperado: $($w.Condition.Extent.Text)" }
        }
        $sessionCalls.Count | Should Be 1
        $attemptCalls.Count | Should Be 2
        $watchdogCalls.Count | Should Be 1
        $tickCalls.Count | Should Be 1

        $sessionWhile = Get-NearestWhile $sessionCalls[0]
        $sorted = @($attemptCalls | Sort-Object { $_.Extent.StartOffset })
        $findIn = { param($name) @($sessionWhile.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)) }

        $decisionInLoop = (& $findIn 'Get-PlanBootstrapDecision')[0]
        ($sessionCalls[0].Extent.StartOffset -lt $decisionInLoop.Extent.StartOffset) | Should Be $true

        $current = @(& $findIn 'Set-DriverStatusCurrentSession' | Where-Object { $_.Extent.Text -match '-SessionId\s+\$sessionId\b' })[0]
        ($sorted[0].Extent.StartOffset -gt $current.Extent.StartOffset) | Should Be $true

        $saves = @(& $findIn 'Save-SessionStreamLog' | Sort-Object { $_.Extent.StartOffset })
        ($sorted[1].Extent.StartOffset -gt $saves[-1].Extent.StartOffset) | Should Be $true

        (Get-DriverCalls 'Set-DriverStatusLiveness').Count | Should Be 0
    }

    It 'D7: la numeracion de sesiones continua desde la herencia' {
        $assigns = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'iter' -and
                    $n.Right.Extent.Text -eq '$iterBase'
                }, $true))
        $assigns.Count | Should BeGreaterThan 0
        (Get-DriverCalls 'Get-DriverStatusMaxIter').Count | Should BeGreaterThan 0
        $resolve = Get-DriverCalls 'Resolve-BootstrapBranchAction'
        $resolve.Count | Should Be 1
        (Get-ParamArgText $resolve[0] 'IsFirstIteration') | Should Match '\$iterBase'
        $text | Should Not Match '\$iter -eq 0'
    }

    It 'D2: con CompletedBy current_level publica currentLevel igual a totalLevels, el motivo y el aviso en consola' {
        $ifs = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -match 'CompletedBy' -and
                    $n.Clauses[0].Item1.Extent.Text -match "'current_level'"
                }, $true))
        $ifs.Count | Should BeGreaterThan 0
        $body = $ifs[0].Clauses[0].Item2
        $find = { param($name) @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)) }
        $progress = & $find 'Set-DriverStatusProgress'
        $progress.Count | Should Be 1
        (Get-ParamArgText $progress[0] 'CurrentLevel') | Should Match 'TotalLevels'
        (& $find 'Set-DriverStatusReason').Count | Should Be 1
        (& $find 'Write-Host').Count | Should BeGreaterThan 0
        $text | Should Match 'Plan completo según current_level \(completed_levels'
    }

    It '1a-3: el progreso y el motivo de D2 van en try separados' {
        $ifs = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -match 'CompletedBy' -and
                    $n.Clauses[0].Item1.Extent.Text -match "'current_level'"
                }, $true))
        $ifs.Count | Should BeGreaterThan 0
        $body = $ifs[0].Clauses[0].Item2
        $find = { param($name) @($body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)) }
        $nearestTry = {
            param($node)
            $n = $node.Parent
            while ($n -and -not ($n -is [System.Management.Automation.Language.TryStatementAst])) { $n = $n.Parent }
            return $n
        }
        $progress = @(& $find 'Set-DriverStatusProgress')
        $reason = @(& $find 'Set-DriverStatusReason')
        $progress.Count | Should Be 1
        $reason.Count | Should Be 1
        $tryP = & $nearestTry $progress[0]
        $tryR = & $nearestTry $reason[0]
        $tryP | Should Not BeNullOrEmpty
        $tryR | Should Not BeNullOrEmpty
        ($tryP.Extent.StartOffset -ne $tryR.Extent.StartOffset) | Should Be $true
        foreach ($t in @($tryP, $tryR)) {
            $warn = @($t.CatchClauses | ForEach-Object { $_.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Write-Warning' }, $true) })
            $warn.Count | Should BeGreaterThan 0
        }
    }

    It 'D2 persistente: la publicacion tras la sesion usa TotalLevels si la iteracion cerro por current_level' {
        $assigns = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'progressLevel' -and
                    $n.Right.Extent.Text -eq '$decision.TotalLevels'
                }, $true))
        $assigns.Count | Should Be 1

        # Walk up hasta el if que condiciona la asignacion: debe exigir CompletedBy current_level.
        $n = $assigns[0].Parent
        while ($n -and -not ($n -is [System.Management.Automation.Language.IfStatementAst])) { $n = $n.Parent }
        $n | Should Not BeNullOrEmpty
        $n.Clauses[0].Item1.Extent.Text | Should Match 'CompletedBy'
        $n.Clauses[0].Item1.Extent.Text | Should Match "'current_level'"

        $publish = @($ast.FindAll({ param($c)
                    $c -is [System.Management.Automation.Language.CommandAst] -and
                    $c.GetCommandName() -eq 'Set-DriverStatusProgress' -and
                    $c.Extent.Text -match '-CurrentLevel\s+\$progressLevel\b'
                }, $true))
        $publish.Count | Should Be 1
        ($publish[0].Extent.StartOffset -gt $assigns[0].Extent.StartOffset) | Should Be $true
    }
}

Describe 'plan-session-driver (Ola 1b-driver: D1 y D5)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-CallParams($Call) {
        return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
    }

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    function Get-OuterTry {
        $tries = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.TryStatementAst] -and
                    $null -ne $n.Finally -and
                    @($n.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-DriverInterruptCleanup' }, $true)).Count -gt 0
                }, $true))
        if ($tries.Count -ne 1) { throw "se esperaba 1 try exterior con el cleanup en el finally, hay $($tries.Count)" }
        return $tries[0]
    }

    function Get-DriverParam([string]$Name) {
        return ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    }

    function Get-ParamArgNode($Call, [string]$Name) {
        $els = @($Call.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
                return $(if ($null -ne $els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] })
            }
        }
        throw "falta el parametro -$Name"
    }

    function Get-NearestTry($Node) {
        $n = $Node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.TryStatementAst]) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    It 'declara -MaxTransientRetries 2, -RetryBackoffSeconds 60, 300, -NotifyUrl vacio y -NoToast' {
        $max = Get-DriverParam 'MaxTransientRetries'
        $max | Should Not BeNullOrEmpty
        $max.DefaultValue.Extent.Text | Should Be '2'
        ($max.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(0, 10\)'

        $backoff = Get-DriverParam 'RetryBackoffSeconds'
        $backoff | Should Not BeNullOrEmpty
        $backoff.DefaultValue.Extent.Text | Should Be '@(60, 300)'
        ($backoff.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(0, 86400\)'

        $url = Get-DriverParam 'NotifyUrl'
        $url | Should Not BeNullOrEmpty
        $url.DefaultValue.Extent.Text | Should Be "''"

        $toast = Get-DriverParam 'NoToast'
        $toast | Should Not BeNullOrEmpty
        $toast.StaticType.Name | Should Be 'SwitchParameter'
    }

    It 'D1: un solo Add-DriverStatusEvent con los campos de reintento' {
        $calls = Get-DriverCalls 'Add-DriverStatusEvent'
        $calls.Count | Should Be 1
        $p = Get-CallParams $calls[0]
        foreach ($name in @('Attempt', 'FailureKind', 'FailureMatch', 'ResumedSessionId', 'PriorCause', 'TransientRetries')) {
            ($p -contains $name) | Should Be $true
        }
    }

    It 'D1: clasifica una vez y espera con heartbeat y motivo de reintento' {
        (Get-DriverCalls 'Get-SessionFailureKind').Count | Should Be 1
        $waits = Get-DriverCalls 'Wait-RetryBackoff'
        $waits.Count | Should Be 1
        $onTick = (Get-ParamArgNode $waits[0] 'OnTick').Extent.Text
        $onTick | Should Match 'Set-DriverStatusHeartbeat'
        $onTick | Should Not Match 'LastProgressAt'

        $text | Should Match 'Reintento \$k/\$MaxTransientRetries en \$delay s \(\$cause\)'
        $reasons = @(Get-DriverCalls 'Set-DriverStatusReason' | Where-Object { $_.Extent.Text -match '-Reason\s+\$retryText\b' })
        $reasons.Count | Should Be 1

        # No se reintenta si el proceso de la sesion colgada sigue vivo tras el kill.
        $text.Contains('$killedOk = $proc.HasExited') | Should Be $true
        $canRetryAssigns = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'canRetry'
                }, $true))
        $canRetryAssigns.Count | Should Be 1
        $canRetryAssigns[0].Right.Extent.Text | Should Match '\$killedOk'
    }

    It 'D1: el kill solo cuenta como confirmado si taskkill fue el metodo (no reanuda tras Stop-Process)' {
        $killedAssigns = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'killedOk'
                }, $true))
        $guarded = @($killedAssigns | Where-Object { $_.Right.Extent.Text -eq "`$proc.HasExited -and `$kill.Method -eq 'taskkill'" })
        $guarded.Count | Should Be 1
        # La guarda vive en la rama colgada, no en la salida normal (que sigue con $true).
        $hungBranch = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -eq '$hung' -and
                    @($n.Clauses[0].Item2.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Stop-ProcessTree' }, $true)).Count -gt 0
                }, $true))
        $hungBranch.Count | Should Be 1
        $guarded[0].Extent.StartOffset -ge $hungBranch[0].Clauses[0].Item2.Extent.StartOffset | Should Be $true
        $guarded[0].Extent.EndOffset -le $hungBranch[0].Clauses[0].Item2.Extent.EndOffset | Should Be $true
    }

    It 'D1: evalua Test-ResumeSessionMissing antes de Wait-RetryBackoff y usa espera 0 si el resume no existe' {
        $missing = Get-DriverCalls 'Test-ResumeSessionMissing'
        $waits = Get-DriverCalls 'Wait-RetryBackoff'
        $missing.Count | Should Be 1
        $waits.Count | Should Be 1
        ($missing[0].Extent.StartOffset -lt $waits[0].Extent.StartOffset) | Should Be $true

        $resumeAssigns = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'resumeMissing'
                }, $true))
        $resumeAssigns.Count | Should Be 1
        $resumeAssigns[0].Right.Extent.Text | Should Match 'Test-ResumeSessionMissing'
        ($resumeAssigns[0].Extent.StartOffset -lt $waits[0].Extent.StartOffset) | Should Be $true

        $text | Should Match '\$delay = if \(\$resumeMissing\) \{ 0 \} else \{ Get-RetryDelaySeconds'
        ($ast.Extent.Text.Contains('if ($resumeMissing) {')) | Should Be $true
    }

    It 'D1: restaura el motivo previo (-Reason $reasonBeforeRetry) despues de Wait-RetryBackoff' {
        $waits = Get-DriverCalls 'Wait-RetryBackoff'
        $waits.Count | Should Be 1
        $restores = @(Get-DriverCalls 'Set-DriverStatusReason' | Where-Object { $_.Extent.Text -match '-Reason\s+\$reasonBeforeRetry\b' })
        $restores.Count | Should Be 1
        ($restores[0].Extent.StartOffset -gt $waits[0].Extent.StartOffset) | Should Be $true
    }

    It 'D1: los reintentos no tocan $iter ni el presupuesto' {
        ([regex]::Matches($text, '\$iter\+\+')).Count | Should Be 1

        $attemptLoops = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -eq '$true'
                }, $true))
        $attemptLoops.Count | Should Be 1
        $assigns = @($attemptLoops[0].Body.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'iter'
                }, $true))
        $assigns.Count | Should Be 0

        $sessionLoops = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.WhileStatementAst] -and
                    $n.Condition.Extent.Text -match '\(\$iter - \$iterBase\) -lt \$sessionBudget'
                }, $true))
        $sessionLoops.Count | Should Be 1
    }

    It 'D1: nombres session-N-rK-<sello> para los archivos de un reintento' {
        $text | Should Match 'session-\$iter-r\$attempt-\$attemptStamp\.log'
        $text | Should Match 'session-\$iter-r\$attempt-\$attemptStamp\.err\.log'
        $text | Should Match 'session-\$iter-r\$attempt-\$attemptStamp\.stream\.jsonl'
        $text | Should Match "\`$attemptStamp = Get-Date -Format 'yyyyMMdd-HHmmss'"
        $text | Should Match 'session-\$iter-\$timestamp\.stream\.jsonl'
        $text | Should Not Match 'session-\$iter-r\$attempt\.'
    }

    It 'D1: reanuda con --resume y el prompt de reanudacion, y cae a sesion nueva con Test-ResumeSessionMissing' {
        # Tres llamadas (2c): las dos de D1 y la que prepara el intento de Invoke-DriverAwaitPoint.
        $calls = Get-DriverCalls 'ConvertTo-RetryClaudeArgs'
        $calls.Count | Should Be 3
        $resume = @($calls | Where-Object { $_.Extent.Text -match "-SessionFlag\s+'--resume'" -and $_.Extent.Text -match '-Prompt\s+\(Get-ResumePrompt\)' })
        $resume.Count | Should Be 1
        $fresh = @($calls | Where-Object { $_.Extent.Text -match "-SessionFlag\s+'--session-id'" -and $_.Extent.Text -match '-Prompt\s+\$promptText\b' })
        $fresh.Count | Should Be 1
        $awaitFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DriverAwaitPoint' }, $true))
        $awaitFn.Count | Should Be 1
        $inAwait = @($calls | Where-Object { $_.Extent.StartOffset -ge $awaitFn[0].Extent.StartOffset -and $_.Extent.EndOffset -le $awaitFn[0].Extent.EndOffset })
        $inAwait.Count | Should Be 1
        $inAwait[0].Extent.Text | Should Match "-SessionFlag\s+'--resume'"
        $inAwait[0].Extent.Text | Should Match '-Prompt\s+\$resumePrompt\b'
        (Get-DriverCalls 'Test-ResumeSessionMissing').Count | Should Be 1
    }

    It 'D5: el aviso final esta en el finally exterior, despues del cleanup y en su propio try; el de AWAITING en Enter-DriverAwaiting' {
        # Dos llamadas (2c): la del finally exterior y la de Enter-DriverAwaiting (-Status AWAITING).
        $sends = Get-DriverCalls 'Send-DriverNotification'
        $sends.Count | Should Be 2
        $outer = Get-OuterTry
        $finalSends = @($sends | Where-Object { $_.Extent.StartOffset -ge $outer.Finally.Extent.StartOffset -and $_.Extent.EndOffset -le $outer.Finally.Extent.EndOffset })
        $finalSends.Count | Should Be 1
        $send = $finalSends[0]
        $awaitFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Enter-DriverAwaiting' }, $true))
        $awaitFn.Count | Should Be 1
        $awaitSends = @($sends | Where-Object { $_.Extent.StartOffset -ge $awaitFn[0].Extent.StartOffset -and $_.Extent.EndOffset -le $awaitFn[0].Extent.EndOffset })
        $awaitSends.Count | Should Be 1
        $awaitSends[0].Extent.Text | Should Match '-Status\s+AWAITING'

        $outer = Get-OuterTry
        $inFinally = ($send.Extent.StartOffset -ge $outer.Finally.Extent.StartOffset) -and ($send.Extent.EndOffset -le $outer.Finally.Extent.EndOffset)
        $inFinally | Should Be $true

        $cleanup = (Get-DriverCalls 'Invoke-DriverInterruptCleanup')[0]
        ($send.Extent.StartOffset -gt $cleanup.Extent.StartOffset) | Should Be $true

        $sendTry = Get-NearestTry $send
        $cleanupTry = Get-NearestTry $cleanup
        $sendTry | Should Not BeNullOrEmpty
        $cleanupTry | Should Not BeNullOrEmpty
        [object]::ReferenceEquals($sendTry, $cleanupTry) | Should Be $false
        @($sendTry.CatchClauses | Where-Object {
                @($_.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Write-Warning' }, $true)).Count -gt 0
            }).Count | Should BeGreaterThan 0

        $inTry = { param($name) @($sendTry.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)) }
        (& $inTry 'Test-DriverNotificationDue').Count | Should Be 1
        (& $inTry 'Set-DriverStatusNotification').Count | Should Be 1
    }

    It 'D5: pasa NoToast, NotifyUrl y DashboardUrl; ganchos de prueba presentes' {
        $sendCalls = Get-DriverCalls 'Send-DriverNotification'
        $sendCalls.Count | Should Be 2
        foreach ($sendCall in $sendCalls) {
            $p = Get-CallParams $sendCall
            foreach ($name in @('NoToast', 'NotifyUrl', 'DashboardUrl')) {
                ($p -contains $name) | Should Be $true
            }
        }
        $text | Should Match 'PLAN_DRIVER_CLAUDE_PATH'
        $text | Should Match 'PLAN_DRIVER_NO_DASHBOARD'
        $launch = Get-DriverCalls 'Start-HeadlessProcess'
        $launch.Count | Should Be 1
        (Get-ParamArgNode $launch[0] 'ArgumentList').Extent.Text | Should Match 'claudePrefixArgs'
    }
}

Describe 'plan-session-driver (Ola 1b-driver: punta a punta con claude falso)' {
    Import-Module (Join-Path $moduleRoot 'scripts\modules\ProcessLauncher.psm1') -Force
    Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverInterrupt.psm1') -Force
    Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverStatus.psm1') -Force
    Import-Module (Join-Path $moduleRoot 'scripts\modules\SessionRetry.psm1') -Force
    Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverControl.psm1') -Force
    . (Join-Path $moduleRoot 'tests\fixtures\WebhookCapture.ps1')

    $driverScript = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    # PowerShell no distingue mayusculas: el parametro -DriverScript de Invoke-FakeDriverRun taparia a $driverScript.
    $defaultDriverScript = $driverScript
    $fakeClaude = Join-Path $moduleRoot 'tests\fixtures\fake-claude\fake-claude.ps1'
    $planLeaf = '2026-10-27-falso.md'

    function Get-FakePlanPath([string]$Name) {
        return (Join-Path $TestDrive "$Name\docs\superpowers\plans\$planLeaf")
    }

    # Pasos de guion reutilizables.
    function New-FakeStep([int]$ExitCode, [string[]]$Stdout = @(), [string[]]$Stderr = @(), $WriteFiles = $null) {
        return [ordered]@{ exitCode = $ExitCode; stdout = @($Stdout); stderr = @($Stderr); writeFiles = $WriteFiles; sleepSeconds = 0 }
    }
    function Get-StepTransitorio {
        New-FakeStep 1 -Stdout @('{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529,"result":"API Error: 529 Overloaded"}')
    }
    function Get-StepPermanente {
        New-FakeStep 1 -Stdout @('{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":401,"result":"Invalid API key · Please run /login"}')
    }
    function Get-StepSinSesion {
        New-FakeStep 1 -Stderr @('No conversation found with session ID: x')
    }
    function Get-StepNivelOk([string]$Plan) {
        $state = ([ordered]@{ plan = $Plan; completed_levels = @(0); current_level = 1; tasks = [ordered]@{} } | ConvertTo-Json -Compress -Depth 4)
        New-FakeStep 0 -Stdout @('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":"Nivel listo.\nPLAN_STATUS: CONTINUE"}') -WriteFiles ([ordered]@{ 'docs\superpowers\plans\.controller-state.json' = $state })
    }
    function Get-StepCierreOk {
        New-FakeStep 0 -Stdout @('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":"Revisión hecha.\nPLAN_STATUS: COMPLETE"}') -WriteFiles ([ordered]@{ 'docs\superpowers\plans\.final-review-2026-10-27-falso.md' = 'sin hallazgos' })
    }

    # Ola 2c: BLOCKED del modelo, y CONTINUE sin tocar el checkpoint (BLOCKED por regla del driver con -NoProgressRetries 0).
    function Get-StepBloqueado([string]$Motivo) {
        New-FakeStep 0 -Stdout @('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":"Necesito una decision.\nPLAN_STATUS: BLOCKED: ' + $Motivo + '"}')
    }
    function Get-StepContinueSinAvance {
        New-FakeStep 0 -Stdout @('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":"Sigo.\nPLAN_STATUS: CONTINUE"}')
    }

    function Invoke-FakeDriverRun {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][object[]]$Steps,
            [string[]]$DriverArgs = @(),
            [string]$ClaudePath,
            [scriptblock]$AfterInit,
            [scriptblock]$WhileRunning,
            [string]$RetryBackoff = '0',
            [switch]$AwaitHook,
            [string]$OpenLog,
            # Ola 3 (PC-9): driver alternativo (una copia del runner con el perfil roto); sin el se usa el del Describe.
            [string]$DriverScript
        )

        $driverToRun = if ($DriverScript) { $DriverScript } else { $defaultDriverScript }

        # Guarda de seguridad: sin el gancho el driver lanzaria el claude real sin restricciones de permisos.
        if ((Get-Content -LiteralPath $driverToRun -Raw) -notmatch 'PLAN_DRIVER_CLAUDE_PATH') {
            throw 'El driver no tiene el gancho PLAN_DRIVER_CLAUDE_PATH: no se lanza (lanzaria el claude real)'
        }

        $repo = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        git -C $repo init -q | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'docs/' -Encoding ascii
        git -C $repo add .gitignore | Out-Null
        git -C $repo -c user.name=t -c user.email=t@example.com commit -q -m init | Out-Null
        if ($AfterInit) { & $AfterInit $repo }

        $planDir = Join-Path $repo 'docs\superpowers\plans'
        New-Item -ItemType Directory -Path $planDir -Force | Out-Null
        $planLines = @(
            '# Plan falso', '',
            '## Dependency Map', '',
            '| Task | Depends On | Level |',
            '|------|-----------|-------|',
            '| Task 1: Foo | none | 0 |'
        )
        Set-Content -LiteralPath (Join-Path $planDir $planLeaf) -Value $planLines -Encoding utf8

        $scenario = Join-Path $TestDrive "$Name-guion.json"
        Set-Content -LiteralPath $scenario -Value (ConvertTo-Json -InputObject @($Steps) -Depth 6) -Encoding utf8

        $argv = @('-NoProfile', '-File', $driverToRun, '-ProjectPath', $repo, '-PlanFile', $planLeaf,
            '-UseCurrentBranch', '-LivenessPollSeconds', '1', '-LivenessTimeoutMinutes', '1',
            '-RetryBackoffSeconds', $RetryBackoff, '-NoToast') + $DriverArgs

        $names = @('PLAN_DRIVER_CLAUDE_PATH', 'PLAN_DRIVER_NO_DASHBOARD', 'FAKE_CLAUDE_SCENARIO', 'PLAN_DRIVER_AWAIT_WITHOUT_DASHBOARD', 'PLAN_DRIVER_OPEN_LOG')
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        $outFile = Join-Path $TestDrive "$Name-out.txt"
        $errFile = Join-Path $TestDrive "$Name-err.txt"
        try {
            [Environment]::SetEnvironmentVariable('PLAN_DRIVER_CLAUDE_PATH', $(if ($ClaudePath) { $ClaudePath } else { $fakeClaude }))
            [Environment]::SetEnvironmentVariable('PLAN_DRIVER_NO_DASHBOARD', '1')
            [Environment]::SetEnvironmentVariable('FAKE_CLAUDE_SCENARIO', $scenario)
            # Ola 2c: ganchos de AWAITING sin dashboard y de A6 sin abrir ventanas; siempre se fijan (o se vacian) para no heredar el entorno.
            [Environment]::SetEnvironmentVariable('PLAN_DRIVER_AWAIT_WITHOUT_DASHBOARD', $(if ($AwaitHook) { '1' } else { $null }))
            [Environment]::SetEnvironmentVariable('PLAN_DRIVER_OPEN_LOG', $(if ($OpenLog) { $OpenLog } else { $null }))

            $launch = Start-HeadlessProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $argv -StdoutPath $outFile -StderrPath $errFile -WorkingDirectory $repo
            # 4 llamadas como maximo por It x LivenessTimeoutMinutes 1 (60 s, tope del watchdog por intento) + 60 s de margen.
            $timeoutMs = 300000
            # Con -WhileRunning (2b) se espera en vueltas de 250 ms y se llama al guion en cada una; el tope y el kill no cambian.
            $exited = $false
            if ($WhileRunning) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                # Si el guion lanza, se mata el arbol antes de relanzar: un driver en PAUSED viviria hasta AwaitDecisionMinutes.
                try {
                    while (-not $exited -and $sw.ElapsedMilliseconds -lt $timeoutMs) {
                        $exited = $launch.Process.WaitForExit(250)
                        if (-not $exited) { & $WhileRunning $repo }
                    }
                }
                catch {
                    $null = Stop-ProcessTree -ProcessId $launch.Process.Id
                    & $launch.Cleanup
                    throw
                }
            }
            else {
                $exited = $launch.Process.WaitForExit($timeoutMs)
            }
            if (-not $exited) {
                $null = Stop-ProcessTree -ProcessId $launch.Process.Id
                & $launch.Cleanup
                throw "El driver de prueba '$Name' no termino en 300 s; se mato su arbol de procesos"
            }
            & $launch.Cleanup
            $exitCode = $launch.Process.ExitCode
        }
        finally {
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }

        $output = ''
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) { $output += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
        }
        $statusPath = Join-Path $planDir '.driver-status.json'
        $status = if (Test-Path -LiteralPath $statusPath) { Get-DriverStatus -StatusPath $statusPath } else { $null }
        $callsPath = "$scenario.calls.jsonl"
        $calls = @()
        if (Test-Path -LiteralPath $callsPath) {
            $calls = @(Get-Content -LiteralPath $callsPath -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        return [pscustomobject]@{
            Output   = $output
            ExitCode = $exitCode
            Status   = $status
            Calls    = $calls
            LogsDir  = Join-Path $planDir '.driver-logs'
            Repo     = $repo
        }
    }

    # Valor que sigue a una bandera en los argumentos de una llamada del claude falso.
    function Get-FakeArg($Call, [string]$Flag) {
        $a = @($Call.args)
        $i = [Array]::IndexOf($a, $Flag)
        if ($i -lt 0 -or $i + 1 -ge $a.Count) { return $null }
        return $a[$i + 1]
    }

    # Ola 2b: orden de control en la forma de C4 (texto JSON).
    function Get-ControlJson([string]$Id, [string]$Action, $Params = $null) {
        $p = if ($null -eq $Params) { [ordered]@{} } else { $Params }
        return ([ordered]@{ id = $Id; action = $Action; params = $p; requestedAt = '2026-10-27T20:00:00Z' } | ConvertTo-Json -Compress -Depth 4)
    }

    # Escritura atomica como el servidor: .tmp y Move-Item al nombre final.
    function Write-FakeControl([string]$Repo, [string]$Id, [string]$Action, $Params = $null) {
        $dir = Join-Path $Repo 'docs\superpowers\plans'
        $tmp = Join-Path $dir '.driver-control.json.tmp'
        [System.IO.File]::WriteAllText($tmp, (Get-ControlJson -Id $Id -Action $Action -Params $Params), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination (Join-Path $dir '.driver-control.json') -Force
    }

    function Read-FakeStatus([string]$Repo) {
        $path = Join-Path $Repo 'docs\superpowers\plans\.driver-status.json'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        # La lectura puede chocar con una escritura del driver: se devuelve $null y la vuelta siguiente reintenta.
        try { return (Get-DriverStatus -StatusPath $path) } catch { return $null }
    }

    # Paso con la orden escrita por el claude falso (antes de dormir sleepSeconds).
    function Add-StepControl($Step, [string]$Id, [string]$Action, $Params = $null, [int]$SleepSeconds = 3) {
        $wf = [ordered]@{}
        if ($null -ne $Step.writeFiles) { foreach ($k in $Step.writeFiles.Keys) { $wf[$k] = $Step.writeFiles[$k] } }
        $wf['docs\superpowers\plans\.driver-control.json'] = (Get-ControlJson -Id $Id -Action $Action -Params $Params)
        $Step.writeFiles = $wf
        $Step.sleepSeconds = $SleepSeconds
        return $Step
    }

    # Ola 2c: guion de espera comun para -WhileRunning. En la primera vuelta con AWAITING y el aviso ya escrito
    # guarda una copia del status en $State['saved'] y manda la primera orden; cada orden siguiente espera a
    # que control.last.id sea el de la anterior. $Orders: arreglo de @{ Id; Action; Params }.
    function Step-AwaitScript([string]$Repo, [hashtable]$State, [object[]]$Orders) {
        $cur = Read-FakeStatus $Repo
        if (-not $cur) { return }
        if (-not $State.ContainsKey('saved')) {
            if ($cur.globalStatus -eq 'AWAITING' -and $cur.notification) { $State['saved'] = $cur } else { return }
        }
        if ($State['next'] -ge @($Orders).Count) { return }
        if ($State['next'] -gt 0) {
            $prev = @($Orders)[$State['next'] - 1].Id
            if (-not ($cur.control -and $cur.control.last -and $cur.control.last.id -eq $prev)) { return }
        }
        $o = @($Orders)[$State['next']]
        Write-FakeControl -Repo $Repo -Id $o.Id -Action $o.Action -Params $o.Params
        $State['next'] = $State['next'] + 1
    }

    # Procesos vivos cuyo comando incluye la ruta del claude falso de esta corrida.
    function Get-FakeClaudeProcesses {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*fake-claude.ps1*' -and $_.ProcessId -ne $PID })
    }

    It 'D1: transitorio, reintento con --resume y DONE, sin consumir el presupuesto' {
        $name = 'e2e-retry-done'
        $steps = @((Get-StepTransitorio), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -DriverArgs @('-MaxIterations', '2')

        $run.Status.globalStatus | Should Be 'DONE'
        $run.Output | Should Match ([regex]::Escape("Usando claude de prueba: $fakeClaude"))
        $run.Calls.Count | Should Be 3

        $id1 = Get-FakeArg $run.Calls[0] '--session-id'
        $id1 | Should Not BeNullOrEmpty
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be $id1
        (@($run.Calls[1].args) -contains '--session-id') | Should Be $false
        (Get-FakeArg $run.Calls[1] '-p') | Should Be (Get-ResumePrompt)

        $h = @($run.Status.history)
        $h.Count | Should Be 3
        $h[0].iter | Should Be 1
        $h[0].attempt | Should Be 0
        $h[0].cause | Should Be 'exit_no_cero'
        $h[0].failureKind | Should Be 'transient'
        $h[0].failureMatch | Should Be 'http_5xx'
        $h[1].iter | Should Be 1
        $h[1].attempt | Should Be 1
        $h[1].resumedSessionId | Should Be $id1
        $h[1].priorCause | Should Be 'exit_no_cero'
        $h[2].iter | Should Be 2
        $h[2].attempt | Should Be 0

        foreach ($pattern in @('session-1-r1-????????-??????.stream.jsonl', 'session-1-r1-????????-??????.err.log', 'session-1-r1-????????-??????.log')) {
            @(Get-ChildItem -LiteralPath $run.LogsDir -Filter $pattern).Count | Should Be 1
        }
        $streamFile = @(Get-ChildItem -LiteralPath $run.LogsDir -Filter 'session-1-r1-????????-??????.stream.jsonl')[0].Name
        $h[1].streamFile | Should Be $streamFile

        foreach ($e in $h) {
            ($e.PSObject.Properties.Name -contains 'transientRetries') | Should Be $false
        }
    }

    It 'D1: permanente termina en FAILED sin reintento y D5 avisa por webhook local' {
        $name = 'e2e-permanent'
        $cap = Start-WebhookCapture -OutFile (Join-Path $TestDrive 'req-permanent.json')
        try {
            $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepPermanente)) -DriverArgs @('-NotifyUrl', $cap.Url)

            $run.Status.globalStatus | Should Be 'FAILED'
            $run.Status.reason | Should Be 'exit code 1'
            $run.Calls.Count | Should Be 1
            $last = @($run.Status.history)[-1]
            $last.failureKind | Should Be 'permanent'
            $last.failureMatch | Should Be 'http_401'
            $last.transientRetries | Should Be 0

            $req = Get-Content -LiteralPath (Join-Path $TestDrive 'req-permanent.json') -Raw | ConvertFrom-Json
            $req.headers.title | Should Be 'Driver FAILED: 2026-10-27-falso'
            $req.headers.priority | Should Be 'high'

            $run.Status.notification.toast | Should Be 'omitido'
            $run.Status.notification.webhook | Should Be 'ok'
            $run.Status.notification.webhookHost | Should Be '127.0.0.1'

            $raw = Get-Content -LiteralPath (Join-Path $run.Repo 'docs\superpowers\plans\.driver-status.json') -Raw
            $raw | Should Not Match 'mi-topico-secreto'
            $run.Output | Should Not Match 'mi-topico-secreto'
        }
        finally { Stop-WebhookCapture -Capture $cap }
    }

    It 'D1: tope agotado termina en FAILED con transientRetries' {
        $run = Invoke-FakeDriverRun -Name 'e2e-exhausted' -Steps @((Get-StepTransitorio), (Get-StepTransitorio)) -DriverArgs @('-MaxTransientRetries', '1')

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Calls.Count | Should Be 2
        $last = @($run.Status.history)[-1]
        $last.attempt | Should Be 1
        $last.failureKind | Should Be 'transient'
        $last.transientRetries | Should Be 1
        $run.Status.notification.webhook | Should Be 'omitido'
    }

    It 'D1: respaldo con sesion nueva cuando la sesion a reanudar no existe' {
        $name = 'e2e-fallback'
        $steps = @((Get-StepTransitorio), (Get-StepSinSesion), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps

        $run.Status.globalStatus | Should Be 'DONE'
        $run.Calls.Count | Should Be 4

        $id1 = Get-FakeArg $run.Calls[0] '--session-id'
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be $id1
        $id3 = Get-FakeArg $run.Calls[2] '--session-id'
        $id3 | Should Not BeNullOrEmpty
        $id3 | Should Not Be $id1
        (@($run.Calls[2].args) -contains '--resume') | Should Be $false
        (Get-FakeArg $run.Calls[2] '-p') | Should Match 'my-subagent-driven-development'

        $h = @($run.Status.history)
        $h[2].attempt | Should Be 2
        $h[2].resumedSessionId | Should BeNullOrEmpty
        $h[2].priorCause | Should Be 'exit_no_cero'
    }

    It 'D1: -MaxTransientRetries 0 desactiva el reintento' {
        $run = Invoke-FakeDriverRun -Name 'e2e-no-retry' -Steps @((Get-StepTransitorio)) -DriverArgs @('-MaxTransientRetries', '0')

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Calls.Count | Should Be 1
        $last = @($run.Status.history)[-1]
        $last.failureKind | Should Be 'transient'
        $last.transientRetries | Should Be 0
    }

    It 'PA-1: PLAN_DRIVER_CLAUDE_PATH invalido aborta sin lanzar nada' {
        $cmdPath = Join-Path $TestDrive 'falso.cmd'
        Set-Content -LiteralPath $cmdPath -Value '@echo off' -Encoding ascii
        $cases = @(
            @{ Name = 'e2e-invalid-missing'; Path = (Join-Path $TestDrive 'no-existe.ps1') },
            @{ Name = 'e2e-invalid-cmd'; Path = $cmdPath }
        )
        foreach ($case in $cases) {
            $run = Invoke-FakeDriverRun -Name $case.Name -Steps @((Get-StepNivelOk (Get-FakePlanPath $case.Name))) -ClaudePath $case.Path
            $run.Output | Should Match 'PLAN_DRIVER_CLAUDE_PATH invalido'
            $run.Output | Should Not Match 'Usando claude de prueba'
            $run.Calls.Count | Should Be 0
            if ($null -ne $run.Status) { $run.Status.globalStatus | Should Be 'FAILED' }
        }
    }

    It '2a: DONE publica limits, params, phase y git' {
        $name = 'e2e-2a-done'
        $steps = @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -DriverArgs @('-MaxIterations', '2')

        $run.Status.globalStatus | Should Be 'DONE'

        $l = $run.Status.limits
        $l.sessionBudget | Should Be 2
        $l.budgetSource | Should Be 'explicito'
        $l.iterBase | Should Be 0
        $l.maxTransientRetries | Should Be 2
        $l.noProgressRetries | Should Be 1
        $l.maxCostUsd | Should Be 0
        $l.awaitDecisionMinutes | Should Be 480
        ($l.PSObject.Properties.Name -join ',') | Should Be 'sessionBudget,budgetSource,iterBase,maxTransientRetries,noProgressRetries,maxCostUsd,awaitDecisionMinutes'

        $p = $run.Status.params
        $p.model | Should Be 'claude-opus-5-5'
        $p.levelEffort | Should Be 'high'
        $p.closeEffort | Should Be 'high'
        (@($p.retryBackoffSeconds) -join ',') | Should Be '0'
        $p.livenessTimeoutMinutes | Should Be 1

        $ph = $run.Status.phase
        $ph.mode | Should Be 'done'
        $ph.completedBy | Should Be 'levels'
        $ph.finalReviewFile | Should Be '.final-review-2026-10-27-falso.md'
        $ph.finalReviewExists | Should Be $true

        $g = $run.Status.git
        $g.branch | Should Be ((git -C $run.Repo rev-parse --abbrev-ref HEAD) | Select-Object -First 1)
        $g.updatedAt | Should Not BeNullOrEmpty
        if ($null -eq $g.error) {
            $g.clean | Should Be $true
        }
        else {
            $g.error | Should Be 'sin rama base (develop, main o master)'
        }

        $prompt = Get-FakeArg $run.Calls[1] '-p'
        $prompt | Should Match ([regex]::Escape('**Veredicto:**'))
        $prompt | Should Match ([regex]::Escape('| # | Severidad | Ubicación | Descripción |'))
    }

    It '2a: FAILED en bootstrap publica phase sin revision final' {
        $name = 'e2e-2a-failed'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepPermanente))

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Status.phase.mode | Should Be 'bootstrap'
        $run.Status.phase.completedBy | Should BeNullOrEmpty
        $run.Status.phase.finalReviewExists | Should Be $false
        $run.Status.limits.budgetSource | Should Be 'auto'
        $run.Status.limits.sessionBudget | Should BeGreaterThan 0
        ($run.Status.PSObject.Properties.Name -contains 'git') | Should Be $true
    }

    It '2a: git refleja ahead, commits, diffstat y cambios frente a master' {
        $name = 'e2e-2a-git'
        $afterInit = {
            param($r)
            git -C $r branch -M master
            git -C $r checkout -q -b feat/ola2a
            Set-Content -LiteralPath (Join-Path $r 'a.txt') -Value 'a' -Encoding ascii
            git -C $r add a.txt
            [IO.File]::WriteAllText((Join-Path $TestDrive 'msg-2a.txt'), 'feat: añade a', [Text.UTF8Encoding]::new($false))
            git -C $r -c user.name=t -c user.email=t@example.com commit -q -F (Join-Path $TestDrive 'msg-2a.txt')
        }
        $nivel = Get-StepNivelOk (Get-FakePlanPath $name)
        $nivel.writeFiles['sucio.txt'] = 'x'
        $run = Invoke-FakeDriverRun -Name $name -Steps @($nivel, (Get-StepCierreOk)) -DriverArgs @('-MaxIterations', '2') -AfterInit $afterInit

        $run.Status.globalStatus | Should Be 'DONE'
        $g = $run.Status.git
        $g.branch | Should Be 'feat/ola2a'
        $g.baseBranch | Should Be 'master'
        $g.ahead | Should Be 1
        @($g.commits).Count | Should Be 1
        @($g.commits)[0].subject | Should Be 'feat: añade a'
        (@($g.commits)[0].hash -match '^[0-9a-f]{7,}$') | Should Be $true
        $g.diffstat.files | Should Be 1
        $g.diffstat.insertions | Should Be 1
        $g.diffstat.deletions | Should Be 0
        $g.clean | Should Be $false
        $g.error | Should BeNullOrEmpty
    }

    AfterAll {
        # Ningun claude falso debe quedar vivo tras las pruebas.
        @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'fake-claude' }) | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    It '2b A5: set-params en vigilancia aplica en la sesion siguiente y se registra en actions' {
        $name = 'e2e-2b-setparams'
        $id = '21111111-1111-4111-8111-111111111111'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $id 'set-params' ([ordered]@{ model = 'claude-prueba-2b'; closeEffort = 'low'; awaitDecisionMinutes = 30 })
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk))

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 2
        (Get-FakeArg $run.Calls[0] '--model') | Should Be 'claude-opus-5-5'
        (Get-FakeArg $run.Calls[1] '--model') | Should Be 'claude-prueba-2b'
        (Get-FakeArg $run.Calls[1] '--effort') | Should Be 'low'
        $run.Status.params.model | Should Be 'claude-prueba-2b'
        $run.Status.params.closeEffort | Should Be 'low'
        $run.Status.limits.awaitDecisionMinutes | Should Be 30
        @($run.Status.history)[0].telemetry.model | Should Be 'claude-opus-5-5'

        @($run.Status.actions).Count | Should Be 1
        $a = @($run.Status.actions)[0]
        $a.id | Should Be $id
        $a.action | Should Be 'set-params'
        $a.origin | Should Be 'dashboard'
        $a.result | Should Be 'applied'
        $a.iter | Should Be 1
        $a.detail | Should Match 'model'
        $run.Status.control.last.id | Should Be $id
        $run.Status.control.enabled | Should Be $false
        (Test-Path -LiteralPath (Join-Path $run.Repo 'docs\superpowers\plans\.driver-control.json')) | Should Be $false
    }

    It '2b A2: pausa en vigilancia, PAUSED entre sesiones y reanudar sigue hasta DONE' {
        $name = 'e2e-2b-pause-resume'
        $idPause = '22222222-2222-4222-8222-222222222222'
        $idResume = '22222222-2222-4222-9222-222222222223'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $idPause 'pause'
        $seen = @{}
        $watch = {
            param($repo)
            if ($seen.ContainsKey('paused')) { return }
            $st = Read-FakeStatus $repo
            if ($st -and $st.globalStatus -eq 'PAUSED') {
                $seen['paused'] = $st
                Write-FakeControl -Repo $repo -Id $idResume -Action 'resume'
            }
        }
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk)) -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 2
        $seen.ContainsKey('paused') | Should Be $true
        $p = $seen['paused']
        $p.reason | Should Be 'En pausa (dashboard)'
        $p.paused.actionId | Should Be $idPause
        $p.paused.since | Should Not BeNullOrEmpty
        $p.paused.deadline | Should Not BeNullOrEmpty
        $p.currentSession | Should BeNullOrEmpty

        $acts = @($run.Status.actions)
        $acts.Count | Should Be 2
        $acts[0].action | Should Be 'pause'
        $acts[0].result | Should Be 'applied'
        $acts[0].detail | Should Be 'pausa al terminar la sesión en curso'
        $acts[0].iter | Should Be 1
        $acts[1].action | Should Be 'resume'
        $acts[1].result | Should Be 'applied'
        ($run.Status.PSObject.Properties.Name -contains 'paused') | Should Be $false
        $run.Output | Should Match 'En pausa'
    }

    It '2b A3: detener en vigilancia mata la sesion y cierra STOPPED con causa dashboard' {
        $name = 'e2e-2b-stop-watch'
        $id = '23333333-3333-4333-8333-333333333333'
        $s1 = Add-StepControl (New-FakeStep 0 -Stdout @('PLAN_STATUS: CONTINUE')) $id 'stop' $null 30
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1)
        $sw.Stop()

        $sw.Elapsed.TotalSeconds | Should BeLessThan 25
        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.reason | Should Be 'Detenido desde el dashboard'
        $run.Status.cause | Should Be 'dashboard'
        @($run.Status.history).Count | Should Be 1
        @($run.Status.history)[0].cause | Should Be 'dashboard'
        @($run.Status.history)[0].exitCode | Should Be -1
        @($run.Status.actions)[0].action | Should Be 'stop'
        @($run.Status.actions)[0].result | Should Be 'applied'
        @($run.Calls).Count | Should Be 1
        @(Get-FakeClaudeProcesses).Count | Should Be 0
        $run.Status.notification | Should Not BeNullOrEmpty
    }

    It '2b A3: detener en pausa cierra STOPPED sin lanzar otra sesion' {
        $name = 'e2e-2b-stop-paused'
        $idPause = '24444444-4444-4444-8444-444444444444'
        $idStop = '24444444-4444-4444-9444-444444444445'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $idPause 'pause'
        $sent = @{}
        $watch = {
            param($repo)
            if ($sent.ContainsKey('stop')) { return }
            $st = Read-FakeStatus $repo
            if ($st -and $st.globalStatus -eq 'PAUSED') {
                $sent['stop'] = $true
                Write-FakeControl -Repo $repo -Id $idStop -Action 'stop'
            }
        }
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk)) -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'dashboard'
        $run.Status.reason | Should Be 'Detenido desde el dashboard'
        ($run.Status.PSObject.Properties.Name -contains 'paused') | Should Be $false
        @($run.Calls).Count | Should Be 1
        @($run.Status.history).Count | Should Be 1
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 2
        $acts[0].action | Should Be 'pause'
        $acts[0].result | Should Be 'applied'
        $acts[1].action | Should Be 'stop'
        $acts[1].result | Should Be 'applied'
    }

    It '2b A2: la pausa vence y cierra STOPPED con causa pausa_vencida' {
        $name = 'e2e-2b-pause-expired'
        $id = '25555555-5555-4555-8555-555555555555'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $id 'pause'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk)) -DriverArgs @('-AwaitDecisionMinutes', '1')
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'pausa_vencida'
        $run.Status.reason | Should Be 'Pausa vencida: sin reanudar en 1 min'
        @($run.Calls).Count | Should Be 1
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 55
        $sw.Elapsed.TotalSeconds | Should BeLessThan 150
    }

    It '2b: una orden no valida en el estado se rechaza y la corrida sigue' {
        $name = 'e2e-2b-invalid'
        $id = '26666666-6666-4666-8666-666666666666'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $id 'resume'
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk))

        $run.Status.globalStatus | Should Be 'DONE'
        $a = @($run.Status.actions)[0]
        $a.result | Should Be 'rejected'
        $a.detail | Should Be 'resume no es válida con una sesión en curso'
        $run.Status.control.last.result | Should Be 'rejected'
    }

    It '2b A2: pausa pedida antes del reintento: PAUSED, reanudar y reintento con --resume' {
        $name = 'e2e-2b-pause-retry'
        $idPause = '27777777-7777-4777-8777-777777777777'
        $idResume = '27777777-7777-4777-9777-777777777778'
        $s1 = Add-StepControl (Get-StepTransitorio) $idPause 'pause' $null 0
        $sent = @{}
        $watch = {
            param($repo)
            if ($sent.ContainsKey('resume')) { return }
            $st = Read-FakeStatus $repo
            if ($st -and $st.globalStatus -eq 'PAUSED') {
                $sent['resume'] = $true
                Write-FakeControl -Repo $repo -Id $idResume -Action 'resume'
            }
        }
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        @($run.Status.history)[1].attempt | Should Be 1
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 2
        $acts[0].action | Should Be 'pause'
        $acts[0].result | Should Be 'applied'
        $acts[0].iter | Should Be 1
        $acts[1].action | Should Be 'resume'
        $acts[1].result | Should Be 'applied'
    }

    It '2b: borra una orden huerfana al arrancar' {
        $name = 'e2e-2b-orphan'
        $after = {
            param($repo)
            $dir = Join-Path $repo 'docs\superpowers\plans'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir '.driver-control.json'), (Get-ControlJson -Id '28888888-8888-4888-8888-888888888888' -Action 'stop'), [System.Text.UTF8Encoding]::new($false))
        }
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -AfterInit $after

        $run.Status.globalStatus | Should Be 'DONE'
        # La consola redirigida del hijo no conserva las tildes: la ó se acepta como cualquier caracter.
        $run.Output | Should Match 'Se borr. una orden pendiente de una corrida anterior'
        # Sin actions o vacia: la orden huerfana no se proceso.
        @(@($run.Status.actions) | Where-Object { $null -ne $_ }).Count | Should Be 0
    }

    It '2b-1: set-params awaitDecisionMinutes 0 en PAUSED quita el plazo y la pausa no vence' {
        $name = 'e2e-2b-await0'
        $idPause = '29999999-9999-4999-8999-99999999999a'
        $idSet = '29999999-9999-4999-8999-99999999999b'
        $idStop = '29999999-9999-4999-8999-99999999999c'
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) $idPause 'pause'
        $st = @{}
        $watch = {
            param($repo)
            $cur = Read-FakeStatus $repo
            if (-not $cur) { return }
            if ($cur.globalStatus -eq 'PAUSED' -and -not $st.ContainsKey('pausedAt')) {
                $st['pausedAt'] = Get-Date
                Write-FakeControl -Repo $repo -Id $idSet -Action 'set-params' -Params ([ordered]@{ awaitDecisionMinutes = 0 })
                return
            }
            if (-not $st.ContainsKey('afterSet') -and $cur.control -and $cur.control.last -and $cur.control.last.id -eq $idSet) {
                $st['afterSet'] = $cur
            }
            # 75 s > 60 s de AwaitDecisionMinutes 1: si el plazo siguiera vivo, la pausa ya habria vencido.
            if ($st.ContainsKey('afterSet') -and -not $st.ContainsKey('stopSent') -and (Get-Date) -ge $st['pausedAt'].AddSeconds(75)) {
                $st['stopSent'] = $true
                Write-FakeControl -Repo $repo -Id $idStop -Action 'stop'
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepCierreOk)) -DriverArgs @('-AwaitDecisionMinutes', '1') -WhileRunning $watch
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'dashboard'
        $run.Status.reason | Should Be 'Detenido desde el dashboard'

        $after = $st['afterSet']
        $after | Should Not BeNullOrEmpty
        $after.globalStatus | Should Be 'PAUSED'
        $after.paused.deadline | Should BeNullOrEmpty
        $after.paused.since | Should Not BeNullOrEmpty
        $after.limits.awaitDecisionMinutes | Should Be 0
        $after.control.last.result | Should Be 'applied'

        $acts = @($run.Status.actions)
        $acts.Count | Should Be 3
        $acts[0].action | Should Be 'pause'
        $acts[1].action | Should Be 'set-params'
        $acts[1].detail | Should Be 'aplicados: awaitDecisionMinutes'
        $acts[2].action | Should Be 'stop'
        foreach ($a in $acts) { $a.result | Should Be 'applied' }
        @($run.Calls).Count | Should Be 1
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 75
    }

    It '2b-2: pausa durante el backoff: PAUSED, reanudar y reintento con --resume sin esperar el backoff' {
        $name = 'e2e-2b-backoff-pause'
        $idPause = '29999999-9999-4999-8999-99999999999d'
        $idResume = '29999999-9999-4999-8999-99999999999e'
        $st = @{}
        $watch = {
            param($repo)
            $cur = Read-FakeStatus $repo
            if (-not $cur) { return }
            if (-not $st.ContainsKey('pauseSent') -and "$($cur.reason)" -match '^Reintento 1/') {
                $st['pauseSent'] = $true
                Write-FakeControl -Repo $repo -Id $idPause -Action 'pause'
                return
            }
            if ($cur.globalStatus -eq 'PAUSED' -and -not $st.ContainsKey('paused')) {
                $st['paused'] = $cur
                Write-FakeControl -Repo $repo -Id $idResume -Action 'resume'
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepTransitorio), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -RetryBackoff '60' -WhileRunning $watch
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'DONE'
        # Sin el corte de la espera, el backoff solo serian al menos 60 s.
        $sw.Elapsed.TotalSeconds | Should BeLessThan 45
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        @($run.Status.history)[1].attempt | Should Be 1
        $st['paused'] | Should Not BeNullOrEmpty
        $st['paused'].reason | Should Be 'En pausa (dashboard)'
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 2
        $acts[0].action | Should Be 'pause'
        $acts[0].result | Should Be 'applied'
        $acts[0].detail | Should Be 'en pausa'
        $acts[0].iter | Should Be 1
        $acts[1].action | Should Be 'resume'
        $acts[1].result | Should Be 'applied'
    }

    It '2b-2: detener durante el backoff cierra STOPPED con causa dashboard' {
        $name = 'e2e-2b-backoff-stop'
        $idStop = '29999999-9999-4999-8999-99999999999f'
        $st = @{}
        $watch = {
            param($repo)
            if ($st.ContainsKey('stopSent')) { return }
            $cur = Read-FakeStatus $repo
            if ($cur -and "$($cur.reason)" -match '^Reintento 1/') {
                $st['stopSent'] = $true
                Write-FakeControl -Repo $repo -Id $idStop -Action 'stop'
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepTransitorio), (Get-StepNivelOk (Get-FakePlanPath $name))) -RetryBackoff '60' -WhileRunning $watch
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'dashboard'
        $run.Status.reason | Should Be 'Detenido desde el dashboard'
        $sw.Elapsed.TotalSeconds | Should BeLessThan 45
        @($run.Calls).Count | Should Be 1
        $acts = @($run.Status.actions)
        $acts[0].action | Should Be 'stop'
        $acts[0].result | Should Be 'applied'
        $run.Status.paused | Should BeNullOrEmpty
        $run.Status.notification | Should Not BeNullOrEmpty
    }

    It '2c A1: BLOCKED del modelo, AWAITING y respuesta con --resume' {
        $name = 'e2e-2c-a1-resume'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '31111111-1111-4111-8111-111111111111'; Action = 'answer'; Params = [ordered]@{ text = 'usa A' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepBloqueado 'elegir A o B'), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        $s = $ctl['saved']
        $s | Should Not BeNullOrEmpty
        $s.globalStatus | Should Be 'AWAITING'
        $s.reason | Should Be 'Esperando decisión: elegir A o B'
        $s.awaiting.origin | Should Be 'BLOCKED'
        $s.awaiting.resumable | Should Be $true
        (@($s.awaiting.allowed) -join ',') | Should Be 'answer,retry,stop,set-params,open'
        $s.awaiting.iter | Should Be 1
        $s.awaiting.sessionId | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        $s.awaiting.deadline | Should Not BeNullOrEmpty
        $s.notification | Should Not BeNullOrEmpty

        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        ((Get-FakeArg $run.Calls[1] '-p') -ceq (Get-DriverAnswerPrompt -Text 'usa A')) | Should Be $true
        $hist = @($run.Status.history)
        $hist[1].attempt | Should Be 1
        $hist[1].priorCause | Should Be 'respuesta_usuario'
        $a = @($run.Status.actions)[0]
        $a.action | Should Be 'answer'
        $a.result | Should Be 'applied'
        $a.detail | Should Be 'respuesta enviada a la sesión (--resume)'
        $a.params.textLength | Should Be 5
        ($run.Status.PSObject.Properties.Name -contains 'awaiting') | Should Be $false
    }

    It '2c A1: BLOCKED de una regla del driver: respuesta en una sesion nueva' {
        $name = 'e2e-2c-a1-new'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '32222222-2222-4222-8222-222222222222'; Action = 'answer'; Params = [ordered]@{ text = 'sigue con T1' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepContinueSinAvance), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -DriverArgs @('-NoProgressRetries', '0', '-MaxIterations', '5') -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        $ctl['saved'].awaiting.cause | Should Be 'continue_sin_avance'
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--session-id') | Should Not Be (Get-FakeArg $run.Calls[0] '--session-id')
        (Get-FakeArg $run.Calls[1] '--resume') | Should BeNullOrEmpty
        (Get-FakeArg $run.Calls[1] '-p').EndsWith("`n`nDecisión del usuario: sigue con T1") | Should Be $true
        @($run.Status.history)[1].iter | Should Be 2
        @($run.Status.actions)[0].detail | Should Be 'respuesta en una sesión nueva'
    }

    It '2c A4: FAILED y reintento de la sesion con --resume' {
        $name = 'e2e-2c-a4-session'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '33333333-3333-4333-8333-333333333333'; Action = 'retry'; Params = [ordered]@{ mode = 'session' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepPermanente), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        $s = $ctl['saved']
        $s.awaiting.origin | Should Be 'FAILED'
        $s.awaiting.cause | Should Be 'exit_no_cero'
        (@($s.awaiting.allowed) -join ',') | Should Be 'retry,stop,set-params,open'
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        ((Get-FakeArg $run.Calls[1] '-p') -ceq (Get-ResumePrompt)) | Should Be $true
        $hist = @($run.Status.history)
        $hist[1].attempt | Should Be 1
        $hist[1].priorCause | Should Be 'exit_no_cero'
        @($run.Status.actions)[0].detail | Should Be 'reintento de la sesión (--resume)'
    }

    It '2c A4: FAILED y reintento del nivel con sesion nueva' {
        $name = 'e2e-2c-a4-level'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '34444444-4444-4444-8444-444444444444'; Action = 'retry'; Params = [ordered]@{ mode = 'level' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepPermanente), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--session-id') | Should Not Be (Get-FakeArg $run.Calls[0] '--session-id')
        (Get-FakeArg $run.Calls[1] '--resume') | Should BeNullOrEmpty
        @($run.Status.history)[1].iter | Should Be 2
        @($run.Status.actions)[0].detail | Should Be 'reintento del nivel con sesión nueva'
    }

    It '2c DO-8: tope de costo, AWAITING, subir el tope y reintentar el nivel' {
        $name = 'e2e-2c-cap-raise'
        $ctl = @{ next = 0 }
        $orders = @(
            @{ Id = '35555555-5555-4555-8555-555555555551'; Action = 'retry'; Params = [ordered]@{ mode = 'level' } },
            @{ Id = '35555555-5555-4555-8555-555555555552'; Action = 'set-params'; Params = [ordered]@{ maxCostUsd = 1 } },
            @{ Id = '35555555-5555-4555-8555-555555555553'; Action = 'retry'; Params = [ordered]@{ mode = 'level' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -DriverArgs @('-MaxCostUsd', '0.01') -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        $s = $ctl['saved']
        $s.awaiting.origin | Should Be 'tope_costo'
        $s.awaiting.resumable | Should Be $false
        (@($s.awaiting.allowed) -join ',') | Should Be 'retry,stop,set-params,open'
        $s.reason.StartsWith('Esperando decisión: Tope de costo alcanzado: 0.01 USD de 0.01 USD') | Should Be $true
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 3
        $acts[0].action | Should Be 'retry'
        $acts[0].result | Should Be 'rejected'
        $acts[0].detail | Should Be 'tope de costo alcanzado'
        $acts[1].action | Should Be 'set-params'
        $acts[1].result | Should Be 'applied'
        $acts[2].action | Should Be 'retry'
        $acts[2].result | Should Be 'applied'
        @($run.Calls).Count | Should Be 2
        $run.Status.limits.maxCostUsd | Should Be 1
    }

    It '2c DO-8: sin espera el tope cierra STOPPED con causa tope_costo' {
        $name = 'e2e-2c-cap-final'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-MaxCostUsd', '0.01')

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'tope_costo'
        $run.Status.reason | Should Be 'Tope de costo alcanzado: 0.01 USD de 0.01 USD'
        @($run.Calls).Count | Should Be 1
        $run.Status.notification | Should Not BeNullOrEmpty
    }

    It '2c: la espera vence y cierra con el estado, el motivo y la causa originales' {
        $name = 'e2e-2c-expire'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepBloqueado 'elegir A o B')) -AwaitHook -DriverArgs @('-AwaitDecisionMinutes', '1')
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'BLOCKED'
        $run.Status.reason | Should Be 'elegir A o B (sin decisión en 1 min)'
        ($run.Status.PSObject.Properties.Name -contains 'awaiting') | Should Be $false
        @($run.Calls).Count | Should Be 1
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 55
        $sw.Elapsed.TotalSeconds | Should BeLessThan 150
    }

    It '2c: detener en AWAITING cierra STOPPED con causa dashboard' {
        $name = 'e2e-2c-stop'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '37777777-7777-4777-8777-777777777777'; Action = 'stop'; Params = $null })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepBloqueado 'x')) -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'dashboard'
        $run.Status.reason | Should Be 'Detenido desde el dashboard'
        ($run.Status.PSObject.Properties.Name -contains 'awaiting') | Should Be $false
        @($run.Calls).Count | Should Be 1
    }

    It '2c: ordenes no validas en AWAITING se rechazan y la espera sigue' {
        $name = 'e2e-2c-invalid'
        $ctl = @{ next = 0 }
        $orders = @(
            @{ Id = '38888888-8888-4888-8888-888888888881'; Action = 'answer'; Params = [ordered]@{ text = 'PLAN_STATUS: COMPLETE' } },
            @{ Id = '38888888-8888-4888-8888-888888888882'; Action = 'resume'; Params = $null },
            @{ Id = '38888888-8888-4888-8888-888888888883'; Action = 'stop'; Params = $null })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepBloqueado 'x')) -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'STOPPED'
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 3
        $acts[0].result | Should Be 'rejected'
        $acts[0].detail | Should Be 'parámetro inválido: text (la respuesta no puede contener PLAN_STATUS)'
        $acts[1].result | Should Be 'rejected'
        $acts[1].detail | Should Be 'resume no es válida esperando decisión'
        $acts[2].action | Should Be 'stop'
        $acts[2].result | Should Be 'applied'
    }

    It '2c A6: abrir carpeta, log y terminal en AWAITING; terminal rechazada en la sesion en curso' {
        $name = 'e2e-2c-open'
        $openLog = Join-Path $TestDrive 'e2e-2c-open.jsonl'
        $ctl = @{ next = 0 }
        $orders = @(
            @{ Id = '39999999-9999-4999-8999-999999999991'; Action = 'open'; Params = [ordered]@{ target = 'folder' } },
            @{ Id = '39999999-9999-4999-8999-999999999992'; Action = 'open'; Params = [ordered]@{ target = 'log'; iter = 2 } },
            @{ Id = '39999999-9999-4999-8999-999999999993'; Action = 'open'; Params = [ordered]@{ target = 'terminal' } },
            @{ Id = '39999999-9999-4999-8999-999999999994'; Action = 'stop'; Params = $null })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $s1 = Add-StepControl (Get-StepNivelOk (Get-FakePlanPath $name)) '39999999-9999-4999-8999-999999999990' 'open' ([ordered]@{ target = 'terminal' })
        $run = Invoke-FakeDriverRun -Name $name -Steps @($s1, (Get-StepBloqueado 'x')) -AwaitHook -OpenLog $openLog -WhileRunning $watch

        $acts = @($run.Status.actions)
        $acts[0].result | Should Be 'rejected'
        $acts[0].detail | Should Be 'terminal no disponible para la sesión en curso'
        $acts[1].result | Should Be 'applied'
        $acts[1].detail | Should Be 'abierto: folder'
        $acts[2].result | Should Be 'applied'
        $acts[2].detail | Should Be 'abierto: log'
        $acts[3].result | Should Be 'applied'
        $acts[3].detail | Should Be 'abierto: terminal'

        $lines = @(Get-Content -LiteralPath $openLog -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        $lines.Count | Should Be 3
        $lines[0].filePath | Should Be 'explorer.exe'
        (Split-Path -Leaf @($lines[0].arguments)[0]) | Should Be $name
        $lines[1].kind | Should Be 'item'
        $lines[1].filePath.Contains('.driver-logs') | Should Be $true
        $lines[1].filePath.EndsWith('.log') | Should Be $true
        @($lines[2].arguments)[-1] | Should Be ('claude --resume ' + (Get-FakeArg $run.Calls[1] '--session-id'))
    }

    It '2c: sin gancho o con AwaitDecisionMinutes 0 el BLOCKED cierra como hoy' {
        $nameA = 'e2e-2c-nohook'
        $runA = Invoke-FakeDriverRun -Name $nameA -Steps @((Get-StepBloqueado 'x'))
        $nameB = 'e2e-2c-zero'
        $runB = Invoke-FakeDriverRun -Name $nameB -Steps @((Get-StepBloqueado 'x')) -AwaitHook -DriverArgs @('-AwaitDecisionMinutes', '0')

        foreach ($run in @($runA, $runB)) {
            $run.Status.globalStatus | Should Be 'BLOCKED'
            $run.Status.reason | Should Be 'x'
            ($run.Status.PSObject.Properties.Name -contains 'awaiting') | Should Be $false
            $run.Output | Should Not Match 'Esperando decisi'
            @($run.Calls).Count | Should Be 1
        }
    }

    It '2c-1: si el --resume de la respuesta no existe, la sesion nueva lleva la respuesta' {
        $name = 'e2e-2c-answer-fallback'
        $ctl = @{ next = 0 }
        $orders = @(@{ Id = '41111111-1111-4111-8111-111111111111'; Action = 'answer'; Params = [ordered]@{ text = 'usa A' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $steps = @((Get-StepBloqueado 'elegir A o B'), (Get-StepSinSesion), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 4
        (Get-FakeArg $run.Calls[1] '--resume') | Should Be (Get-FakeArg $run.Calls[0] '--session-id')
        (Get-FakeArg $run.Calls[2] '--session-id') | Should Not BeNullOrEmpty
        (Get-FakeArg $run.Calls[2] '--session-id') | Should Not Be (Get-FakeArg $run.Calls[0] '--session-id')
        (Get-FakeArg $run.Calls[2] '--resume') | Should BeNullOrEmpty
        (Get-FakeArg $run.Calls[2] '-p').EndsWith("`n`nDecisión del usuario: usa A") | Should Be $true
    }

    It '2c-2: set-params awaitDecisionMinutes 0 en AWAITING quita el plazo y la espera no vence' {
        $name = 'e2e-2c-await0'
        $idSet = '42222222-2222-4222-8222-222222222222'
        $idStop = '42222222-2222-4222-8222-222222222223'
        $st = @{}
        $watch = {
            param($repo)
            $cur = Read-FakeStatus $repo
            if (-not $cur) { return }
            if ($cur.globalStatus -eq 'AWAITING' -and -not $st.ContainsKey('awaitAt')) {
                $st['awaitAt'] = Get-Date
                Write-FakeControl -Repo $repo -Id $idSet -Action 'set-params' -Params ([ordered]@{ awaitDecisionMinutes = 0 })
                return
            }
            if (-not $st.ContainsKey('afterSet') -and $cur.control -and $cur.control.last -and $cur.control.last.id -eq $idSet) {
                $st['afterSet'] = $cur
            }
            # 75 s > 60 s de AwaitDecisionMinutes 1: si el plazo siguiera vivo, la espera ya habria vencido.
            if ($st.ContainsKey('afterSet') -and -not $st.ContainsKey('stopSent') -and (Get-Date) -ge $st['awaitAt'].AddSeconds(75)) {
                $st['stopSent'] = $true
                Write-FakeControl -Repo $repo -Id $idStop -Action 'stop'
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepBloqueado 'x')) -AwaitHook -DriverArgs @('-AwaitDecisionMinutes', '1') -WhileRunning $watch
        $sw.Stop()

        $run.Status.globalStatus | Should Be 'STOPPED'
        $run.Status.cause | Should Be 'dashboard'

        $after = $st['afterSet']
        $after | Should Not BeNullOrEmpty
        $after.globalStatus | Should Be 'AWAITING'
        $after.awaiting.deadline | Should BeNullOrEmpty
        $after.limits.awaitDecisionMinutes | Should Be 0
        @($run.Calls).Count | Should Be 1
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 75
    }

    It '2c-3: tope de costo tras el backoff: retry session rechazado por tope y retry level con sesion nueva' {
        $name = 'e2e-2c-cap-backoff'
        $ctl = @{ next = 0 }
        $orders = @(
            @{ Id = '43333333-3333-4333-8333-333333333331'; Action = 'retry'; Params = [ordered]@{ mode = 'session' } },
            @{ Id = '43333333-3333-4333-8333-333333333332'; Action = 'set-params'; Params = [ordered]@{ maxCostUsd = 1 } },
            @{ Id = '43333333-3333-4333-8333-333333333333'; Action = 'retry'; Params = [ordered]@{ mode = 'level' } })
        $watch = { param($repo) Step-AwaitScript -Repo $repo -State $ctl -Orders $orders }
        $transitorioConCosto = New-FakeStep 1 -Stdout @('{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529,"total_cost_usd":0.01,"result":"API Error: 529 Overloaded"}')
        $steps = @($transitorioConCosto, (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))
        $run = Invoke-FakeDriverRun -Name $name -Steps $steps -AwaitHook -RetryBackoff '0' -DriverArgs @('-MaxCostUsd', '0.01') -WhileRunning $watch

        $run.Status.globalStatus | Should Be 'DONE'
        $s = $ctl['saved']
        $s | Should Not BeNullOrEmpty
        $s.awaiting.origin | Should Be 'tope_costo'
        $s.awaiting.resumable | Should Be $false
        $acts = @($run.Status.actions)
        $acts.Count | Should Be 3
        $acts[0].action | Should Be 'retry'
        $acts[0].result | Should Be 'rejected'
        $acts[0].detail | Should Be 'tope de costo alcanzado'
        $acts[1].action | Should Be 'set-params'
        $acts[1].result | Should Be 'applied'
        $acts[2].action | Should Be 'retry'
        $acts[2].result | Should Be 'applied'
        @($run.Calls).Count | Should Be 3
        (Get-FakeArg $run.Calls[1] '--resume') | Should BeNullOrEmpty
        (Get-FakeArg $run.Calls[1] '--session-id') | Should Not BeNullOrEmpty
        (Get-FakeArg $run.Calls[1] '--session-id') | Should Not Be (Get-FakeArg $run.Calls[0] '--session-id')
    }

    It '1a-6: con historial heredado la corrida sigue la numeracion y conserva el historial' {
        $name = 'e2e-1a-inherit'
        $planFull = Get-FakePlanPath $name
        $planLeafName = $planLeaf
        $setup = {
            param($repo)
            $plansDir = Join-Path $repo 'docs\superpowers\plans'
            New-Item -ItemType Directory -Path $plansDir -Force | Out-Null
            $state = [ordered]@{ plan = $planLeafName; completed_levels = @(0); current_level = 1; tasks = [ordered]@{} }
            [System.IO.File]::WriteAllText((Join-Path $plansDir '.controller-state.json'), ($state | ConvertTo-Json -Compress -Depth 4), [System.Text.UTF8Encoding]::new($false))
            $branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
            $prev = [ordered]@{
                projectPath  = $repo
                planFile     = $planFull.ToUpper().Replace('\', '/')
                workBranch   = $branch
                startedAt    = '2026-10-27T18:00:00.0000000Z'
                updatedAt    = '2026-10-27T19:00:00.0000000Z'
                globalStatus = 'BLOCKED'
                reason       = 'previo'
                history      = @(
                    [ordered]@{ iter = 1; exitCode = 0; planStatus = 'CONTINUE'; logPath = 'a.log'; sessionId = '51111111-1111-4111-8111-111111111111'; at = '2026-10-27T18:10:00.0000000Z' },
                    [ordered]@{ iter = 2; exitCode = 0; planStatus = 'BLOCKED'; logPath = 'b.log'; sessionId = '51111111-1111-4111-8111-111111111112'; at = '2026-10-27T18:50:00.0000000Z' })
            }
            [System.IO.File]::WriteAllText((Join-Path $plansDir '.driver-status.json'), ($prev | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        }
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepCierreOk)) -AfterInit $setup

        $run.Status.globalStatus | Should Be 'DONE'
        $run.Output | Should Match 'Historial heredado de la corrida anterior'
        $run.Status.previousRun.inherited | Should Be $true
        @($run.Status.history).Count | Should Be 3
        @($run.Status.history)[-1].iter | Should Be 3
        @($run.Calls).Count | Should Be 1
    }

    It '5a: Ola 3 D8: el claude falso recibe --settings con la ruta absoluta del perfil y el status publica permissions' {
        $name = 'e2e-ola3-settings'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepTransitorio), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 3
        $perfil = Join-Path $moduleRoot 'scripts\profiles\plan.settings.json'
        foreach ($c in @($run.Calls)) {
            (Get-FakeArg $c '--settings') | Should Be $perfil
            (@($c.args) -contains '--dangerously-skip-permissions') | Should Be $false
        }
        (@($run.Calls[1].args) -contains '--resume') | Should Be $true
        $run.Status.permissions.mode | Should Be 'profile'
        $run.Status.permissions.profile | Should Be 'plan'
    }

    It '5b: Ola 3 D8: con -UnsafeSkipPermissions vuelve el flag de permisos saltados y permissions dice unsafe' {
        $name = 'e2e-ola3-unsafe'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-UnsafeSkipPermissions')

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 2
        foreach ($c in @($run.Calls)) {
            (@($c.args) -contains '--dangerously-skip-permissions') | Should Be $true
            (@($c.args) -contains '--settings') | Should Be $false
        }
        $run.Status.permissions.mode | Should Be 'unsafe'
        $run.Status.permissions.profile | Should BeNullOrEmpty
        $run.Output | Should Match 'Permisos: sin restricciones'
    }

    It '5c: Ola 3 D8: perfil invalido cierra FAILED perfil_invalido sin lanzar sesiones' {
        $name = 'e2e-ola3-perfil-roto'
        # Copia del runner con el perfil roto: el driver real y su perfil no se tocan (PC-9).
        $runner = Join-Path $TestDrive 'runner-roto'
        New-Item -ItemType Directory -Path $runner -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $moduleRoot 'scripts') -Destination $runner -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $moduleRoot 'assets') -Destination $runner -Recurse -Force
        $rotoPath = Join-Path $runner 'scripts\profiles\plan.settings.json'
        Set-Content -LiteralPath $rotoPath -Value '{"permissions":{"allow":[],"deny":["Bash(gh *)"]}}' -Encoding utf8
        $driverRoto = Join-Path $runner 'scripts\plan-session-driver.ps1'

        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepCierreOk)) -DriverScript $driverRoto

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Status.cause | Should Be 'perfil_invalido'
        $run.Status.reason | Should Be 'perfil de permisos inválido: permissions.allow o permissions.deny vacía'
        @($run.Calls).Count | Should Be 0
        @($run.Status.history).Count | Should Be 0
        $run.Status.permissions | Should BeNullOrEmpty
    }

    It '5d: Ola 3 I7: el status publica tasks del plan y del checkpoint' {
        $name = 'e2e-ola3-tasks'
        $state = ([ordered]@{ plan = $planLeaf; completed_levels = @(0); current_level = 1; tasks = [ordered]@{ 'Task 1' = [ordered]@{ status = 'DONE'; commit = 'abc1234' } } } | ConvertTo-Json -Compress -Depth 6)
        $nivel = New-FakeStep 0 -Stdout @('{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"result":"Nivel listo.\nPLAN_STATUS: CONTINUE"}') -WriteFiles ([ordered]@{ 'docs\superpowers\plans\.controller-state.json' = $state })
        $run = Invoke-FakeDriverRun -Name $name -Steps @($nivel, (Get-StepCierreOk))

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Status.tasks.items).Count | Should Be 1
        $item = @($run.Status.tasks.items)[0]
        $item.id | Should Be 'Task 1'
        $item.title | Should Be 'Foo'
        $item.level | Should Be 0
        $item.status | Should Be 'done'
        $item.commit | Should Be 'abc1234'
        $run.Status.tasks.updatedAt | Should Not BeNullOrEmpty
    }

    # Ola 6: paso del guion que responde a "claude mcp list" con la salida real (33 servidores).
    function Get-StepMcpList {
        $lines = @(Get-Content -LiteralPath (Join-Path $moduleRoot 'tests\fixtures\mcp-list.txt') -Encoding utf8)
        New-FakeStep 0 -Stdout $lines
    }

    It '6a: Ola 6: sin -AllowMcp las sesiones llevan --strict-mcp-config, sin inventario, y el status dice none' {
        $name = 'e2e-ola6-none'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk))

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 2
        foreach ($c in @($run.Calls)) {
            (@($c.args) -contains '--strict-mcp-config') | Should Be $true
            (@($c.args) -contains '--disallowedTools') | Should Be $false
            @($c.args)[0] | Should Not Be 'mcp'
        }
        $run.Status.mcp.mode | Should Be 'none'
        $run.Output | Should Match 'MCP: none'
    }

    It '6b: Ola 6: -AllowMcp playwright corre el inventario una vez y bloquea los otros 32 servidores' {
        $name = 'e2e-ola6-allowlist'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepMcpList), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-UnsafeSkipPermissions', '-AllowMcp', 'playwright')

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 3
        (@($run.Calls[0].args) -join ' ') | Should Be 'mcp list'
        foreach ($c in @($run.Calls)[1..2]) {
            (@($c.args) -contains '--strict-mcp-config') | Should Be $false
            $prefixes = @((Get-FakeArg $c '--disallowedTools') -split ',')
            $prefixes.Count | Should Be 32
            ($prefixes -ccontains 'mcp__plugin_vercel_vercel') | Should Be $true
            ($prefixes -ccontains 'mcp__playwright') | Should Be $false
        }
        $run.Status.mcp.mode | Should Be 'allowlist'
        @($run.Status.mcp.allowed)[0] | Should Be 'playwright'
        $run.Status.mcp.blocked | Should Be 32
        $run.Output | Should Match 'MCP: allowlist \(permitidos: playwright; bloqueados: 32\)'
    }

    It "6b2: Ola 6: -AllowMcp 'playwright,pencil' por pwsh -File se parte en dos nombres" {
        $name = 'e2e-ola6-allowlist-comas'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepMcpList), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-UnsafeSkipPermissions', '-AllowMcp', 'playwright,pencil')

        $run.Status.globalStatus | Should Be 'DONE'
        $prefixes = @((Get-FakeArg @($run.Calls)[1] '--disallowedTools') -split ',')
        $prefixes.Count | Should Be 31
        ($prefixes -ccontains 'mcp__playwright') | Should Be $false
        ($prefixes -ccontains 'mcp__pencil') | Should Be $false
        $run.Status.mcp.mode | Should Be 'allowlist'
        @($run.Status.mcp.allowed).Count | Should Be 2
        $run.Status.mcp.blocked | Should Be 31
    }

    It "6c: Ola 6: -AllowMcp '*' hereda todo, sin argumentos de MCP ni inventario" {
        $name = 'e2e-ola6-inherit'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-UnsafeSkipPermissions', '-AllowMcp', '*')

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 2
        foreach ($c in @($run.Calls)) {
            (@($c.args) -contains '--strict-mcp-config') | Should Be $false
            (@($c.args) -contains '--disallowedTools') | Should Be $false
        }
        $run.Status.mcp.mode | Should Be 'inherit'
        $run.Status.mcp.reason | Should BeNullOrEmpty
    }

    It '6d: Ola 6: un nombre desconocido cierra FAILED mcp_desconocido sin lanzar sesiones' {
        $name = 'e2e-ola6-desconocido'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepMcpList)) -DriverArgs @('-UnsafeSkipPermissions', '-AllowMcp', 'NoExiste')

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Status.cause | Should Be 'mcp_desconocido'
        $run.Status.reason | Should Match 'NoExiste'
        @($run.Calls).Count | Should Be 1
        @($run.Status.history).Count | Should Be 0
        $run.Status.mcp | Should BeNullOrEmpty
    }

    It '6e: Ola 6: inventario fallido hereda todo con aviso y la corrida sigue' {
        $name = 'e2e-ola6-inventario-roto'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((New-FakeStep 1 -Stderr @('boom')), (Get-StepNivelOk (Get-FakePlanPath $name)), (Get-StepCierreOk)) -DriverArgs @('-UnsafeSkipPermissions', '-AllowMcp', 'playwright')

        $run.Status.globalStatus | Should Be 'DONE'
        @($run.Calls).Count | Should Be 3
        foreach ($c in @($run.Calls)[1..2]) {
            (@($c.args) -contains '--strict-mcp-config') | Should Be $false
            (@($c.args) -contains '--disallowedTools') | Should Be $false
        }
        $run.Status.mcp.mode | Should Be 'inherit'
        $run.Status.mcp.reason | Should Be 'inventario_fallido'
        $run.Output | Should Match 'Inventario de MCP fallido'
    }

    It '6f: Ola 6: modo perfil con -AllowMcp cierra FAILED mcp_requiere_unsafe sin inventario ni sesiones' {
        $name = 'e2e-ola6-perfil'
        $run = Invoke-FakeDriverRun -Name $name -Steps @((Get-StepCierreOk)) -DriverArgs @('-AllowMcp', 'playwright')

        $run.Status.globalStatus | Should Be 'FAILED'
        $run.Status.cause | Should Be 'mcp_requiere_unsafe'
        @($run.Calls).Count | Should Be 0
        @($run.Status.history).Count | Should Be 0
        $run.Status.mcp | Should BeNullOrEmpty
    }
}

Describe 'plan-session-driver (Ola 2a: limits, params, phase y git)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    function Get-ParamArgNode($Call, [string]$Name) {
        $els = @($Call.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
                return $(if ($null -ne $els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] })
            }
        }
        throw "falta el parametro -$Name"
    }

    function Get-NearestTry($Node) {
        $n = $Node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.TryStatementAst]) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    function Get-BlockCalls([string]$BlockName) {
        return @(Get-DriverCalls 'Set-DriverStatusBlock' | Where-Object {
                $arg = Get-ParamArgNode $_ 'Name'
                $arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $arg.Value -eq $BlockName
            })
    }

    function Test-CatchWarns($Try) {
        if ($null -eq $Try -or @($Try.CatchClauses).Count -eq 0) { return $false }
        return (@($Try.CatchClauses[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Warning' }, $true)).Count -gt 0)
    }

    It '2a: el prompt de cierre fija el formato de la revision final' {
        $closeStart = $text.IndexOf('$CLOSE_PROMPT_TEMPLATE = @''')
        $closeStart | Should BeGreaterThan -1
        $endMark = $text.IndexOf('Al terminar, agrega como última línea de tu respuesta EXACTAMENTE una de estas', $closeStart)
        $endMark | Should BeGreaterThan -1
        foreach ($lit in @('**Veredicto:** <texto breve del veredicto>', '| # | Severidad | Ubicación | Descripción | Fix sugerido |', 'La celda Severidad lleva exactamente CRITICAL, IMPORTANT o MINOR')) {
            $text | Should Match ([regex]::Escape($lit))
            $idx = $text.IndexOf($lit, $closeStart)
            $idx | Should BeGreaterThan $closeStart
            $idx | Should BeLessThan $endMark
        }
    }

    It '2a: limits y params se publican una vez, tras el presupuesto y antes del bucle, con aviso si fallan' {
        $modelo = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' -and $n.Extent.Text -match 'Modelo:' }, $true))
        $modelo.Count | Should Be 1
        $loops = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -match '\$sessionBudget' }, $true))
        $loops.Count | Should Be 1

        foreach ($blockName in @('limits', 'params')) {
            $calls = Get-BlockCalls $blockName
            $calls.Count | Should Be 1
            $calls[0].Extent.StartOffset | Should BeGreaterThan $modelo[0].Extent.StartOffset
            $calls[0].Extent.StartOffset | Should BeLessThan $loops[0].Extent.StartOffset
            (Test-CatchWarns (Get-NearestTry $calls[0])) | Should Be $true
        }
        $text | Should Match 'maxCostUsd = \$MaxCostUsd'
        $text | Should Match 'awaitDecisionMinutes = \$AwaitDecisionMinutes'
    }

    It '2a: phase y git se publican al inicio de cada iteracion y tras cada intento' {
        foreach ($fnName in @('Publish-DriverPhase', 'Publish-DriverGit')) {
            $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true))
            $fn.Count | Should Be 1
            $sets = @($fn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-DriverStatusBlock' }, $true))
            $sets.Count | Should Be 1
            (Test-CatchWarns (Get-NearestTry $sets[0])) | Should Be $true
        }
        $gitFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-DriverGit' }, $true))[0]
        @($gitFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-GitSummary' }, $true)).Count | Should Be 1

        $decisionAssign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$decision' -and $n.Right.Extent.Text -match 'Get-PlanBootstrapDecision' }, $true))
        $decisionAssign.Count | Should Be 1
        $doneIf = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$decision.Mode -eq ''done''' -and $n.Extent.Text -match 'break' }, $true))
        $doneIf.Count | Should Be 1
        $retryIf = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$canRetry' }, $true))
        $retryIf.Count | Should Be 1
        $event = Get-DriverCalls 'Add-DriverStatusEvent'
        $event.Count | Should Be 1

        foreach ($name in @('Publish-DriverPhase', 'Publish-DriverGit')) {
            $calls = Get-DriverCalls $name
            $calls.Count | Should Be 2
            $start = @($calls | Where-Object { $_.Extent.StartOffset -gt $decisionAssign[0].Extent.StartOffset -and $_.Extent.StartOffset -lt $doneIf[0].Extent.StartOffset })
            $start.Count | Should Be 1
            $after = @($calls | Where-Object { $_.Extent.StartOffset -gt $event[0].Extent.StartOffset -and $_.Extent.StartOffset -lt $retryIf[0].Extent.StartOffset })
            $after.Count | Should Be 1
            if ($name -eq 'Publish-DriverPhase') {
                (Get-ParamArgNode $start[0] 'Decision') | Should Not BeNullOrEmpty
            }
        }
    }

    It '2a: la base de Initialize-WorkBranch se conserva y se resuelve si falta' {
        $text | Should Match ([regex]::Escape('$baseBranch = Initialize-WorkBranch -RepoRoot $repoRoot -Branch $workBranch'))
        $text | Should Not Match ([regex]::Escape('Initialize-WorkBranch -RepoRoot $repoRoot -Branch $workBranch | Out-Null'))
        $text | Should Match ([regex]::Escape('$baseBranch = Resolve-WorkspaceBaseBranch -RepoRoot $repoRoot'))
    }

    function Test-InNodeRange($Node, $Container) {
        return ($Node.Extent.StartOffset -ge $Container.Extent.StartOffset -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset)
    }

    It 'Ola 3: importa DriverProfile.psm1 y PlanTasks.psm1' {
        $errors.Count | Should Be 0
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'DriverProfile\.psm1'\) -Force"
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'PlanTasks\.psm1'\) -Force"
    }

    It 'Ola 3: Publish-DriverTasks se llama tras cada publicacion de LevelTaskCounts y fuera de su try' {
        $progress = @(Get-DriverCalls 'Set-DriverStatusProgress' | Where-Object { $_.Extent.Text -match '-LevelTaskCounts' } | Sort-Object { $_.Extent.StartOffset })
        $pubs = @(Get-DriverCalls 'Publish-DriverTasks' | Sort-Object { $_.Extent.StartOffset })
        $progress.Count | Should Be 3
        $pubs.Count | Should Be 3

        $def = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-DriverTasks' }, $true))
        $def.Count | Should Be 1
        # Definida antes de la primera llamada: un script define las funciones en orden.
        $def[0].Extent.StartOffset | Should BeLessThan $progress[0].Extent.StartOffset
        $tries = @($def[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        $tries.Count | Should BeGreaterThan 0
        $tries[0].CatchClauses[0].Body.Extent.Text | Should Match 'Write-Warning'
        $tries[0].Body.Extent.Text | Should Match 'Get-PlanTasks'

        for ($i = 0; $i -lt 3; $i++) {
            $pubs[$i].Extent.StartOffset | Should BeGreaterThan $progress[$i].Extent.EndOffset
            if ($i -lt 2) { $pubs[$i].Extent.StartOffset | Should BeLessThan $progress[$i + 1].Extent.StartOffset }
            # Nunca dentro del try propio del progreso (el try de una sola instruccion que lo envuelve, como el de D2).
            $progressTry = Get-NearestTry $progress[$i]
            if ($progressTry -and @($progressTry.Body.Statements).Count -eq 1) {
                (Test-InNodeRange $pubs[$i] $progressTry) | Should Be $false
            }
        }
    }
}

Describe 'plan-session-driver (Ola 2b: canal de control, A2, A3, A5)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    function Get-DriverParam([string]$Name) {
        return ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    }

    function Get-ParamArgNode($Call, [string]$Name) {
        $els = @($Call.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
                return $(if ($null -ne $els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] })
            }
        }
        throw "falta el parametro -$Name"
    }

    function Get-NearestTry($Node) {
        $n = $Node.Parent
        while ($n) {
            if ($n -is [System.Management.Automation.Language.TryStatementAst]) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    function Get-Ancestor($Node, [type]$Type) {
        $n = $Node.Parent
        while ($n) {
            if ($Type.IsInstanceOfType($n)) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    It '2b: declara -AwaitDecisionMinutes 480 y -MaxCostUsd 0 con sus rangos' {
        $errors.Count | Should Be 0
        $await = Get-DriverParam 'AwaitDecisionMinutes'
        $await | Should Not BeNullOrEmpty
        $await.DefaultValue.Extent.Text | Should Be '480'
        ($await.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(0, 1440\)'
        $cost = Get-DriverParam 'MaxCostUsd'
        $cost | Should Not BeNullOrEmpty
        $cost.DefaultValue.Extent.Text | Should Be '0'
        ($cost.Attributes | ForEach-Object { $_.Extent.Text }) -join ' ' | Should Match 'ValidateRange\(0, 1000\)'
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'DriverControl\.psm1'\) -Force"
    }

    It '2b: genera el token, lo pasa al servidor, abre 127.0.0.1 con #t= y no lo pone en el aviso D5' {
        (Get-DriverCalls 'Get-DriverControlToken').Count | Should Be 1
        $start = Get-DriverCalls 'Start-DriverDashboard'
        $start.Count | Should Be 1
        (Get-ParamArgNode $start[0] 'ControlToken').Extent.Text | Should Be '$controlToken'
        $text.Contains('"http://127.0.0.1:$($dashboard.Port)/#t=$controlToken"') | Should Be $true

        $urlAssign = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$dashboardUrl' }, $true))
        $urlAssign.Count | Should Be 1
        $urlAssign[0].Extent.Text | Should Not Match 'controlToken'

        $control = @(Get-DriverCalls 'Set-DriverStatusBlock' | Where-Object {
                $arg = Get-ParamArgNode $_ 'Name'
                $arg -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $arg.Value -eq 'control'
            })
        $control.Count | Should Be 1
        $try = Get-NearestTry $control[0]
        $try | Should Not BeNullOrEmpty
        @($try.CatchClauses[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Warning' }, $true)).Count | Should BeGreaterThan 0
    }

    It '2b: borra la orden huerfana antes de crear el status y lanzar el dashboard' {
        $text | Should Match ([regex]::Escape('.driver-control.json'))
        $removes = @(Get-DriverCalls 'Remove-Item' | Where-Object {
                $loop = Get-Ancestor $_ ([System.Management.Automation.Language.ForEachStatementAst])
                $null -ne $loop -and $loop.Condition.Extent.Text -match '\$controlPath'
            })
        $removes.Count | Should Be 1
        $create = @(Get-DriverCalls 'New-DriverStatus')[0]
        $start = @(Get-DriverCalls 'Start-DriverDashboard')[0]
        $removes[0].Extent.StartOffset | Should BeLessThan $create.Extent.StartOffset
        $removes[0].Extent.StartOffset | Should BeLessThan $start.Extent.StartOffset
    }

    It '2b: la vigilancia lee el control en ticks de 1 s y detiene con el cleanup de causa dashboard' {
        $watch = @(Get-DriverCalls 'Invoke-DriverControlPoint' | Where-Object { $_.Extent.Text -match '-State\s+watch' })
        $watch.Count | Should Be 1
        $for = Get-Ancestor $watch[0] ([System.Management.Automation.Language.ForStatementAst])
        $for | Should Not BeNullOrEmpty
        $while = Get-Ancestor $for ([System.Management.Automation.Language.WhileStatementAst])
        $while.Condition.Extent.Text | Should Match 'HasExited'
        @($for.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -match '^Start-Sleep\s+-Seconds\s+1$' }, $true)).Count | Should Be 1
        $text | Should Not Match 'Start-Sleep\s+-Seconds\s+\$LivenessPollSeconds'

        $cleanup = @(Get-DriverCalls 'Invoke-DriverInterruptCleanup' | Where-Object { $_.Extent.Text -match "-Cause\s+'dashboard'" })
        $cleanup.Count | Should Be 1
        $hungIf = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$hung' -and
                    @($n.Clauses[0].Item2.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Stop-ProcessTree' }, $true)).Count -gt 0 }, $true))
        $hungIf.Count | Should Be 1
        $cleanup[0].Extent.StartOffset | Should BeLessThan $hungIf[0].Extent.StartOffset
    }

    It '2b: puntos entre sesiones al inicio y fin de la iteracion y antes del reintento; la espera corta con la senal' {
        $between = Get-DriverCalls 'Invoke-DriverBetweenPoint'
        $between.Count | Should Be 4
        @($between | Where-Object { $_.Extent.Text -match '-Signal\s+\$waitSignal' }).Count | Should Be 1

        $sessionWhile = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -match '\$sessionBudget' }, $true))[0]
        $heartbeat = @($sessionWhile.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-DriverStatusHeartbeat' }, $true))[0]
        $decision = @($sessionWhile.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-PlanBootstrapDecision' }, $true))[0]
        $first = @($between | Sort-Object { $_.Extent.StartOffset })[0]
        $first.Extent.StartOffset | Should BeGreaterThan $heartbeat.Extent.StartOffset
        $first.Extent.StartOffset | Should BeLessThan $decision.Extent.StartOffset

        $retryIf = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$canRetry' }, $true))[0]
        $wait = @(Get-DriverCalls 'Wait-RetryBackoff')[0]
        $inRetry = @($between | Where-Object { $_.Extent.StartOffset -ge $retryIf.Extent.StartOffset -and $_.Extent.EndOffset -le $retryIf.Extent.EndOffset -and $_.Extent.StartOffset -lt $wait.Extent.StartOffset })
        $inRetry.Count | Should Be 1

        $progress = @(Get-DriverCalls 'Set-DriverStatusProgress' | Sort-Object { $_.Extent.StartOffset })[-1]
        $last = @($between | Sort-Object { $_.Extent.StartOffset })[-1]
        $last.Extent.StartOffset | Should BeGreaterThan $progress.Extent.StartOffset

        (Get-ParamArgNode $wait 'PollSeconds').Extent.Text | Should Be '1'
        (Get-ParamArgNode $wait 'Seconds').Extent.Text | Should Match '\$between\.Paused'
        (Get-ParamArgNode $wait 'OnTick').Extent.Text | Should Match 'Invoke-DriverControlPoint -State between'
    }

    It '2b: set-params aplica en el proximo intento: modelo y corte capturados al lanzar' {
        $saves = Get-DriverCalls 'Save-SessionStreamLog'
        $saves.Count | Should Be 4
        foreach ($c in $saves) { (Get-ParamArgNode $c 'Model').Extent.Text | Should Be '$attemptModel' }

        $current = @(Get-DriverCalls 'Set-DriverStatusCurrentSession' | Where-Object { $_.Extent.Text -match '-SessionId\s+\$sessionId\b' })
        $current.Count | Should Be 1
        (Get-ParamArgNode $current[0] 'LivenessTimeoutMinutes').Extent.Text | Should Be '$attemptLivenessMinutes'

        $launch = @(Get-DriverCalls 'Start-HeadlessProcess')[0]
        $capture = $text.IndexOf('$attemptModel = $Model; $attemptLivenessMinutes = $LivenessTimeoutMinutes')
        $capture | Should BeGreaterThan -1
        # La captura que cuenta es la del lanzamiento: la ultima antes de Start-HeadlessProcess.
        $captures = @([regex]::Matches($text, [regex]::Escape('$attemptModel = $Model')) | Where-Object { $_.Index -lt $launch.Extent.StartOffset })
        $captures.Count | Should BeGreaterThan 1

        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-DriverLimits' }, $true))
        $fn.Count | Should Be 1
        (Get-DriverCalls 'Publish-DriverLimits').Count | Should BeGreaterThan 1
        $setFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-DriverRunParams' }, $true))
        $setFn.Count | Should Be 1
        $setFn[0].Extent.Text | Should Match ([regex]::Escape('$script:Model ='))
        $setFn[0].Extent.Text | Should Match 'Publish-DriverLimits'
    }
}

Describe 'plan-session-driver (Ola 2c: AWAITING, A1, A4, A6 y tope de costo)' {
    $script = Join-Path $moduleRoot 'scripts\plan-session-driver.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $text = Get-Content -LiteralPath $script -Raw

    function Get-DriverCalls([string]$Name) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
    }

    function Get-DriverFunction([string]$Name) {
        $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
        if ($found.Count -ne 1) { throw "se esperaba una sola funcion $Name y hay $($found.Count)" }
        return $found[0]
    }

    function Get-ParamArgNode($Call, [string]$Name) {
        $els = @($Call.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
                return $(if ($null -ne $els[$i].Argument) { $els[$i].Argument } else { $els[$i + 1] })
            }
        }
        throw "falta el parametro -$Name"
    }

    function Get-Ancestor($Node, [type]$Type) {
        $n = $Node.Parent
        while ($n) {
            if ($Type.IsInstanceOfType($n)) { return $n }
            $n = $n.Parent
        }
        return $null
    }

    function Test-InNode($Node, $Container) {
        return ($Node.Extent.StartOffset -ge $Container.Extent.StartOffset -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset)
    }

    function Get-IfByCondition([string]$Condition) {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq $Condition }, $true))
    }

    # Asignacion del bucle de sesiones: ancla por -ceq porque Publish-DriverPhase contiene "$Decision = Get-PlanBootstrapDecision".
    function Get-LoopDecisionAssign {
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$decision' -and $n.Right.Extent.Text -match 'Get-PlanBootstrapDecision' }, $true))
    }

    It '2c: importa DriverOpen.psm1 y declara los ganchos de prueba' {
        $errors.Count | Should Be 0
        $text | Should Match "Import-Module \(Join-Path \`$modulesDir 'DriverOpen\.psm1'\) -Force"
        $text.Contains('PLAN_DRIVER_AWAIT_WITHOUT_DASHBOARD') | Should Be $true
        $text.Contains('PLAN_DRIVER_OPEN_LOG') | Should Be $true
        (Get-DriverFunction 'Test-DriverAwaitEnabled').Extent.Text | Should Match ([regex]::Escape('$AwaitDecisionMinutes -gt 0'))
    }

    It '2c: Invoke-DriverAwaitPoint en los cuatro puntos de entrada y nunca en el catch exterior' {
        $calls = Get-DriverCalls 'Invoke-DriverAwaitPoint'
        $calls.Count | Should Be 4
        foreach ($c in $calls) {
            (Get-Ancestor $c ([System.Management.Automation.Language.CatchClauseAst])) | Should BeNullOrEmpty
        }

        $caps = @($calls | Where-Object { $_.Extent.Text -match '-Origin\s+tope_costo' } | Sort-Object { $_.Extent.StartOffset })
        $caps.Count | Should Be 2
        $firstBetween = @(Get-DriverCalls 'Invoke-DriverBetweenPoint' | Sort-Object { $_.Extent.StartOffset })[0]
        $decisionAssign = Get-LoopDecisionAssign
        $decisionAssign.Count | Should Be 1
        $caps[0].Extent.StartOffset | Should BeGreaterThan $firstBetween.Extent.StartOffset
        $caps[0].Extent.StartOffset | Should BeLessThan $decisionAssign[0].Extent.StartOffset

        $retryIf = (Get-IfByCondition '$canRetry')[0]
        $wait = @(Get-DriverCalls 'Wait-RetryBackoff')[0]
        (Test-InNode $caps[1] $retryIf) | Should Be $true
        $caps[1].Extent.StartOffset | Should BeGreaterThan $wait.Extent.StartOffset

        $hung = @($calls | Where-Object { $_.Extent.Text -match "-Cause\s+'colgada'" })
        $hung.Count | Should Be 1
        $hungIf = Get-Ancestor $hung[0] ([System.Management.Automation.Language.IfStatementAst])
        $hungIf.Clauses[0].Item1.Extent.Text | Should Be '$hung'
        $hungIf.Clauses[0].Item2.Extent.Text | Should Match ([regex]::Escape("`$finalStatus = 'FAILED'"))
        @($hungIf.Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-ProcessTree' }, $true)).Count | Should Be 0

        $decisionCalls = @($calls | Where-Object { $_.Extent.Text -match '\$sessionDecision\.GlobalStatus' })
        $decisionCalls.Count | Should Be 1
        $sessionIf = @(Get-IfByCondition '-not $sessionDecision.ShouldContinue')
        $sessionIf.Count | Should Be 1
        (Test-InNode $decisionCalls[0] $sessionIf[0]) | Should Be $true
    }

    It '2c-3: la sesion colgada entra con KillConfirmed y sin kill confirmado solo admite stop, set-params y open' {
        Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverControl.psm1') -Force
        $hung = @(Get-DriverCalls 'Invoke-DriverAwaitPoint' | Where-Object { $_.Extent.Text -match "-Cause\s+'colgada'" })
        $hung.Count | Should Be 1
        $hung[0].Extent.Text | Should Match '-KillConfirmed\s+\$killedOk'

        # Invoke-DriverAwaitPoint delega en Enter-DriverAwaiting, que es quien calcula las acciones admitidas.
        $point = Get-DriverFunction 'Invoke-DriverAwaitPoint'
        $enterCalls = @(Get-DriverCalls 'Enter-DriverAwaiting' | Where-Object { Test-InNode $_ $point })
        $enterCalls.Count | Should Be 1
        $enterCalls[0].Extent.Text | Should Match '-KillConfirmed\s+\$KillConfirmed'
        $enter = Get-DriverFunction 'Enter-DriverAwaiting'
        $allowedCalls = @(Get-DriverCalls 'Get-DriverAwaitingAllowed' | Where-Object { Test-InNode $_ $enter })
        $allowedCalls.Count | Should Be 1
        $allowedCalls[0].Extent.Text | Should Match '-KillConfirmed\s+\$KillConfirmed'

        ((Get-DriverAwaitingAllowed -Origin FAILED -KillConfirmed $false) -join ',') | Should Be 'stop,set-params,open'
    }

    It '2c-1: el texto de la respuesta se guarda para el respaldo y se limpia en cada iteracion' {
        $fn = Get-DriverFunction 'Invoke-DriverAwaitPoint'
        $save = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$script:answerFallbackText' -and $n.Right.Extent.Text -ceq '$a.Text' }, $true))
        $save.Count | Should Be 1
        $branch = Get-Ancestor $save[0] ([System.Management.Automation.Language.IfStatementAst])
        $branch.Clauses[0].Item1.Extent.Text | Should Match 'answer-resume'

        $clear = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$answerFallbackText' -and $n.Right.Extent.Text -ceq '$null' }, $true))
        $priorClear = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$priorCause' -and $n.Right.Extent.Text -ceq '$null' }, $true))
        # El inicio de cada iteracion es la primera asignacion de $priorCause = $null.
        $priorStart = @($priorClear | Sort-Object { $_.Extent.StartOffset })[0]
        $priorStart | Should Not BeNullOrEmpty
        @($clear | Where-Object { $_.Parent -eq $priorStart.Parent }).Count | Should Be 1

        # Hay dos if sobre $resumeMissing (el del retraso y el del respaldo): interesa el que arma los argumentos.
        $resumeIf = @(Get-IfByCondition '$resumeMissing' | Where-Object { $_.Clauses[0].Item2.Extent.Text.Contains('ConvertTo-RetryClaudeArgs') })
        $resumeIf.Count | Should Be 1
        $adds = @(Get-DriverCalls 'Add-DriverDecisionSection' | Where-Object { Test-InNode $_ $resumeIf[0] })
        $adds.Count | Should Be 1
        $adds[0].Extent.Text | Should Match '-Text\s+\$answerFallbackText'
        $conv = @(Get-DriverCalls 'ConvertTo-RetryClaudeArgs' | Where-Object { Test-InNode $_ $resumeIf[0] })
        $conv.Count | Should BeGreaterThan 0
        $adds[0].Extent.StartOffset | Should BeLessThan $conv[0].Extent.StartOffset
    }

    It '2c: el aviso de AWAITING va en su propio try, con -Status AWAITING y sin el token' {
        $fn = Get-DriverFunction 'Enter-DriverAwaiting'
        $sends = @(Get-DriverCalls 'Send-DriverNotification' | Where-Object { Test-InNode $_ $fn })
        $sends.Count | Should Be 1
        $sends[0].Extent.Text | Should Match '-Status\s+AWAITING'
        $try = Get-Ancestor $sends[0] ([System.Management.Automation.Language.TryStatementAst])
        $try | Should Not BeNullOrEmpty
        @($try.CatchClauses | Where-Object {
                @($_.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Write-Warning' }, $true)).Count -gt 0
            }).Count | Should BeGreaterThan 0
        (Get-ParamArgNode $sends[0] 'DashboardUrl').Extent.Text | Should Be '$awaitUrl'
        $sends[0].Extent.Text | Should Not Match 'controlToken'
        $urlAssign = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$awaitUrl' }, $true))
        $urlAssign.Count | Should Be 1
        $urlAssign[0].Extent.Text | Should Not Match 'controlToken'
        $urlAssign[0].Extent.Text | Should Not Match '#t='
        $fn.Extent.Text.Contains('#t=') | Should Be $false
        @($try.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-DriverStatusNotification' }, $true)).Count | Should Be 1
    }

    It '2c: la respuesta viaja como elemento del arreglo de argumentos' {
        $text | Should Not Match 'Invoke-Expression'
        $text | Should Not Match 'iex '
        $text | Should Not Match 'cmd /c'
        $text | Should Not Match 'cmd\.exe'
        $text.Contains('\.(cmd|bat)$') | Should Be $true

        (Get-DriverCalls 'Get-DriverAnswerPrompt').Count | Should Be 1
        $adds = Get-DriverCalls 'Add-DriverDecisionSection'
        $adds.Count | Should Be 2
        $literal = $text.IndexOf("`$promptText = if (`$decision.Mode -eq 'close')")
        $literal | Should BeGreaterThan -1
        foreach ($add in $adds) {
            $assign = Get-Ancestor $add ([System.Management.Automation.Language.AssignmentStatementAst])
            $assign.Left.Extent.Text | Should Be '$promptText'
            $add.Extent.StartOffset | Should BeGreaterThan $literal
        }
    }

    It '2c: el tope se comprueba antes de lanzar una sesion o un intento' {
        $calls = Get-DriverCalls 'Test-DriverCostCap'
        $calls.Count | Should Be 5
        $controlFn = Get-DriverFunction 'Invoke-DriverControlPoint'
        @($calls | Where-Object { Test-InNode $_ $controlFn }).Count | Should Be 3
        $outside = @($calls | Where-Object { -not (Test-InNode $_ $controlFn) } | Sort-Object { $_.Extent.StartOffset })
        $outside.Count | Should Be 2

        $decisionAssign = Get-LoopDecisionAssign
        $outside[0].Extent.StartOffset | Should BeLessThan $decisionAssign[0].Extent.StartOffset

        $retryIf = (Get-IfByCondition '$canRetry')[0]
        (Test-InNode $outside[1] $retryIf) | Should Be $true
        $recalc = @($retryIf.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -ceq '$sessionEffort' }, $true))
        $recalc.Count | Should Be 1
        $outside[1].Extent.StartOffset | Should BeLessThan $recalc[0].Extent.StartOffset
    }

    It '2c: Invoke-DriverControlPoint acepta awaiting y Set-DriverRunParams recalcula el plazo de la espera' {
        $controlFn = Get-DriverFunction 'Invoke-DriverControlPoint'
        (($controlFn.Body.ParamBlock.Parameters[0].Attributes | ForEach-Object { $_.Extent.Text }) -join ' ') | Should Match "'awaiting'"

        $setFn = Get-DriverFunction 'Set-DriverRunParams'
        $setFn.Extent.Text.Contains('$script:awaitSince') | Should Be $true
        $setFn.Extent.Text | Should Match '-State\s+AWAITING'

        $enter = Get-DriverFunction 'Enter-DriverAwaiting'
        $waits = @(Get-DriverCalls 'Wait-DriverPause' | Where-Object { Test-InNode $_ $enter })
        $waits.Count | Should Be 1
        $waits[0].Extent.Text | Should Match '-State\s+AWAITING'
        $waits[0].Extent.Text | Should Match '-ExitSignals'

        $openFn = Get-DriverFunction 'Invoke-DriverOpenOrder'
        $openFn.Extent.Text.Contains("'between'") | Should Be $true
        $openFn.Extent.Text.Contains('KillConfirmed') | Should Be $true
    }

    It 'Ola 3: los 3 lanzamientos usan $permissionArgs y el literal de permisos saltados solo vive tras -UnsafeSkipPermissions' {
        $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$(script:)?claudeArgs$' }, $true))
        $assigns.Count | Should Be 3
        foreach ($a in $assigns) {
            $a.Right.Extent.Text.Contains('$permissionArgs') | Should Be $true
            $a.Right.Extent.Text.Contains('--dangerously-skip-permissions') | Should Be $false
        }

        $literals = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq '--dangerously-skip-permissions' }, $true))
        $literals.Count | Should Be 1
        foreach ($l in $literals) {
            $if = Get-Ancestor $l ([System.Management.Automation.Language.IfStatementAst])
            $if | Should Not BeNullOrEmpty
            $if.Clauses[0].Item1.Extent.Text.Contains('$UnsafeSkipPermissions') | Should Be $true
        }
    }

    It 'Ola 3: UnsafeSkipPermissions es un switch sin valor por defecto, nunca se asigna ni sale del entorno o del canal' {
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UnsafeSkipPermissions' })
        $param.Count | Should Be 1
        $param[0].StaticType.FullName | Should Be 'System.Management.Automation.SwitchParameter'
        $param[0].DefaultValue | Should BeNullOrEmpty

        $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$(script:)?UnsafeSkipPermissions$' }, $true))
        $assigns.Count | Should Be 0
        ($text -match '(?i)env:[A-Za-z_]*UNSAFE') | Should Be $false

        $setFn = Get-DriverFunction 'Set-DriverRunParams'
        ($setFn.Extent.Text -match '(?i)Unsafe|permission') | Should Be $false
    }

    It 'Ola 6: los 3 lanzamientos suman $mcpArgs justo despues de $permissionArgs' {
        $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$(script:)?claudeArgs$' }, $true))
        $assigns.Count | Should Be 3
        foreach ($a in $assigns) {
            $a.Right.Extent.Text.Contains('$permissionArgs + $mcpArgs') | Should Be $true
        }
    }

    It 'Ola 6: AllowMcp es string[] vacio por defecto y no sale del entorno ni del canal' {
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowMcp' })
        $param.Count | Should Be 1
        $param[0].StaticType.FullName | Should Be 'System.String[]'
        $param[0].DefaultValue.Extent.Text | Should Be '@()'

        $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$(script:)?AllowMcp$' }, $true))
        $assigns.Count | Should Be 0
        ($text -match '(?i)env:[A-Za-z_]*MCP') | Should Be $false

        $setFn = Get-DriverFunction 'Set-DriverRunParams'
        ($setFn.Extent.Text -match '(?i)AllowMcp|mcpArgs|mcpPlan') | Should Be $false
        $control = Get-Content -LiteralPath (Join-Path $moduleRoot 'scripts\modules\DriverControl.psm1') -Raw
        ($control -match '(?i)allowMcp') | Should Be $false
    }

    It 'Ola 6: el FAILED de mcpPlan va despues del de perfil_invalido, al inicio del bucle' {
        $iProfile = $text.IndexOf("`$finalCause = 'perfil_invalido'")
        $iMcp = $text.IndexOf('$finalCause = $mcpPlan.cause')
        $iProfile | Should BeGreaterThan 0
        $iMcp | Should BeGreaterThan $iProfile
    }
}

$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverStatus.psm1') -Force

Describe 'DriverStatus lifecycle' {
    It 'New-DriverStatus crea el archivo con estado inicial RUNNING' {
        $path = Join-Path $TestDrive '.driver-status.json'
        $status = New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'docs/superpowers/plans/plan.md'
        Test-Path -LiteralPath $path | Should Be $true
        $status.globalStatus | Should Be 'RUNNING'
        $status.history.Count | Should Be 0
    }

    It 'New-DriverStatus inicializa currentSession en $null' {
        $path = Join-Path $TestDrive 'status-current-session-init.json'
        $status = New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md'
        $status.currentSession | Should Be $null
    }

    It 'Add-DriverStatusEvent agrega un evento al historial' {
        $path = Join-Path $TestDrive 'status-events.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath '.driver-logs/session-1.log' -SessionId 'sess-aaa'
        $updated.history.Count | Should Be 1
        $updated.history[0].iter | Should Be 1
        $updated.history[0].planStatus | Should Be 'CONTINUE'
    }

    It 'Add-DriverStatusEvent agrega el sessionId al evento' {
        $path = Join-Path $TestDrive 'status-events-sessionid.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-bbb'
        $updated.history[0].sessionId | Should Be 'sess-bbb'
    }

    It 'Add-DriverStatusEvent conserva el motivo del BLOCKED en el evento' {
        $path = Join-Path $TestDrive 'status-blocked-reason.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'BLOCKED' -LogPath 'a.log' -SessionId 'sess-b' -PlanStatusReason 'decision de contrato sobre el motor'
        $updated.history[0].planStatus | Should Be 'BLOCKED'
        $updated.history[0].planStatusReason | Should Be 'decision de contrato sobre el motor'
    }

    It 'Add-DriverStatusEvent deja planStatusReason nulo cuando no se pasa motivo' {
        $path = Join-Path $TestDrive 'status-sin-reason.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-c'
        $updated.history[0].planStatusReason | Should Be $null
    }

    It 'Add-DriverStatusEvent acumula varios eventos en orden' {
        $path = Join-Path $TestDrive 'status-multi.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-1' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 2 -ExitCode 0 -PlanStatus 'COMPLETE' -LogPath 'b.log' -SessionId 'sess-2'
        $updated.history.Count | Should Be 2
        $updated.history[1].planStatus | Should Be 'COMPLETE'
        $updated.history[1].sessionId | Should Be 'sess-2'
    }

    It 'Set-DriverStatusFinal marca el estado global final con motivo' {
        $path = Join-Path $TestDrive 'status-final.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'BLOCKED' -Reason 'revisar esquema'
        $updated.globalStatus | Should Be 'BLOCKED'
        $updated.reason | Should Be 'revisar esquema'
    }

    It 'M14: Set-DriverStatusFinal con Reason $null persiste reason null' {
        $path = Join-Path $TestDrive 'status-final-null.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'DONE' -Reason $null | Out-Null
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        ($null -eq $raw.reason) | Should Be $true
    }

    It 'M14: Set-DriverStatusFinal con Reason vacio persiste reason null' {
        $path = Join-Path $TestDrive 'status-final-empty.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'DONE' -Reason '' | Out-Null
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        ($null -eq $raw.reason) | Should Be $true
    }

    It 'Set-DriverStatusProgress actualiza nivel actual y total' {
        $path = Join-Path $TestDrive 'status-progress.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels 5 -CurrentLevel 2
        $updated.totalLevels | Should Be 5
        $updated.currentLevel | Should Be 2
    }

    It 'Set-DriverStatusProgress acepta $null explicito en TotalLevels y CurrentLevel' {
        $path = Join-Path $TestDrive 'status-progress-null.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels $null -CurrentLevel $null
        $updated.totalLevels | Should Be $null
        $updated.currentLevel | Should Be $null
    }

    It 'New-DriverStatus inicializa levelHistory vacio y levelTaskCounts $null' {
        $path = Join-Path $TestDrive 'status-level-init.json'
        $status = New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md'
        $status.levelHistory.Count | Should Be 0
        $status.levelTaskCounts | Should Be $null
    }

    It 'Set-DriverStatusProgress abre la primera entrada de levelHistory cuando CurrentLevel pasa de $null a 0' {
        $path = Join-Path $TestDrive 'status-level-open.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 0 -LevelTaskCounts @(2, 1, 1)
        $updated.levelHistory.Count | Should Be 1
        $updated.levelHistory[0].level | Should Be 0
        $updated.levelHistory[0].completedAt | Should Be $null
        $updated.levelTaskCounts[0] | Should Be 2
    }

    It 'Set-DriverStatusProgress cierra la entrada previa y abre la nueva cuando CurrentLevel avanza' {
        $path = Join-Path $TestDrive 'status-level-advance.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 0 -LevelTaskCounts @(2, 1, 1) | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 1 -LevelTaskCounts @(2, 1, 1)
        $updated.levelHistory.Count | Should Be 2
        $updated.levelHistory[0].level | Should Be 0
        $updated.levelHistory[0].completedAt | Should Not Be $null
        $updated.levelHistory[1].level | Should Be 1
        $updated.levelHistory[1].completedAt | Should Be $null
    }

    It 'Set-DriverStatusProgress no toca levelHistory cuando CurrentLevel es $null' {
        $path = Join-Path $TestDrive 'status-level-null.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels $null -CurrentLevel $null -LevelTaskCounts $null
        $updated.levelHistory.Count | Should Be 0
    }

    It 'Set-DriverStatusProgress publica el pipeline en bootstrap: totalLevels y levelTaskCounts con CurrentLevel $null y sin abrir levelHistory' {
        # Caso del arranque con plan detectado pero sin .controller-state.json
        # todavia (Fix B): el dashboard debe poder mostrar los niveles como
        # "pendiente" desde el inicio, sin que se abra ninguna entrada de nivel.
        $path = Join-Path $TestDrive 'status-bootstrap-pipeline.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel $null -LevelTaskCounts @(6, 1, 1)
        $updated.totalLevels | Should Be 3
        $updated.currentLevel | Should Be $null
        $updated.levelTaskCounts[0] | Should Be 6
        $updated.levelTaskCounts[2] | Should Be 1
        $updated.levelHistory.Count | Should Be 0
    }

    It 'Set-DriverStatusFinal cierra la entrada abierta de levelHistory al fijar un estado terminal' {
        $path = Join-Path $TestDrive 'status-level-final.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 1 -LevelTaskCounts @(2, 1, 1) | Out-Null
        $updated = Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'FAILED' -Reason 'exit code 1'
        $updated.levelHistory[0].level | Should Be 1
        $updated.levelHistory[0].completedAt | Should Not Be $null
    }

    It 'Set-DriverStatusProgress no duplica la entrada de levelHistory si CurrentLevel pasa transitoriamente a $null y vuelve al mismo nivel' {
        $path = Join-Path $TestDrive 'status-level-transient-null.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 1 -LevelTaskCounts @(2, 1, 1) | Out-Null
        Set-DriverStatusProgress -StatusPath $path -TotalLevels $null -CurrentLevel $null -LevelTaskCounts $null | Out-Null
        $updated = Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 1 -LevelTaskCounts @(2, 1, 1)
        ($updated.levelHistory | Where-Object { $_.level -eq 1 }).Count | Should Be 1
    }

    It 'Set-DriverStatusCurrentSession fija iter y sessionId' {
        $path = Join-Path $TestDrive 'status-current-session-set.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 'sess-xyz'
        $updated.currentSession.iter | Should Be 1
        $updated.currentSession.sessionId | Should Be 'sess-xyz'
    }

    It 'Set-DriverStatusCurrentSession con SessionId $null limpia currentSession' {
        $path = Join-Path $TestDrive 'status-current-session-clear.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 'sess-xyz' | Out-Null
        $updated = Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId $null
        $updated.currentSession | Should Be $null
    }

    It 'Add-DriverStatusEvent limpia currentSession al cerrar el evento de esa sesion' {
        $path = Join-Path $TestDrive 'status-current-session-autoclean.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 'sess-done' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-done'
        $updated.currentSession | Should Be $null
    }

    Context 'workBranch' {
        It 'New-DriverStatus inicializa workBranch en $null' {
            $path = Join-Path $TestDrive 'status-branch-init.json'
            New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
            (Get-DriverStatus -StatusPath $path).workBranch | Should Be $null
        }
        It 'Set-DriverStatusBranch persiste el nombre y Get-DriverStatus lo devuelve' {
            $path = Join-Path $TestDrive 'status-branch-set.json'
            New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
            Set-DriverStatusBranch -StatusPath $path -WorkBranch 'plan/x' | Out-Null
            (Get-DriverStatus -StatusPath $path).workBranch | Should Be 'plan/x'
        }
        It 'New-DriverStatus preserva workBranch si el estado ya existe (resume)' {
            $path = Join-Path $TestDrive 'status-branch-resume.json'
            New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
            Set-DriverStatusBranch -StatusPath $path -WorkBranch 'mi-rama' | Out-Null
            New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
            (Get-DriverStatus -StatusPath $path).workBranch | Should Be 'mi-rama'
        }
    }
}

Describe 'Add-DriverStatusEvent con causa (Fase 2)' {
    It 'escribe cause en el evento' {
        $path = Join-Path $TestDrive 'status-cause.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus $null -LogPath 'session-1.log' -SessionId 'sess-c1' -PlanStatusReason $null -Cause 'indeterminado' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.history[0].cause | Should Be 'indeterminado'
    }

    It 'sin -Cause el evento lleva cause nulo' {
        $path = Join-Path $TestDrive 'status-cause-null.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'session-1.log' -SessionId 'sess-c2' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ($s.history[0].PSObject.Properties.Name -contains 'cause') | Should Be $true
        $s.history[0].cause | Should Be $null
    }
}

Describe 'Add-DriverStatusEvent con telemetria (Fase 4, M13)' {
    It 'persiste el objeto telemetry del evento' {
        $path = Join-Path $TestDrive 'status-telemetry.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $tel = [pscustomobject]@{ model = 'claude-opus-5-5'; effort = 'high'; costUsd = 1.25; numTurns = 7 }
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'session-1.log' -SessionId 'sess-t' -Telemetry $tel | Out-Null
        $read = Get-DriverStatus -StatusPath $path
        $read.history[0].telemetry.model | Should Be 'claude-opus-5-5'
        $read.history[0].telemetry.effort | Should Be 'high'
        $read.history[0].telemetry.costUsd | Should Be 1.25
        $read.history[0].telemetry.numTurns | Should Be 7
    }

    It 'sin -Telemetry el evento queda con telemetry nulo' {
        $path = Join-Path $TestDrive 'status-no-telemetry.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'session-1.log' -SessionId 'sess-n' | Out-Null
        $read = Get-DriverStatus -StatusPath $path
        $read.history[0].telemetry | Should BeNullOrEmpty
    }

    It 'compatibilidad 1 (regla 4): status viejo sin telemetry recibe un evento nuevo y conserva los viejos' {
        $path = Join-Path $TestDrive 'status-old-format.json'
        $old = @'
{
  "projectPath": "C:\\proyecto",
  "planFile": "plan.md",
  "globalStatus": "RUNNING",
  "reason": null,
  "startedAt": "2026-10-01T10:00:00.0000000-04:00",
  "updatedAt": "2026-10-01T10:30:00.0000000-04:00",
  "totalLevels": 3,
  "currentLevel": 1,
  "levelTaskCounts": [2, 1, 1],
  "levelHistory": [],
  "currentSession": null,
  "workBranch": "feature/x",
  "history": [
    {
      "iter": 1,
      "timestamp": "2026-10-01T10:30:00.0000000-04:00",
      "exitCode": 0,
      "planStatus": "CONTINUE",
      "planStatusReason": null,
      "cause": "marca_valida",
      "logPath": "session-1-20261001-100000.log",
      "sessionId": "sess-old"
    }
  ]
}
'@
        Set-Content -LiteralPath $path -Value $old -Encoding utf8
        $tel = [pscustomobject]@{ model = 'claude-opus-5-5'; effort = 'medium'; costUsd = 0.5 }
        Add-DriverStatusEvent -StatusPath $path -Iter 2 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'session-2.log' -SessionId 'sess-new' -Cause 'marca_valida' -Telemetry $tel | Out-Null

        $read = Get-DriverStatus -StatusPath $path
        $read.history.Count | Should Be 2
        $read.history[0].sessionId | Should Be 'sess-old'
        ($read.history[0].PSObject.Properties.Name -contains 'telemetry') | Should Be $false
        $read.history[1].telemetry.effort | Should Be 'medium'
        $read.workBranch | Should Be 'feature/x'
    }
}

Describe 'DriverStatus Ola 1b (I2, B-4)' {
    It 'Set-DriverStatusCurrentSession con -StreamFile, -ErrFile y -LivenessTimeoutMinutes persiste los cuatro campos' {
        $path = Join-Path $TestDrive 'status-1b-session-fields.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 'sess-1b' -StreamFile 'session-1-20261027-100000.stream.jsonl' -ErrFile 'session-1-20261027-100000.err.log' -LivenessTimeoutMinutes 30 | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.currentSession.streamFile | Should Be 'session-1-20261027-100000.stream.jsonl'
        $s.currentSession.errFile | Should Be 'session-1-20261027-100000.err.log'
        $s.currentSession.livenessTimeoutMinutes | Should Be 30
        $s.currentSession.lastProgressAt | Should Not BeNullOrEmpty
        $s.currentSession.lastProgressAt | Should Be $s.currentSession.startedAt
    }

    It 'Set-DriverStatusCurrentSession sin los parametros nuevos deja streamFile, errFile y livenessTimeoutMinutes en null y fija lastProgressAt' {
        $path = Join-Path $TestDrive 'status-1b-session-nofields.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 2 -SessionId 'sess-nf' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $names = @($s.currentSession.PSObject.Properties.Name)
        ($names -join ',') | Should Be 'iter,sessionId,startedAt,streamFile,errFile,lastProgressAt,livenessTimeoutMinutes,attempt'
        $s.currentSession.streamFile | Should BeNullOrEmpty
        $s.currentSession.errFile | Should BeNullOrEmpty
        $s.currentSession.livenessTimeoutMinutes | Should BeNullOrEmpty
        $s.currentSession.lastProgressAt | Should Be $s.currentSession.startedAt
    }

    It 'Set-DriverStatusLiveness actualiza solo lastProgressAt y updatedAt' {
        $path = Join-Path $TestDrive 'status-1b-liveness.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 3 -SessionId 'sess-lv' -StreamFile 'a.stream.jsonl' -ErrFile 'a.err.log' -LivenessTimeoutMinutes 30 | Out-Null
        $updatedBefore = (Get-DriverStatus -StatusPath $path).updatedAt
        Start-Sleep -Milliseconds 20
        $when = [datetime]'2026-10-27T10:05:00'
        Set-DriverStatusLiveness -StatusPath $path -LastProgressAt $when | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ([datetime]$s.currentSession.lastProgressAt) | Should Be $when
        $s.updatedAt | Should Not Be $updatedBefore
        $s.currentSession.streamFile | Should Be 'a.stream.jsonl'
        $s.currentSession.iter | Should Be 3
        $s.currentSession.sessionId | Should Be 'sess-lv'
        $s.currentSession.livenessTimeoutMinutes | Should Be 30
    }

    It 'Set-DriverStatusLiveness sin sesion en curso no escribe el archivo' {
        $path = Join-Path $TestDrive 'status-1b-liveness-nosession.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $before = (Get-Item -LiteralPath $path).LastWriteTimeUtc
        $rawBefore = Get-Content -LiteralPath $path -Raw
        Start-Sleep -Milliseconds 50
        $result = Set-DriverStatusLiveness -StatusPath $path -LastProgressAt ([datetime]'2026-10-27T10:05:00')
        (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should Be $before
        (Get-Content -LiteralPath $path -Raw) | Should Be $rawBefore
        $result.currentSession | Should Be $null
    }

    It 'Set-DriverStatusLiveness agrega lastProgressAt a un currentSession de un driver viejo' {
        $path = Join-Path $TestDrive 'status-1b-liveness-old.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $old = Get-DriverStatus -StatusPath $path
        $old.currentSession = [pscustomobject]@{ iter = 1; sessionId = 'sess-old'; startedAt = '2026-10-27T10:00:00.0000000-05:00' }
        $old | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
        $when = [datetime]'2026-10-27T10:07:00'
        Set-DriverStatusLiveness -StatusPath $path -LastProgressAt $when | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ([datetime]$s.currentSession.lastProgressAt) | Should Be $when
        $s.currentSession.sessionId | Should Be 'sess-old'
    }

    It 'Add-DriverStatusEvent persiste streamFile y errFile' {
        $path = Join-Path $TestDrive 'status-1b-event-files.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $updated = Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-ev' -StreamFile 'a.stream.jsonl' -ErrFile 'a.err.log'
        $updated.history[0].streamFile | Should Be 'a.stream.jsonl'
        $updated.history[0].errFile | Should Be 'a.err.log'
    }

    It 'Add-DriverStatusEvent sin -StreamFile/-ErrFile el evento los deja en null' {
        $path = Join-Path $TestDrive 'status-1b-event-nofiles.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 'sess-ev2' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $names = @($s.history[0].PSObject.Properties.Name)
        ($names -contains 'streamFile') | Should Be $true
        ($names -contains 'errFile') | Should Be $true
        $s.history[0].streamFile | Should Be $null
        $s.history[0].errFile | Should Be $null
    }

    It 'Set-DriverStatusFinal acepta STOPPED, persiste reason y cierra levelHistory' {
        $path = Join-Path $TestDrive 'status-1b-stopped.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusProgress -StatusPath $path -TotalLevels 3 -CurrentLevel 1 -LevelTaskCounts @(2, 1, 1) | Out-Null
        $updated = Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'STOPPED' -Reason 'detenido por el usuario'
        $updated.globalStatus | Should Be 'STOPPED'
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'STOPPED'
        $s.reason | Should Be 'detenido por el usuario'
        $s.levelHistory[0].completedAt | Should Not BeNullOrEmpty
    }

    It 'Set-DriverStatusFinal sigue rechazando un estado fuera del set' {
        $p = Join-Path $TestDrive 'status-1b-badstate.json'
        New-DriverStatus -StatusPath $p -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        { Set-DriverStatusFinal -StatusPath $p -GlobalStatus 'CANCELADO' -Reason 'x' } | Should Throw 'GlobalStatus'
    }

    It 'Move-Item con reintento: con el status abierto por otro handle sin FileShare.Delete, Set-DriverStatusLiveness lanza tras 3 intentos y el status anterior queda intacto; al cerrar el handle, la siguiente escritura pasa' {
        $path = Join-Path $TestDrive 'status-1b-locked.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 'sess-lk' -StreamFile 'a.stream.jsonl' | Out-Null
        $rawBefore = Get-Content -LiteralPath $path -Raw
        $handle = [IO.File]::Open($path, 'Open', 'Read', 'Read')
        $lanzo = $false
        try {
            # try/catch en vez de Should Throw: el mensaje de IO es dependiente del idioma.
            try { Set-DriverStatusLiveness -StatusPath $path -LastProgressAt ([datetime]'2026-10-27T10:05:00') | Out-Null }
            catch { $lanzo = $true }
        }
        finally {
            $handle.Close()
        }
        $lanzo | Should Be $true
        Test-Path "$path.tmp" | Should Be $false
        (Get-Content -LiteralPath $path -Raw) | Should Be $rawBefore
        $when = [datetime]'2026-10-27T10:09:00'
        Set-DriverStatusLiveness -StatusPath $path -LastProgressAt $when | Out-Null
        ([datetime](Get-DriverStatus -StatusPath $path).currentSession.lastProgressAt) | Should Be $when
    }
}

Describe 'DriverStatus Ola 1a (D7)' {
    It 'New-DriverStatus escribe el bloque driver con pid, hora de inicio del proceso, heartbeat y heartbeatSeconds' {
        $dir = Join-Path $TestDrive 'd7-driver-block'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' -HeartbeatSeconds 45 | Out-Null
        $raw = Get-Content -LiteralPath $path -Raw
        $s = Get-DriverStatus -StatusPath $path
        $s.driver.pid | Should Be $PID
        $raw | Should Match '"processStartedAt":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"'
        $expected = (Get-Process -Id $PID).StartTime.ToUniversalTime()
        ([math]::Abs((([datetime]$s.driver.processStartedAt).ToUniversalTime() - $expected).TotalSeconds)) | Should BeLessThan 1
        $s.driver.heartbeatAt | Should Not BeNullOrEmpty
        $s.driver.heartbeatSeconds | Should Be 45

        $path2 = Join-Path $dir 'default.json'
        New-DriverStatus -StatusPath $path2 -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        (Get-DriverStatus -StatusPath $path2).driver.heartbeatSeconds | Should Be 30
    }

    It 'New-DriverStatus escribe previousRun nulo por defecto y el objeto recibido con -PreviousRun' {
        $dir = Join-Path $TestDrive 'd7-previous-run'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        (Get-DriverStatus -StatusPath $path).previousRun | Should Be $null

        $path2 = Join-Path $dir 'b.json'
        $prev = [pscustomobject]@{ file = '.driver-runs/20261027-221003-plan.json'; globalStatus = 'FAILED'; inherited = $true }
        New-DriverStatus -StatusPath $path2 -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' -PreviousRun $prev | Out-Null
        $s = Get-DriverStatus -StatusPath $path2
        $s.previousRun.file | Should Be '.driver-runs/20261027-221003-plan.json'
        $s.previousRun.globalStatus | Should Be 'FAILED'
        $s.previousRun.inherited | Should Be $true
    }

    It 'New-DriverStatus con -InheritFrom copia history y levelHistory y usa startedAt nuevo' {
        $dir = Join-Path $TestDrive 'd7-inherit'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        $previous = [pscustomobject]@{
            startedAt    = '2026-01-01T00:00:00.0000000Z'
            globalStatus = 'FAILED'
            history      = @(
                [pscustomobject]@{ iter = 1; exitCode = 0 },
                [pscustomobject]@{ iter = 2; exitCode = 1 }
            )
            levelHistory = @([pscustomobject]@{ level = 1; enteredAt = '2026-01-01T00:00:00.0000000Z'; completedAt = $null })
        }
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' -InheritFrom $previous | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        @($s.history).Count | Should Be 2
        $s.history[1].iter | Should Be 2
        @($s.levelHistory).Count | Should Be 1
        $s.globalStatus | Should Be 'RUNNING'
        ([math]::Abs((([datetime]$s.startedAt) - (Get-Date)).TotalSeconds)) | Should BeLessThan 60
    }

    It 'Set-DriverStatusHeartbeat actualiza heartbeatAt y updatedAt sin tocar la sesion en curso' {
        $dir = Join-Path $TestDrive 'd7-heartbeat'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 's-1' | Out-Null
        $before = Get-DriverStatus -StatusPath $path
        $beforeBeat = ([datetime]$before.driver.heartbeatAt).ToString('o')
        $beforeProgress = ([datetime]$before.currentSession.lastProgressAt).ToString('o')
        $beforeUpdated = ([datetime]$before.updatedAt).ToString('o')
        Start-Sleep -Milliseconds 20
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        $after = Get-DriverStatus -StatusPath $path
        ([datetime]$after.driver.heartbeatAt).ToString('o') | Should Not Be $beforeBeat
        ([datetime]$after.updatedAt).ToString('o') | Should Not Be $beforeUpdated
        ([datetime]$after.currentSession.lastProgressAt).ToString('o') | Should Be $beforeProgress
        $after.globalStatus | Should Be 'RUNNING'
    }

    It 'Set-DriverStatusHeartbeat con -LastProgressAt actualiza tambien lastProgressAt en la misma escritura' {
        $dir = Join-Path $TestDrive 'd7-heartbeat-progress'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 's-1' | Out-Null
        $beforeBeat = ([datetime](Get-DriverStatus -StatusPath $path).driver.heartbeatAt).ToString('o')
        Start-Sleep -Milliseconds 20
        $when = Get-Date '2026-10-27T10:00:00'
        Set-DriverStatusHeartbeat -StatusPath $path -LastProgressAt $when | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ([datetime]$s.currentSession.lastProgressAt) | Should Be $when
        ([datetime]$s.driver.heartbeatAt).ToString('o') | Should Not Be $beforeBeat

        # Sin sesion en curso: no lanza y currentSession sigue nulo.
        $path2 = Join-Path $dir 'b.json'
        New-DriverStatus -StatusPath $path2 -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        { Set-DriverStatusHeartbeat -StatusPath $path2 -LastProgressAt $when | Out-Null } | Should Not Throw
        (Get-DriverStatus -StatusPath $path2).currentSession | Should Be $null
    }

    It 'Set-DriverStatusHeartbeat sobre un status sin bloque driver no lo crea' {
        $dir = Join-Path $TestDrive 'd7-heartbeat-nodriver'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        @{ globalStatus = 'RUNNING'; history = @(); currentSession = $null; updatedAt = $null } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ($s.PSObject.Properties.Name -contains 'driver') | Should Be $false
        $s.updatedAt | Should Not BeNullOrEmpty
    }

    It 'Set-DriverStatusFinal actualiza driver.heartbeatAt por ultima vez' {
        $dir = Join-Path $TestDrive 'd7-final-heartbeat'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $beforeBeat = [datetime](Get-DriverStatus -StatusPath $path).driver.heartbeatAt
        Start-Sleep -Milliseconds 20
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus DONE -Reason 'x' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ([datetime]$s.driver.heartbeatAt) | Should BeGreaterThan $beforeBeat
        $s.globalStatus | Should Be 'DONE'
    }

    It 'Set-DriverStatusReason fija y limpia reason sin tocar globalStatus' {
        $dir = Join-Path $TestDrive 'd7-reason'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        $texto = 'Plan completo según current_level (completed_levels 2/3): pasa a cierre'
        Set-DriverStatusReason -StatusPath $path -Reason $texto | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.reason | Should Be $texto
        $s.globalStatus | Should Be 'RUNNING'
        Set-DriverStatusReason -StatusPath $path -Reason '' | Out-Null
        (Get-DriverStatus -StatusPath $path).reason | Should Be $null
    }

    It 'Save-DriverStatusArchive sin status previo devuelve null y no crea .driver-runs' {
        $dir = Join-Path $TestDrive 'd7-archive-none'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        Save-DriverStatusArchive -StatusPath $path | Should Be $null
        Test-Path -LiteralPath (Join-Path $dir '.driver-runs') | Should Be $false
    }

    It 'Save-DriverStatusArchive copia el status legible sin modificarlo con nombre de startedAt y hoja del plan' {
        $dir = Join-Path $TestDrive 'd7-archive-ok'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        @{
            startedAt    = '2026-10-27T22:10:03.5120000-04:00'
            planFile     = 'C:\p\docs\superpowers\plans\2026-10-27-mi-plan.md'
            globalStatus = 'FAILED'
        } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        $name = ([datetimeoffset]::Parse('2026-10-27T22:10:03.5120000-04:00')).LocalDateTime.ToString('yyyyMMdd-HHmmss') + '-2026-10-27-mi-plan.json'
        $r = Save-DriverStatusArchive -StatusPath $path
        $r.RelativePath | Should Be ('.driver-runs/' + $name)
        $r.Readable | Should Be $true
        $r.Previous.globalStatus | Should Be 'FAILED'
        $copy = Join-Path (Join-Path $dir '.driver-runs') $name
        Test-Path -LiteralPath $copy | Should Be $true
        ([IO.File]::ReadAllBytes($copy) -join ',') | Should Be ([IO.File]::ReadAllBytes($path) -join ',')
    }

    It 'Save-DriverStatusArchive agrega sufijos -2 y -3 y no borra lo existente' {
        $dir = Join-Path $TestDrive 'd7-archive-suffix'
        $runs = Join-Path $dir '.driver-runs'
        New-Item -ItemType Directory -Path $runs -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runs 'otro.json') -Value '{}' -Encoding utf8
        $path = Join-Path $dir '.driver-status.json'
        @{ startedAt = '2026-10-27T22:10:03.5120000-04:00'; planFile = 'C:\p\plan.md'; globalStatus = 'DONE' } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        $base = ([datetimeoffset]::Parse('2026-10-27T22:10:03.5120000-04:00')).LocalDateTime.ToString('yyyyMMdd-HHmmss') + '-plan'
        $r1 = Save-DriverStatusArchive -StatusPath $path
        $r2 = Save-DriverStatusArchive -StatusPath $path
        $r3 = Save-DriverStatusArchive -StatusPath $path
        $r1.RelativePath | Should Be (".driver-runs/$base.json")
        $r2.RelativePath | Should Be (".driver-runs/$base-2.json")
        $r3.RelativePath | Should Be (".driver-runs/$base-3.json")
        Test-Path -LiteralPath (Join-Path $runs 'otro.json') | Should Be $true
    }

    It 'Save-DriverStatusArchive copia un status ilegible con sufijo -ilegible y no devuelve Previous' {
        $dir = Join-Path $TestDrive 'd7-archive-bad'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        Set-Content -LiteralPath $path -Value '{ esto no es json' -Encoding utf8
        $r = Save-DriverStatusArchive -StatusPath $path
        $r.Readable | Should Be $false
        $r.Previous | Should Be $null
        $r.RelativePath | Should Match '^\.driver-runs/\d{8}-\d{6}-ilegible\.json$'
        ([IO.File]::ReadAllBytes($r.FullPath) -join ',') | Should Be ([IO.File]::ReadAllBytes($path) -join ',')
    }

    It 'Save-DriverStatusArchive sin startedAt ni planFile usa la hora del archivo y sin-plan' {
        $dir = Join-Path $TestDrive 'd7-archive-minimal'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        Set-Content -LiteralPath $path -Value '{"globalStatus":"DONE"}' -Encoding utf8
        (Get-Item -LiteralPath $path).LastWriteTime = [datetime]'2026-10-20 08:09:10'
        $r = Save-DriverStatusArchive -StatusPath $path
        $r.RelativePath | Should Be '.driver-runs/20261020-080910-sin-plan.json'
    }

    It 'Test-DriverStatusInheritable: mismo plan, misma rama y modo continue hereda' {
        $prev = [pscustomobject]@{ planFile = 'C:\p\plan.md'; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'c:\P\PLAN.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $true
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'c:\P\PLAN.md' -CurrentBranch 'feat/x' -FirstMode 'close' | Should Be $true
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'c:\P\PLAN.md' -CurrentBranch 'feat/x' -FirstMode 'done' | Should Be $true
    }

    It 'Test-DriverStatusInheritable: no hereda con bootstrap, otro plan, otra rama, sin rama previa, sin plan o sin previo' {
        $prev = [pscustomobject]@{ planFile = 'C:\p\plan.md'; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'C:\p\plan.md' -CurrentBranch 'feat/x' -FirstMode 'bootstrap' | Should Be $false
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'C:\p\otro.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'C:\p\plan.md' -CurrentBranch 'feat/y' -FirstMode 'continue' | Should Be $false
        $sinRama = [pscustomobject]@{ planFile = 'C:\p\plan.md'; workBranch = $null }
        Test-DriverStatusInheritable -Previous $sinRama -PlanFile 'C:\p\plan.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
        Test-DriverStatusInheritable -Previous $prev -PlanFile '' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
        Test-DriverStatusInheritable -Previous $null -PlanFile 'C:\p\plan.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
    }

    It '1a-4: Test-DriverStatusInheritable compara planFile sin distinguir mayusculas ni separadores' {
        $prev = [pscustomobject]@{ planFile = 'C:/Repo/Docs/Superpowers/Plans/P.md'; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'c:\repo\docs\superpowers\plans\p.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $true
        $conBarra = [pscustomobject]@{ planFile = 'C:/Repo/Docs/Superpowers/Plans/P.md/'; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $conBarra -PlanFile 'c:\repo\docs\superpowers\plans\p.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $true
    }

    It '1a-4: Test-DriverStatusInheritable no hereda si la ruta normalizada es otra' {
        $prev = [pscustomobject]@{ planFile = 'C:\repo\a\p.md'; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $prev -PlanFile 'C:\repo\b\p.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
        $vacio = [pscustomobject]@{ planFile = ''; workBranch = 'feat/x' }
        Test-DriverStatusInheritable -Previous $vacio -PlanFile 'C:\repo\a\p.md' -CurrentBranch 'feat/x' -FirstMode 'continue' | Should Be $false
    }

    It 'Get-DriverStatusMaxIter devuelve el maximo iter del historial y 0 sin historial' {
        $con = [pscustomobject]@{ history = @(
            [pscustomobject]@{ iter = 3 }, [pscustomobject]@{ iter = 7 }, [pscustomobject]@{ iter = 5 }) }
        Get-DriverStatusMaxIter -Status $con | Should Be 7
        Get-DriverStatusMaxIter -Status ([pscustomobject]@{ history = @() }) | Should Be 0
        Get-DriverStatusMaxIter -Status ([pscustomobject]@{ globalStatus = 'DONE' }) | Should Be 0
    }

    It 'New-DriverStatus y Set-DriverStatusHeartbeat dejan processStartedAt y heartbeatAt como texto con Z o ±hh:mm, a menos de 1 s del valor original' {
        $dir = Join-Path $TestDrive 'd7-roundtrip'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        $rawBefore = Get-Content -LiteralPath $path -Raw
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 's-1' | Out-Null
        $rawAfter = Get-Content -LiteralPath $path -Raw
        foreach ($key in 'processStartedAt', 'heartbeatAt') {
            $pattern = '"' + $key + '":\s*"([^"]*)"'
            $rawBefore -match $pattern | Should Be $true
            $original = $Matches[1]
            $rawAfter -match $pattern | Should Be $true
            $nuevo = $Matches[1]
            $nuevo | Should Match '(Z|[+-]\d{2}:\d{2})$'
            ([math]::Abs(([datetimeoffset]::Parse($nuevo) - [datetimeoffset]::Parse($original)).TotalSeconds)) | Should BeLessThan 1
        }
    }
}

Describe 'DriverStatus Ola 1b (D1 y D5)' {
    function New-1bStatus {
        param([string]$Name)
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        return $path
    }

    It 'Add-DriverStatusEvent sin parametros nuevos escribe attempt 0 y los demas campos nulos, sin transientRetries' {
        $path = New-1bStatus 'd1-defaults'
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'DONE' -LogPath 'a.log' -SessionId 's-1' | Out-Null
        $ev = @((Get-DriverStatus -StatusPath $path).history)[-1]
        $ev.attempt | Should Be 0
        foreach ($n in 'failureKind', 'failureMatch', 'resumedSessionId', 'priorCause') {
            ($null -ne $ev.PSObject.Properties[$n]) | Should Be $true
            $ev.$n | Should BeNullOrEmpty
        }
        ($null -eq $ev.PSObject.Properties['transientRetries']) | Should Be $true
    }

    It 'Add-DriverStatusEvent escribe attempt, failureKind, failureMatch, resumedSessionId y priorCause' {
        $path = New-1bStatus 'd1-campos'
        Add-DriverStatusEvent -StatusPath $path -Iter 2 -ExitCode 1 -PlanStatus $null -LogPath 'a.log' -SessionId 's-2' -Attempt 1 -FailureKind 'transient' -FailureMatch 'http_5xx' -ResumedSessionId 'id-1' -PriorCause 'exit_no_cero' | Out-Null
        $ev = @((Get-DriverStatus -StatusPath $path).history)[-1]
        $ev.attempt | Should Be 1
        $ev.failureKind | Should Be 'transient'
        $ev.failureMatch | Should Be 'http_5xx'
        $ev.resumedSessionId | Should Be 'id-1'
        $ev.priorCause | Should Be 'exit_no_cero'
        $raw = Get-Content -LiteralPath $path -Raw
        $orden = '"telemetry"', '"attempt"', '"failureKind"', '"failureMatch"', '"resumedSessionId"', '"priorCause"' | ForEach-Object { $raw.IndexOf($_) }
        foreach ($i in 0..5) { $orden[$i] | Should BeGreaterThan -1 }
        foreach ($i in 0..4) { $orden[$i] | Should BeLessThan $orden[$i + 1] }
    }

    It 'Add-DriverStatusEvent con -TransientRetries agrega transientRetries, incluido 0' {
        $path = New-1bStatus 'd1-retries'
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 1 -PlanStatus $null -LogPath 'a.log' -SessionId 's-1' -TransientRetries 2 -FailureKind 'transient' | Out-Null
        $ev = @((Get-DriverStatus -StatusPath $path).history)[-1]
        $ev.transientRetries | Should Be 2
        Add-DriverStatusEvent -StatusPath $path -Iter 2 -ExitCode 1 -PlanStatus $null -LogPath 'b.log' -SessionId 's-2' -TransientRetries 0 -FailureKind 'permanent' | Out-Null
        $ev = @((Get-DriverStatus -StatusPath $path).history)[-1]
        ($null -ne $ev.PSObject.Properties['transientRetries']) | Should Be $true
        $ev.transientRetries | Should Be 0
        $ev.failureKind | Should Be 'permanent'
    }

    It 'Set-DriverStatusCurrentSession guarda attempt en la sesion en curso, 0 por defecto' {
        $path = New-1bStatus 'd1-current'
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 's-1' | Out-Null
        (Get-DriverStatus -StatusPath $path).currentSession.attempt | Should Be 0
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId 's-1' -Attempt 2 | Out-Null
        (Get-DriverStatus -StatusPath $path).currentSession.attempt | Should Be 2
        Set-DriverStatusCurrentSession -StatusPath $path -Iter 1 -SessionId $null | Out-Null
        (Get-DriverStatus -StatusPath $path).currentSession | Should BeNullOrEmpty
    }

    It 'Set-DriverStatusNotification escribe notification sin tocar globalStatus ni reason' {
        $path = New-1bStatus 'd5-notification'
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'FAILED' -Reason 'exit code 1' | Out-Null
        Set-DriverStatusNotification -StatusPath $path -Notification ([pscustomobject][ordered]@{ sentAt = '2026-10-27T23:00:00.0000000-04:00'; toast = 'omitido'; webhook = 'ok'; webhookHost = 'ntfy.sh' }) | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.notification.toast | Should Be 'omitido'
        $s.notification.webhook | Should Be 'ok'
        $s.notification.webhookHost | Should Be 'ntfy.sh'
        $s.globalStatus | Should Be 'FAILED'
        $s.reason | Should Be 'exit code 1'
    }

    It 'Set-DriverStatusNotification sobre un status sin la clave la agrega' {
        $dir = Join-Path $TestDrive 'd5-sin-clave'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'viejo.json'
        @{ globalStatus = 'DONE'; history = @(); updatedAt = $null } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        Set-DriverStatusNotification -StatusPath $path -Notification ([pscustomobject]@{ sentAt = 'x'; toast = 'ok'; webhook = 'omitido'; webhookHost = $null }) | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        ($null -ne $s.PSObject.Properties['notification']) | Should Be $true
        $s.notification.toast | Should Be 'ok'
        $s.updatedAt | Should Not BeNullOrEmpty
    }
}

Describe 'DriverStatus Ola 2a (bloques limits, params, phase y git)' {
    function New-2aStatus {
        param([string]$Name)
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir '.driver-status.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        return $path
    }

    function Write-2aBlocks {
        param([string]$Path)
        Set-DriverStatusBlock -StatusPath $Path -Name limits -Value ([ordered]@{ sessionBudget = 8; budgetSource = 'auto'; iterBase = 0; maxTransientRetries = 2; noProgressRetries = 1; maxCostUsd = 0; awaitDecisionMinutes = 0 }) | Out-Null
        Set-DriverStatusBlock -StatusPath $Path -Name params -Value ([ordered]@{ planFile = 'plan.md'; workDir = 'C:\x' }) | Out-Null
        Set-DriverStatusBlock -StatusPath $Path -Name phase -Value ([ordered]@{ mode = 'bootstrap' }) | Out-Null
        Set-DriverStatusBlock -StatusPath $Path -Name git -Value ([ordered]@{ branch = 'feat/x'; baseBranch = 'master'; ahead = 3; error = $null }) | Out-Null
    }

    It 'Set-DriverStatusBlock escribe los cuatro bloques sin tocar globalStatus ni history' {
        $path = New-2aStatus 'bloques-cuatro'
        $antes = [regex]::Match((Get-Content -LiteralPath $path -Raw), '"updatedAt"\s*:\s*"([^"]*)"').Groups[1].Value
        Start-Sleep -Milliseconds 20
        Write-2aBlocks -Path $path
        $s = Get-DriverStatus -StatusPath $path
        $s.limits.sessionBudget | Should Be 8
        $s.limits.budgetSource | Should Be 'auto'
        $s.params.planFile | Should Be 'plan.md'
        $s.phase.mode | Should Be 'bootstrap'
        $s.git.branch | Should Be 'feat/x'
        $s.git.ahead | Should Be 3
        $s.globalStatus | Should Be 'RUNNING'
        @($s.history).Count | Should Be 0
        $s.updatedAt | Should Not BeNullOrEmpty
        # El texto crudo evita que ConvertFrom-Json convierta la fecha a [datetime].
        $despues = [regex]::Match((Get-Content -LiteralPath $path -Raw), '"updatedAt"\s*:\s*"([^"]*)"').Groups[1].Value
        $despues | Should Not BeNullOrEmpty
        $despues | Should Not Be $antes
    }

    It 'Set-DriverStatusBlock rechaza un nombre fuera de la lista' {
        $path = New-2aStatus 'bloques-nombre'
        { Set-DriverStatusBlock -StatusPath $path -Name 'otro' -Value @{ a = 1 } } | Should Throw 'Name'
        Set-DriverStatusBlock -StatusPath $path -Name 'control' -Value ([ordered]@{ enabled = $true; last = $null }) | Out-Null
        (Get-DriverStatus -StatusPath $path).control.enabled | Should Be $true
    }

    It 'Set-DriverStatusBlock acepta tasks y permissions' {
        $path = New-2aStatus 'bloques-ola3'
        $tasks = [ordered]@{
            items     = @([ordered]@{ id = 'T1'; title = 'Foo'; level = 0; status = 'done'; commit = 'abc1234'; fixCommits = [string[]]@() })
            updatedAt = '2026-10-28T08:10:45-04:00'
        }
        Set-DriverStatusBlock -StatusPath $path -Name tasks -Value $tasks | Out-Null
        Set-DriverStatusBlock -StatusPath $path -Name permissions -Value ([ordered]@{ mode = 'profile'; profile = 'plan' }) | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        @($s.tasks.items).Count | Should Be 1
        $s.tasks.items[0].id | Should Be 'T1'
        $s.tasks.items[0].status | Should Be 'done'
        @($s.tasks.items[0].fixCommits).Count | Should Be 0
        $s.permissions.mode | Should Be 'profile'
        $s.permissions.profile | Should Be 'plan'
        { Set-DriverStatusBlock -StatusPath $path -Name 'otro' -Value @{ a = 1 } } | Should Throw 'Name'
    }

    It 'Set-DriverStatusBlock acepta mcp (Ola 6)' {
        $path = New-2aStatus 'bloques-ola6'
        Set-DriverStatusBlock -StatusPath $path -Name mcp -Value ([ordered]@{ mode = 'allowlist'; allowed = [string[]]@('playwright'); blocked = 32; reason = $null }) | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.mcp.mode | Should Be 'allowlist'
        @($s.mcp.allowed)[0] | Should Be 'playwright'
        $s.mcp.blocked | Should Be 32
        $s.mcp.reason | Should BeNullOrEmpty
    }

    It 'Set-DriverStatusBlock reemplaza el bloque entero y lo agrega en un status viejo' {
        $dir = Join-Path $TestDrive 'bloques-viejo'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'viejo.json'
        @{ globalStatus = 'RUNNING'; history = @(); updatedAt = $null } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
        Set-DriverStatusBlock -StatusPath $path -Name phase -Value @{ mode = 'bootstrap' } | Out-Null
        (Get-DriverStatus -StatusPath $path).phase.mode | Should Be 'bootstrap'
        Set-DriverStatusBlock -StatusPath $path -Name phase -Value @{ mode = 'close'; finalReviewExists = $true } | Out-Null
        Set-DriverStatusBlock -StatusPath $path -Name phase -Value @{ mode = 'done' } | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.phase.mode | Should Be 'done'
        ($null -eq $s.phase.PSObject.Properties['finalReviewExists']) | Should Be $true
    }

    It 'Set-DriverStatusFinal conserva los bloques' {
        $path = New-2aStatus 'bloques-final'
        Write-2aBlocks -Path $path
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus 'DONE' -Reason 'ok' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'DONE'
        ($null -ne $s.PSObject.Properties['limits']) | Should Be $true
        ($null -ne $s.PSObject.Properties['params']) | Should Be $true
        ($null -ne $s.PSObject.Properties['phase']) | Should Be $true
        ($null -ne $s.PSObject.Properties['git']) | Should Be $true
        $s.limits.sessionBudget | Should Be 8
    }

    It 'git con un solo commit sigue siendo arreglo tras otra escritura' {
        $path = New-2aStatus 'bloques-git-arreglo'
        $git = [pscustomobject][ordered]@{
            branch     = 'feat/x'
            baseBranch = 'master'
            ahead      = 1
            commits    = @([pscustomobject][ordered]@{ hash = 'abc1234'; subject = 'feat: x' })
            diffstat   = [pscustomobject][ordered]@{ files = 5; insertions = 120; deletions = 8 }
            clean      = $true
            updatedAt  = '2026-10-27T20:00:00-04:00'
            error      = $null
        }
        Set-DriverStatusBlock -StatusPath $path -Name git -Value $git | Out-Null
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        (Get-Content -LiteralPath $path -Raw) | Should Match '"commits": \['
        $s = Get-DriverStatus -StatusPath $path
        @($s.git.commits).Count | Should Be 1
        $s.git.commits[0].hash | Should Be 'abc1234'
        $s.git.diffstat.files | Should Be 5
    }
}

Describe 'DriverStatus Ola 2b (control, pausa y acciones)' {
    function New-2bStatus {
        param([string]$Name)
        $path = Join-Path $TestDrive "$Name.json"
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\p' -PlanFile 'p.md' | Out-Null
        return $path
    }

    function New-2bEntry {
        param([int]$Iter, [string]$Id = ([guid]::NewGuid().ToString()))
        return [ordered]@{ id = $Id; action = 'pause'; params = [ordered]@{}; origin = 'dashboard'; requestedAt = '2026-10-27T20:00:00.000000+00:00'; appliedAt = '2026-10-27T20:00:01.000000+00:00'; result = 'applied'; detail = ''; iter = $Iter }
    }

    It 'Set-DriverStatusLiveState PAUSED escribe estado, motivo y bloque paused sin tocar history ni driver' {
        $path = New-2bStatus 'live-paused'
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 's-1' | Out-Null
        $before = Get-DriverStatus -StatusPath $path
        $block = [ordered]@{ since = '2026-10-27T20:00:00.000Z'; deadline = '2026-10-28T04:00:00.000Z'; actionId = 'a1' }
        Set-DriverStatusLiveState -StatusPath $path -State PAUSED -Reason 'En pausa (dashboard)' -Block $block | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'PAUSED'
        $s.reason | Should Be 'En pausa (dashboard)'
        # ConvertFrom-Json (pwsh 7) convierte las fechas ISO: se compara contra el texto crudo.
        (Get-Content -LiteralPath $path -Raw) | Should Match '"since": "2026-10-27T20:00:00.000Z"'
        $s.paused.actionId | Should Be 'a1'
        @($s.history).Count | Should Be 1
        $s.driver.processStartedAt | Should Be $before.driver.processStartedAt
        $s.driver.heartbeatAt | Should Be $before.driver.heartbeatAt
    }

    It 'Set-DriverStatusLiveState RUNNING quita paused y awaiting; PAUSED sin Block lanza; estados finales rechazados' {
        $path = New-2bStatus 'live-running'
        Set-DriverStatusLiveState -StatusPath $path -State PAUSED -Reason 'x' -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a' }) | Out-Null
        Set-DriverStatusLiveState -StatusPath $path -State RUNNING -Reason $null | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'RUNNING'
        $s.reason | Should BeNullOrEmpty
        ($null -eq $s.PSObject.Properties['paused']) | Should Be $true

        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $raw | Add-Member -NotePropertyName awaiting -NotePropertyValue ([pscustomobject]@{ since = 's' }) -Force
        $raw.globalStatus = 'AWAITING'
        $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
        Set-DriverStatusLiveState -StatusPath $path -State RUNNING | Out-Null
        ($null -eq (Get-DriverStatus -StatusPath $path).PSObject.Properties['awaiting']) | Should Be $true

        { Set-DriverStatusLiveState -StatusPath $path -State PAUSED } | Should Throw 'exige -Block'
        { Set-DriverStatusLiveState -StatusPath $path -State DONE } | Should Throw 'State'
    }

    It 'Set-DriverStatusFinal rechaza PAUSED y AWAITING, quita paused y awaiting y escribe cause solo con -Cause' {
        $path = New-2bStatus 'final-cause'
        { Set-DriverStatusFinal -StatusPath $path -GlobalStatus PAUSED -Reason 'r' } | Should Throw 'GlobalStatus'
        { Set-DriverStatusFinal -StatusPath $path -GlobalStatus AWAITING -Reason 'r' } | Should Throw 'GlobalStatus'
        Set-DriverStatusLiveState -StatusPath $path -State PAUSED -Reason 'x' -Block ([ordered]@{ since = 's'; deadline = $null; actionId = 'a' }) | Out-Null
        Set-DriverStatusFinal -StatusPath $path -GlobalStatus STOPPED -Reason 'r' -Cause 'dashboard' | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.globalStatus | Should Be 'STOPPED'
        $s.cause | Should Be 'dashboard'
        ($null -eq $s.PSObject.Properties['paused']) | Should Be $true

        $other = New-2bStatus 'final-sin-cause'
        Set-DriverStatusFinal -StatusPath $other -GlobalStatus DONE -Reason 'ok' | Out-Null
        ($null -eq (Get-DriverStatus -StatusPath $other).PSObject.Properties['cause']) | Should Be $true
    }

    It 'Add-DriverStatusAction agrega la entrada, fija control.last y conserva control.enabled; crea control si falta' {
        $path = New-2bStatus 'action-last'
        $e1 = New-2bEntry -Iter 1
        Add-DriverStatusAction -StatusPath $path -Entry $e1 | Out-Null
        $s = Get-DriverStatus -StatusPath $path
        $s.control.enabled | Should Be $false
        $s.control.last.id | Should Be $e1.id
        (@($s.control.last.PSObject.Properties.Name) -join ',') | Should Be 'id,action,result,detail,appliedAt'
        @($s.actions).Count | Should Be 1

        $path2 = New-2bStatus 'action-enabled'
        Set-DriverStatusBlock -StatusPath $path2 -Name control -Value ([ordered]@{ enabled = $true; last = $null }) | Out-Null
        Add-DriverStatusAction -StatusPath $path2 -Entry (New-2bEntry -Iter 1) | Out-Null
        $e2 = New-2bEntry -Iter 2
        Add-DriverStatusAction -StatusPath $path2 -Entry $e2 | Out-Null
        $s2 = Get-DriverStatus -StatusPath $path2
        $s2.control.enabled | Should Be $true
        $s2.control.last.id | Should Be $e2.id
        @($s2.actions).Count | Should Be 2
    }

    It 'Add-DriverStatusAction conserva solo las ultimas 200 entradas' {
        $path = New-2bStatus 'action-200'
        for ($i = 1; $i -le 205; $i++) {
            Add-DriverStatusAction -StatusPath $path -Entry (New-2bEntry -Iter $i) | Out-Null
        }
        $s = Get-DriverStatus -StatusPath $path
        @($s.actions).Count | Should Be 200
        @($s.actions)[0].iter | Should Be 6
        @($s.actions)[199].iter | Should Be 205
    }

    It 'actions con una sola entrada sigue siendo arreglo tras otra escritura' {
        $path = New-2bStatus 'action-un-elemento'
        Add-DriverStatusAction -StatusPath $path -Entry (New-2bEntry -Iter 1) | Out-Null
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        (Get-Content -LiteralPath $path -Raw) | Should Match '"actions": \['
    }
}

Describe 'DriverStatus Ola 4 (1a-5: lectura de fechas)' {
    $json = '{"globalStatus":"RUNNING","updatedAt":"2026-10-28T08:10:45-04:00","driver":{"pid":4242,"processStartedAt":"2026-10-28T12:00:00.123Z","heartbeatAt":"2026-10-28T12:05:30.456Z","heartbeatSeconds":30},"history":[{"iter":1,"at":"2026-10-28T12:01:00.0000000Z"}]}'

    It '1a-5: Test-JsonDateKindSupport coincide con el parametro DateKind de ConvertFrom-Json' {
        $r = Test-JsonDateKindSupport
        ($r -is [bool]) | Should Be $true
        $r | Should Be ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind'))
    }

    It '1a-5: rama anterior a 7.5 (Mock false): fechas del driver como texto identico y demas claves conservadas' {
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $false }
        $o = ConvertFrom-DriverJson -Text $json
        ($o.driver.processStartedAt -is [string]) | Should Be $true
        $o.driver.processStartedAt | Should Be '2026-10-28T12:00:00.123Z'
        $o.driver.heartbeatAt | Should Be '2026-10-28T12:05:30.456Z'
        $o.globalStatus | Should Be 'RUNNING'
        $o.driver.pid | Should Be 4242
        @($o.history).Count | Should Be 1
        Assert-MockCalled -ModuleName DriverStatus Test-JsonDateKindSupport -Times 1
    }

    It '1a-5: rama 7.5+ (Mock true): mismas fechas como texto' {
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $true }
        $o = ConvertFrom-DriverJson -Text $json
        ($o.driver.processStartedAt -is [string]) | Should Be $true
        $o.driver.processStartedAt | Should Be '2026-10-28T12:00:00.123Z'
        $o.driver.heartbeatAt | Should Be '2026-10-28T12:05:30.456Z'
        ($o.updatedAt -is [string]) | Should Be $true
    }

    It '1a-5: sin bloque driver ni fechas devuelve el objeto sin error en las dos ramas' {
        $plain = '{"globalStatus":"DONE","n":1}'
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $false }
        { ConvertFrom-DriverJson -Text $plain | Out-Null } | Should Not Throw
        $o = ConvertFrom-DriverJson -Text $plain
        $o.globalStatus | Should Be 'DONE'
        $o.n | Should Be 1
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $true }
        { ConvertFrom-DriverJson -Text $plain | Out-Null } | Should Not Throw
        $o = ConvertFrom-DriverJson -Text $plain
        $o.globalStatus | Should Be 'DONE'
        $o.n | Should Be 1
    }

    It '1a-5: con la rama anterior a 7.5 una escritura real conserva processStartedAt y heartbeatAt como texto' {
        Mock -ModuleName DriverStatus Test-JsonDateKindSupport { $false }
        $dir = Join-Path $TestDrive '1a5-rama-vieja'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'a.json'
        New-DriverStatus -StatusPath $path -ProjectPath 'C:\proyecto' -PlanFile 'plan.md' | Out-Null
        Set-DriverStatusHeartbeat -StatusPath $path | Out-Null
        $rawBefore = Get-Content -LiteralPath $path -Raw
        Add-DriverStatusEvent -StatusPath $path -Iter 1 -ExitCode 0 -PlanStatus 'CONTINUE' -LogPath 'a.log' -SessionId 's-1' | Out-Null
        $rawAfter = Get-Content -LiteralPath $path -Raw
        foreach ($key in 'processStartedAt', 'heartbeatAt') {
            $pattern = '"' + $key + '":\s*"([^"]*)"'
            $rawBefore -match $pattern | Should Be $true
            $original = $Matches[1]
            $rawAfter -match $pattern | Should Be $true
            $Matches[1] | Should Be $original
        }
    }
}

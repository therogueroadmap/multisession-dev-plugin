$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$htmlPath = Join-Path $moduleRoot 'assets\dashboard.html'

Describe 'dashboard.html' {
    It 'existe en assets/dashboard.html' {
        Test-Path -LiteralPath $htmlPath | Should Be $true
    }

    It 'hace polling contra /status.json' {
        (Get-Content -LiteralPath $htmlPath -Raw) | Should Match "fetch\('/status.json'"
    }

    It 'expone los elementos que el JS necesita para renderizar' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match 'id="globalStatus"'
        $content | Should Match 'id="history-body"'
        $content | Should Match 'id="progressFill"'
        $content | Should Match 'id="reason"'
    }

    It 'expone el encabezado pipeline y sus estados de color' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match 'id="pipeline-header"'
        $content | Should Match 'renderPipeline'
        $content | Should Match 'node-pending'
        $content | Should Match 'node-running'
        $content | Should Match 'node-success'
        $content | Should Match 'node-error'
    }

    It 'expone el elemento de sesion en curso y la columna Comando con boton de copiar' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match 'id="currentSession"'
        $content | Should Match '<th>Comando</th>'
        $content | Should Match 'resumeCommand'
        $content | Should Match 'copyCommand'
        $content | Should Match 'class="copy-btn"'
    }

    It 'muestra la causa de cada sesion y la usa para colorear (Fase 2)' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match 'function isFailedEntry\(ev\)'
        $content | Should Match 'function sessionLabel\(ev\)'
        $content | Should Match 'ev\.cause'
        $content | Should Match '<td>\$\{sessionLabel\(ev\)\}</td>'
        $content | Should Not Match "ev\.planStatus \|\| 'exit '"
    }

    It 'muestra modelo/effort y coste por sesion y el acumulado, tolerando eventos sin telemetry (Fase 4, regla 5)' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match '<th>Resultado</th><th>Modelo / effort</th><th>Coste</th><th>Log</th>'
        $content | Should Match 'id="totalCost"'
        $content | Should Match 'function modelEffortLabel\(ev\)'
        $content | Should Match 'function costLabel\(ev\)'
        $content | Should Match 'function renderTotalCost\(history\)'
        $content | Should Match 'ev\.telemetry && ev\.telemetry\.model'
        $content | Should Match "ev\.telemetry && typeof ev\.telemetry\.costUsd === 'number'"
        $content | Should Match '<td>\$\{modelEffortLabel\(ev\)\}</td><td>\$\{costLabel\(ev\)\}</td>'
        $content | Should Match 'renderTotalCost\(data\.history \|\| \[\]\)'
        # Fallback para eventos sin telemetry (driver viejo).
        $content | Should Match "'\u2014'"
        # Las tres guardas "ev.telemetry && ..." (modelEffortLabel, costLabel y el
        # filter de renderTotalCost): si alguien quita una, el conteo baja.
        $guardedUses = [regex]::Matches($content, 'ev\.telemetry && (typeof )?ev\.telemetry\.(model|costUsd)')
        $guardedUses.Count | Should Be 3
    }

    It 'con telemetry parcial sin effort muestra solo el modelo, nunca "modelo / undefined"' {
        $content = Get-Content -LiteralPath $htmlPath -Raw
        $content | Should Match 'ev\.telemetry\.effort \? `\$\{ev\.telemetry\.model\} / \$\{ev\.telemetry\.effort\}` : ev\.telemetry\.model'
    }
}

Describe 'dashboard: contrato del servidor con fixtures (1c)' {
    $demo = Join-Path $moduleRoot 'tests\fixtures\dashboard\Start-DashboardDemo.ps1'
    $noPython = -not (Get-Command python -ErrorAction SilentlyContinue)
    Import-Module (Join-Path $moduleRoot 'scripts\modules\HttpDashboard.psm1') -Force
    $script:statusPaths = @()

    AfterAll {
        # Por si un It fallo antes de su finally: mata lo que cuelgue de $TestDrive.
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$TestDrive*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $module = Get-Module HttpDashboard
        foreach ($sp in $script:statusPaths) {
            $logs = & $module { Get-DriverDashboardServerLogs -StatusPath $args[0] } $sp
            Remove-Item -LiteralPath $logs.Out, $logs.Err -Force -ErrorAction SilentlyContinue
        }
    }

    It 'activity.json de la sesion en vivo cumple el modelo de vista (tasks[].code, no task)' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State RUNNING -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $v = Invoke-RestMethod -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5
            $v.available | Should Be $true
            $v.session.iter | Should Be 3
            $v.session.live | Should Be $true
            $v.session.streamFile | Should Be 'session-3-20261015-154320.stream.jsonl'
            (@($v.tasks).code -join ',') | Should Be 'T4,T6,T9,otras'
            foreach ($t in @($v.tasks)) {
                (($t.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'code,cycles,done,reworkAlert,stages'
                foreach ($s in @($t.stages)) {
                    (($s.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'barId,label,role,state'
                }
            }
            $bar = @($v.bars)[0]
            (($bar.PSObject.Properties.Name | Sort-Object) -join ',') | Should Be 'description,endedAt,id,lastTool,role,startedAt,status,subagentType,task,tokens,toolUses'
            $t4 = @($v.tasks) | Where-Object { $_.code -eq 'T4' }
            $t4.cycles | Should Be 2
            $t4.reworkAlert | Should Be $false
            $t4.done | Should Be $true
            @($t4.stages).Count | Should Be 5
            $t9 = @($v.tasks) | Where-Object { $_.code -eq 'T9' }
            @($t9.stages)[0].state | Should Be 'run'
            (@($v.live) -join ',') | Should Be 'syn-t9'
            @($v.commits)[0].branch | Should Be 'feature/DEMO-1'
            @($v.commits)[0].at | Should Not BeNullOrEmpty
            $v.quota.fiveHour.utilization | Should Be 0.75
            $v.quota.sevenDay.utilization | Should Be 0.68
            $v.quota.observedAt | Should Not BeNullOrEmpty
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'activity.json de una sesion terminada marca unclosed y no run' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State STOPPED -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $v = Invoke-RestMethod -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5
            $v.available | Should Be $true
            $v.session.live | Should Be $false
            $t9 = @($v.tasks) | Where-Object { $_.code -eq 'T9' }
            @($t9.stages)[0].state | Should Be 'unclosed'
            $states = @($v.tasks.stages.state)
            ($states -contains 'run') | Should Be $false
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'activity.json de una sesion sin stream devuelve available false' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State RUNNING -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $v = Invoke-RestMethod -Uri "$($h.Url)activity.json?session=1" -NoProxy -TimeoutSec 5
            $v.available | Should Be $false
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'status.json y logs del panel final (BLOCKED)' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State BLOCKED -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $s = Invoke-RestMethod -Uri "$($h.Url)status.json" -NoProxy -TimeoutSec 5
            $s.globalStatus | Should Be 'BLOCKED'
            $s.currentSession | Should BeNullOrEmpty
            @($s.history)[-1].errFile | Should Be 'session-3-20261015-154320.err.log'

            $log = Invoke-WebRequest -Uri "$($h.Url)logs/session-3-20261015-154320.log?tail=30" -NoProxy -TimeoutSec 5
            $lines = @($log.Content -split "`r?`n" | Where-Object { $_ -ne '' })
            $lines.Count | Should Be 30
            $lines[-1] | Should Match 'PLAN_STATUS: BLOCKED'

            $err = Invoke-WebRequest -Uri "$($h.Url)logs/session-3-20261015-154320.err.log?tail=20" -NoProxy -TimeoutSec 5
            @($err.Content -split "`r?`n" | Where-Object { $_ -ne '' }).Count | Should Be 20

            $bad = Invoke-WebRequest -Uri "$($h.Url)logs/..%2F.driver-status.json" -NoProxy -TimeoutSec 5 -SkipHttpErrorCheck
            [int]$bad.StatusCode | Should Be 404
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'el status legado no rompe el servidor' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State LEGACY -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $r = Invoke-WebRequest -Uri "$($h.Url)status.json" -NoProxy -TimeoutSec 5 -SkipHttpErrorCheck
            [int]$r.StatusCode | Should Be 200
            $s = $r.Content | ConvertFrom-Json
            $s.PSObject.Properties.Name -contains 'workBranch' | Should Be $false
            $v = Invoke-RestMethod -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5
            $v.available | Should Be $false
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'el demo con -Rebase deja la ultima actividad en los ultimos 2 minutos' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State RUNNING -Root $Root -Rebase
        $script:statusPaths += $h.StatusPath
        try {
            $act = Invoke-WebRequest -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5
            $sta = Invoke-WebRequest -Uri "$($h.Url)status.json" -NoProxy -TimeoutSec 5
            $m1 = [regex]::Match($act.Content, '"lastEventAt"\s*:\s*"([^"]+)"')
            $m2 = [regex]::Match($sta.Content, '"lastProgressAt"\s*:\s*"([^"]+)"')
            $m1.Success | Should Be $true
            $m2.Success | Should Be $true
            $now = [DateTimeOffset]::UtcNow
            ($now - [DateTimeOffset]::Parse($m1.Groups[1].Value)).TotalSeconds | Should BeLessThan 300
            ($now - [DateTimeOffset]::Parse($m2.Groups[1].Value)).TotalSeconds | Should BeLessThan 300
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }
}

$noNode = -not (Get-Command node -ErrorAction SilentlyContinue)

# Ejecuta una expresion JS contra el bloque puro de la pagina y devuelve su JSON ya parseado.
function Invoke-DashboardPure([string]$Expr) {
    $html = Get-Content -LiteralPath $htmlPath -Raw
    $m = [regex]::Match($html, '(?s)// == puro:inicio ==(.*?)// == puro:fin ==')
    if (-not $m.Success) { throw 'No se encontro el bloque puro en dashboard.html' }
    $tail = "`nconsole.log((JSON.stringify((function(){ return $Expr; })()) ?? 'null').replace(/[\u0080-￿]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')));`n"
    $file = Join-Path $TestDrive ('pure-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.js')
    [IO.File]::WriteAllText($file, $m.Groups[1].Value + $tail, [Text.UTF8Encoding]::new($false))
    $out = & node $file 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("node fallo: " + ($out -join "`n")) }
    return (($out -join "`n") | ConvertFrom-Json)
}

Describe 'dashboard.html (1c): logica pura y estructura' {
    $demo = Join-Path $moduleRoot 'tests\fixtures\dashboard\Start-DashboardDemo.ps1'
    $fixtures = Join-Path $moduleRoot 'tests\fixtures\dashboard'
    $noPython = -not (Get-Command python -ErrorAction SilentlyContinue)
    Import-Module (Join-Path $moduleRoot 'scripts\modules\HttpDashboard.psm1') -Force
    $script:statusPaths = @()

    AfterAll {
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$TestDrive*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $module = Get-Module HttpDashboard
        foreach ($sp in $script:statusPaths) {
            $logs = & $module { Get-DriverDashboardServerLogs -StatusPath $args[0] } $sp
            Remove-Item -LiteralPath $logs.Out, $logs.Err -Force -ErrorAction SilentlyContinue
        }
    }

    It 'el bloque puro existe y define las funciones del contrato (2a)' -Skip:$noNode {
        $r = Invoke-DashboardPure "[typeof isFinalStatus, typeof nextPollDelay, typeof shouldNotify, typeof livenessInfo, typeof elapsedMs, typeof quotaView, typeof sessionOptions, typeof defaultSessionIter, typeof activityUrl, typeof logLeaf, typeof suggestedAction, typeof finalPanelInfo, typeof driverDeadInfo, typeof shouldNotifyDriverDead, typeof waitReasonText, typeof attemptLabel, typeof durationText, typeof telemetryCells, typeof iterBaseOf, typeof costView, typeof sessionsView, typeof retriesView, typeof endEstimate, typeof gitView, typeof finalReviewView, typeof phaseBadge, typeof shouldFetchFinalReview, typeof shouldHideFinalReview, typeof readFragmentToken, typeof availableActions, typeof controlBarView, typeof controlRequest, typeof controlErrorText, typeof controlResultView, typeof paramsCurrent, typeof changedParams, typeof stopConfirmState, typeof pausedInfo, typeof actionRows, typeof levelNodeState, typeof actionParams, typeof openTargets, typeof openParams, typeof answerTextError, typeof awaitingInfo, typeof planTasksView, typeof integrationView, typeof permissionsView, typeof staleStopState, typeof staleStopText]"
        @($r).Count | Should Be 50
        foreach ($t in @($r)) { $t | Should Be 'function' }
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $block = [regex]::Match($html, '(?s)// == puro:inicio ==(.*?)// == puro:fin ==').Groups[1].Value
        $block | Should Not BeNullOrEmpty
        ($block -cmatch '\bdocument\.|\bwindow\.|\bfetch\(|\blocalStorage\b|\bNotification\b') | Should Be $false
    }

    It 'D1: attemptLabel y sessionOptions muestran el reintento y una opcion por sesion' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const opts = sessionOptions({globalStatus:'FAILED', history:[{iter:1,attempt:0},{iter:1,attempt:1},{iter:2,attempt:0}]});
  const cur = sessionOptions({globalStatus:'RUNNING', history:[{iter:1,attempt:0},{iter:2,attempt:0}], currentSession:{iter:2, attempt:1}});
  return {
    vacios: [attemptLabel({attempt:0}) === '', attemptLabel({}) === '', attemptLabel({attempt:'2'}) === ''],
    dos: attemptLabel({attempt:2}) === ' \u00b7 reintento 2',
    count: opts.length,
    iters: opts.map(o => o.iter),
    l1: opts[0].label === 'Sesi\u00f3n 1 \u00b7 reintento 1',
    l2: opts[1].label === 'Sesi\u00f3n 2',
    curCount: cur.length,
    curLabel: cur[1].label === 'Sesi\u00f3n 2 \u00b7 reintento 1 (en curso)',
    curLive: cur[1].live === true
  };
})()
"@
        ((@($r.vacios) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,True,True'
        $r.dos | Should Be $true
        $r.count | Should Be 2
        ((@($r.iters) | ForEach-Object { "$_" }) -join ',') | Should Be '1,2'
        $r.l1 | Should Be $true
        $r.l2 | Should Be $true
        $r.curCount | Should Be 2
        $r.curLabel | Should Be $true
        $r.curLive | Should Be $true
    }

    It 'D1: el pipeline y la tabla del historial usan attemptLabel' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $pipeline = [regex]::Match($html, '(?s)function renderPipelineSessions\(.*?\n    \}\r?\n').Value
        $pipeline | Should Not BeNullOrEmpty
        $pipeline | Should Match 'attemptLabel\(ev\)'
        $hist = [regex]::Match($html, '(?s)safeRender\(''history-body''.*?\n      \}\);').Value
        $hist | Should Not BeNullOrEmpty
        $hist | Should Match 'attemptLabel\(ev\)'
        ($pipeline -cmatch '\.attempt\b') | Should Be $false
        ($hist -cmatch '\.attempt\b') | Should Be $false
    }

    It 'isFinalStatus y nextPollDelay: el polling se detiene con un status final y sigue a 4000 con sesion no viva, 503, error de red y {}' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  finals: ['DONE','BLOCKED','FAILED','STOPPED','STOPPED_MAX_ITERATIONS'].map(s => isFinalStatus(s)),
  running: isFinalStatus('RUNNING'),
  undef: isFinalStatus(undefined),
  stops: ['DONE','BLOCKED','FAILED','STOPPED','STOPPED_MAX_ITERATIONS'].map(s => String(nextPollDelay(200, {globalStatus: s}))),
  keep: [
    nextPollDelay(200, {globalStatus:'RUNNING'}),
    nextPollDelay(200, {globalStatus:'RUNNING'}, {session:{live:true}}),
    nextPollDelay(503, null),
    nextPollDelay(0, null),
    nextPollDelay(200, {})
  ],
  slow: nextPollDelay(200, {globalStatus:'RUNNING'}, {session:{live:false}})
}
"@
        ((@($r.finals) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,True,True,True,True'
        $r.running | Should Be $false
        $r.undef | Should Be $false
        (@($r.stops) -join ',') | Should Be 'null,null,null,null,null'
        (@($r.keep) -join ',') | Should Be '4000,4000,4000,4000,4000'
        $r.slow | Should Be 4000
    }

    It 'shouldNotify solo en la transicion desde RUNNING a final y nunca en el primer poll' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldNotify('RUNNING','DONE',false), shouldNotify('RUNNING','BLOCKED',true), shouldNotify('RUNNING','RUNNING',false), shouldNotify('DONE','DONE',false), shouldNotify(null,'FAILED',false)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,False,False,False,False'
    }

    It 'livenessInfo en RUNNING usa la hora mas reciente y calcula el corte' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const st = {globalStatus:'RUNNING', currentSession:{lastProgressAt:'2026-10-15T20:00:00Z', livenessTimeoutMinutes:30}};
  const act = {lastEventAt:'2026-10-15T20:10:00Z'};
  const stNoTimeout = {globalStatus:'RUNNING', currentSession:{lastProgressAt:'2026-10-15T20:00:00Z'}};
  const stNoProgress = {globalStatus:'RUNNING', currentSession:{livenessTimeoutMinutes:30}};
  return {
    a: livenessInfo(st, act, Date.parse('2026-10-15T20:12:00Z')),
    b: livenessInfo(st, act, Date.parse('2026-10-15T20:26:00Z')),
    c: livenessInfo(stNoTimeout, null, Date.parse('2026-10-15T20:02:00Z')),
    d: livenessInfo(stNoProgress, null, Date.parse('2026-10-15T20:02:00Z'))
  };
})()
"@
        $r.a.secondsAgo | Should Be 120
        $r.a.remainingMs | Should Be (18 * 60000)
        $r.a.warn | Should Be $false
        $r.b.warn | Should Be $true
        $r.c.secondsAgo | Should Be 120
        $r.c.remainingMs | Should BeNullOrEmpty
        $r.c.warn | Should Be $false
        $r.d.secondsAgo | Should BeNullOrEmpty
    }

    It 'sin cuenta regresiva ni fin estimado fuera de RUNNING' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
['BLOCKED','DONE','FAILED','STOPPED'].map(s => String(livenessInfo({globalStatus:s, currentSession:{lastProgressAt:'2026-10-15T20:00:00Z', livenessTimeoutMinutes:30}}, {lastEventAt:'2026-10-15T20:10:00Z'}, Date.parse('2026-10-15T20:12:00Z'))))
"@
        (@($r) -join ',') | Should Be 'null,null,null,null'
        $e = Invoke-DashboardPure @"
['BLOCKED','DONE','FAILED','STOPPED','PAUSED','AWAITING'].map(s => String(endEstimate({globalStatus:s, totalLevels:4, currentLevel:2, levelHistory:[{enteredAt:'2026-10-15T20:00:00Z', completedAt:'2026-10-15T20:10:00Z'}]}, Date.parse('2026-10-15T20:12:00Z'))))
"@
        (@($e) -join ',') | Should Be 'null,null,null,null,null,null'
    }

    It 'elapsedMs y quotaView, con fechas de 7 decimales y desfase' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const now = Date.parse('2026-10-15T21:00:00Z');
  return {
    utc: elapsedMs({globalStatus:'DONE', startedAt:'2026-10-15T19:00:00Z', updatedAt:'2026-10-15T20:30:00Z'}, now),
    off: elapsedMs({globalStatus:'DONE', startedAt:'2026-10-27T08:00:00.0000000-04:00', updatedAt:'2026-10-27T09:30:12.0000000-04:00'}, now),
    run: elapsedMs({globalStatus:'RUNNING', startedAt:'2026-10-15T19:00:00Z', updatedAt:'2026-10-15T20:30:00Z'}, now),
    none: elapsedMs({globalStatus:'RUNNING', updatedAt:'2026-10-15T20:30:00Z'}, now),
    q: quotaView({fiveHour:{utilization:0.75, resetsAt:'2026-10-15T22:30:00.000Z'}, sevenDay:null, observedAt:'x'}),
    qnull: quotaView(null)
  };
})()
"@
        $r.utc | Should Be 5400000
        $r.off | Should Be 5412000
        $r.run | Should Be 7200000
        $r.none | Should BeNullOrEmpty
        $r.q.fiveHour.pct | Should Be 75
        $r.q.sevenDay | Should BeNullOrEmpty
        $r.qnull | Should BeNullOrEmpty
    }

    It 'sessionOptions, defaultSessionIter y activityUrl' -Skip:$noNode {
        $running = Get-Content -LiteralPath (Join-Path $fixtures 'status-running.json') -Raw
        $blocked = Get-Content -LiteralPath (Join-Path $fixtures 'status-blocked.json') -Raw
        $r = Invoke-DashboardPure @"
{
  run: sessionOptions($running),
  defRun: defaultSessionIter($running),
  blk: sessionOptions($blocked),
  defBlk: defaultSessionIter($blocked),
  empty: sessionOptions({}),
  defEmpty: defaultSessionIter({}),
  u2: activityUrl(2),
  uNull: activityUrl(null)
}
"@
        (@($r.run).iter -join ',') | Should Be '1,2,3'
        @($r.run)[2].label | Should Match 'en curso'
        @($r.run)[2].live | Should Be $true
        $r.defRun | Should Be 3
        (@($r.blk).iter -join ',') | Should Be '1,2,3'
        (@($r.blk).label -join ',') | Should Not Match 'en curso'
        $r.defBlk | Should Be 3
        @($r.empty).Count | Should Be 0
        $r.defEmpty | Should BeNullOrEmpty
        $r.u2 | Should Be '/activity.json?session=2'
        $r.uNull | Should Be '/activity.json'
    }

    It 'expone los ids de los paneles de esta parte' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $ids = 'meta', 'notify-toggle', 'globalStatus', 'liveness', 'kpi-session', 'kpi-elapsed', 'totalCost',
            'kpi-quota5h', 'kpi-quota7d', 'pipeline-header', 'progressFill', 'currentSession', 'poll-state',
            'refresh-now', 'session-select', 'activity-meta', 'history-body',
            'final-panel', 'reason', 'final-cause', 'final-plan-reason', 'final-log', 'final-err', 'final-action', 'final-resume'
        $ids.Count | Should Be 25
        foreach ($id in $ids) { $html | Should Match ('id="' + [regex]::Escape($id) + '"') }
    }

    It 'consulta las rutas del servidor y respeta el 503' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should Match "fetch\('/status.json'"
        $html | Should Match 'activityUrl\('
        $html | Should Match 'nextPollDelay\('
        $html | Should Match '503'
        $html | Should Match "fetch\('/logs/' \+ encodeURIComponent\("
        $html | Should Match 'tail=30'
        $html | Should Match 'tail=20'
        $html | Should Not Match 'JSON\.parse\(\s*await'
        $html | Should Not Match 'arrayBuffer\('
    }

    It 'robustez: safeRender por panel, localStorage en try y Notification protegida' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        [regex]::Matches($html, 'safeRender\(').Count | Should BeGreaterThan 7
        [regex]::Matches($html, 'localStorage').Count | Should Be 2
        foreach ($fn in 'function loadNotifyPref\(\)', 'function saveNotifyPref\(v\)') {
            $m = [regex]::Match($html, '(?s)' + $fn + '\s*\{.*?\n    \}')
            $m.Success | Should Be $true
            $m.Value.IndexOf('try') | Should BeGreaterThan -1
            $m.Value.IndexOf('try') | Should BeLessThan $m.Value.IndexOf('localStorage')
        }
        $html | Should Match "'Notification' in window"
    }

    It 'el servidor real sirve esta pagina' -Skip:$noPython {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State RUNNING -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $r = Invoke-WebRequest -Uri "$($h.Url)" -NoProxy -TimeoutSec 5
            [int]$r.StatusCode | Should Be 200
            $r.Headers['Content-Type'] | Should Match 'text/html; charset=utf-8'
            $r.Content | Should Match 'id="session-select"'
            $r.Content | Should Match '// == puro:inicio =='
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'excluye lo que no es de la Ola 1 y no usa dependencias externas' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($p in 'MOCKUP', 'setMode\(', '<svg', '<canvas', '<script[^>]+src=', '<link[^>]+href=') {
            ($html -cmatch $p) | Should Be $false
        }
    }

    It 'pollStatus programa el siguiente poll con nextPollDelay' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $m = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $m.Success | Should Be $true
        $m.Value.IndexOf('nextPollDelay(') | Should BeGreaterThan -1
        $m.Value.IndexOf('nextPollDelay(') | Should BeLessThan $m.Value.IndexOf('setTimeout(')
        $stop = [regex]::Match($html, '(?s)function stopPolling\(.*?\n    \}')
        $stop.Success | Should Be $true
        $stop.Value.Contains('clearTimeout(pollTimer)') | Should Be $true
        $stop.Value.Contains('stopTicker()') | Should Be $true
    }

    It 'H1: nextPollDelay deja de hacer polling con el driver muerto en RUNNING' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
[
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:false,reason:'pid_muerto'}})),
  nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:true}}),
  nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:null}}),
  nextPollDelay(200, {globalStatus:'RUNNING'}, {session:{live:false}}),
  String(nextPollDelay(200, {globalStatus:'DONE'}, {driver:{alive:false}})),
  nextPollDelay(503, null, {driver:{alive:false}})
]
"@
        (@($r) -join ',') | Should Be 'null,4000,4000,4000,null,4000'
    }

    It 'H1: heartbeat_vencido sigue el polling a POLL_MS y se recupera; pid_muerto y pid_reutilizado lo detienen' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
[
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:false,reason:'heartbeat_vencido'}})),
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:false,reason:'pid_muerto'}})),
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:false,reason:'pid_reutilizado'}})),
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:true}})),
  String(nextPollDelay(200, {globalStatus:'RUNNING'}, {driver:{alive:false,reason:'heartbeat_vencido'}}))
]
"@
        (@($r) -join ',') | Should Be '4000,null,null,4000,4000'
    }

    It 'H1: driverDeadInfo arma badge y aviso para cada motivo' -Skip:$noNode {
        $r = Invoke-DashboardPure "['pid_muerto','pid_reutilizado','heartbeat_vencido'].map(m => driverDeadInfo({globalStatus:'RUNNING'}, {alive:false, reason:m}))"
        $motivos = 'pid_muerto', 'pid_reutilizado', 'heartbeat_vencido'
        @($r).Count | Should Be 3
        for ($i = 0; $i -lt 3; $i++) {
            $item = @($r)[$i]
            $item.reason | Should Be $motivos[$i]
            $item.badge | Should Be 'RUNNING · sin driver'
            $item.message | Should Be ('El driver no responde (status huérfano en RUNNING, motivo: ' + $motivos[$i] + '). Revisa la consola donde corría o relanza el driver.')
        }
    }

    It 'H1: driverDeadInfo es nulo fuera de RUNNING o con driver vivo o desconocido, y deja el motivo como texto' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  done: driverDeadInfo({globalStatus:'DONE'}, {alive:false, reason:'pid_muerto'}),
  vivo: driverDeadInfo({globalStatus:'RUNNING'}, {alive:true, reason:null}),
  nulo: driverDeadInfo({globalStatus:'RUNNING'}, null),
  html: driverDeadInfo({globalStatus:'RUNNING'}, {alive:false, reason:'<img src=x>'}).message,
  num: driverDeadInfo({globalStatus:'RUNNING'}, {alive:false, reason:5}).message
}
"@
        $r.done | Should BeNullOrEmpty
        $r.vivo | Should BeNullOrEmpty
        $r.nulo | Should BeNullOrEmpty
        $r.html.Contains('<img src=x>') | Should Be $true
        $r.num.Contains('motivo: desconocido') | Should Be $true
    }

    It 'H1/A8: shouldNotifyDriverDead solo en la transicion a alive false y nunca en el primer poll' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldNotifyDriverDead(true,false,false), shouldNotifyDriverDead(null,false,false), shouldNotifyDriverDead(true,false,true), shouldNotifyDriverDead(false,false,false), shouldNotifyDriverDead(true,true,false), shouldNotifyDriverDead(true,null,false)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,True,False,False,False,False'
    }

    It 'H1: waitReasonText muestra reason solo en RUNNING con texto' -Skip:$noNode {
        $r = Invoke-DashboardPure "[waitReasonText({globalStatus:'RUNNING', reason:'Reintento 1/2 en 60 s (exit_no_cero)'}), waitReasonText({globalStatus:'RUNNING', reason:''}), waitReasonText({globalStatus:'RUNNING', reason:null}), waitReasonText({globalStatus:'DONE', reason:'texto'})]"
        $items = @($r)
        $items.Count | Should Be 4
        $items[0] | Should Be 'Reintento 1/2 en 60 s (exit_no_cero)'
        $items[1] | Should BeNullOrEmpty
        $items[2] | Should BeNullOrEmpty
        $items[3] | Should BeNullOrEmpty
    }

    It 'H1: estructura del polling: sin SLOW_POLL_MS, driver pedido en cada poll y aviso con textContent' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should Not Match 'SLOW_POLL_MS'
        $html | Should Match 'async function fetchDriver\('
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $poll.Value.Contains('fetchDriver(') | Should Be $true
        $poll.Value.Contains('lastDriver') | Should Be $true
        $stop = [regex]::Match($html, '(?s)function stopPolling\(.*?\n    \}')
        $stop.Success | Should Be $true
        $stop.Value.Contains('driverDeadInfo(') | Should Be $true
        $stop.Value.Contains('textContent') | Should Be $true
        $stop.Value.Contains('innerHTML') | Should Be $false
    }

    It 'H1 bis: staleStopState arranca, mantiene y corta el reloj del heartbeat vencido' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const hb = {alive:false, reason:'heartbeat_vencido'};
  const R = {globalStatus:'RUNNING'};
  return {
    arranca: staleStopState(null, 200, R, hb, 1000),
    antes: staleStopState(1000, 200, R, hb, 600999),
    corta: staleStopState(1000, 200, R, hb, 601000),
    pausado: staleStopState(1000, 200, {globalStatus:'PAUSED'}, hb, 601000),
    espera: staleStopState(1000, 200, {globalStatus:'AWAITING'}, hb, 601000),
    vivo: staleStopState(1000, 200, R, {alive:true}, 601000),
    otra: staleStopState(1000, 200, R, {alive:false, reason:'pid_muerto'}, 601000),
    sinDriver: staleStopState(1000, 200, R, null, 601000),
    final: staleStopState(1000, 200, {globalStatus:'DONE'}, hb, 601000),
    http503: staleStopState(1000, 503, null, hb, 601000),
    http0: staleStopState(1000, 0, null, hb, 601000),
    tope: STALE_STOP_MS
  };
})()
"@
        $r.arranca.since | Should Be 1000
        $r.arranca.stop | Should Be $false
        $r.antes.since | Should Be 1000
        $r.antes.stop | Should Be $false
        $r.corta.since | Should Be 1000
        $r.corta.stop | Should Be $true
        $r.pausado.stop | Should Be $true
        $r.espera.stop | Should Be $true
        foreach ($k in 'vivo', 'otra', 'sinDriver', 'final') {
            $r.$k.since | Should BeNullOrEmpty
            $r.$k.stop | Should Be $false
        }
        foreach ($k in 'http503', 'http0') {
            $r.$k.since | Should Be 1000
            $r.$k.stop | Should Be $false
        }
        $r.tope | Should Be 600000
    }

    It 'H1 bis: staleStopText arma el aviso con la hora local HH:MM' -Skip:$noNode {
        $r = Invoke-DashboardPure "[staleStopText(new Date(2026, 9, 28, 7, 5).getTime()), staleStopText(new Date(2026, 9, 28, 23, 59).getTime())]"
        $items = @($r)
        $items.Count | Should Be 2
        $items[0] | Should Be ('El driver no da se' + [char]0x00F1 + 'al desde las 07:05; puede estar colgado.')
        $items[1].EndsWith('23:59; puede estar colgado.') | Should Be $true
    }

    It 'H1 bis: estructura: aviso stale-stop-notice, Volver a consultar y stopPolling en la rama del tope' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $block = [regex]::Match($html, '(?s)// == puro:inicio ==(.*?)// == puro:fin ==').Groups[1].Value
        $block.Contains('const STALE_STOP_MS = 600000;') | Should Be $true
        $html | Should Match '(?s)id="stale-stop-notice"[^>]*style="display: none".*?id="stale-retry"[^>]*>Volver a consultar</button>'
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $poll.Value.Contains('staleStopState(') | Should Be $true
        $poll.Value.Contains('staleSince = stale.since') | Should Be $true
        $i = $poll.Value.IndexOf('else if (stale.stop)')
        $i | Should BeGreaterThan -1
        $branch = $poll.Value.Substring($i)
        $s = $branch.IndexOf('stopPolling(data, true)')
        $s | Should BeGreaterThan -1
        $branch.IndexOf('showStaleNotice(') | Should BeGreaterThan $s
        $retry = [regex]::Match($html, "(?s)\`$\('stale-retry'\)\.addEventListener\(.*?\}\);")
        $retry.Success | Should Be $true
        $retry.Value.Contains('staleSince = null') | Should Be $true
        $retry.Value.Contains('pollStatus()') | Should Be $true
    }

    It 'DT-20: stopPolling(data, staleCut) pinta badge sin senal, sin mensaje y sin innerHTML' {
        $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
        $stop = [regex]::Match($html, '(?s)function stopPolling\(data, staleCut\).*?\n    \}')
        $stop.Success | Should Be $true
        $stop.Value.Contains(" " + [char]0x00B7 + " sin se" + [char]0x00F1 + "al'") | Should Be $true
        $stop.Value.Contains("setPollState('')") | Should Be $true
        $stop.Value.Contains('textContent') | Should Be $true
        $stop.Value.Contains('innerHTML') | Should Be $false
    }

    It 'DT-20: la rama del tope llama stopPolling(data, true) antes del aviso; delay null conserva stopPolling(data)' {
        $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $i = $poll.Value.IndexOf('else if (stale.stop)')
        $i | Should BeGreaterThan -1
        $nullBranch = $poll.Value.Substring(0, $i)
        $nullBranch.Contains('if (delay === null) {') | Should Be $true
        $nullBranch.Contains('stopPolling(data);') | Should Be $true
        $branch = $poll.Value.Substring($i)
        $s = $branch.IndexOf('stopPolling(data, true)')
        $s | Should BeGreaterThan -1
        $branch.IndexOf('showStaleNotice(') | Should BeGreaterThan $s
    }

    It 'H1 bis: el aviso se pinta con textContent y sin innerHTML' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $show = [regex]::Match($html, '(?s)function showStaleNotice\(.*?\n    \}')
        $show.Success | Should Be $true
        $show.Value.Contains('textContent = staleStopText(') | Should Be $true
        $show.Value.Contains('innerHTML') | Should Be $false
        $bad = @($html -split "`n" | Where-Object { $_.Contains('innerHTML') -and $_ -match 'stale' })
        $bad.Count | Should Be 0
    }

    It 'H1: pollStatus vuelve a pintar la barra de acciones despues de pedir el driver (oculta con driver muerto)' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $i = $poll.Value.IndexOf('fetchDriver(')
        $j = $poll.Value.IndexOf('renderControlBar(data);')
        $i | Should BeGreaterThan -1
        $j | Should BeGreaterThan $i
    }

    It 'H1/A8: maybeNotify avisa Driver: sin respuesta y se llama despues de pedir el driver' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $html | Should Match "'Driver: sin respuesta'"
        $notify = [regex]::Match($html, '(?s)function maybeNotify\(.*?\n    \}')
        $notify.Success | Should Be $true
        $notify.Value.Contains('shouldNotifyDriverDead(') | Should Be $true
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Value.IndexOf('maybeNotify(') | Should BeGreaterThan $poll.Value.IndexOf('fetchDriver(')
    }

    It 'H1: contrato de punta a punta: /activity.json con el driver muerto detiene el polling' -Skip:($noNode -or $noPython) {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State RUNNING -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $dead = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden
            $dead.WaitForExit(10000) | Should Be $true
            $deadId = $dead.Id
            $st = Get-Content -LiteralPath $h.StatusPath -Raw | ConvertFrom-Json
            $st | Add-Member -NotePropertyName driver -NotePropertyValue ([pscustomobject]@{ pid = $deadId; processStartedAt = $null; heartbeatAt = $null; heartbeatSeconds = 30 }) -Force
            $st | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $h.StatusPath -Encoding utf8
            $json = (Invoke-WebRequest -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5).Content
            $r = Invoke-DashboardPure "(function(a){ return { reason: a.driver.reason, delay: nextPollDelay(200, {globalStatus:'RUNNING'}, a) }; })($json)"
            $r.reason | Should Be 'pid_muerto'
            $r.delay | Should BeNullOrEmpty
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It '2a I5: telemetryCells y durationText con y sin telemetria' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const full = telemetryCells({telemetry:{durationMs:125000, numTurns:12, inputTokens:1500, outputTokens:800, cacheReadTokens:200000, cacheCreationTokens:30000}});
  const none = telemetryCells({});
  const onlyRead = telemetryCells({telemetry:{cacheReadTokens:5000}});
  return { full: full, none: none, cache: onlyRead.cacheTokens, neg: durationText(-1), nul: durationText(null) };
})()
'@
        $r.full.duration | Should Be '2m 5s'
        $r.full.turns | Should Be '12'
        $r.full.inputTokens | Should Be '2 k'
        $r.full.outputTokens | Should Be '800'
        $r.full.cacheTokens | Should Be '230 k'
        foreach ($k in 'duration', 'turns', 'inputTokens', 'outputTokens', 'cacheTokens') { $r.none.$k | Should Be ([string][char]0x2014) }
        $r.cache | Should Be '5 k'
        $r.neg | Should Be ([string][char]0x2014)
        $r.nul | Should Be ([string][char]0x2014)
    }

    It '2a I5: costView suma history y compara con el tope' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const h = [{telemetry:{costUsd:1.25}}, {telemetry:{costUsd:1.25}}];
  return {
    sin: costView({history:h}),
    cero: costView({history:h, limits:{maxCostUsd:0}}),
    diez: costView({history:h, limits:{maxCostUsd:10}}),
    dos: costView({history:h, limits:{maxCostUsd:2}}),
    vacio: costView({history:[{}], limits:{maxCostUsd:10}})
  };
})()
'@
        $r.sin.cap | Should BeNullOrEmpty
        $r.sin.text | Should Be '$2.50'
        $r.cero.cap | Should BeNullOrEmpty
        $r.diez.pct | Should Be 25
        $r.diez.text | Should Be '$2.50 / $10.00'
        $r.dos.pct | Should Be 100
        $r.vacio.total | Should BeNullOrEmpty
        $r.vacio.text | Should Be ([string][char]0x2014)
    }

    It '2a I6: sessionsView cuenta iteraciones distintas de esta corrida' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const h = [{iter:1},{iter:2,attempt:1},{iter:3,attempt:0},{iter:3,attempt:1}];
  return {
    con: sessionsView({history:h, currentSession:{iter:4}, limits:{sessionBudget:8, budgetSource:'auto', iterBase:2}}),
    sin: sessionsView({history:h})
  };
})()
'@
        $r.con.used | Should Be 2
        $r.con.text | Should Be '2 / 8 (auto)'
        $r.sin | Should BeNullOrEmpty
    }

    It '2a I6: retriesView cuenta reintentos de esta corrida' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const h = [{iter:1},{iter:2,attempt:1},{iter:3,attempt:0},{iter:3,attempt:1}];
  const con = retriesView({history:h, limits:{iterBase:2, maxTransientRetries:2}});
  const sin = retriesView({history:h});
  return {
    count: con.count,
    textoOk: con.text === '1 (máx. 2 por sesión)',
    sinCount: sin.count, sinMax: sin.max, sinText: sin.text
  };
})()
'@
        $r.count | Should Be 1
        $r.textoOk | Should Be $true
        $r.sinCount | Should Be 2
        $r.sinMax | Should BeNullOrEmpty
        $r.sinText | Should Be '2'
    }

    It '2a I6: endEstimate con niveles cerrados, sin ellos y sin cierre pendiente' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const now = Date.parse('2026-10-15T21:00:00Z');
  const closed = [
    {enteredAt:'2026-10-15T18:00:00Z', completedAt:'2026-10-15T18:10:00Z'},
    {enteredAt:'2026-10-15T18:10:00Z', completedAt:'2026-10-15T18:30:00Z'}
  ];
  const base = {globalStatus:'RUNNING', totalLevels:4, currentLevel:2, levelHistory:closed,
    history:[{iter:1, telemetry:{durationMs:300000}}, {iter:2, telemetry:{durationMs:300000}}]};
  const a = endEstimate(base, now);
  const b = endEstimate(Object.assign({}, base, {phase:{finalReviewExists:true}}), now);
  const c = endEstimate(Object.assign({}, base, {levelHistory:[]}), now);
  const d = endEstimate(Object.assign({}, base, {levelHistory:[closed[0], {enteredAt:'2026-10-15T18:10:00Z'}]}), now);
  return { a: a, etaOk: a.etaMs === now + a.remainingMs, b: b.remainingMs, c: c, d: d.remainingMs };
})()
'@
        $r.a.available | Should Be $true
        $r.a.remainingMs | Should Be 2100000
        $r.etaOk | Should Be $true
        $r.b | Should Be 1800000
        $r.c.available | Should Be $false
        $r.d | Should Be 1500000
    }

    It '2a I8: gitView con bloque, con error y sin bloque' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const g = {branch:'feat/x', baseBranch:'master', ahead:3, commits:[{hash:'abc1234', subject:'feat: algo'}],
    diffstat:{files:5, insertions:120, deletions:8}, clean:true, updatedAt:'2026-10-27T20:00:00-04:00', error:null};
  return {
    ok: gitView(g),
    sucio: gitView(Object.assign({}, g, {clean:false})).cleanText === 'con cambios sin commitear',
    err: gitView({error:'git rev-list fallo (exit 128): x'}),
    nulo: gitView(undefined),
    xss: gitView(Object.assign({}, g, {commits:[{hash:'a', subject:'<img src=x onerror=alert(1)>'}]})).commits[0].subject
  };
})()
'@
        $r.ok.branchText | Should Be 'feat/x (base master)'
        $r.ok.aheadText | Should Be '3 commits por delante'
        $r.ok.diffText | Should Be '5 archivos, +120 / -8'
        $r.ok.cleanText | Should Be 'limpio'
        @($r.ok.commits).Count | Should Be 1
        $r.ok.commits[0].hash | Should Be 'abc1234'
        $r.sucio | Should Be $true
        $r.err.error | Should Be 'git rev-list fallo (exit 128): x'
        $r.err.branchText | Should BeNullOrEmpty
        $r.nulo | Should BeNullOrEmpty
        $r.xss | Should Be '<img src=x onerror=alert(1)>'
    }

    It '2a I9: finalReviewView estructurado, crudo e inexistente' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const est = finalReviewView({exists:true, verdict:'Listo', counts:{CRITICAL:1, IMPORTANT:0, MINOR:3},
    findings:[{severity:'MINOR', title:'t'}], raw:'# x'});
  const crudo = finalReviewView({exists:true, verdict:null, counts:null, findings:[], raw:'<b>x</b>'});
  return { est: est, crudo: crudo, noExiste: finalReviewView({exists:false}), nulo: finalReviewView(null) };
})()
'@
        $r.est.structured | Should Be $true
        ((@($r.est.counts) | ForEach-Object { $_.severity }) -join ',') | Should Be 'CRITICAL,IMPORTANT,MINOR'
        ((@($r.est.counts) | ForEach-Object { "$($_.danger)" }) -join ',') | Should Be 'True,False,False'
        $r.est.counts[2].n | Should Be 3
        $r.est.verdict | Should Be 'Listo'
        $r.crudo.structured | Should Be $false
        $r.crudo.raw | Should Be '<b>x</b>'
        $r.noExiste | Should BeNullOrEmpty
        $r.nulo | Should BeNullOrEmpty
    }

    It '2a I11: phaseBadge por modo' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  return {
    sin: phaseBadge({}),
    boot: phaseBadge({phase:{mode:'bootstrap'}}).text,
    pend: phaseBadge({phase:{mode:'close', finalReviewExists:false}}).text === 'close · revisión final: pendiente',
    lista: phaseBadge({phase:{mode:'close', finalReviewExists:true}}).text === 'close · revisión final: lista'
  };
})()
'@
        $r.sin | Should BeNullOrEmpty
        $r.boot | Should Be 'bootstrap'
        $r.pend | Should Be $true
        $r.lista | Should Be $true
    }

    It '2a I9: shouldFetchFinalReview pide al cargar y en la transicion a true' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldFetchFinalReview(false,false,true), shouldFetchFinalReview(false,true,false), shouldFetchFinalReview(true,true,false), shouldFetchFinalReview(false,false,false), shouldFetchFinalReview(undefined,undefined,false)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,True,False,False,False'
    }

    It '2a: estructura de KPIs, paneles y escapado' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($id in 'phase-badge', 'kpi-sessions', 'kpi-retries', 'kpi-eta', 'costBar', 'git-panel', 'final-review-panel', 'final-review-raw') {
            $html | Should Match ('id="' + [regex]::Escape($id) + '"')
        }
        $html.Contains('<tr><th>Sesión</th><th>Hora</th><th>Duración</th><th>Turnos</th><th>Tokens entrada</th><th>Tokens salida</th><th>Caché</th><th>Resultado</th><th>Modelo / effort</th><th>Coste</th><th>Log</th><th>Comando</th></tr>') | Should Be $true
        $html.Contains("fetch('/final-review.json'") | Should Be $true
        $fr = [regex]::Match($html, '(?s)function renderFinalReview\(.*?\n    \}')
        $fr.Success | Should Be $true
        $fr.Value.Contains('textContent') | Should Be $true
        $fr.Value.Contains('escapeHtml(f.title)') | Should Be $true
        $fr.Value.Contains('escapeHtml(f.severity)') | Should Be $true
        ($fr.Value -cmatch 'innerHTML[^;]*raw') | Should Be $false
        $git = [regex]::Match($html, '(?s)function renderGitPanel\(.*?\n    \}')
        $git.Success | Should Be $true
        $git.Value.Contains('escapeHtml(c.subject)') | Should Be $true
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Value.Contains('shouldFetchFinalReview(') | Should Be $true
        $poll.Value.Contains('reviewOk = await fetchFinalReview()') | Should Be $true
        $poll.Value.Contains('if (reviewOk || !reviewExists)') | Should Be $true
    }

    It '2a-3: shouldHideFinalReview solo oculta con bloque phase' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldHideFinalReview({}, false, false), shouldHideFinalReview(null, false, false), shouldHideFinalReview({phase:{finalReviewExists:false}}, false, false), shouldHideFinalReview({phase:{}}, false, true), shouldHideFinalReview({phase:{finalReviewExists:true}}, true, false)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'False,False,True,False,False'
    }

    It '2a-3: pollStatus oculta la revision con shouldHideFinalReview' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $poll.Value.Contains('shouldHideFinalReview(') | Should Be $true
        $html.Contains('if (!reviewExists && !firstReviewCheck) hideFinalReviewPanel();') | Should Be $false
    }

    It '2a I9: contrato de punta a punta: /final-review.json del servidor real alimenta finalReviewView' -Skip:($noNode -or $noPython) {
        $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $h = & $demo -State DONE -Root $Root
        $script:statusPaths += $h.StatusPath
        try {
            $folder = Split-Path -Parent $h.StatusPath
            $md = @(
                '# Revision final',
                '',
                '**Veredicto:** Listo',
                '',
                '| # | Severidad | Ubicación | Descripción | Fix sugerido |',
                '|---|---|---|---|---|',
                '| 1 | CRITICAL | a.ps1:1 | algo grave | arreglar |',
                '| 2 | MINOR | b.ps1:2 | algo menor | pulir |'
            ) -join "`n"
            Set-Content -LiteralPath (Join-Path $folder '.final-review-demo.md') -Value $md -Encoding utf8
            $st = Get-Content -LiteralPath $h.StatusPath -Raw | ConvertFrom-Json
            $st | Add-Member -NotePropertyName phase -NotePropertyValue ([pscustomobject]@{ mode = 'done'; completedBy = 'levels'; finalReviewFile = '.final-review-demo.md'; finalReviewExists = $true }) -Force
            $st | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $h.StatusPath -Encoding utf8
            $resp = Invoke-WebRequest -Uri "$($h.Url)final-review.json" -NoProxy -TimeoutSec 5
            $resp.StatusCode | Should Be 200
            $json = $resp.Content
            $r = Invoke-DashboardPure "(function(r){ const v = finalReviewView(r); return { verdict: v.verdict, c: v.counts[0].n, m: v.counts[2].n, danger: v.counts[0].danger }; })($json)"
            $r.verdict | Should Be 'Listo'
            $r.c | Should Be 1
            $r.m | Should Be 1
            $r.danger | Should Be $true
        }
        finally { Stop-DriverDashboard -ProcessId $h.Pid }
    }

    It 'los badges de estado existen para RUNNING, BLOCKED, FAILED, DONE y STOPPED' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($s in 'RUNNING', 'BLOCKED', 'FAILED', 'DONE', 'STOPPED') {
            ($html -cmatch ('\.badge-' + $s + '\b')) | Should Be $true
        }
    }

    It '2b: readFragmentToken acepta solo 64 hex en el fragmento' -Skip:$noNode {
        $tok = 'ab' * 32
        $up = 'AB' * 32
        $r = Invoke-DashboardPure "[readFragmentToken('#t=$tok'), readFragmentToken('#x=1&t=$tok'), readFragmentToken('#t=$up'), readFragmentToken('#t=abc'), readFragmentToken(''), readFragmentToken(null)]"
        $items = @($r)
        $items.Count | Should Be 6
        $items[0] | Should Be $tok
        $items[1] | Should Be $tok
        $items[2] | Should BeNullOrEmpty
        $items[3] | Should BeNullOrEmpty
        $items[4] | Should BeNullOrEmpty
        $items[5] | Should BeNullOrEmpty
    }

    It '2b: availableActions y controlBarView por estado, canal y token' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  running: availableActions({globalStatus:'RUNNING', control:{enabled:true}}, null),
  paused: availableActions({globalStatus:'PAUSED', control:{enabled:true}}, {alive:true}),
  done: availableActions({globalStatus:'DONE', control:{enabled:true}}, null),
  sinControl: availableActions({globalStatus:'RUNNING'}, null),
  apagado: availableActions({globalStatus:'RUNNING', control:{enabled:false}}, null),
  muerto: availableActions({globalStatus:'RUNNING', control:{enabled:true}}, {alive:false}),
  barDone: controlBarView({globalStatus:'DONE', control:{enabled:true}}, null, true),
  barNull: controlBarView(null, null, true),
  barMuerto: controlBarView({globalStatus:'RUNNING', control:{enabled:true}}, {alive:false}, true),
  barSinToken: controlBarView({globalStatus:'RUNNING', control:{enabled:true}}, null, false),
  barApagado: controlBarView({globalStatus:'RUNNING', control:{enabled:false}}, null, true),
  barOk: controlBarView({globalStatus:'PAUSED', control:{enabled:true}}, null, true)
}
"@
        (@($r.running) -join ',') | Should Be 'pause,stop,set-params,open'
        (@($r.paused) -join ',') | Should Be 'resume,stop,set-params,open'
        @($r.done).Count | Should Be 0
        @($r.sinControl).Count | Should Be 0
        @($r.apagado).Count | Should Be 0
        @($r.muerto).Count | Should Be 0
        $r.barDone.visible | Should Be $false
        $r.barNull.visible | Should Be $false
        $r.barMuerto.visible | Should Be $false
        $disabled = 'Acciones deshabilitadas: abre la URL con token que imprimió el driver'
        $r.barSinToken.visible | Should Be $true
        @($r.barSinToken.actions).Count | Should Be 0
        $r.barSinToken.message | Should Be $disabled
        $r.barApagado.visible | Should Be $true
        @($r.barApagado.actions).Count | Should Be 0
        $r.barApagado.message | Should Be $disabled
        $r.barOk.visible | Should Be $true
        (@($r.barOk.actions) -join ',') | Should Be 'resume,stop,set-params,open'
        $r.barOk.message | Should BeNullOrEmpty
    }

    It '2b: controlRequest arma el POST con token y cuerpo JSON' -Skip:$noNode {
        $r = Invoke-DashboardPure "[controlRequest('set-params', {model:'x'}, 'tk'), controlRequest('pause', null, 'tk')]"
        $a = @($r)[0]
        $a.path | Should Be '/control/set-params'
        $a.init.method | Should Be 'POST'
        $a.init.headers.'Content-Type' | Should Be 'application/json'
        $a.init.headers.'X-Control-Token' | Should Be 'tk'
        @($a.init.headers.PSObject.Properties).Count | Should Be 2
        $a.init.body | Should Be '{"model":"x"}'
        $b = @($r)[1]
        $b.path | Should Be '/control/pause'
        $b.init.body | Should Be '{}'
    }

    It '2b: controlErrorText y controlResultView' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  e409: controlErrorText(409, null),
  e403: controlErrorText(403, {error:'token invalido'}),
  e400: controlErrorText(400, {field:'maxCostUsd'}),
  e413: controlErrorText(413, null),
  e415: controlErrorText(415, null),
  e0: controlErrorText(0, null),
  e500: controlErrorText(500, null),
  idle: controlResultView(null, {control:{last:null}}),
  pending: controlResultView('id-A', {globalStatus:'RUNNING'}, 29999),
  applied: controlResultView('id-A', {control:{last:{id:'id-A', result:'applied', action:'pause', detail:'pausa al terminar la sesión en curso'}}}),
  appliedSinDetalle: controlResultView('id-A', {control:{last:{id:'id-A', result:'applied', action:'stop'}}}),
  rejected: controlResultView('id-A', {control:{last:{id:'id-A', result:'rejected', action:'pause', detail:'x'}}})
}
"@
        $r.e409 | Should Be 'Hay una orden pendiente'
        $r.e403 | Should Be 'El servidor rechazó la orden: token invalido'
        $r.e400 | Should Be 'Parámetro inválido: maxCostUsd'
        $r.e413 | Should Be 'La orden es demasiado grande'
        $r.e415 | Should Be 'Tipo de contenido no admitido'
        $r.e0 | Should Be 'Sin conexión con el servidor'
        $r.e500 | Should Be 'Error HTTP 500'
        $r.idle.state | Should Be 'idle'
        $r.pending.state | Should Be 'pending'
        $r.pending.text | Should Be 'Orden enviada…'
        $r.applied.state | Should Be 'done'
        $r.applied.text | Should Be 'Orden aplicada: Pausar (pausa al terminar la sesión en curso)'
        $r.appliedSinDetalle.text | Should Be 'Orden aplicada: Detener'
        $r.rejected.state | Should Be 'done'
        $r.rejected.text | Should Be 'Orden rechazada: x'
    }

    It '2b: paramsCurrent y changedParams envian solo lo cambiado' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const st = {
    params: {model:'m', levelEffort:'high', closeEffort:'high', retryBackoffSeconds:[60,300], livenessTimeoutMinutes:30},
    limits: {maxTransientRetries:2, maxCostUsd:0, awaitDecisionMinutes:480}
  };
  const cur = paramsCurrent(st);
  const same = {model:'m', levelEffort:'high', closeEffort:'high', retryBackoffSeconds:'60', livenessTimeoutMinutes:'30',
    maxTransientRetries:'2', maxCostUsd:'0', awaitDecisionMinutes:'480'};
  const changed = Object.assign({}, same, {model:'n', maxCostUsd:'12.5', awaitDecisionMinutes:'30'});
  const frac = Object.assign({}, same, {maxTransientRetries:'1.5'});
  const empty = Object.assign({}, same, {model:'', levelEffort:'', maxCostUsd:''});
  const a = changedParams(cur, same);
  const b = changedParams(cur, changed);
  const c = changedParams(cur, frac);
  const d = changedParams(cur, empty);
  return {
    cur: cur,
    curVacio: paramsCurrent(null),
    sameKeys: Object.keys(a.params), sameInvalid: a.invalid,
    chKeys: Object.keys(b.params).sort(), chModel: b.params.model,
    chCost: b.params.maxCostUsd, chAwait: b.params.awaitDecisionMinutes,
    chTypes: [typeof b.params.maxCostUsd, typeof b.params.awaitDecisionMinutes],
    fracInvalid: c.invalid,
    emptyKeys: Object.keys(d.params), emptyInvalid: d.invalid
  };
})()
"@
        $r.cur.retryBackoffSeconds | Should Be 60
        $r.cur.model | Should Be 'm'
        $r.cur.maxTransientRetries | Should Be 2
        $r.cur.awaitDecisionMinutes | Should Be 480
        $r.curVacio.model | Should BeNullOrEmpty
        @($r.sameKeys).Count | Should Be 0
        @($r.sameInvalid).Count | Should Be 0
        (@($r.chKeys) -join ',') | Should Be 'awaitDecisionMinutes,maxCostUsd,model'
        $r.chModel | Should Be 'n'
        $r.chCost | Should Be 12.5
        $r.chAwait | Should Be 30
        (@($r.chTypes) -join ',') | Should Be 'number,number'
        (@($r.fracInvalid) -join ',') | Should Be 'maxTransientRetries'
        @($r.emptyKeys).Count | Should Be 0
        @($r.emptyInvalid).Count | Should Be 0
    }

    It '2b: stopConfirmState arma por 5 s' -Skip:$noNode {
        $r = Invoke-DashboardPure "[stopConfirmState(null, 0), stopConfirmState(1000, 1000), stopConfirmState(1000, 5999), stopConfirmState(1000, 6000)]"
        (@($r) -join ',') | Should Be 'idle,armed,armed,idle'
    }

    It '2b: pausedInfo con y sin vencimiento' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const now = Date.parse('2026-10-27T12:00:00Z');
  return {
    run: pausedInfo({globalStatus:'RUNNING', paused:{since:'2026-10-27T11:00:00Z'}}, now),
    sinBloque: pausedInfo({globalStatus:'PAUSED'}, now),
    con: pausedInfo({globalStatus:'PAUSED', paused:{since:'2026-10-27T11:00:00Z', deadline:'2026-10-27T14:00:00Z'}}, now),
    sin: pausedInfo({globalStatus:'PAUSED', paused:{since:'2026-10-27T11:00:00Z', deadline:null}}, now),
    vencida: pausedInfo({globalStatus:'PAUSED', paused:{since:'2026-10-27T11:00:00Z', deadline:'2026-10-27T11:30:00Z'}}, now)
  };
})()
"@
        $r.run | Should BeNullOrEmpty
        $r.sinBloque | Should BeNullOrEmpty
        $r.con.remainingMs | Should Be 7200000
        $r.con.text | Should Match '^En pausa desde'
        $r.con.text | Should Match 'vence en'
        $r.sin.text | Should Match 'sin vencimiento'
        $r.sin.text | Should Not Match 'vence en'
        $r.vencida.remainingMs | Should Be 0
    }

    It '2b: actionRows y marcas de acciones en timelineLayout' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function () {
  const many = Array.from({length: 25}, (_, i) => ({id: 'a' + i, action: 'pause', appliedAt: '2026-10-27T10:05:00Z', result: 'applied', detail: 'd' + i}));
  const rows = actionRows({actions: many});
  const rej = actionRows({actions: [{action: 'stop', requestedAt: '2026-10-27T10:05:00Z', result: 'rejected', detail: 'x'}]});
  const raro = actionRows({actions: [{}]});
  const view = {
    bars: [{id: 'b1', task: 'T1', role: 'impl', startedAt: '2026-10-27T10:00:00Z', endedAt: '2026-10-27T10:10:00Z'}],
    tasks: [{code: 'T1', stages: []}], commits: [], session: {live: false}
  };
  const now = Date.parse('2026-10-27T10:10:00Z');
  const acts = [
    {action: 'pause', appliedAt: '2026-10-27T10:05:00Z', result: 'applied'},
    {action: 'stop', appliedAt: '2026-10-27T11:00:00Z', result: 'applied'}
  ];
  const con = timelineLayout(view, now, acts);
  const sin = timelineLayout(view, now);
  return {
    n: rows.length, first: rows[0].detail, last: rows[19].detail, firstAction: rows[0].action, firstResult: rows[0].result,
    rejResult: rej[0].result, rejAction: rej[0].action, rejDetail: rej[0].detail,
    raro: raro[0], vacio: actionRows(null),
    conN: con.actions.length, conLeft: con.actions[0].leftPct, conTitle: con.actions[0].title,
    sinN: sin.actions.length, lanesIguales: con.lanes.length === sin.lanes.length && con.startMs === sin.startMs && con.endMs === sin.endMs
  };
})()
"@
        $r.n | Should Be 20
        $r.first | Should Be 'd24'
        $r.last | Should Be 'd5'
        $r.firstAction | Should Be 'Pausar'
        $r.firstResult | Should Be 'aplicada'
        $r.rejResult | Should Be 'rechazada'
        $r.rejAction | Should Be 'Detener'
        $r.rejDetail | Should Be 'x'
        $r.raro.time | Should Be '—'
        $r.raro.action | Should Be '—'
        $r.raro.result | Should Be '—'
        $r.raro.detail | Should Be ''
        @($r.vacio).Count | Should Be 0
        $r.conN | Should Be 1
        $r.conLeft | Should BeGreaterThan -1
        $r.conLeft | Should BeLessThan 101
        $r.conTitle | Should Be 'Pausar · aplicada'
        $r.sinN | Should Be 0
        $r.lanesIguales | Should Be $true
    }

    It '2b: nextPollDelay y driverDeadInfo tratan PAUSED como RUNNING' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  sano: nextPollDelay(200, {globalStatus:'PAUSED'}, null),
  muerto: nextPollDelay(200, {globalStatus:'PAUSED'}, {driver:{alive:false, reason:'pid_muerto'}}),
  heartbeat: nextPollDelay(200, {globalStatus:'PAUSED'}, {driver:{alive:false, reason:'heartbeat_vencido'}}),
  badge: driverDeadInfo({globalStatus:'PAUSED'}, {alive:false, reason:'pid_muerto'}).badge,
  message: driverDeadInfo({globalStatus:'PAUSED'}, {alive:false, reason:'pid_muerto'}).message,
  running: driverDeadInfo({globalStatus:'RUNNING'}, {alive:false, reason:'pid_muerto'}).badge,
  awaiting: driverDeadInfo({globalStatus:'AWAITING'}, {alive:false, reason:'pid_muerto'})
}
"@
        $r.sano | Should Be 4000
        $r.muerto | Should BeNullOrEmpty
        $r.heartbeat | Should Be 4000
        $r.badge | Should Be 'PAUSED · sin driver'
        $r.message | Should Be 'El driver no responde (status huérfano en PAUSED, motivo: pid_muerto). Revisa la consola donde corría o relanza el driver.'
        $r.running | Should Be 'RUNNING · sin driver'
        $r.awaiting.badge | Should Be 'AWAITING · sin driver'
    }

    It '2b: panel final con causa dashboard y pausa_vencida desde status.cause' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  dash: finalPanelInfo({globalStatus:'STOPPED', cause:'dashboard', history:[{cause:'continue'}]}),
  venc: finalPanelInfo({globalStatus:'STOPPED', cause:'pausa_vencida', history:[]}),
  sinRaiz: finalPanelInfo({globalStatus:'STOPPED', history:[{cause:'manual'}]}),
  vacia: finalPanelInfo({globalStatus:'STOPPED', cause:'', history:[{cause:'manual'}]})
}
"@
        $r.dash.cause | Should Be 'dashboard'
        $r.dash.action | Should Be 'Detenido desde el dashboard. Relanza el driver con el mismo comando para reanudar; la sesión interrumpida puede haber dejado cambios sin commitear.'
        $r.venc.cause | Should Be 'pausa_vencida'
        $r.venc.action | Should Be 'La pausa venció sin reanudar. Relanza el driver con el mismo comando para continuar.'
        $r.sinRaiz.cause | Should Be 'manual'
        $r.sinRaiz.action | Should Match 'Ctrl\+C'
        $r.vacia.cause | Should Be 'manual'
    }

    It '2b: estructura de la barra de acciones, el formulario y el panel Acciones' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $ids = @('control-bar', 'act-pause', 'act-resume', 'act-stop', 'act-params', 'control-msg', 'control-disabled',
            'paused-info', 'params-form', 'params-send', 'params-cancel', 'actions-panel', 'actions-list')
        foreach ($k in 'model', 'levelEffort', 'closeEffort', 'maxTransientRetries', 'retryBackoffSeconds',
                'livenessTimeoutMinutes', 'maxCostUsd', 'awaitDecisionMinutes') { $ids += ('p-' + $k) }
        foreach ($id in $ids) { $html | Should Match ('id="' + $id + '"') }
        foreach ($t in 'Pausar', 'Reanudar', 'Detener', 'Confirmar detener', 'Parámetros', 'Enviar cambios', 'Sin acciones') {
            $html.Contains($t) | Should Be $true
        }
        $block = [regex]::Match($html, '(?s)// == puro:inicio ==(.*?)// == puro:fin ==').Groups[1].Value
        [regex]::Matches($block, 'X-Control-Token').Count | Should BeGreaterThan 0
        [regex]::Matches($html, 'X-Control-Token').Count | Should Be ([regex]::Matches($block, 'X-Control-Token').Count)
        $html.Contains('window.confirm') | Should Be $false
        $html.Contains('alert(') | Should Be $false
        ($html -cmatch '\.badge-PAUSED\b') | Should Be $true
        ($html -cmatch '\.node-paused\b') | Should Be $true
        ($html -cmatch '\.action-mark\b') | Should Be $true
        $poll = [regex]::Match($html, '(?s)function pollStatus\(.*?\n    \}')
        $poll.Success | Should Be $true
        $i = $poll.Value.IndexOf('LIVE_STATUSES.indexOf(data.globalStatus) !== -1')
        $i | Should BeGreaterThan -1
        $i | Should BeLessThan $poll.Value.IndexOf('fetchDriver(')
        $html | Should Match "safeRender\('control-bar'"
        [regex]::Matches($html, "safeRender\('control-bar', \(\) => renderControlBar\([^)]*\), 'control-msg'\)").Count | Should Be 2
        $html | Should Match "safeRender\('actions-panel'"
        $poll.Value.Contains('prev !== data.globalStatus') | Should Be $true
    }

    It '2b: el token del fragmento se guarda en sessionStorage y se limpia antes del primer poll' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $m = [regex]::Match($html, '(?s)function initControlToken\(\)\s*\{.*?\n    \}')
        $m.Success | Should Be $true
        $fn = $m.Value
        $uses = [regex]::Matches($fn, 'sessionStorage')
        $uses.Count | Should BeGreaterThan 0
        [regex]::Matches($fn, '\btry\b').Count | Should BeGreaterThan ($uses.Count - 1)
        foreach ($u in $uses) { $fn.Substring(0, $u.Index).Contains('try') | Should Be $true }
        $fn.Contains('replaceState(') | Should Be $true
        $fn.Contains('readFragmentToken(') | Should Be $true
        $a = $html.IndexOf('let controlToken = initControlToken();')
        $a | Should BeGreaterThan -1
        $a | Should BeLessThan $html.LastIndexOf('pollStatus();')
        [regex]::Matches($html, 'localStorage').Count | Should Be 2
    }

    It '2b: contrato de punta a punta: controlRequest contra el server.py real con token' -Skip:($noNode -or $noPython) {
        $Root = Join-Path $TestDrive ('ctl ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $logs = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        $statusPath = Join-Path $Root '.driver-status.json'
        $script:statusPaths += $statusPath
        [IO.File]::WriteAllText($statusPath, '{"globalStatus":"RUNNING","control":{"enabled":true,"last":null}}', [Text.UTF8Encoding]::new($false))
        $tok = 'ab' * 32
        $server = Join-Path $moduleRoot 'scripts\dashboard\server.py'
        $assets = Join-Path $moduleRoot 'assets'
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
        $argLine = "`"$server`" --status `"$statusPath`" --logs `"$logs`" --assets `"$assets`" --port 0 --idle-minutes 5"
        $p = Start-Process -FilePath $python -ArgumentList $argLine -Environment @{ DRIVER_DASHBOARD_TOKEN = $tok } -PassThru -WindowStyle Hidden
        try {
            $infoPath = Join-Path $Root '.driver-dashboard.json'
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $infoPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $infoPath | Should Be $true
            $port = (Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).port
            $req = Invoke-DashboardPure "controlRequest('set-params', {model:'claude-x'}, '$tok')"
            $headers = @{ Origin = "http://127.0.0.1:$port" }
            foreach ($prop in $req.init.headers.PSObject.Properties) {
                if ($prop.Name -ne 'Content-Type') { $headers[$prop.Name] = $prop.Value }
            }
            $send = {
                Invoke-WebRequest -Uri "http://127.0.0.1:$port$($req.path)" -Method $req.init.method -Headers $headers `
                    -ContentType $req.init.headers.'Content-Type' -Body $req.init.body -NoProxy -TimeoutSec 5 -SkipHttpErrorCheck
            }
            $first = & $send
            [int]$first.StatusCode | Should Be 202
            $id = ($first.Content | ConvertFrom-Json).id
            $id | Should Not BeNullOrEmpty
            $ctl = Get-Content -LiteralPath (Join-Path $Root '.driver-control.json') -Raw | ConvertFrom-Json
            $ctl.action | Should Be 'set-params'
            $ctl.params.model | Should Be 'claude-x'
            $ctl.id | Should Be $id
            $second = & $send
            [int]$second.StatusCode | Should Be 409
            $err = Invoke-DashboardPure ("controlErrorText(409, " + $second.Content + ")")
            $err | Should Be 'Hay una orden pendiente'
            $applied = '{"globalStatus":"RUNNING","control":{"enabled":true,"last":{"id":"' + $id + '","action":"set-params","result":"applied","detail":"aplicados: model","appliedAt":"2026-10-27T20:00:01Z"}}}'
            $view = Invoke-DashboardPure "controlResultView('$id', $applied)"
            $view.state | Should Be 'done'
            $view.text | Should Match 'Orden aplicada'
        }
        finally { Stop-DriverDashboard -ProcessId $p.Id }
    }

    It '2c: availableActions en AWAITING segun allowed, origin y resumable' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  completo: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'BLOCKED', resumable:true, allowed:['answer','retry','stop','set-params','open']}}, null),
  noReanudable: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'BLOCKED', resumable:false, allowed:['answer','retry','stop','set-params','open']}}, null),
  fallo: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'FAILED', resumable:true, allowed:['retry','stop','set-params','open']}}, null),
  falloConAnswer: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'FAILED', resumable:true, allowed:['answer','retry','stop','set-params','open']}}, null),
  soloTres: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'BLOCKED', resumable:true, allowed:['stop','set-params','open']}}, null),
  sinAwaiting: availableActions({globalStatus:'AWAITING', control:{enabled:true}}, null),
  muerto: availableActions({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'BLOCKED', resumable:true, allowed:['answer','retry','stop','set-params','open']}}, {alive:false}),
  bar: controlBarView({globalStatus:'AWAITING', control:{enabled:true}, awaiting:{origin:'BLOCKED', resumable:true, allowed:['answer','retry','stop','set-params','open']}}, null, true)
}
'@
        (@($r.completo) -join ',') | Should Be 'answer,retry-session,retry-level,stop,set-params,open'
        (@($r.noReanudable) -join ',') | Should Be 'answer,retry-level,stop,set-params,open'
        (@($r.fallo) -join ',') | Should Be 'retry-session,retry-level,stop,set-params,open'
        (@($r.falloConAnswer) -join ',') | Should Be 'retry-session,retry-level,stop,set-params,open'
        (@($r.soloTres) -join ',') | Should Be 'stop,set-params,open'
        @($r.sinAwaiting).Count | Should Be 0
        @($r.muerto).Count | Should Be 0
        $r.bar.visible | Should Be $true
        (@($r.bar.actions) -join ',') | Should Be 'answer,retry-session,retry-level,stop,set-params,open'
    }

    It '2c: actionParams arma la accion y los parametros del canal' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  session: actionParams('retry-session'),
  level: actionParams('retry-level'),
  answer: actionParams('answer', {text:'x'}),
  open: actionParams('open', {target:'log', iter:2}),
  pause: actionParams('pause')
}
'@
        $r.session.action | Should Be 'retry'
        $r.session.params.mode | Should Be 'session'
        $r.level.action | Should Be 'retry'
        $r.level.params.mode | Should Be 'level'
        $r.answer.action | Should Be 'answer'
        $r.answer.params.text | Should Be 'x'
        $r.open.action | Should Be 'open'
        $r.open.params.target | Should Be 'log'
        $r.open.params.iter | Should Be 2
        $r.pause.action | Should Be 'pause'
        @($r.pause.params.PSObject.Properties).Count | Should Be 0
    }

    It '2c: openTargets y openParams' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  runSin: openTargets({globalStatus:'RUNNING'}),
  runCon: openTargets({globalStatus:'RUNNING', history:[{iter:1, sessionId:'s'}]}),
  awCon: openTargets({globalStatus:'AWAITING', history:[{iter:1, sessionId:'11111111-1111-1111-1111-111111111111'}]}),
  awSin: openTargets({globalStatus:'AWAITING', history:[{iter:1}]}),
  pausaCon: openTargets({globalStatus:'PAUSED', history:[{iter:1, sessionId:'s'}]}),
  log: openParams('log', {history:[{iter:1},{iter:2}]}),
  carpeta: openParams('folder', {history:[{iter:1},{iter:2}]}),
  terminal: openParams('terminal', {history:[{iter:3, sessionId:'s'}]})
}
'@
        (@($r.runSin) -join ',') | Should Be 'folder'
        (@($r.runCon) -join ',') | Should Be 'folder,log'
        (@($r.awCon) -join ',') | Should Be 'folder,log,terminal'
        (@($r.awSin) -join ',') | Should Be 'folder,log'
        (@($r.pausaCon) -join ',') | Should Be 'folder,log,terminal'
        $r.log.target | Should Be 'log'
        $r.log.iter | Should Be 2
        $r.carpeta.target | Should Be 'folder'
        @($r.carpeta.PSObject.Properties).Count | Should Be 1
        $r.terminal.iter | Should Be 3
    }

    It '2c: answerTextError con las reglas del servidor' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  ok: answerTextError('usa A'),
  okControl: answerTextError('a\tb\r\nc'),
  vacio: answerTextError(''),
  blancos: answerTextError('  '),
  largo: answerTextError('a'.repeat(4001)),
  limite: answerTextError('a'.repeat(4000)),
  surrogate: answerTextError('x\uD800'),
  nul: answerTextError('a\u0000b'),
  esc: answerTextError('\u001b[31m'),
  bidi: answerTextError('x‮y'),
  planStatus: answerTextError('PLAN_STATUS: X'),
  grande: answerTextError('€'.repeat(3000)),
  emojis: answerTextError('😀'.repeat(2000)),
  noTexto: answerTextError(null)
}
'@
        $r.ok | Should BeNullOrEmpty
        $r.okControl | Should BeNullOrEmpty
        $r.vacio | Should Be 'Escribe una respuesta'
        $r.blancos | Should Be 'Escribe una respuesta'
        $r.largo | Should Be 'Máximo 4000 caracteres'
        $r.limite | Should BeNullOrEmpty
        $r.surrogate | Should Be 'La respuesta tiene caracteres no permitidos'
        $r.nul | Should Be 'La respuesta tiene caracteres de control'
        $r.esc | Should Be 'La respuesta tiene caracteres de control'
        $r.bidi | Should Be 'La respuesta tiene caracteres no permitidos'
        $r.planStatus | Should Be 'La respuesta no puede contener PLAN_STATUS'
        $r.grande | Should BeNullOrEmpty
        $r.emojis | Should BeNullOrEmpty
        $r.noTexto | Should Be 'Escribe una respuesta'
    }

    It 'S1: answerTextError acepta 4000 caracteres no ASCII' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  euros: answerTextError('€'.repeat(4000)),
  max: CONTROL_BODY_MAX
}
'@
        $r.euros | Should BeNullOrEmpty
        $r.max | Should Be 16384
    }

    It 'S2: answerTextError rechaza plan_status en minusculas' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  minusculas: answerTextError('plan_status: x')
}
'@
        $r.minusculas | Should Be 'La respuesta no puede contener PLAN_STATUS'
    }

    It 'Q1: controlResultView con la corrida terminada no queda en Orden enviada' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  terminada: controlResultView('id-1', {globalStatus:'STOPPED', control:{last:{id:'otro'}}}, 10),
  confirmada: controlResultView('id-1', {globalStatus:'STOPPED', control:{last:{id:'id-1', result:'applied', action:'stop', detail:'x'}}}, 10),
  viva: controlResultView('id-1', {globalStatus:'RUNNING', control:{last:{id:'otro'}}}, 10)
}
'@
        $r.terminada.state | Should Be 'done'
        $r.terminada.text | Should Be 'La corrida terminó: STOPPED'
        $r.confirmada.state | Should Be 'done'
        $r.confirmada.text | Should Match '^Orden aplicada: '
        $r.viva.state | Should Be 'pending'
    }

    It 'Q1: renderControlBar oculta la barra y limpia la orden pendiente y el mensaje' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $fn = [regex]::Match($html, '(?s)function renderControlBar\(data\) \{.*?if \(!view\.visible\) \{(?<rama>.*?)\r?\n      \}')
        $fn.Success | Should Be $true
        $rama = $fn.Groups['rama'].Value
        $ret = $rama.IndexOf('return;')
        $ret | Should BeGreaterThan -1
        foreach ($t in 'pendingControlId = null', "controlNotice = ''", "`$('control-msg').textContent = ''") {
            $i = $rama.IndexOf($t)
            $i | Should BeGreaterThan -1
            $i | Should BeLessThan $ret
        }
    }

    It '2c: awaitingInfo con y sin vencimiento' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const now = Date.parse('2026-10-28T12:00:00Z');
  const since = '2026-10-28T11:00:00Z';
  return {
    running: awaitingInfo({globalStatus:'RUNNING'}, now),
    con: awaitingInfo({globalStatus:'AWAITING', awaiting:{since:since, deadline:'2026-10-28T14:00:00Z', origin:'BLOCKED', reason:'pregunta'}}, now),
    sin: awaitingInfo({globalStatus:'AWAITING', awaiting:{since:since, deadline:null, origin:'FAILED'}}, now),
    vencido: awaitingInfo({globalStatus:'AWAITING', awaiting:{since:since, deadline:'2026-10-28T11:30:00Z', origin:'FAILED'}}, now),
    sinBloque: awaitingInfo({globalStatus:'AWAITING'}, now)
  };
})()
'@
        $r.running | Should BeNullOrEmpty
        $r.con.remainingMs | Should Be 7200000
        $r.con.origin | Should Be 'BLOCKED'
        $r.con.reason | Should Be 'pregunta'
        $r.con.text | Should Match '^Esperando decisión \(BLOCKED\)'
        $r.con.text | Should Match 'vence en'
        $r.sin.text | Should Match 'sin vencimiento'
        $r.sin.remainingMs | Should BeNullOrEmpty
        $r.sin.reason | Should BeNullOrEmpty
        $r.vencido.remainingMs | Should Be 0
        $r.sinBloque | Should BeNullOrEmpty
    }

    It '2c: shouldNotify avisa al entrar en AWAITING y al cerrar desde AWAITING' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldNotify('RUNNING', 'AWAITING', false), shouldNotify('PAUSED', 'AWAITING', false), shouldNotify('AWAITING', 'AWAITING', false), shouldNotify('AWAITING', 'BLOCKED', false), shouldNotify('AWAITING', 'RUNNING', false), shouldNotify('RUNNING', 'AWAITING', true)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,True,False,True,False,False'
    }

    It '2c: AWAITING es estado vivo: polling, driver muerto y nodo de nivel' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  sano: nextPollDelay(200, {globalStatus:'AWAITING'}, null),
  muerto: nextPollDelay(200, {globalStatus:'AWAITING'}, {driver:{alive:false, reason:'pid_muerto'}}),
  badge: driverDeadInfo({globalStatus:'AWAITING'}, {alive:false, reason:'pid_muerto'}).badge,
  nodo: levelNodeState('AWAITING'),
  motivo: waitReasonText({globalStatus:'AWAITING', reason:'Esperando decisión: x'})
}
'@
        $r.sano | Should Be 4000
        $r.muerto | Should BeNullOrEmpty
        $r.badge | Should Be 'AWAITING · sin driver'
        $r.nodo | Should Be 'awaiting'
        $r.motivo | Should Be 'Esperando decisión: x'
    }

    It '2c: panel I4 en AWAITING y texto del tope de costo' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  aw: finalPanelInfo({globalStatus:'AWAITING', awaiting:{cause:'exit_no_cero'}, history:[{cause:'otra'}]}),
  awSinCausa: finalPanelInfo({globalStatus:'AWAITING', awaiting:{cause:''}, history:[{cause:'otra'}]}),
  tope: finalPanelInfo({globalStatus:'STOPPED', cause:'tope_costo'})
}
'@
        $r.aw.visible | Should Be $true
        $r.aw.cause | Should Be 'exit_no_cero'
        $r.aw.action | Should Be 'La corrida espera tu decisión: responde, reintenta o detén desde la barra de acciones antes de que venza el plazo.'
        $r.awSinCausa.cause | Should Be 'otra'
        $r.tope.action | Should Be 'Se alcanzó el tope de costo. Súbelo con -MaxCostUsd (o desde Parámetros en una corrida viva) y relanza el driver con el mismo comando.'
    }

    It '2c: costView suma solo esta corrida' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  base: costView({limits:{iterBase:2, maxCostUsd:1}, history:[{iter:1, telemetry:{costUsd:0.5}},{iter:3, telemetry:{costUsd:0.25}},{iter:4, telemetry:{costUsd:0.25}}]}),
  sinBase: costView({limits:{maxCostUsd:1}, history:[{iter:1, telemetry:{costUsd:0.5}},{iter:3, telemetry:{costUsd:0.25}},{iter:4, telemetry:{costUsd:0.25}}]}),
  sinIter: costView({limits:{iterBase:2, maxCostUsd:1}, history:[{iter:1, telemetry:{costUsd:0.5}},{iter:3, telemetry:{costUsd:0.25}},{iter:4, telemetry:{costUsd:0.25}},{telemetry:{costUsd:0.1}}]})
}
'@
        $r.base.total | Should Be 0.5
        $r.base.text | Should Be '$0.50 / $1.00'
        $r.sinBase.total | Should Be 1
        $r.sinIter.total | Should Be 0.6
    }

    It '2c: estructura de la barra de espera, el cuadro de respuesta y el menu Abrir' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($id in 'act-answer', 'act-retry-session', 'act-retry-level', 'act-open', 'awaiting-info', 'answer-form', 'answer-text',
                'answer-note', 'answer-send', 'answer-cancel', 'open-menu', 'open-folder', 'open-log', 'open-terminal') {
            $html | Should Match ('id="' + $id + '"')
        }
        $html.Contains('maxlength="4000"') | Should Be $true
        foreach ($t in 'Responder y continuar', 'Reintentar sesión', 'Reintentar nivel', 'Abrir carpeta', 'Abrir log', 'Abrir terminal') {
            $html.Contains($t) | Should Be $true
        }
        ($html -cmatch '\.badge-AWAITING\b') | Should Be $true
        ($html -cmatch '\.node-awaiting\b') | Should Be $true
        $note = 'Si continúas la sesión en la terminal, detén la corrida antes de responder aquí: serían dos continuaciones de la misma conversación.'
        $html.Contains('TERMINAL_NOTE') | Should Be $true
        $html.Contains("const TERMINAL_NOTE = '$note';") | Should Be $true
        $html.Contains("`$('answer-note').textContent = TERMINAL_NOTE;") | Should Be $true
        $html.Contains('window.confirm') | Should Be $false
        $html.Contains('alert(') | Should Be $false
        $h = [regex]::Match($html, "(?s)\`$\('answer-send'\)\.addEventListener\('click'.*?\n    \}\);")
        $h.Success | Should Be $true
        $h.Value.IndexOf('answerTextError(') | Should BeGreaterThan -1
        $h.Value.IndexOf('answerTextError(') | Should BeLessThan $h.Value.IndexOf('sendControl(')
        $envio = $h.Value.IndexOf('await sendControl(')
        $envio | Should BeGreaterThan -1
        $patronVaciado = '(?s)if \(pendingControlId != null\) \{[^}]*?\$\(''answer-text''\)\.value = '''';'
        ($h.Value -cmatch $patronVaciado) | Should Be $true
        [regex]::Match($h.Value, $patronVaciado).Index | Should BeGreaterThan $envio
        $html.IndexOf('answerTextError(', $html.IndexOf('// == puro:fin ==')) | Should BeGreaterThan -1
    }

    It '2c: contrato de punta a punta: answer, retry y open contra el server.py real' -Skip:($noNode -or $noPython) {
        $Root = Join-Path $TestDrive ('ctl ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $logs = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        $statusPath = Join-Path $Root '.driver-status.json'
        $script:statusPaths += $statusPath
        [IO.File]::WriteAllText($statusPath, '{"globalStatus":"AWAITING","control":{"enabled":true,"last":null},"awaiting":{"origin":"BLOCKED","resumable":true,"allowed":["answer","retry","stop","set-params","open"]}}', [Text.UTF8Encoding]::new($false))
        $tok = 'cd' * 32
        $server = Join-Path $moduleRoot 'scripts\dashboard\server.py'
        $assets = Join-Path $moduleRoot 'assets'
        $python = (Get-Command python -CommandType Application | Select-Object -First 1).Source
        $argLine = "`"$server`" --status `"$statusPath`" --logs `"$logs`" --assets `"$assets`" --port 0 --idle-minutes 5"
        $p = Start-Process -FilePath $python -ArgumentList $argLine -Environment @{ DRIVER_DASHBOARD_TOKEN = $tok } -PassThru -WindowStyle Hidden
        try {
            $infoPath = Join-Path $Root '.driver-dashboard.json'
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $infoPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $infoPath | Should Be $true
            $port = (Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).port
            $ctlPath = Join-Path $Root '.driver-control.json'
            $cases = @(
                @{ Expr = "(function () { const r = actionParams('answer', {text:'usa A\ncon ñ'}); return controlRequest(r.action, r.params, '$tok'); })()"; Action = 'answer' },
                @{ Expr = "(function () { const r = actionParams('retry-level'); return controlRequest(r.action, r.params, '$tok'); })()"; Action = 'retry' },
                @{ Expr = "(function () { const r = actionParams('open', openParams('log', {history:[{iter:1}]})); return controlRequest(r.action, r.params, '$tok'); })()"; Action = 'open' }
            )
            $seen = @{}
            foreach ($c in $cases) {
                $req = Invoke-DashboardPure $c.Expr
                $headers = @{ Origin = "http://127.0.0.1:$port" }
                foreach ($prop in $req.init.headers.PSObject.Properties) {
                    if ($prop.Name -ne 'Content-Type') { $headers[$prop.Name] = $prop.Value }
                }
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$req.init.body)
                $res = Invoke-WebRequest -Uri "http://127.0.0.1:$port$($req.path)" -Method $req.init.method -Headers $headers `
                    -ContentType $req.init.headers.'Content-Type' -Body $bytes -NoProxy -TimeoutSec 5 -SkipHttpErrorCheck
                [int]$res.StatusCode | Should Be 202
                $seen[$c.Action] = Get-Content -LiteralPath $ctlPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $seen[$c.Action].action | Should Be $c.Action
                Remove-Item -LiteralPath $ctlPath -Force
            }
            $seen['answer'].params.text | Should Be "usa A`ncon ñ"
            $seen['retry'].params.mode | Should Be 'level'
            $seen['open'].params.target | Should Be 'log'
            $seen['open'].params.iter | Should Be 1
        }
        finally { Stop-DriverDashboard -ProcessId $p.Id }
    }

    It '2b: shouldNotify notifica PAUSED→STOPPED' -Skip:$noNode {
        $r = Invoke-DashboardPure "[shouldNotify('PAUSED', 'STOPPED', false), shouldNotify('PAUSED', 'RUNNING', false), shouldNotify('RUNNING', 'STOPPED', false), shouldNotify('PAUSED', 'STOPPED', true)]"
        ((@($r) | ForEach-Object { "$_" }) -join ',') | Should Be 'True,False,True,False'
    }

    It '2b: el nivel en PAUSED no se pinta como error' -Skip:$noNode {
        $r = Invoke-DashboardPure "[levelNodeState('PAUSED'), levelNodeState('RUNNING'), levelNodeState('FAILED')]"
        (@($r) -join ',') | Should Be 'paused,running,error'
        @($r)[0] | Should Not Be 'error'
    }

    It '2b: controlResultView sin confirmación tras 30 s rehabilita los botones' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  antes: controlResultView('id-A', {control:{last:null}}, 29999),
  plazo: controlResultView('id-A', {control:{last:null}}, 30000),
  gana: controlResultView('id-A', {control:{last:{id:'id-A', result:'applied', action:'pause', detail:'x'}}}, 30000),
  sinPlazo: controlResultView('id-A', {control:{last:null}})
}
"@
        $r.antes.state | Should Be 'pending'
        $r.plazo.state | Should Be 'done'
        $r.plazo.text | Should Be 'Sin confirmación del driver'
        $r.gana.state | Should Be 'done'
        $r.gana.text | Should Match 'Orden aplicada'
        $r.sinPlazo.state | Should Be 'pending'
    }

    # ---- Ola 3: I7 (tareas del plan), D3 (pendiente de integrar), D8 (permisos) ----

    It 'I7: planTasksView agrupa por nivel en orden y pinta las 4 insignias' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
planTasksView({ currentLevel: 1, tasks: { items: [
  { id: 'T3', title: 'Tres', level: 1, status: 'in_progress' },
  { id: 'T1', title: 'Uno', level: 0, status: 'done' },
  { id: 'T2', title: 'Dos', level: 0, status: 'blocked' },
  { id: 'T4', title: 'Cuatro', level: 2, status: 'pending' },
  { id: 'T5', title: 'Cinco', level: 2, status: 'raro' },
  { id: 'T6', title: 'Seis', level: -1, status: 'done' },
  { id: 'T7', title: 'Siete', level: 'x', status: 'done' },
  { id: 'T8', title: 'Ocho', level: 1.5, status: 'done' },
  { id: 'T9', title: 'Nueve', level: null, status: 'done' }
], updatedAt: '2026-10-28T08:10:45-04:00' } })
'@
        $r.truncated | Should Be $false
        (@($r.levels).level -join ',') | Should Be '0,1,2'
        $l0 = @($r.levels)[0]
        $l0.total | Should Be 2
        $l0.doneCount | Should Be 1
        (@($l0.items).id -join ',') | Should Be 'T1,T2'
        $l0.items[0].badgeCls | Should Be 'tk-done'
        $l0.items[0].badgeText | Should Be 'hecha'
        $l0.items[1].badgeCls | Should Be 'tk-blocked'
        $l0.items[1].badgeText | Should Be 'bloqueada'
        $l1 = @($r.levels)[1]
        $l1.items[0].badgeCls | Should Be 'tk-progress'
        $l1.items[0].badgeText | Should Be 'en curso'
        $l1.doneCount | Should Be 0
        $l2 = @($r.levels)[2]
        $l2.items[0].badgeCls | Should Be 'tk-pending'
        $l2.items[0].badgeText | Should Be 'pendiente'
        $l2.items[1].badgeCls | Should Be 'tk-pending'
        $l2.items[1].badgeText | Should Be 'raro'
        $l2.items[1].status | Should Be 'raro'
        $t = Invoke-DashboardPure "planTasksView({ tasks: { items: [{ id: 'A', title: 'a', level: 0, status: 'done' }], truncated: true } }).truncated"
        $t | Should Be $true
    }

    It 'I7: planTasksView sin tasks, con items vacio o con un status viejo devuelve null' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
[
  planTasksView({}),
  planTasksView({ tasks: null }),
  planTasksView({ tasks: 'x' }),
  planTasksView({ tasks: [] }),
  planTasksView({ tasks: {} }),
  planTasksView({ tasks: { items: [] } }),
  planTasksView({ tasks: { items: 'no' } }),
  planTasksView({ tasks: { items: { 0: 1 } } }),
  planTasksView(null),
  planTasksView(undefined),
  planTasksView({ globalStatus: 'RUNNING', currentLevel: 2, totalLevels: 5 })
]
'@
        @($r).Count | Should Be 11
        foreach ($x in @($r)) { $x | Should BeNullOrEmpty }
    }

    It 'I7: planTasksView abre el nivel actual y, si no coincide, el primero con tareas pendientes' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const mk = (cur, defs) => planTasksView({ currentLevel: cur, tasks: { items: defs.map((d, i) => ({ id: 'T' + i, title: 't', level: d[0], status: d[1] })) } });
  const opens = v => v.levels.map(l => l.open ? 1 : 0).join(',');
  return {
    actual: opens(mk(1, [[0, 'done'], [1, 'pending'], [2, 'pending']])),
    actualHecho: opens(mk(0, [[0, 'done'], [1, 'pending']])),
    sinCoincidencia: opens(mk(7, [[0, 'done'], [1, 'in_progress'], [2, 'pending']])),
    sinCurrentLevel: opens(mk(undefined, [[0, 'done'], [1, 'blocked'], [2, 'pending']])),
    primeroAbierto: opens(mk(7, [[0, 'pending'], [1, 'pending']])),
    todasHechas: opens(mk(7, [[0, 'done'], [1, 'done']])),
    desordenado: opens(mk(7, [[2, 'pending'], [0, 'done'], [1, 'pending']]))
  };
})()
'@
        $r.actual | Should Be '0,1,0'
        $r.actualHecho | Should Be '1,0'
        $r.sinCoincidencia | Should Be '0,1,0'
        $r.sinCurrentLevel | Should Be '0,1,0'
        $r.primeroAbierto | Should Be '1,0'
        $r.todasHechas | Should Be '0,0'
        $r.desordenado | Should Be '0,1,0'
        # planLevelUserChoice y planLevelOpenState: sin eleccion sigue a la vista, una eleccion distinta del default se conserva y el default no se registra.
        $q = Invoke-DashboardPure @'
(function () {
  const view = cur => planTasksView({ currentLevel: cur, tasks: { items: [
    { id: 'T0', title: 't', level: 0, status: 'pending' },
    { id: 'T1', title: 't', level: 1, status: 'pending' },
    { id: 'T2', title: 't', level: 2, status: 'pending' }
  ] } }).levels.map(l => l.open);
  const v0 = view(0);
  const v1 = view(1);
  return {
    vista0: v0.join(',') === 'true,false,false',
    vista1: v1.join(',') === 'false,true,false',
    // (a) sin eleccion del usuario el nivel sigue a la vista al pasar de currentLevel 0 a 1
    sigueVistaNivel1: planLevelOpenState(v1[1], undefined) === true,
    sigueVistaNivel0: planLevelOpenState(v1[0], undefined) === false,
    // (b) una eleccion distinta del default se conserva aunque la vista cambie
    conservaAbierto: planLevelOpenState(v1[2], planLevelUserChoice(true, false)) === true,
    conservaCerrado: planLevelOpenState(v0[0], planLevelUserChoice(false, true)) === false,
    // (c) un open igual al default no se registra como eleccion
    igualDefectoCerrado: planLevelUserChoice(false, false) === undefined,
    igualDefectoAbierto: planLevelUserChoice(true, true) === undefined
  };
})()
'@
        $q.vista0 | Should Be $true
        $q.vista1 | Should Be $true
        $q.sigueVistaNivel1 | Should Be $true
        $q.sigueVistaNivel0 | Should Be $true
        $q.conservaAbierto | Should Be $true
        $q.conservaCerrado | Should Be $true
        $q.igualDefectoCerrado | Should Be $true
        $q.igualDefectoAbierto | Should Be $true
    }

    It 'I7: planTasksView da hashes cortos de commit y fixCommits' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const v = planTasksView({ tasks: { items: [
    { id: 'A', title: 'a', level: 0, status: 'done', commit: 'ABCDEF1234567890', fixCommits: ['2e2ff1a', 'nope', 'abc"onmouseover=x', 'a'.repeat(40), 'abc12', 'a'.repeat(41), 7] },
    { id: 'B', title: 'b', level: 0, status: 'done', commit: 'abc123', fixCommits: 'no-es-arreglo' },
    { id: 'C', title: 'c', level: 0, status: 'done', commit: 'xyz1234' },
    { id: 'D', title: 'd', level: 0, status: 'done', commit: 'a'.repeat(41) },
    { id: 'E', title: 'e', level: 0, status: 'done', commit: 1234567 },
    { id: 'F', title: 'f', level: 0, status: 'done', commit: null, fixCommits: null },
    { id: 'G', title: 'g', level: 0, status: 'done', commit: 'a'.repeat(40) }
  ] } });
  return v.levels[0].items;
})()
'@
        $a = @($r)[0]
        $a.commit | Should Be 'ABCDEF1234567890'
        $a.commitShort | Should Be 'ABCDEF1'
        @($a.fixCommits).Count | Should Be 2
        $a.fixCommits[0].hash | Should Be '2e2ff1a'
        $a.fixCommits[0].short | Should Be '2e2ff1a'
        $a.fixCommits[1].hash | Should Be ('a' * 40)
        $a.fixCommits[1].short | Should Be 'aaaaaaa'
        foreach ($i in 1..5) {
            @($r)[$i].commit | Should BeNullOrEmpty
            @($r)[$i].commitShort | Should BeNullOrEmpty
            @(@($r)[$i].fixCommits).Count | Should Be 0
        }
        @($r)[6].commit | Should Be ('a' * 40)
        @($r)[6].commitShort | Should Be 'aaaaaaa'
    }

    It 'I7: el HTML en el plan o el checkpoint no se interpreta' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const v = planTasksView({ tasks: { items: [
    { id: '<b>x</b>', title: '<img src=x onerror=alert(1)>', level: 0, status: '<img src=x onerror=alert(1)>', commit: 'abc"onmouseover=x', fixCommits: ['abc"onmouseover=x'] }
  ] } });
  return v.levels[0].items[0];
})()
'@
        $r.id | Should Be '<b>x</b>'
        $r.title | Should Be '<img src=x onerror=alert(1)>'
        $r.badgeText | Should Be '<img src=x onerror=alert(1)>'
        $r.badgeCls | Should Be 'tk-pending'
        $r.commit | Should BeNullOrEmpty
        @($r.fixCommits).Count | Should Be 0
        # Sin id ni title el panel muestra un guion, nunca 'undefined' ni 'null'. Se usa [char] para no depender de la codificacion del fichero.
        $sinDatos = Invoke-DashboardPure @'
(function () {
  const v = planTasksView({ tasks: { items: [ { level: 0, status: 'done' } ] } });
  return v.levels[0].items[0];
})()
'@
        $sinDatos.id | Should Be ([string][char]0x2014)
        $sinDatos.title | Should Be ([string][char]0x2014)
        # El render pinta con textContent / escapeHtml: nada de HTML armado con esos valores.
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $fn = [regex]::Match($html, '(?s)function renderPlanTasks\(.*?\n    \}\r?\n').Value
        $fn | Should Not BeNullOrEmpty
        $fn.Contains('textContent') | Should Be $true
        $fn.Contains('innerHTML') | Should Be $false
        $fn.Contains('insertAdjacentHTML') | Should Be $false
        ($fn -cmatch "textContent = [^;]*\b(it|tk|item)\.id\b") | Should Be $true
        ($fn -cmatch "textContent = [^;]*\b(it|tk|item)\.title\b") | Should Be $true
        ($fn -cmatch "textContent = [^;]*\b(it|tk|item)\.badgeText\b") | Should Be $true
        ($fn -cmatch "textContent = [^;]*\blv\.level\b") | Should Be $true
        ($fn -cmatch "setAttribute\('data-cmd', [^)]*\.hash\)|escapeHtml\([^)]*\.hash\)") | Should Be $true
    }

    It 'D3: integrationView es null si el estado no es DONE' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const git = { branch: 'b', baseBranch: 'main', ahead: 1, clean: true, error: null };
  const rv = { exists: true, counts: { CRITICAL: 0, IMPORTANT: 0, MINOR: 0 } };
  return ['RUNNING', 'FAILED', 'BLOCKED', 'STOPPED', 'AWAITING', 'PAUSED', 'done', '', undefined].map(s => integrationView({ globalStatus: s, git }, rv))
    .concat([integrationView({}, rv), integrationView(null, rv), integrationView(undefined, undefined)]);
})()
'@
        @($r).Count | Should Be 12
        foreach ($x in @($r)) { $x | Should BeNullOrEmpty }
    }

    It 'D3: integrationView da Lista para integrar con arbol limpio y sin CRITICAL ni IMPORTANT' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
integrationView(
  { globalStatus: 'DONE', git: { branch: 'feat/x', baseBranch: 'main', ahead: 3, clean: true, error: null } },
  { exists: true, counts: { CRITICAL: 0, IMPORTANT: 0, MINOR: 2 } })
'@
        $r.ready | Should Be $true
        $r.badgeCls | Should Be 'ig-ready'
        $r.badgeText | Should Be 'Lista para integrar'
        $r.branchText | Should Be 'feat/x (base main)'
        $r.aheadText | Should Be '3 commits por delante'
        $r.cleanText | Should Be 'limpio'
        $r.countsText | Should Be 'CRITICAL: 0 · IMPORTANT: 0 · MINOR: 2'
        @($r.steps).Count | Should Be 1
        $r.steps[0] | Should Be '1. Ejecutar finishing-a-development-branch (merge, push o PR) desde una sesión humana'
    }

    It 'D3: integrationView muestra Resolver los hallazgos solo con CRITICAL o IMPORTANT' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const g = { branch: 'b', baseBranch: 'main', ahead: 1, clean: true, error: null };
  const rv = (c, i, m) => ({ exists: true, counts: { CRITICAL: c, IMPORTANT: i, MINOR: m } });
  return {
    critical: integrationView({ globalStatus: 'DONE', git: g }, rv(1, 0, 0)).steps,
    important: integrationView({ globalStatus: 'DONE', git: g }, rv(0, 1, 0)).steps,
    minor: integrationView({ globalStatus: 'DONE', git: g }, rv(0, 0, 3)).steps
  };
})()
'@
        $critical = @($r.critical)
        $critical.Count | Should Be 2
        $critical[0] | Should Be '1. Resolver los hallazgos abiertos'
        $critical[1] | Should Match '^2\. Ejecutar finishing-a-development-branch'
        $important = @($r.important)
        $important.Count | Should Be 2
        $important[0] | Should Be '1. Resolver los hallazgos abiertos'
        $important[1] | Should Match '^2\. Ejecutar finishing-a-development-branch'
        $minor = @($r.minor)
        $minor.Count | Should Be 1
        $minor[0] | Should Match '^1\. Ejecutar finishing-a-development-branch'
    }

    It 'D3: integrationView da Requiere atencion con CRITICAL, con IMPORTANT o con el arbol sucio' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const g = c => ({ branch: 'b', baseBranch: 'main', ahead: 1, clean: c, error: null });
  const rv = (c, i, m) => ({ exists: true, counts: { CRITICAL: c, IMPORTANT: i, MINOR: m } });
  return [
    integrationView({ globalStatus: 'DONE', git: g(true) }, rv(1, 0, 0)),
    integrationView({ globalStatus: 'DONE', git: g(true) }, rv(0, 2, 0)),
    integrationView({ globalStatus: 'DONE', git: g(false) }, rv(0, 0, 0)),
    integrationView({ globalStatus: 'DONE', git: g('si') }, rv(0, 0, 0))
  ];
})()
'@
        foreach ($x in @($r)) {
            $x.ready | Should Be $false
            $x.badgeCls | Should Be 'ig-attention'
            $x.badgeText | Should Be 'Requiere atención'
        }
        @($r)[2].cleanText | Should Be 'con cambios sin commitear'
        @($r)[0].countsText | Should Be 'CRITICAL: 1 · IMPORTANT: 0 · MINOR: 0'
    }

    It 'D3: integrationView da Requiere atencion si falta git, si git trae error, si falta la revision o si no trae counts' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const g = { branch: 'b', baseBranch: 'main', ahead: 1, clean: true, error: null };
  const ok = { exists: true, counts: { CRITICAL: 0, IMPORTANT: 0, MINOR: 0 } };
  const d = (git, rv) => integrationView({ globalStatus: 'DONE', git }, rv);
  return {
    sinGit: d(undefined, ok),
    gitNull: d(null, ok),
    gitError: d({ branch: 'b', baseBranch: 'main', ahead: 1, clean: true, error: 'fatal' }, ok),
    sinRevision: d(g, null),
    noExiste: d(g, { exists: false }),
    sinCounts: d(g, { exists: true, counts: null }),
    sinCountsClave: d(g, { exists: true }),
    countNoEntero: d(g, { exists: true, counts: { CRITICAL: '0', IMPORTANT: 0, MINOR: 0 } }),
    countFaltante: d(g, { exists: true, counts: { CRITICAL: 0, MINOR: 0 } }),
    countFraccion: d(g, { exists: true, counts: { CRITICAL: 0, IMPORTANT: 0.5, MINOR: 0 } }),
    cleanFalta: d({ branch: 'b', baseBranch: 'main', ahead: 1 }, ok)
  };
})()
'@
        foreach ($p in $r.PSObject.Properties) {
            $p.Value.ready | Should Be $false
            $p.Value.badgeCls | Should Be 'ig-attention'
            $p.Value.badgeText | Should Be 'Requiere atención'
        }
        $r.sinGit.branchText | Should Be '—'
        $r.sinGit.aheadText | Should Be '—'
        $r.sinGit.cleanText | Should Be '—'
        $r.gitError.branchText | Should Be '—'
        $r.sinRevision.countsText | Should Be 'sin revisión final'
        $r.noExiste.countsText | Should Be 'sin revisión final'
        $r.cleanFalta.cleanText | Should Be '—'
    }

    It 'D3: los pasos fijos: el 1 solo con hallazgos y el 2 siempre' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
(function () {
  const g = { branch: 'b', baseBranch: 'main', ahead: 1, clean: true, error: null };
  const d = (rv, git) => integrationView({ globalStatus: 'DONE', git: git === undefined ? g : git }, rv).steps;
  const c = (a, b, m) => ({ exists: true, counts: { CRITICAL: a, IMPORTANT: b, MINOR: m } });
  return {
    ceros: d(c(0, 0, 0)),
    critical: d(c(1, 0, 0)),
    important: d(c(0, 1, 0)),
    minor: d(c(0, 0, 3)),
    sinRevision: d(null),
    sinCounts: d({ exists: true, counts: null }),
    sinGit: d(c(0, 0, 0), null),
    gitSucio: d(c(0, 0, 0), { clean: false })
  };
})()
'@
        $uno = '1. Resolver los hallazgos abiertos'
        $dosFin = '2. Ejecutar finishing-a-development-branch (merge, push o PR) desde una sesión humana'
        $unoFin = '1. Ejecutar finishing-a-development-branch (merge, push o PR) desde una sesión humana'
        @($r.ceros).Count | Should Be 1
        $r.ceros[0] | Should Be $unoFin
        foreach ($k in 'critical', 'important') {
            @($r.$k).Count | Should Be 2
            $r.$k[0] | Should Be $uno
            $r.$k[1] | Should Be $dosFin
        }
        @($r.minor).Count | Should Be 1
        $r.minor[0] | Should Be $unoFin
        foreach ($k in 'sinRevision', 'sinCounts', 'sinGit', 'gitSucio') {
            @($r.$k).Count | Should Be 1
            $r.$k[0] | Should Be $unoFin
        }
    }

    It 'D8: permissionsView con perfil, con unsafe, sin bloque y con un modo desconocido' -Skip:$noNode {
        $r = Invoke-DashboardPure @'
{
  perfil: permissionsView({ permissions: { mode: 'profile', profile: 'plan' } }),
  perfilOtro: permissionsView({ permissions: { mode: 'profile', profile: 'estricto' } }),
  perfilNulo: permissionsView({ permissions: { mode: 'profile', profile: null } }),
  unsafe: permissionsView({ permissions: { mode: 'unsafe', profile: null } }),
  sinBloque: permissionsView({ globalStatus: 'RUNNING' }),
  nulo: permissionsView({ permissions: null }),
  texto: permissionsView({ permissions: 'x' }),
  desconocido: permissionsView({ permissions: { mode: 'otro', profile: 'plan' } }),
  sinModo: permissionsView({ permissions: {} }),
  sinStatus: permissionsView(null)
}
'@
        $r.perfil.cls | Should Be 'perm-profile'
        $r.perfil.text | Should Be 'Permisos: perfil plan'
        $r.perfilOtro.text | Should Be 'Permisos: perfil estricto'
        $r.perfilNulo.cls | Should Be 'perm-profile'
        $r.perfilNulo.text | Should Be 'Permisos: perfil —'
        $r.unsafe.cls | Should Be 'perm-unsafe'
        $r.unsafe.text | Should Be 'Permisos: sin restricciones'
        foreach ($k in 'sinBloque', 'nulo', 'texto', 'desconocido', 'sinModo', 'sinStatus') { $r.$k | Should BeNullOrEmpty }
    }

    It 'D8: suggestedAction de perfil_invalido' -Skip:$noNode {
        $r = Invoke-DashboardPure "[suggestedAction('FAILED', 'perfil_invalido'), suggestedAction('FAILED', 'error_driver')]"
        @($r)[0] | Should Be 'Revisa scripts/profiles/plan.settings.json en el runner; relanzar con -UnsafeSkipPermissions quita todas las restricciones.'
        @($r)[0] | Should Not Be @($r)[1]
    }

    It 'estructura: perm-badge, plan-tasks-panel e integration-panel existen y el panel de integracion no ejecuta nada' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($id in 'perm-badge', 'plan-tasks-panel', 'plan-tasks-body', 'integration-panel', 'integration-body') {
            $html | Should Match ('id="' + $id + '"')
        }
        foreach ($c in 'tk-done', 'tk-progress', 'tk-blocked', 'tk-pending', 'ig-ready', 'ig-attention', 'perm-unsafe') {
            ($html -cmatch ('\.' + $c + '\s*\{')) | Should Be $true
        }
        $html.Contains('Tareas del plan') | Should Be $true
        $html.Contains('Pendiente de integrar') | Should Be $true
        $html.Contains('lastFinalReview') | Should Be $true
        ($html.IndexOf('id="final-review-panel"') -lt $html.IndexOf('id="integration-panel"')) | Should Be $true
        ($html.IndexOf('id="plan-tasks-panel"') -lt $html.IndexOf('id="tasks-panel"')) | Should Be $true
        $fn = [regex]::Match($html, '(?s)function renderIntegration\(.*?\n    \}\r?\n').Value
        $fn | Should Not BeNullOrEmpty
        foreach ($t in 'fetch(', 'controlRequest', 'sendControl', '<button', 'onclick', '<a ', 'createElement(''button'')', 'createElement(''a'')') {
            $fn.Contains($t) | Should Be $false
        }
        $panel = [regex]::Match($html, '(?s)<div class="card" id="integration-panel".*?</div>\s*</div>').Value
        $panel | Should Not BeNullOrEmpty
        $panel | Should Not Match '<button|<a |onclick'
    }

    It 'fixtures: tasks de status-done.json coincide con Get-PlanTasks de los fixtures de T2' {
        Import-Module (Join-Path $moduleRoot 'scripts\modules\PlanTasks.psm1') -Force
        try {
            $ptDir = Join-Path $moduleRoot 'tests\fixtures\plan-tasks'
            # El checkpoint nombra al plan 2026-10-28-dashboard-ola-2c.md: se copia el plan fixture con ese nombre.
            $plan = Join-Path $TestDrive '2026-10-28-dashboard-ola-2c.md'
            Copy-Item -LiteralPath (Join-Path $ptDir 'plan-ola-2c-map.md') -Destination $plan -Force
            $expected = Get-PlanTasks -PlanFilePath $plan -ControllerStatePath (Join-Path $ptDir 'controller-state-ola-2c.json')
            $line = { param($i) '{0}|{1}|{2}|{3}|{4}|{5}' -f $i.id, $i.title, $i.level, $i.status, $i.commit, (@($i.fixCommits) -join ',') }
            $done = Get-Content -LiteralPath (Join-Path $fixtures 'status-done.json') -Raw | ConvertFrom-Json
            @($done.tasks.items).Count | Should Be @($expected.items).Count
            (@($done.tasks.items | ForEach-Object { & $line $_ }) -join "`n") | Should Be (@($expected.items | ForEach-Object { & $line $_ }) -join "`n")
            $done.tasks.updatedAt | Should Not BeNullOrEmpty
            $done.permissions.mode | Should Be 'profile'
            $done.permissions.profile | Should Be 'plan'
            $done.git.clean | Should Be $true
            $done.git.error | Should BeNullOrEmpty
            $run = Get-Content -LiteralPath (Join-Path $fixtures 'status-running.json') -Raw | ConvertFrom-Json
            (@($run.tasks.items).status | Sort-Object -Unique) -join ',' | Should Be 'blocked,done,in_progress,pending'
            $run.permissions.mode | Should Be 'unsafe'
            $run.permissions.profile | Should BeNullOrEmpty
        } finally {
            Remove-Module PlanTasks -ErrorAction SilentlyContinue
        }
    }
}

Describe 'dashboard.html (1c): panel final' {
    $fixtures = Join-Path $moduleRoot 'tests\fixtures\dashboard'

    It 'finalPanelInfo toma el ultimo evento y logLeaf tolera rutas de driver viejo' -Skip:$noNode {
        $blocked = Get-Content -LiteralPath (Join-Path $fixtures 'status-blocked.json') -Raw
        $running = Get-Content -LiteralPath (Join-Path $fixtures 'status-running.json') -Raw
        $done = Get-Content -LiteralPath (Join-Path $fixtures 'status-done.json') -Raw
        $r = Invoke-DashboardPure @"
{
  blk: finalPanelInfo($blocked),
  run: finalPanelInfo($running),
  done: finalPanelInfo($done),
  empty: finalPanelInfo({}),
  nul: finalPanelInfo(null),
  noHist: finalPanelInfo({globalStatus:'FAILED'}),
  emptyHist: finalPanelInfo({globalStatus:'FAILED', history:[]}),
  old: logLeaf('C:\\a\\b\\session-1-20261015-152000.log'),
  unix: logLeaf('/a/b/c.log'),
  plain: logLeaf('x.log'),
  none: logLeaf(null),
  blank: logLeaf('')
}
"@
        $r.blk.visible | Should Be $true
        $r.blk.cause | Should BeNullOrEmpty
        $r.blk.planStatusReason | Should Match '^falta definir'
        $r.blk.logName | Should Be 'session-3-20261015-154320.log'
        $r.blk.errName | Should Be 'session-3-20261015-154320.err.log'
        $r.blk.sessionId | Should Be 'sess-demo-3'
        $r.run.visible | Should Be $false
        $r.done.visible | Should Be $false
        $r.empty.visible | Should Be $false
        $r.nul.visible | Should Be $false
        $r.noHist.visible | Should Be $true
        $r.noHist.logName | Should BeNullOrEmpty
        $r.emptyHist.visible | Should Be $true
        $r.emptyHist.errName | Should BeNullOrEmpty
        $r.old | Should Be 'session-1-20261015-152000.log'
        $r.unix | Should Be 'c.log'
        $r.plain | Should Be 'x.log'
        $r.none | Should BeNullOrEmpty
        $r.blank | Should BeNullOrEmpty
    }

    It 'suggestedAction cubre cada causa conocida y tiene texto por defecto' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  trunc: suggestedAction('FAILED','truncada_background'),
  colg: suggestedAction('FAILED','colgada'),
  drv: suggestedAction('FAILED','error_driver'),
  blkQ: suggestedAction('BLOCKED','pregunta_sin_marca'),
  man: suggestedAction('STOPPED','manual'),
  max: suggestedAction('STOPPED_MAX_ITERATIONS', null),
  newFail: suggestedAction('FAILED','causa_nueva'),
  blkNull: suggestedAction('BLOCKED', null),
  other: suggestedAction('DONE', null)
}
"@
        $r.trunc | Should Match 'BackgroundWaitCeilingMs'
        $r.trunc | Should Match 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'
        $r.colg | Should Match 'LivenessTimeoutMinutes'
        $r.drv | Should Not BeNullOrEmpty
        $r.drv | Should Match 'durante la corrida'
        $r.blkQ | Should Match 'claude --resume'
        $r.man | Should Match 'mismo comando'
        $r.max | Should Match 'MaxIterations'
        $r.newFail | Should Not BeNullOrEmpty
        $r.blkNull | Should Not BeNullOrEmpty
        $r.other | Should Not BeNullOrEmpty
    }
}

Describe 'dashboard.html (1c): actividad V1-V6' {
    $demo = Join-Path $moduleRoot 'tests\fixtures\dashboard\Start-DashboardDemo.ps1'
    $noPython = -not (Get-Command python -ErrorAction SilentlyContinue)
    Import-Module (Join-Path $moduleRoot 'scripts\modules\HttpDashboard.psm1') -Force
    $script:statusPaths = @()

    # Vista de sesion viva con dos barras de T4 (la primera rechazada, la segunda abierta) y un commit.
    $liveView = @'
{ available: true,
  session: { iter: 3, streamFile: 'session-3.stream.jsonl', live: true },
  stats: { bytes: 100, events: 4, skipped: 0 },
  lastEventAt: '2026-10-15T20:10:00.000Z',
  tasks: [{ code: 'T4', stages: [
      { role: 'impl', label: 'primera', state: 'ko', barId: 'b1' },
      { role: 'quality', label: null, state: 'run', barId: 'b2' }], cycles: 1, reworkAlert: false, done: false }],
  bars: [
    { id: 'b1', task: 'T4', role: 'impl', subagentType: 'implementer', description: 'primera', startedAt: '2026-10-15T20:00:00.000Z', endedAt: '2026-10-15T20:10:00.000Z', status: 'completed', tokens: 1000, toolUses: 3, lastTool: 'Edit' },
    { id: 'b2', task: 'T4', role: 'quality', subagentType: 'reviewer', description: 'segunda', startedAt: '2026-10-15T20:10:00.000Z', endedAt: null, status: null, tokens: 41234, toolUses: null, lastTool: 'Read' }],
  live: ['b2'],
  commits: [{ at: '2026-10-15T20:05:00.000Z', branch: 'feature/X' }],
  quota: null }
'@

    AfterAll {
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$TestDrive*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $module = Get-Module HttpDashboard
        foreach ($sp in $script:statusPaths) {
            $logs = & $module { Get-DriverDashboardServerLogs -StatusPath $args[0] } $sp
            Remove-Item -LiteralPath $logs.Out, $logs.Err -Force -ErrorAction SilentlyContinue
        }
    }

    It 'roleLabel y stageView cubren los cuatro estados, incluido unclosed' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  ko: stageView({role:'quality',state:'ko'}),
  unc: stageView({role:'other',state:'unclosed'}),
  ok: stageView({role:'impl',state:'ok'}),
  run: stageView({role:'fix',state:'run'}),
  pend: stageView({role:'spec',state:'raro'}),
  impl: roleLabel('impl'),
  unknown: roleLabel('zzz'),
  nul: roleLabel(null)
}
"@
        $r.ko.cls | Should Be 'st-ko'
        $r.ko.text | Should Match 'calidad'
        $r.unc.cls | Should Be 'st-unclosed'
        $r.unc.text | Should Match 'sin cierre'
        $r.ok.cls | Should Be 'st-ok'
        $r.run.cls | Should Be 'st-run'
        $r.pend.cls | Should Be 'st-pend'
        $r.impl | Should Be 'implementer'
        $r.unknown | Should Be 'zzz'
        $r.nul | Should Be 'otro'
    }

    It 'taskRows usa tasks[].code, respeta el orden y arma los badges' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
{
  rows: taskRows({ available: true, tasks: [
    { code: 'T4', stages: [{ role: 'impl', label: null, state: 'ok', barId: 'a' }], cycles: 3, reworkAlert: true, done: false },
    { code: 'T6', stages: [], cycles: 1, reworkAlert: false, done: true },
    { code: 'otras', stages: [], cycles: 0, reworkAlert: false, done: false }] }),
  off: taskRows({ available: false }),
  nul: taskRows(null),
  bare: taskRows({ available: true })
}
"@
        (@($r.rows).code -join ',') | Should Be 'T4,T6,otras'
        $t4 = @($r.rows)[0]
        $t4.badge.cls | Should Be 'rw-warn'
        $t4.badge.text | Should Match '3 ciclos'
        @($t4.stages)[0].cls | Should Be 'st-ok'
        @($t4.stages)[0].barId | Should Be 'a'
        $t6 = @($r.rows)[1]
        $t6.badge.cls | Should Be 'rw-ok'
        $t6.badge.text | Should Match 'hecha'
        $t6.badge.text | Should Match '1 ciclo'
        $t6.badge.text | Should Not Match '1 ciclos'
        @($r.off).Count | Should Be 0
        @($r.nul).Count | Should Be 0
        @($r.bare).Count | Should Be 0
        $html = Get-Content -LiteralPath $htmlPath -Raw
        $block = [regex]::Match($html, '(?s)// == puro:inicio ==(.*?)// == puro:fin ==').Groups[1].Value
        $block | Should Not Match '\.tasks\[[^\]]*\]\.task\b'
        $block | Should Not Match 'task\.task\b'
    }

    It 'timelineLayout con sesion viva: barra abierta hasta ahora, linea ahora y commits' -Skip:$noNode {
        $r = Invoke-DashboardPure "timelineLayout($liveView, Date.parse('2026-10-15T20:20:00Z'))"
        $lane = @($r.lanes)[0]
        $lane.code | Should Be 'T4'
        @($lane.bars).Count | Should Be 2
        $b1 = @($lane.bars)[0]
        $b1.leftPct | Should Be 0
        $b1.widthPct | Should Be 50
        $b1.ko | Should Be $true
        $b1.cls | Should Be 't-impl'
        $b2 = @($lane.bars)[1]
        $b2.live | Should Be $true
        $b2.unclosed | Should Be $false
        ($b2.leftPct + $b2.widthPct) | Should Be 100
        $r.nowPct | Should Be 100
        @($r.commits)[0].leftPct | Should Be 25
        @($r.commits)[0].title | Should Match 'feature/X'
        @($r.ticks).Count | Should BeGreaterThan 0
        @($r.ticks).Count | Should BeLessThan 9
    }

    It 'timelineLayout con sesion terminada: unclosed, sin linea ahora y degradacion' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function(){
  const v = $liveView;
  v.session.live = false;
  v.lastEventAt = '2026-10-15T20:15:00.000Z';
  const base = timelineLayout(v, Date.parse('2026-10-15T20:30:00Z'));
  v.bars.push({ id: 'b3', task: 'T4', role: 'fix', description: null, startedAt: null, endedAt: null });
  const withNull = timelineLayout(v, Date.parse('2026-10-15T20:30:00Z'));
  return {
    base, nullBars: withNull.lanes[0].bars.length, expectEnd: Date.parse('2026-10-15T20:15:00Z'),
    none: timelineLayout({ available: true, tasks: [], bars: [], live: [], commits: [] }, 0),
    nul: timelineLayout(null, 0),
    bare: timelineLayout({}, 0)
  };
})()
"@
        $r.base.nowPct | Should BeNullOrEmpty
        $r.base.endMs | Should Be $r.expectEnd
        @(@($r.base.lanes)[0].bars)[1].unclosed | Should Be $true
        @(@($r.base.lanes)[0].bars)[1].live | Should Be $false
        $r.nullBars | Should Be 2
        $r.none | Should BeNullOrEmpty
        $r.nul | Should BeNullOrEmpty
        $r.bare | Should BeNullOrEmpty
        @($r.base.commits).Count | Should Be 1
    }

    It 'liveRows y formatTokens' -Skip:$noNode {
        $r = Invoke-DashboardPure @"
(function(){
  const v = $liveView;
  const now = Date.parse('2026-10-15T20:14:00Z');
  const vivo = liveRows(v, now);
  v.session.live = false;
  const muerto = liveRows(v, now);
  return {
    vivo, muerto,
    vacio: liveRows({ available: true, live: ['zzz'], bars: [] }, now),
    nul: liveRows(null, now),
    t0: formatTokens(null), t1: formatTokens(950), t2: formatTokens(41234),
    t3: formatTokens('x')
  };
})()
"@
        @($r.vivo).Count | Should Be 1
        @($r.vivo)[0].id | Should Be 'b2'
        @($r.vivo)[0].elapsedMs | Should Be 240000
        @($r.vivo)[0].unclosed | Should Be $false
        @($r.vivo)[0].lastTool | Should Be 'Read'
        @($r.vivo)[0].tokens | Should Be 41234
        @($r.muerto)[0].unclosed | Should Be $true
        @($r.vacio).Count | Should Be 0
        @($r.nul).Count | Should Be 0
        $r.t0 | Should Be ([string][char]0x2014)
        $r.t1 | Should Be '950'
        $r.t2 | Should Be '41 k'
        $r.t3 | Should Be ([string][char]0x2014)
    }

    It 'sin projectPath, la cabecera y resumeCommand no muestran undefined' -Skip:$noNode {
        $r = Invoke-DashboardPure "[projectLabel(undefined), projectLabel('C:/proyecto'), resumeCommand(undefined, 'abc-123'), resumeCommand(null, 'abc-123'), resumeCommand('C:/x y', 'abc-123')]"
        $items = @($r)
        $items.Count | Should Be 5
        $items[0] | Should Be 'proyecto sin dato'
        $items[1] | Should Be 'C:/proyecto'
        $items[2] | Should Not Match 'undefined'
        $items[2] | Should Be 'claude --resume abc-123'
        $items[3] | Should Not Match 'undefined'
        $items[4] | Should Be 'cd "C:/x y" && claude --resume abc-123'
    }

    It 'contrato de punta a punta: la vista real del servidor alimenta las funciones puras' -Skip:($noNode -or $noPython) {
        $expr = "(function(v){ return { rows: taskRows(v), tl: timelineLayout(v, Date.parse(v.lastEventAt)), live: liveRows(v, Date.parse(v.lastEventAt)) }; })"
        foreach ($state in 'RUNNING', 'STOPPED') {
            $Root = Join-Path $TestDrive ('demo ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $h = & $demo -State $state -Root $Root
            $script:statusPaths += $h.StatusPath
            try {
                # JSON crudo como literal JS: pasarlo por ConvertFrom-Json convertiria las fechas ISO en DateTime.
                $json = (Invoke-WebRequest -Uri "$($h.Url)activity.json" -NoProxy -TimeoutSec 5).Content
                $r = Invoke-DashboardPure "$expr($json)"
                (@($r.rows).code -join ',') | Should Be 'T4,T6,T9,otras'
                $t4 = @($r.rows) | Where-Object { $_.code -eq 'T4' }
                @($t4.stages).Count | Should Be 5
                $t4.badge.text | Should Match 'hecha'
                $t9 = @($r.rows) | Where-Object { $_.code -eq 'T9' }
                (@($r.tl.lanes).code -join ',') | Should Be 'T4,T6,T9,otras'
                @($r.tl.commits).Count | Should Be 1
                @($r.live).Count | Should Be 1
                @($r.live)[0].id | Should Be 'syn-t9'
                if ($state -eq 'RUNNING') {
                    @($t9.stages)[0].cls | Should Be 'st-run'
                }
                else {
                    @($t9.stages)[0].cls | Should Be 'st-unclosed'
                    $r.tl.nowPct | Should BeNullOrEmpty
                    @($r.live)[0].unclosed | Should Be $true
                }
            }
            finally { Stop-DriverDashboard -ProcessId $h.Pid }
        }
    }

    It 'estructura de los paneles de actividad' {
        $html = Get-Content -LiteralPath $htmlPath -Raw
        foreach ($p in 'id="tasks-panel"', 'id="timeline"', 'id="live-activity"', 'inferido', 'sin cierre',
                "safeRender\('tasks-panel'", "safeRender\('timeline'", "safeRender\('live-activity'",
                "matches\(':hover'\)",
                'st-unclosed', 't-other') {
            $html | Should Match $p
        }
    }
}

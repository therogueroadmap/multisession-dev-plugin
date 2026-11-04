$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverNotify.psm1') -Force
. (Join-Path $moduleRoot 'tests\fixtures\WebhookCapture.ps1')

# Espera a que exista el archivo de captura (hasta $TimeoutSeconds).
function Wait-CaptureFile {
    param([string]$Path, [int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    return (Test-Path -LiteralPath $Path)
}

function ConvertFrom-B64Utf8 {
    param([string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

Describe 'DriverNotify' {
    It 'Format-DriverNotification arma titulo y cuerpo con sesiones, coste y duracion' {
        $f = Format-DriverNotification -Status DONE -Reason 'plan completo' `
            -PlanFile 'C:\p\docs\superpowers\plans\2026-10-27-mi-plan.md' -Sessions 3 -CostUsd 12.5 `
            -Duration (New-TimeSpan -Minutes 83) -DashboardUrl 'http://localhost:8787/'
        $f.Title | Should Be 'Driver DONE: 2026-10-27-mi-plan'
        $f.Body | Should Be "plan completo`n3 sesiones · 12,50 USD · 1 h 23 min`nhttp://localhost:8787/"
    }

    It 'Format-DriverNotification recorta reason a 200, omite coste nulo, url ausente y usa minutos bajo una hora' {
        $f = Format-DriverNotification -Status FAILED -Reason ('a' * 250) -Sessions 2 -CostUsd $null `
            -Duration (New-TimeSpan -Minutes 5 -Seconds 59)
        $lines = $f.Body -split "`n"
        $lines.Count | Should Be 2
        $lines[0].Length | Should Be 200
        $lines[1] | Should Be '2 sesiones · 5 min'
        $f.Title | Should Be 'Driver FAILED: sin-plan'

        $g = Format-DriverNotification -Status FAILED -Sessions 2 -CostUsd $null -Duration (New-TimeSpan -Minutes 5)
        ($g.Body -split "`n")[0] | Should Be '2 sesiones · 5 min'
    }

    It 'prioridad, etiquetas y titulo ASCII' {
        (Format-DriverNotification -Status FAILED).Priority | Should Be 'high'
        (Format-DriverNotification -Status BLOCKED).Priority | Should Be 'high'
        (Format-DriverNotification -Status STOPPED_MAX_ITERATIONS).Priority | Should Be 'high'
        (Format-DriverNotification -Status DONE).Priority | Should Be 'default'
        $f = Format-DriverNotification -Status DONE -PlanFile 'C:\x\revisión-ñandú.md'
        $f.AsciiTitle | Should Be 'Driver DONE: revision-nandu'
        (Format-DriverNotification -Status DONE).Tags | Should Be 'white_check_mark'
        (Format-DriverNotification -Status FAILED).Tags | Should Be 'x'
    }

    It 'Test-DriverNotificationDue: finales si, RUNNING no, STOPPED por Ctrl+C no' {
        foreach ($s in 'DONE', 'BLOCKED', 'FAILED', 'STOPPED_MAX_ITERATIONS') {
            Test-DriverNotificationDue -Status ([pscustomobject]@{ globalStatus = $s; history = @() }) | Should Be $true
        }
        Test-DriverNotificationDue -Status ([pscustomobject]@{ globalStatus = 'RUNNING'; history = @() }) | Should Be $false
        Test-DriverNotificationDue -Status $null | Should Be $false
        $manual = [pscustomobject]@{ globalStatus = 'STOPPED'; reason = 'otro'; history = @([pscustomobject]@{ cause = 'manual' }) }
        Test-DriverNotificationDue -Status $manual | Should Be $false
        $ctrlC = [pscustomobject]@{ globalStatus = 'STOPPED'; reason = 'Interrumpido con Ctrl+C'; history = @() }
        Test-DriverNotificationDue -Status $ctrlC | Should Be $false
        $err = [pscustomobject]@{ globalStatus = 'STOPPED'; reason = 'otro'; history = @([pscustomobject]@{ cause = 'error_driver' }) }
        Test-DriverNotificationDue -Status $err | Should Be $true
    }

    It 'Get-DriverNotificationSummary cuenta sesiones con attempt 0 o sin attempt de esta corrida y suma el coste' {
        $history = @(
            [pscustomobject]@{ iter = 1; attempt = 0; telemetry = [pscustomobject]@{ costUsd = 7.0 }; timestamp = '2026-10-26T09:00:00.0000000-04:00' },
            [pscustomobject]@{ iter = 2; attempt = 0; telemetry = [pscustomobject]@{ costUsd = 1.0 }; timestamp = '2026-10-27T10:10:00.0000000-04:00' },
            [pscustomobject]@{ iter = 2; attempt = 1; telemetry = [pscustomobject]@{ costUsd = 0.5 }; timestamp = '2026-10-27T10:20:00.0000000-04:00' },
            [pscustomobject]@{ iter = 3; telemetry = $null; timestamp = '2026-10-27T10:30:00.0000000-04:00' }
        )
        $status = [pscustomobject]@{ startedAt = '2026-10-27T10:00:00.0000000-04:00'; history = $history }
        $now = [datetimeoffset]::Parse('2026-10-27T11:23:30-04:00').LocalDateTime

        $s = Get-DriverNotificationSummary -Status $status -Now $now
        $s.Sessions | Should Be 2
        $s.CostUsd | Should Be 1.5
        $s.Duration.TotalMinutes | Should BeGreaterThan 83
        $s.Duration.TotalMinutes | Should BeLessThan 84

        $s2 = Get-DriverNotificationSummary -Status $status -Now $now -CostMode sum
        $s2.Sessions | Should Be 2
        $s2.CostUsd | Should Be 1.5

        $noCost = [pscustomobject]@{
            startedAt = '2026-10-27T10:00:00.0000000-04:00'
            history   = @([pscustomobject]@{ iter = 1; attempt = 0; telemetry = $null; timestamp = '2026-10-27T10:10:00.0000000-04:00' })
        }
        (Get-DriverNotificationSummary -Status $noCost -Now $now).CostUsd | Should BeNullOrEmpty

        $noStart = [pscustomobject]@{ history = $history }
        $s3 = Get-DriverNotificationSummary -Status $noStart -Now $now
        $s3.Duration | Should BeNullOrEmpty
        $s3.Sessions | Should Be 3
        $s3.CostUsd | Should Be 8.5

        # startedAt como [datetime] Utc (lo que deja ConvertFrom-Json en pwsh 7.6): se pasa a hora local antes de restar.
        $utcStatus = [pscustomobject]@{ startedAt = [datetimeoffset]::Parse('2026-10-27T14:00:00Z').UtcDateTime; history = @() }
        $utcNow = [datetimeoffset]::Parse('2026-10-27T15:23:30Z').LocalDateTime
        $sU = Get-DriverNotificationSummary -Status $utcStatus -Now $utcNow
        $sU.Duration.TotalMinutes | Should BeGreaterThan 83
        $sU.Duration.TotalMinutes | Should BeLessThan 84

        # attempt no numerico: no cuenta como sesion, no lanza y su coste se suma en modo sum.
        $histX = @($history) + [pscustomobject]@{ iter = 4; attempt = 'x'; telemetry = [pscustomobject]@{ costUsd = 2.0 }; timestamp = '2026-10-27T10:40:00.0000000-04:00' }
        $statusX = [pscustomobject]@{ startedAt = '2026-10-27T10:00:00.0000000-04:00'; history = $histX }
        { Get-DriverNotificationSummary -Status $statusX -Now $now } | Should Not Throw
        $sx = Get-DriverNotificationSummary -Status $statusX -Now $now
        $sx.Sessions | Should Be 2
        $sx.CostUsd | Should Be 3.5
    }

    It 'Get-DriverToastLaunch: script constante con ToastText02, AppId de Windows PowerShell y texto por variables de entorno' {
        $a = Get-DriverToastLaunch -Title 'Driver DONE: a' -Body 'uno'
        $l = Get-DriverToastLaunch -Title "Driver FAILED: it's" -Body 'dos'
        $l.Script | Should Be $a.Script
        $l.EncodedCommand | Should Be $a.EncodedCommand
        $l.Script | Should Match 'ToastText02'
        $l.Script | Should Match 'Windows\.UI\.Notifications'
        $l.Script.Contains('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe') | Should Be $true
        $l.Script | Should Match 'DRIVER_TOAST_TITLE_B64'
        $l.Script | Should Match 'DRIVER_TOAST_BODY_B64'
        $l.Script | Should Match 'CreateTextNode'
        $l.Script | Should Not Match 'LoadXml'
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($l.EncodedCommand)) | Should Be $l.Script
        @($l.Environment.Keys).Count | Should Be 2
        (@($l.Environment.Keys) -contains 'DRIVER_TOAST_TITLE_B64') | Should Be $true
        (@($l.Environment.Keys) -contains 'DRIVER_TOAST_BODY_B64') | Should Be $true
        (ConvertFrom-B64Utf8 $l.Environment['DRIVER_TOAST_TITLE_B64']) | Should Be "Driver FAILED: it's"
        (ConvertFrom-B64Utf8 $l.Environment['DRIVER_TOAST_BODY_B64']) | Should Be 'dos'
        $l.Script.Contains('ErrorActionPreference = ''Stop''') | Should Be $true
        $l.Script.Contains('exit 1') | Should Be $true
    }

    Context 'mocks aislados de canal' {
        It 'Send-DriverNotification con -NoToast y sin -NotifyUrl no llama a ningun canal' {
            Mock -ModuleName DriverNotify Invoke-DriverToast { 'ok' }
            Mock -ModuleName DriverNotify Invoke-DriverMsgFallback { 'msg' }
            Mock -ModuleName DriverNotify Invoke-DriverWebhook { 'ok' }
            $r = Send-DriverNotification -Status DONE -Reason 'x' -PlanFile 'p.md' -NoToast
            $r.toast | Should Be 'omitido'
            $r.webhook | Should Be 'omitido'
            $r.webhookHost | Should BeNullOrEmpty
            $r.sentAt | Should Not BeNullOrEmpty
            Assert-MockCalled -ModuleName DriverNotify Invoke-DriverToast -Times 0 -Exactly
            Assert-MockCalled -ModuleName DriverNotify Invoke-DriverMsgFallback -Times 0 -Exactly
            Assert-MockCalled -ModuleName DriverNotify Invoke-DriverWebhook -Times 0 -Exactly
        }
    }

    Context 'mocks aislados de canal' {
        It 'toast fallido cae a msg.exe y los dos fallidos dejan fallo sin lanzar' {
            Mock -ModuleName DriverNotify Invoke-DriverToast { 'ok' }
            Mock -ModuleName DriverNotify Invoke-DriverMsgFallback { 'msg' }
            $r = Send-DriverNotification -Status DONE -PlanFile 'p.md'
            $r.toast | Should Be 'ok'
            Assert-MockCalled -ModuleName DriverNotify Invoke-DriverMsgFallback -Times 0 -Exactly

            Mock -ModuleName DriverNotify Invoke-DriverToast { 'fallo' }
            $r = Send-DriverNotification -Status DONE -PlanFile 'p.md'
            $r.toast | Should Be 'msg'

            Mock -ModuleName DriverNotify Invoke-DriverMsgFallback { 'fallo' }
            { Send-DriverNotification -Status DONE -PlanFile 'p.md' 3>$null | Out-Null } | Should Not Throw
            $r = Send-DriverNotification -Status DONE -PlanFile 'p.md' 3>$null
            $r.toast | Should Be 'fallo'
        }
    }

    It 'webhook contra servidor local: POST con cuerpo UTF-8, Content-Type y cabeceras ntfy' {
        $outFile = Join-Path $TestDrive 'req1.json'
        $cap = Start-WebhookCapture -OutFile $outFile
        try {
            $r = Send-DriverNotification -Status FAILED -Reason 'falló la revisión' -PlanFile 'C:\p\revisión.md' -Sessions 1 -NoToast -NotifyUrl $cap.Url
            (Wait-CaptureFile -Path $outFile) | Should Be $true
            $req = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $req.requestLine.StartsWith('POST /mi-topico-secreto') | Should Be $true
            $req.headers.'content-type' | Should Be 'text/plain; charset=utf-8'
            $req.headers.title | Should Be 'Driver FAILED: revision'
            $req.headers.priority | Should Be 'high'
            $req.headers.tags | Should Be 'x'
            $expected = (Format-DriverNotification -Status FAILED -Reason 'falló la revisión' -PlanFile 'C:\p\revisión.md' -Sessions 1).Body
            (ConvertFrom-B64Utf8 $req.bodyBase64) | Should Be $expected
            $r.webhook | Should Be 'ok'
            $r.webhookHost | Should Be '127.0.0.1'
            $r.toast | Should Be 'omitido'
        }
        finally { Stop-WebhookCapture -Capture $cap }
    }

    It 'webhook que no responde: fallo por timeout, sin excepcion y dentro del plazo' {
        $cap = Start-WebhookCapture -OutFile (Join-Path $TestDrive 'req2.json') -NoResponse
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            { $script:r10 = Send-DriverNotification -Status DONE -NoToast -NotifyUrl $cap.Url -WebhookTimeoutSeconds 2 3>$null } | Should Not Throw
            $sw.Stop()
            $script:r10.webhook | Should Be 'fallo'
            $sw.Elapsed.TotalSeconds | Should BeLessThan 8
        }
        finally { Stop-WebhookCapture -Capture $cap }
    }

    It 'webhook sin servidor o con URL invalida: fallo sin excepcion y sin guardar ni mostrar la URL' {
        # Puerto al azar que no escucha nadie.
        $port = 0
        for ($i = 0; $i -lt 30; $i++) {
            $port = Get-Random -Minimum 20000 -Maximum 30000
            $tc = New-Object System.Net.Sockets.TcpClient
            $connected = $false
            try { $tc.Connect('127.0.0.1', $port); $connected = $true } catch { }
            finally { $tc.Close() }
            if (-not $connected) { break }
        }

        $out = @(Send-DriverNotification -Status DONE -NoToast -NotifyUrl "http://127.0.0.1:$port/mi-topico-secreto" 3>&1)
        $r = $out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $r.webhook | Should Be 'fallo'
        $r.webhookHost | Should Be '127.0.0.1'
        ($r | ConvertTo-Json) | Should Not Match 'mi-topico-secreto'
        $warnings.Count | Should BeGreaterThan 0
        foreach ($w in $warnings) { $w.Message | Should Not Match 'mi-topico-secreto' }

        $out2 = @(Send-DriverNotification -Status DONE -NoToast -NotifyUrl 'no-es-url' 3>&1)
        $r2 = $out2 | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
        $warnings2 = @($out2 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $r2.webhook | Should Be 'fallo'
        $r2.webhookHost | Should BeNullOrEmpty
        ($r2 | ConvertTo-Json) | Should Not Match 'no-es-url'
        $warnings2.Count | Should BeGreaterThan 0
        foreach ($w in $warnings2) { $w.Message | Should Not Match 'no-es-url' }
    }

    Context 'mocks aislados de canal' {
        It 'un fallo inesperado de un canal no escapa de Send-DriverNotification' {
            Mock -ModuleName DriverNotify Invoke-DriverWebhook { throw 'boom' }
            { $script:r12 = Send-DriverNotification -Status DONE -NoToast -NotifyUrl 'http://127.0.0.1:20001/x' 3>$null } | Should Not Throw
            $script:r12.webhook | Should Be 'fallo'

            Mock -ModuleName DriverNotify Invoke-DriverToast { throw 'boom' }
            Mock -ModuleName DriverNotify Invoke-DriverMsgFallback { 'fallo' }
            { $script:r12b = Send-DriverNotification -Status DONE 3>$null } | Should Not Throw
            $script:r12b.toast | Should Be 'fallo'
        }
    }

    It 'Get-DriverToastLaunch: un reason con comillas tipograficas no entra en el script' {
        $payload = 'x' + [char]0x2019 + '; Start-Process calc; ' + [char]0x2018
        $f = Format-DriverNotification -Status FAILED -Reason $payload
        $l = Get-DriverToastLaunch -Title $f.Title -Body $f.Body
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($l.EncodedCommand))
        $l.Script.Contains('Start-Process calc') | Should Be $false
        $l.Script.Contains([string][char]0x2019) | Should Be $false
        $l.Script.Contains([string][char]0x2018) | Should Be $false
        $decoded.Contains('Start-Process calc') | Should Be $false
        $decoded.Contains([string][char]0x2019) | Should Be $false
        $decoded.Contains([string][char]0x2018) | Should Be $false
        $l.Script | Should Be (Get-DriverToastLaunch -Title $f.Title -Body 'otro').Script
        (ConvertFrom-B64Utf8 $l.Environment['DRIVER_TOAST_BODY_B64']).Contains($payload) | Should Be $true
    }

    It 'Get-DriverToastLaunch: cuerpo con <, & y comillas produce XML valido' {
        $body = 'a < b & "c" ''d'' ' + [char]0x2019 + 'e' + [char]0x2019
        $l = Get-DriverToastLaunch -Title 'Driver DONE: x' -Body $body
        $t = ConvertFrom-B64Utf8 $l.Environment['DRIVER_TOAST_TITLE_B64']
        $b = ConvertFrom-B64Utf8 $l.Environment['DRIVER_TOAST_BODY_B64']
        $doc = [xml]'<toast><visual><binding template="ToastText02"><text id="1"/><text id="2"/></binding></visual></toast>'
        $nodes = $doc.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($doc.CreateTextNode($t))
        [void]$nodes.Item(1).AppendChild($doc.CreateTextNode($b))
        { [xml]$doc.OuterXml } | Should Not Throw
        $reloaded = [xml]$doc.OuterXml
        $reloaded.GetElementsByTagName('text').Item(1).InnerText | Should Be $body
    }

    It 'Get-DriverNotificationSummary con -CostMode lastAttempt cuenta solo el ultimo intento de cada sesion' {
        $history = @(
            [pscustomobject]@{ iter = 1; attempt = 0; telemetry = [pscustomobject]@{ costUsd = 1.0 }; timestamp = '2026-10-27T10:10:00.0000000-04:00' },
            [pscustomobject]@{ iter = 1; attempt = 1; telemetry = [pscustomobject]@{ costUsd = 1.4 }; timestamp = '2026-10-27T10:20:00.0000000-04:00' },
            [pscustomobject]@{ iter = 2; attempt = 0; telemetry = [pscustomobject]@{ costUsd = 0.3 }; timestamp = '2026-10-27T10:30:00.0000000-04:00' }
        )
        $status = [pscustomobject]@{ startedAt = '2026-10-27T10:00:00.0000000-04:00'; history = $history }
        $now = [datetimeoffset]::Parse('2026-10-27T11:23:30-04:00').LocalDateTime

        $s = Get-DriverNotificationSummary -Status $status -Now $now -CostMode lastAttempt
        $s.CostUsd | Should Be 1.7
        $s.Sessions | Should Be 2
        (Get-DriverNotificationSummary -Status $status -Now $now -CostMode sum).CostUsd | Should Be 2.7
        (Get-DriverNotificationSummary -Status $status -Now $now).CostUsd | Should Be 2.7
    }

    It '2c: AWAITING avisa con prioridad alta y no cuenta como final' {
        $f = Format-DriverNotification -Status AWAITING -Reason 'Esperando decisión: x' -PlanFile 'p.md'
        $f.Title | Should Be 'Driver AWAITING: p'
        $f.Priority | Should Be 'high'
        $f.Tags | Should Be 'raising_hand'
        Test-DriverNotificationDue -Status ([pscustomobject]@{ globalStatus = 'AWAITING' }) | Should Be $false
    }
}

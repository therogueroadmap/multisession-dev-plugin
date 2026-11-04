$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\SessionStream.psm1') -Force
Import-Module (Join-Path $moduleRoot 'scripts\modules\StatusLine.psm1') -Force
Import-Module (Join-Path $moduleRoot 'scripts\modules\LogReader.psm1') -Force

$fixture = Join-Path $moduleRoot 'tests\fixtures\stream-result-not-last.jsonl'

function New-ResultLine {
    param([string]$Text)
    return ([ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $Text } | ConvertTo-Json -Compress)
}

Describe 'Read-SessionStream' {
    It 'encuentra el result aunque no sea la ultima linea y extrae la telemetria' {
        $s = Read-SessionStream -Path $fixture
        $s.HasResult | Should Be $true
        $s.ResultText | Should Be "Resumen.`nPLAN_STATUS: CONTINUE"
        $s.Telemetry.costUsd | Should Be 0.0587216
        $s.Telemetry.durationMs | Should Be 8296
        $s.Telemetry.numTurns | Should Be 3
        $s.Telemetry.inputTokens | Should Be 20
        $s.Telemetry.outputTokens | Should Be 562
        $s.Telemetry.cacheReadTokens | Should Be 59096
        $s.Telemetry.cacheCreationTokens | Should Be 24991
        $s.Telemetry.subagentsKilled | Should Be 3
        $s.Telemetry.subagentsFailed | Should Be 1
        $s.Telemetry.isError | Should Be $false
        $s.Telemetry.terminalReason | Should Be 'completed'
    }

    It 'el texto del asistente toma solo el hilo principal y solo bloques text' {
        $s = Read-SessionStream -Path $fixture
        $s.AssistantText | Should Be "Nivel 1 cerrado.`nResumen.`nPLAN_STATUS: CONTINUE"
        $s.AssistantText | Should Not Match 'subagente'
    }

    It 'con dos eventos result gana el ultimo' {
        $p = Join-Path $TestDrive 'two-results.jsonl'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @((New-ResultLine 'PLAN_STATUS: CONTINUE'), (New-ResultLine 'PLAN_STATUS: COMPLETE'))
        (Read-SessionStream -Path $p).ResultText | Should Be 'PLAN_STATUS: COMPLETE'
    }

    It 'varios result por sesion (re-entradas tras subagentes en background): suma los campos por tramo y toma del ultimo los acumulados' {
        # Stream real de la corrida de humo del 2026-10-07: 4 eventos result de la
        # misma sesion. total_cost_usd y subagent_stats vienen acumulados (iguales
        # en los 4); duration_ms, num_turns y usage son del tramo.
        $s = Read-SessionStream -Path (Join-Path $moduleRoot 'tests\fixtures\stream-multi-result.jsonl')
        $s.ResultText | Should Match 'PLAN_STATUS: CONTINUE$'
        $s.Telemetry.costUsd | Should Be 0.2970736400000001
        $s.Telemetry.durationMs | Should Be 39281
        $s.Telemetry.numTurns | Should Be 14
        $s.Telemetry.inputTokens | Should Be 26
        $s.Telemetry.outputTokens | Should Be 5825
        $s.Telemetry.cacheReadTokens | Should Be 617624
        $s.Telemetry.cacheCreationTokens | Should Be 57522
        $s.Telemetry.subagentsKilled | Should Be 0
        $s.Telemetry.subagentsFailed | Should Be 0
        $s.Telemetry.isError | Should Be $false
        $s.Telemetry.terminalReason | Should Be 'completed'
    }

    It 'varios result: isError es verdadero si algun tramo fallo' {
        $p = Join-Path $TestDrive 'multi-error.jsonl'
        $bad = [ordered]@{ type = 'result'; subtype = 'error_during_execution'; is_error = $true; result = ''; duration_ms = 5; num_turns = 1 } | ConvertTo-Json -Compress
        $ok = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = 'PLAN_STATUS: CONTINUE'; duration_ms = 7; num_turns = 2 } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $p -Encoding utf8 -Value @($bad, $ok)
        $s = Read-SessionStream -Path $p
        $s.Telemetry.isError | Should Be $true
        $s.Telemetry.durationMs | Should Be 12
        $s.Telemetry.numTurns | Should Be 3
        $s.Telemetry.inputTokens | Should BeNullOrEmpty
    }

    It 'sin result (sesion truncada): HasResult falso, Telemetry nula y texto del asistente' {
        $p = Join-Path $TestDrive 'no-result.jsonl'
        Get-Content -LiteralPath $fixture | Select-Object -First 5 | Set-Content -LiteralPath $p -Encoding utf8
        $s = Read-SessionStream -Path $p
        $s.HasResult | Should Be $false
        $s.ResultText | Should BeNullOrEmpty
        $s.Telemetry | Should BeNullOrEmpty
        $s.AssistantText | Should Match 'PLAN_STATUS: CONTINUE'
    }

    It 'ignora una ultima linea cortada sin lanzar' {
        $p = Join-Path $TestDrive 'cut.jsonl'
        $lines = @(Get-Content -LiteralPath $fixture) + '{"type":"assistant","message":{"content":[{"type":"te'
        Set-Content -LiteralPath $p -Encoding utf8 -Value $lines
        $s = Read-SessionStream -Path $p
        $s.HasResult | Should Be $true
        $s.ResultText | Should Match 'PLAN_STATUS: CONTINUE'
    }

    It 'archivo inexistente o vacio: objeto vacio sin lanzar' {
        $missing = Read-SessionStream -Path (Join-Path $TestDrive 'nope.jsonl')
        $missing.HasResult | Should Be $false
        $missing.AssistantText | Should Be ''
        $missing.Telemetry | Should BeNullOrEmpty
        $empty = Join-Path $TestDrive 'empty.jsonl'
        Set-Content -LiteralPath $empty -Value '' -Encoding utf8
        (Read-SessionStream -Path $empty).HasResult | Should Be $false
    }

    It 'result con is_error y campos ausentes: isError verdadero y ausentes en null' {
        $p = Join-Path $TestDrive 'error.jsonl'
        Set-Content -LiteralPath $p -Encoding utf8 -Value '{"type":"result","subtype":"error_during_execution","is_error":true}'
        $s = Read-SessionStream -Path $p
        $s.HasResult | Should Be $true
        $s.ResultText | Should BeNullOrEmpty
        $s.Telemetry.isError | Should Be $true
        $s.Telemetry.costUsd | Should BeNullOrEmpty
        $s.Telemetry.inputTokens | Should BeNullOrEmpty
        $s.Telemetry.subagentsKilled | Should BeNullOrEmpty
    }

    It 'archivo abierto para escritura por otro handle (FileShare.ReadWrite): no lanza y devuelve eventos' {
        $p = Join-Path $TestDrive 'locked.jsonl'
        Copy-Item -LiteralPath $fixture -Destination $p
        $writer = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $s = Read-SessionStream -Path $p
            $s.HasResult | Should Be $true
            $s.ResultText | Should Be "Resumen.`nPLAN_STATUS: CONTINUE"
        }
        finally {
            $writer.Dispose()
        }
    }

    It 'ruta de directorio: objeto vacio sin lanzar' {
        $dir = Join-Path $TestDrive 'carpeta'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $s = Read-SessionStream -Path $dir
        $s.HasResult | Should Be $false
        $s.AssistantText | Should Be ''
        $s.Telemetry | Should BeNullOrEmpty
    }

    It 'Ola 1b-driver: expone Subtype y ApiErrorStatus del ultimo result' {
        $p = Join-Path $TestDrive 'subtype-last.jsonl'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @(
            '{"type":"result","subtype":"success","is_error":false,"result":"a"}',
            '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529,"result":"API Error: 529 Overloaded"}'
        )
        $s = Read-SessionStream -Path $p
        $s.Subtype | Should Be 'error_during_execution'
        $s.ApiErrorStatus | Should Be 529

        $m = Read-SessionStream -Path (Join-Path $moduleRoot 'tests\fixtures\stream-multi-result.jsonl')
        $m.Subtype | Should Be 'success'
        $m.ApiErrorStatus | Should BeNullOrEmpty
    }

    It 'Ola 1b-driver: Subtype y ApiErrorStatus nulos sin result, con campos ausentes o con valor no numerico' {
        $p1 = Join-Path $TestDrive 'sub-no-result.jsonl'
        Set-Content -LiteralPath $p1 -Encoding utf8 -Value '{"type":"assistant","message":{"content":[{"type":"text","text":"hola"}]}}'
        $s1 = Read-SessionStream -Path $p1
        $s1.HasResult | Should Be $false
        $s1.Telemetry | Should BeNullOrEmpty
        $s1.Subtype | Should BeNullOrEmpty
        $s1.ApiErrorStatus | Should BeNullOrEmpty

        $p2 = Join-Path $TestDrive 'sub-absent.jsonl'
        Set-Content -LiteralPath $p2 -Encoding utf8 -Value '{"type":"result","is_error":false,"result":"x"}'
        $s2 = Read-SessionStream -Path $p2
        $s2.HasResult | Should Be $true
        $s2.Telemetry | Should Not BeNullOrEmpty
        $s2.Subtype | Should BeNullOrEmpty
        $s2.ApiErrorStatus | Should BeNullOrEmpty

        $p3 = Join-Path $TestDrive 'sub-abc.jsonl'
        Set-Content -LiteralPath $p3 -Encoding utf8 -Value '{"type":"result","subtype":"error","is_error":true,"api_error_status":"abc","result":"x"}'
        $s3 = Read-SessionStream -Path $p3
        $s3.HasResult | Should Be $true
        $s3.Telemetry | Should Not BeNullOrEmpty
        $s3.ApiErrorStatus | Should BeNullOrEmpty

        $p4 = Join-Path $TestDrive 'sub-429.jsonl'
        Set-Content -LiteralPath $p4 -Encoding utf8 -Value '{"type":"result","subtype":"error","is_error":true,"api_error_status":"429","result":"x"}'
        $s4 = Read-SessionStream -Path $p4
        $s4.HasResult | Should Be $true
        $s4.Telemetry | Should Not BeNullOrEmpty
        $s4.ApiErrorStatus | Should Be 429
    }
}

Describe 'Get-SessionLogText' {
    It 'usa ResultText cuando hay result con texto' {
        Get-SessionLogText -Stream (Read-SessionStream -Path $fixture) | Should Be "Resumen.`nPLAN_STATUS: CONTINUE"
    }
    It 'cae al texto del asistente cuando no hay result' {
        $stream = [pscustomobject]@{ HasResult = $false; ResultText = $null; AssistantText = "a`nPLAN_STATUS: BLOCKED: x"; Telemetry = $null }
        Get-SessionLogText -Stream $stream | Should Be "a`nPLAN_STATUS: BLOCKED: x"
    }
    It 'cae al texto del asistente cuando el result no trae texto' {
        $stream = [pscustomobject]@{ HasResult = $true; ResultText = $null; AssistantText = 'b'; Telemetry = $null }
        Get-SessionLogText -Stream $stream | Should Be 'b'
    }
    It 'cae al texto del asistente cuando el result trae cadena vacia' {
        $stream = [pscustomobject]@{ HasResult = $true; ResultText = ''; AssistantText = "c`nPLAN_STATUS: CONTINUE"; Telemetry = $null }
        Get-SessionLogText -Stream $stream | Should Be "c`nPLAN_STATUS: CONTINUE"
    }
}

Describe 'New-SessionTelemetry' {
    It 'con telemetria del stream copia los campos y agrega modelo y effort' {
        $t = New-SessionTelemetry -Model 'claude-opus-5-5' -Effort 'medium' -StreamTelemetry (Read-SessionStream -Path $fixture).Telemetry
        $t.model | Should Be 'claude-opus-5-5'
        $t.effort | Should Be 'medium'
        $t.costUsd | Should Be 0.0587216
        $t.subagentsKilled | Should Be 3
    }
    It 'sin telemetria del stream deja solo modelo y effort' {
        $t = New-SessionTelemetry -Model 'claude-opus-5-5' -Effort 'high' -StreamTelemetry $null
        $t.model | Should Be 'claude-opus-5-5'
        $t.effort | Should Be 'high'
        $t.costUsd | Should BeNullOrEmpty
        $t.terminalReason | Should BeNullOrEmpty
        @($t.PSObject.Properties.Name).Count | Should Be 13
    }
}

Describe 'Compatibilidad 2 (regla 4): la marca se decide igual con .log de modo texto y .log derivado' {
    $cases = @(
        "Listo.`nPLAN_STATUS: CONTINUE",
        "Plan cerrado.`nPLAN_STATUS: COMPLETE",
        "Falta decidir.`nPLAN_STATUS: BLOCKED: elegir esquema",
        "PLAN_STATUS: CONTINUE`n**Ciclo de review/fix:** texto colgante"
    )
    $i = 0
    foreach ($text in $cases) {
        $i++
        It "caso $i decide lo mismo" {
            $textLog = Join-Path $TestDrive "texto-$i.log"
            Set-Content -LiteralPath $textLog -Value $text -Encoding utf8

            $streamPath = Join-Path $TestDrive "stream-$i.jsonl"
            Set-Content -LiteralPath $streamPath -Encoding utf8 -Value @('{"type":"system","subtype":"init"}', (New-ResultLine $text), '{"type":"system","subtype":"ui_status"}')
            $derivedLog = Join-Path $TestDrive "derivado-$i.log"
            Set-Content -LiteralPath $derivedLog -Value (Get-SessionLogText -Stream (Read-SessionStream -Path $streamPath)) -Encoding utf8

            $a = Resolve-SessionOutcome -ExitCode 0 -TailLines @(Get-LogTail -Path $textLog -MaxLines 50) -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
            $b = Resolve-SessionOutcome -ExitCode 0 -TailLines @(Get-LogTail -Path $derivedLog -MaxLines 50) -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
            $b.PlanStatusForEvent | Should Be $a.PlanStatusForEvent
            $b.PlanStatusReasonForEvent | Should Be $a.PlanStatusReasonForEvent
            $b.Cause | Should Be $a.Cause
            $b.Decision.GlobalStatus | Should Be $a.Decision.GlobalStatus
            $b.Decision.ShouldContinue | Should Be $a.Decision.ShouldContinue
        }
    }
}

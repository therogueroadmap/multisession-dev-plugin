$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\SessionRetry.psm1') -Force

function New-Summary([string]$Text, $IsError = $true, $Api = $null, $Subtype = $null) {
    return [pscustomobject]@{
        ResultText     = $Text
        Subtype        = $Subtype
        ApiErrorStatus = $Api
        Telemetry      = [pscustomobject]@{ isError = $IsError }
    }
}

$exit = [pscustomobject]@{ Cause = 'exit_no_cero' }
$hung = [pscustomobject]@{ Cause = 'colgada' }

Describe 'Get-SessionFailureKind' {
    It 'permanente por apiErrorStatus 401 y 403' {
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -Api 401)
        $r.Kind | Should Be 'permanent'
        $r.Match | Should Be 'http_401'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -Api 403)
        $r.Kind | Should Be 'permanent'
        $r.Match | Should Be 'http_403'
    }

    It 'permanente por cada patron de texto en el result con error' {
        $cases = @(
            @('Invalid API key · Please run /login', 'invalid_api_key'),
            @('Authentication failed', 'authentication'),
            @('Please run /login', 'login'),
            @('Not logged in', 'not_logged_in'),
            @('Your credit balance is too low', 'credit_balance'),
            @('model claude-x not found', 'model_unavailable'),
            @('Invalid model name', 'model_unavailable'),
            @('The model is not available', 'model_unavailable')
        )
        foreach ($c in $cases) {
            $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary $c[0])
            if ($r.Kind -ne 'permanent' -or $r.Match -ne $c[1]) {
                throw ("'{0}': esperado permanent/{1}, obtenido {2}/{3}" -f $c[0], $c[1], $r.Kind, $r.Match)
            }
        }
    }

    It 'permanente por patron en la cola de err.log, sin distinguir mayusculas' {
        $r = Get-SessionFailureKind -Outcome $exit -ErrLogTail @('linea', 'ERROR: INVALID API KEY')
        $r.Kind | Should Be 'permanent'
        $r.Match | Should Be 'invalid_api_key'
        $r = Get-SessionFailureKind -Outcome $hung -ErrLogTail @('NOT LOGGED IN')
        $r.Kind | Should Be 'permanent'
        $r.Match | Should Be 'not_logged_in'
    }

    It 'transitorio con 429, 500, 529 y overloaded, con la senal en Match' {
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -Api 429)
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'http_429'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -Api 500)
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'http_5xx'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -Api 529)
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'http_5xx'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'API Error: Overloaded')
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'overloaded'
        $r = Get-SessionFailureKind -Outcome $exit -ErrLogTail @('read ECONNRESET')
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'econnreset'
        $r = Get-SessionFailureKind -Outcome $exit -ErrLogTail @('stream idle timeout')
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'stream_idle'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'rate limited (429)')
        $r.Kind | Should Be 'transient'
        $r.Match | Should Be 'http_429'
    }

    It 'colgada o exit no cero sin senales es transitorio con Match nulo' {
        $r = Get-SessionFailureKind -Outcome $hung
        $r.Kind | Should Be 'transient'
        $r.Match | Should BeNullOrEmpty
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary '')
        $r.Kind | Should Be 'transient'
        $r.Match | Should BeNullOrEmpty
    }

    It 'causas no elegibles devuelven none' {
        $causes = @('continue_sin_avance', 'pregunta_sin_marca', 'truncada_background', 'indeterminado', 'sin_marca_con_avance', $null)
        foreach ($c in $causes) {
            $o = [pscustomobject]@{ Cause = $c }
            $r = Get-SessionFailureKind -Outcome $o -StreamSummary (New-Summary 'x' -Api 401) -ErrLogTail @('invalid api key')
            if ($r.Kind -ne 'none' -or $null -ne $r.Match) {
                throw ("causa '{0}': esperado none/nulo, obtenido {1}/{2}" -f $c, $r.Kind, $r.Match)
            }
        }
    }

    It 'el texto del result solo cuenta para permanente si la sesion termino con error' {
        $text = 'Implementé el módulo de authentication'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary $text -IsError $false)
        $r.Kind | Should Be 'transient'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary $text -IsError $true)
        $r.Kind | Should Be 'permanent'
        $r.Match | Should Be 'authentication'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'x' -IsError $false -Subtype 'authentication_error')
        $r.Kind | Should Be 'permanent'
        $r = Get-SessionFailureKind -Outcome $exit -StreamSummary (New-Summary 'Implementé el módulo de authentication' -IsError $true -Subtype 'success')
        $r.Kind | Should Be 'transient'
    }
}

Describe 'Get-RetryDelaySeconds' {
    It 'Get-RetryDelaySeconds usa el ultimo valor con mas intentos que valores' {
        Get-RetryDelaySeconds -Attempt 1 -Schedule 60, 300 | Should Be 60
        Get-RetryDelaySeconds -Attempt 2 -Schedule 60, 300 | Should Be 300
        Get-RetryDelaySeconds -Attempt 3 -Schedule 60, 300 | Should Be 300
        Get-RetryDelaySeconds -Attempt 2 -Schedule @(0) | Should Be 0
        Get-RetryDelaySeconds -Attempt 1 -Schedule @() | Should Be 0
    }
}

Describe 'Test-ResumeSessionMissing' {
    It 'Test-ResumeSessionMissing detecta no conversation found y session not found solo con exit no cero en menos de 60 s' {
        Test-ResumeSessionMissing -ExitCode 1 -DurationSeconds 3 -ErrLogTail @('No conversation found with session ID: abc') | Should Be $true
        Test-ResumeSessionMissing -ExitCode 1 -DurationSeconds 3 -StreamSummary (New-Summary 'Error: Session not found') | Should Be $true
        Test-ResumeSessionMissing -ExitCode 1 -DurationSeconds 61 -ErrLogTail @('No conversation found with session ID: abc') | Should Be $false
        Test-ResumeSessionMissing -ExitCode 1 -DurationSeconds 61 -StreamSummary (New-Summary 'Error: Session not found') | Should Be $false
        Test-ResumeSessionMissing -ExitCode 0 -DurationSeconds 3 -ErrLogTail @('No conversation found with session ID: abc') | Should Be $false
        Test-ResumeSessionMissing -ExitCode 0 -DurationSeconds 3 -StreamSummary (New-Summary 'Error: Session not found') | Should Be $false
        Test-ResumeSessionMissing -ExitCode 1 -DurationSeconds 3 | Should Be $false
    }
}

Describe 'Get-ResumePrompt' {
    It 'Get-ResumePrompt lleva la linea de caveman y el texto exacto de RESUME_PROMPT' {
        $p = Get-ResumePrompt
        $resume = 'La sesión anterior se interrumpió por un error transitorio. Continúa exactamente donde quedaste y termina con la línea PLAN_STATUS como siempre.'
        $p.Contains('No actives el skill caveman') | Should Be $true
        $p.Contains($resume) | Should Be $true
        $p.IndexOf('No actives el skill caveman') | Should BeLessThan $p.IndexOf($resume)
    }
}

Describe 'ConvertTo-RetryClaudeArgs' {
    It 'ConvertTo-RetryClaudeArgs cambia el prompt y la bandera de sesion sin tocar el resto' {
        $a = @('-p', 'original', '--dangerously-skip-permissions', '--model', 'm', '--effort', 'high', '--output-format', 'stream-json', '--verbose', '--session-id', 'id-1')
        $r = ConvertTo-RetryClaudeArgs -Arguments $a -Prompt 'R' -SessionFlag '--resume' -SessionValue 'id-1'
        $expected = @('-p', 'R', '--dangerously-skip-permissions', '--model', 'm', '--effort', 'high', '--output-format', 'stream-json', '--verbose', '--resume', 'id-1')
        ($r -join '|') | Should Be ($expected -join '|')
        $r.Count | Should Be 12
        ($a -join '|') | Should Be '-p|original|--dangerously-skip-permissions|--model|m|--effort|high|--output-format|stream-json|--verbose|--session-id|id-1'

        $r2 = ConvertTo-RetryClaudeArgs -Arguments $r -Prompt 'original' -SessionFlag '--session-id' -SessionValue 'id-2'
        $r2[10] | Should Be '--session-id'
        $r2[11] | Should Be 'id-2'
        $r2[1] | Should Be 'original'

        { ConvertTo-RetryClaudeArgs -Arguments @('--model', 'm', '--session-id', 'x') -Prompt 'R' -SessionFlag '--resume' -SessionValue 'x' } | Should Throw 'falta'
    }
}

Describe 'Wait-RetryBackoff' {
    It 'Wait-RetryBackoff llama a OnTick en cada vuelta, espera lo pedido y tolera fallos de OnTick' {
        $ticks = New-Object System.Collections.Generic.List[int]
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Wait-RetryBackoff -Seconds 2 -PollSeconds 1 -OnTick { $ticks.Add(1) }
        $sw.Stop()
        $ticks.Count | Should BeGreaterThan 1
        $sw.Elapsed.TotalSeconds | Should BeGreaterThan 1.9
        $sw.Elapsed.TotalSeconds | Should BeLessThan 5

        $ticks0 = New-Object System.Collections.Generic.List[int]
        $sw0 = [Diagnostics.Stopwatch]::StartNew()
        Wait-RetryBackoff -Seconds 0 -PollSeconds 1 -OnTick { $ticks0.Add(1) }
        $sw0.Stop()
        $ticks0.Count | Should Be 1
        $sw0.Elapsed.TotalSeconds | Should BeLessThan 0.5

        { Wait-RetryBackoff -Seconds 0 -PollSeconds 1 -OnTick { throw 'fallo de prueba' } 3>$null } | Should Not Throw

        $x = Wait-RetryBackoff -Seconds 0 -PollSeconds 1 -OnTick { 'fuga' }
        $x | Should BeNullOrEmpty
    }

    It 'Wait-RetryBackoff corta con stop o pause y devuelve la senal' {
        foreach ($signal in 'pause', 'stop') {
            $calls = @{ N = 0 }
            $tick = { $calls.N++; if ($calls.N -ge 2) { $signal } }.GetNewClosure()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Wait-RetryBackoff -Seconds 10 -PollSeconds 1 -OnTick $tick
            $sw.Stop()
            $r | Should Be $signal
            $sw.Elapsed.TotalSeconds | Should BeLessThan 3
        }

        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $none = Wait-RetryBackoff -Seconds 1 -PollSeconds 1 -OnTick { 'set-params' }
        $sw2.Stop()
        $none | Should BeNullOrEmpty
        $sw2.Elapsed.TotalSeconds | Should BeGreaterThan 0.9
    }
}

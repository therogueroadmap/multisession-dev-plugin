$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\ProcessLauncher.psm1') -Force

Describe 'Start-HeadlessProcess' {
    # Regresion de la brecha 7bbd6a2: "Start-Process -ArgumentList" partia el
    # prompt multipalabra y la sesion headless recibia solo "-p Ejecuta". El
    # launcher debe entregar cada argumento verbatim, aun con espacios, saltos de
    # linea y comillas embebidas.

    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = (Get-Command powershell).Source }

    It 'entrega un argumento multipalabra/multilinea como UN solo argumento' {
        $child = Join-Path $TestDrive 'child-args.ps1'
        # Imprime cada arg con delimitadores para poder reconstruirlo exacto.
        Set-Content -LiteralPath $child -Encoding utf8 -Value @'
for ($i = 0; $i -lt $args.Count; $i++) {
    Write-Output ("<<ARG $i>>")
    Write-Output $args[$i]
    Write-Output ("<<END $i>>")
}
'@
        $out = Join-Path $TestDrive 'out.txt'
        $err = Join-Path $TestDrive 'err.txt'
        $prompt = "Ejecuta el plan docs\plan.md con la skill" + [Environment]::NewLine + 'my-subagent-driven-development y autoriza "git commit".'

        # pwsh consume -NoProfile/-File/<script>; el hijo recibe solo los 4 args
        # restantes: -p, <prompt>, --model, claude-opus-5-5.
        $argv = @('-NoProfile', '-File', $child, '-p', $prompt, '--model', 'claude-opus-5-5')
        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList $argv -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        $exit = $launch.Process.ExitCode
        & $launch.Cleanup

        $exit | Should Be 0

        $lines = Get-Content -LiteralPath $out
        $raw = Get-Content -LiteralPath $out -Raw

        # Exactamente 4 argumentos: si el prompt se hubiera partido, habria mas.
        ($lines | Where-Object { $_ -like '<<ARG *' }).Count | Should Be 4
        # -p es el primer arg y el modelo sigue siendo su propio arg (indice 3).
        ($raw -match '<<ARG 0>>\r?\n-p\r?\n<<END 0>>') | Should Be $true
        ($raw -match '<<ARG 3>>\r?\nclaude-opus-5-5\r?\n<<END 3>>') | Should Be $true
        # El prompt completo (con espacios, salto de linea y comillas embebidas)
        # llega verbatim como UN solo argumento.
        $raw.Contains($prompt) | Should Be $true
    }

    It 'redirige stdout completo a archivo sin bloquearse con salida voluminosa' {
        $child = Join-Path $TestDrive 'child-bulk.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value '1..3000 | ForEach-Object { Write-Output ("bulk-$_") }'
        $out = Join-Path $TestDrive 'bulk-out.txt'
        $err = Join-Path $TestDrive 'bulk-err.txt'

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        $lines = Get-Content -LiteralPath $out
        ($lines | Where-Object { $_ -eq 'bulk-1' }).Count | Should Be 1
        ($lines | Where-Object { $_ -eq 'bulk-3000' }).Count | Should Be 1
    }

    It 'redirige stderr a su propio archivo' {
        $child = Join-Path $TestDrive 'child-err.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value '[Console]::Error.WriteLine("ERROR-CANARY"); Write-Output "salida-normal"'
        $out = Join-Path $TestDrive 'sep-out.txt'
        $err = Join-Path $TestDrive 'sep-err.txt'

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        (Get-Content -LiteralPath $err -Raw) | Should Match 'ERROR-CANARY'
        (Get-Content -LiteralPath $out -Raw) | Should Match 'salida-normal'
        (Get-Content -LiteralPath $out -Raw) | Should Not Match 'ERROR-CANARY'
    }

    It 'el cleanup no deja suscripciones de evento residuales' {
        $child = Join-Path $TestDrive 'child-noop.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value 'Write-Output "ok"'
        $out = Join-Path $TestDrive 'noop-out.txt'
        $err = Join-Path $TestDrive 'noop-err.txt'

        $before = (Get-EventSubscriber -ErrorAction SilentlyContinue | Measure-Object).Count
        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        & $launch.Cleanup
        $after = (Get-EventSubscriber -ErrorAction SilentlyContinue | Measure-Object).Count

        $after | Should Be $before
    }

    It 'M19: el archivo de stdout queda completo y termina en la marca al volver de Cleanup (30 lanzamientos)' {
        $child = Join-Path $TestDrive 'child-tail.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value '1..200 | ForEach-Object { "line-$_" }; "PLAN_STATUS: CONTINUE"'
        $completos = 0
        for ($i = 0; $i -lt 30; $i++) {
            $out = Join-Path $TestDrive "tail-out-$i.txt"
            $err = Join-Path $TestDrive "tail-err-$i.txt"
            $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
            $launch.Process.WaitForExit()
            & $launch.Cleanup
            $lines = @(Get-Content -LiteralPath $out)
            if ($lines.Count -eq 201 -and $lines[-1] -eq 'PLAN_STATUS: CONTINUE') { $completos++ }
        }
        $completos | Should Be 30
    }

    It 'M19: el log crece en disco mientras el hijo sigue vivo (senal del watchdog)' {
        $child = Join-Path $TestDrive 'child-live.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value 'Write-Output "primera"; Start-Sleep -Seconds 4; Write-Output "segunda"'
        $out = Join-Path $TestDrive 'live-out.txt'
        $err = Join-Path $TestDrive 'live-err.txt'

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $vistoEnVivo = $false
        while (-not $launch.Process.HasExited) {
            $fs = [System.IO.File]::Open($out, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object System.IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
            $reader.Dispose()
            if ($text -match 'primera') { $vistoEnVivo = $true; break }
            Start-Sleep -Milliseconds 200
        }
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        $vistoEnVivo | Should Be $true
        (Get-Content -LiteralPath $out -Raw) | Should Match 'segunda'
    }

    It 'M2: -Environment entrega las variables al hijo' {
        $child = Join-Path $TestDrive 'child-env.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value 'Write-Output ("FOO=" + $env:FOO_TEST)'
        $out = Join-Path $TestDrive 'env-out.txt'
        $err = Join-Path $TestDrive 'env-err.txt'

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive -Environment @{ FOO_TEST = 'bar' }
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        (Get-Content -LiteralPath $out -Raw) | Should Match 'FOO=bar'
    }

    It 'M2: sin -Environment el hijo hereda el entorno del proceso padre' {
        $child = Join-Path $TestDrive 'child-inherit.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value 'Write-Output ("HER=" + $env:HEREDADA_TEST)'
        $out = Join-Path $TestDrive 'inherit-out.txt'
        $err = Join-Path $TestDrive 'inherit-err.txt'

        $env:HEREDADA_TEST = 'si'
        try {
            $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
            $launch.Process.WaitForExit()
            & $launch.Cleanup
        }
        finally {
            Remove-Item Env:\HEREDADA_TEST -ErrorAction SilentlyContinue
        }

        (Get-Content -LiteralPath $out -Raw) | Should Match 'HER=si'
    }

    # B-3: los U+FFFD vistos en los .stream.jsonl no los produce la copia. Estos
    # tests de caracterizacion fijan que stdout/stderr llegan byte a byte.
    # El texto se arma con [char] para no depender de la codificacion de este archivo.
    $b3TextExpr = "'invitaci' + [char]0x00F3 + 'n ' + [char]0x00F1 + 'and' + [char]0x00FA + ' ' + [char]0x00DC + ' ' + [char]0x2014 + ' PLAN_STATUS: CONTINUE'"

    It 'B-3: stdout UTF-8 con acentos llega byte a byte, sin U+FFFD' {
        $child = Join-Path $TestDrive 'child-utf8-out.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value @"
`$t = $b3TextExpr
`$bytes = [Text.Encoding]::UTF8.GetBytes(`$t)
`$s = [Console]::OpenStandardOutput()
`$s.Write(`$bytes, 0, `$bytes.Length)
`$s.Flush()
"@
        $out = Join-Path $TestDrive 'utf8-out.txt'
        $err = Join-Path $TestDrive 'utf8-out-err.txt'
        $expectedText = 'invitaci' + [char]0x00F3 + 'n ' + [char]0x00F1 + 'and' + [char]0x00FA + ' ' + [char]0x00DC + ' ' + [char]0x2014 + ' PLAN_STATUS: CONTINUE'
        $expected = [Text.Encoding]::UTF8.GetBytes($expectedText)

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        $actual = [IO.File]::ReadAllBytes($out)
        [Convert]::ToBase64String($actual) | Should Be ([Convert]::ToBase64String($expected))
        $text = [Text.Encoding]::UTF8.GetString($actual)
        $text.Contains([string][char]0xFFFD) | Should Be $false
        $text | Should Be $expectedText
    }

    It 'B-3: stderr UTF-8 con acentos llega byte a byte, sin U+FFFD' {
        $child = Join-Path $TestDrive 'child-utf8-err.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value @"
`$t = $b3TextExpr
`$bytes = [Text.Encoding]::UTF8.GetBytes(`$t)
`$s = [Console]::OpenStandardError()
`$s.Write(`$bytes, 0, `$bytes.Length)
`$s.Flush()
"@
        $out = Join-Path $TestDrive 'utf8-err-out.txt'
        $err = Join-Path $TestDrive 'utf8-err.txt'
        $expectedText = 'invitaci' + [char]0x00F3 + 'n ' + [char]0x00F1 + 'and' + [char]0x00FA + ' ' + [char]0x00DC + ' ' + [char]0x2014 + ' PLAN_STATUS: CONTINUE'
        $expected = [Text.Encoding]::UTF8.GetBytes($expectedText)

        $launch = Start-HeadlessProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $child) -StdoutPath $out -StderrPath $err -WorkingDirectory $TestDrive
        $launch.Process.WaitForExit()
        & $launch.Cleanup

        $actual = [IO.File]::ReadAllBytes($err)
        [Convert]::ToBase64String($actual) | Should Be ([Convert]::ToBase64String($expected))
        $text = [Text.Encoding]::UTF8.GetString($actual)
        $text.Contains([string][char]0xFFFD) | Should Be $false
        $text | Should Be $expectedText
    }
}

Describe 'Resolve-BackgroundCeilingEnv' {
    It 'parametro explicito: exporta ese valor' {
        $r = Resolve-BackgroundCeilingEnv -BoundValue 1200000 -HasBound $true -InheritedValue '0'
        $r.Source | Should Be 'parametro'
        $r.Value | Should Be '1200000'
        $r.Env['CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'] | Should Be '1200000'
    }

    It 'sin parametro y con variable en el entorno: la hereda (Env vacio)' {
        $r = Resolve-BackgroundCeilingEnv -BoundValue 0 -HasBound $false -InheritedValue '900000'
        $r.Source | Should Be 'entorno'
        $r.Value | Should Be '900000'
        $r.Env.Count | Should Be 0
    }

    It 'sin parametro ni variable: exporta 0 por defecto' {
        $r = Resolve-BackgroundCeilingEnv -BoundValue 0 -HasBound $false -InheritedValue $null
        $r.Source | Should Be 'default'
        $r.Value | Should Be '0'
        $r.Env['CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'] | Should Be '0'
    }
}

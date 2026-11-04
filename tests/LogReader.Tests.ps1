$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\LogReader.psm1') -Force

Describe 'Get-LastNonEmptyLine' {
    It 'devuelve la ultima linea no vacia de un archivo' {
        $path = Join-Path $TestDrive 'session.log'
        Set-Content -LiteralPath $path -Value @('primera linea', 'PLAN_STATUS: CONTINUE', '', '   ')
        Get-LastNonEmptyLine -Path $path | Should Be 'PLAN_STATUS: CONTINUE'
    }

    It 'devuelve $null si el archivo no existe' {
        $path = Join-Path $TestDrive 'no-existe.log'
        Get-LastNonEmptyLine -Path $path | Should Be $null
    }

    It 'devuelve $null si el archivo esta vacio o solo tiene lineas en blanco' {
        $path = Join-Path $TestDrive 'vacio.log'
        Set-Content -LiteralPath $path -Value @('', '   ', '')
        Get-LastNonEmptyLine -Path $path | Should Be $null
    }

    It 'devuelve la linea si el archivo tiene una sola linea no vacia' {
        $path = Join-Path $TestDrive 'una-linea.log'
        Set-Content -LiteralPath $path -Value 'PLAN_STATUS: COMPLETE'
        Get-LastNonEmptyLine -Path $path | Should Be 'PLAN_STATUS: COMPLETE'
    }
}

Describe 'Get-LogTail' {
    It 'devuelve las ultimas N lineas no vacias, recortadas y en orden de archivo' {
        $path = Join-Path $TestDrive 'tail.log'
        Set-Content -LiteralPath $path -Value @('uno', '', '  dos  ', 'tres', '   ', 'cuatro', '')
        $tail = Get-LogTail -Path $path -MaxLines 3
        $tail.Count | Should Be 3
        $tail[0] | Should Be 'dos'
        $tail[1] | Should Be 'tres'
        $tail[2] | Should Be 'cuatro'
    }

    It 'devuelve un array vacio si el archivo no existe' {
        $path = Join-Path $TestDrive 'no-existe-tail.log'
        $tail = @(Get-LogTail -Path $path -MaxLines 50)
        $tail.Count | Should Be 0
    }

    It 'devuelve un array vacio si el archivo esta vacio o solo tiene blancos' {
        $path = Join-Path $TestDrive 'blancos-tail.log'
        Set-Content -LiteralPath $path -Value @('', '   ', '')
        $tail = @(Get-LogTail -Path $path -MaxLines 50)
        $tail.Count | Should Be 0
    }

    It 'con menos lineas que N devuelve todas' {
        $path = Join-Path $TestDrive 'corto-tail.log'
        Set-Content -LiteralPath $path -Value @('a', 'PLAN_STATUS: CONTINUE')
        $tail = @(Get-LogTail -Path $path -MaxLines 50)
        $tail.Count | Should Be 2
        $tail[1] | Should Be 'PLAN_STATUS: CONTINUE'
    }

    It 'una marca por encima de la ventana queda fuera de la cola' {
        $path = Join-Path $TestDrive 'marca-arriba.log'
        $lines = @('PLAN_STATUS: CONTINUE') + (1..60 | ForEach-Object { "ruido-$_" })
        Set-Content -LiteralPath $path -Value $lines
        $tail = @(Get-LogTail -Path $path -MaxLines 50)
        $tail.Count | Should Be 50
        ($tail -contains 'PLAN_STATUS: CONTINUE') | Should Be $false
        $tail[0] | Should Be 'ruido-11'
    }
}

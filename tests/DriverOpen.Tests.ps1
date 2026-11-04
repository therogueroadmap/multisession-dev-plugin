$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverOpen.psm1') -Force

Describe 'DriverOpen' {
    $guid = '0f8fad5b-d9cb-469f-a165-70867728950e'
    $otherGuid = '1a2b3c4d-1111-4222-8333-444455556666'

    function New-OpenProject {
        param([string]$Name)
        $project = Join-Path $TestDrive $Name
        $logs = Join-Path $project '.driver-logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        return [pscustomobject]@{ Project = $project; Logs = $logs }
    }

    It 'folder abre explorer.exe con la carpeta como un solo argumento' {
        $d = New-OpenProject 'con espacios'
        $r = Resolve-DriverOpenCommand -Target folder -ProjectPath $d.Project -LogsDir $d.Logs
        $r.Ok | Should Be $true
        $r.Kind | Should Be 'process'
        $r.FilePath | Should Be 'explorer.exe'
        @($r.Arguments).Count | Should Be 1
        $r.Arguments[0] | Should Be $d.Project

        $missing = Resolve-DriverOpenCommand -Target folder -ProjectPath (Join-Path $TestDrive 'no-existe') -LogsDir $d.Logs
        $missing.Ok | Should Be $false
        $missing.Detail | Should Be 'carpeta del proyecto inexistente'
    }

    It 'log resuelve el log del iter dentro de .driver-logs y rechaza el resto' {
        $d = New-OpenProject 'logs'
        $log1 = Join-Path $d.Logs 'session-1-20261028-100000.log'
        $log2 = Join-Path $d.Logs 'session-2-20261028-110000.stream.jsonl'
        Set-Content -LiteralPath $log1 -Value 'x'
        Set-Content -LiteralPath $log2 -Value 'x'
        $history = @(
            [pscustomobject]@{ iter = 1; logPath = 'session-1-20261028-100000.log' },
            [pscustomobject]@{ iter = 2; logPath = $null; streamFile = 'session-2-20261028-110000.stream.jsonl' }
        )

        $r1 = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History $history -Iter 1
        $r1.Ok | Should Be $true
        $r1.Kind | Should Be 'item'
        $r1.FilePath | Should Be ([IO.Path]::GetFullPath($log1))
        @($r1.Arguments).Count | Should Be 0

        $rLast = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History $history
        $rLast.Ok | Should Be $true
        $rLast.FilePath | Should Be ([IO.Path]::GetFullPath($log2))

        $r9 = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History $history -Iter 9
        $r9.Ok | Should Be $false
        $r9.Detail | Should Be 'sin sesión para el iter 9'

        $bad1 = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History @([pscustomobject]@{ iter = 1; logPath = '..\x.log' }) -Iter 1
        $bad1.Ok | Should Be $false
        $bad1.Detail | Should Be 'nombre de log no admitido'

        $bad2 = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History @([pscustomobject]@{ iter = 1; logPath = 'session-3.cmd' }) -Iter 1
        $bad2.Ok | Should Be $false
        $bad2.Detail | Should Be 'nombre de log no admitido'

        $none = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History @([pscustomobject]@{ iter = 1; logPath = 'session-4-x.log' }) -Iter 1
        $none.Ok | Should Be $false
        $none.Detail | Should Be 'log inexistente: session-4-x.log'

        $empty = Resolve-DriverOpenCommand -Target log -ProjectPath $d.Project -LogsDir $d.Logs -History @()
        $empty.Ok | Should Be $false
        $empty.Detail | Should Be 'sin sesiones en el historial'
    }

    It 'terminal con wt.exe pasa los argumentos en arreglo con el GUID validado' {
        $d = New-OpenProject 'term-wt'
        $history = @([pscustomobject]@{ iter = 1; sessionId = $guid })
        $r = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history -WtPath 'C:\wt.exe' -PwshPath 'C:\pwsh.exe'
        $r.Ok | Should Be $true
        $r.Kind | Should Be 'process'
        $r.FilePath | Should Be 'C:\wt.exe'
        ($r.Arguments -join '|') | Should Be "-d|$($d.Project)|C:\pwsh.exe|-NoExit|-Command|claude --resume $guid"

        $bad = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History @([pscustomobject]@{ iter = 1; sessionId = 'x; calc' }) -WtPath 'C:\wt.exe' -PwshPath 'C:\pwsh.exe'
        $bad.Ok | Should Be $false
        $bad.Detail | Should Be 'sesión sin id reanudable'
    }

    It 'terminal sin wt.exe o con ; en la ruta usa pwsh en ventana nueva' {
        $d = New-OpenProject 'term-pwsh'
        $history = @([pscustomobject]@{ iter = 1; sessionId = $guid })
        $r = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history -PwshPath 'C:\pwsh.exe'
        $r.Ok | Should Be $true
        $r.FilePath | Should Be 'C:\pwsh.exe'
        ($r.Arguments -join '|') | Should Be "-NoExit|-WorkingDirectory|$($d.Project)|-Command|claude --resume $guid"

        $semi = New-OpenProject 'a;b'
        $r2 = Resolve-DriverOpenCommand -Target terminal -ProjectPath $semi.Project -LogsDir $semi.Logs -History $history -WtPath 'C:\wt.exe' -PwshPath 'C:\pwsh.exe'
        $r2.Ok | Should Be $true
        $r2.FilePath | Should Be 'C:\pwsh.exe'
        ($r2.Arguments -join '|') | Should Be "-NoExit|-WorkingDirectory|$($semi.Project)|-Command|claude --resume $guid"

        $r3 = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history
        $r3.Ok | Should Be $false
        $r3.Detail | Should Be 'pwsh no disponible'
    }

    It 'terminal rechazada para la sesion en curso' {
        $d = New-OpenProject 'term-running'
        $history = @(
            [pscustomobject]@{ iter = 1; sessionId = $otherGuid },
            [pscustomobject]@{ iter = 2; sessionId = $guid }
        )
        $r = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history -RunningSessionId $guid -PwshPath 'C:\pwsh.exe'
        $r.Ok | Should Be $false
        $r.Detail | Should Be 'terminal no disponible para la sesión en curso'

        $same = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history -Iter 2 -RunningSessionId $guid -PwshPath 'C:\pwsh.exe'
        $same.Ok | Should Be $false
        $same.Detail | Should Be 'terminal no disponible para la sesión en curso'

        $other = Resolve-DriverOpenCommand -Target terminal -ProjectPath $d.Project -LogsDir $d.Logs -History $history -Iter 1 -RunningSessionId $guid -PwshPath 'C:\pwsh.exe'
        $other.Ok | Should Be $true
    }

    It 'Invoke-DriverOpen con -RecordPath registra el comando y no abre nada; un fallo no lanza' {
        $d = New-OpenProject 'invoke'
        $cmd = Resolve-DriverOpenCommand -Target folder -ProjectPath $d.Project -LogsDir $d.Logs
        $record = Join-Path $TestDrive 'invoke-record.jsonl'
        $r = Invoke-DriverOpen -Command $cmd -RecordPath $record
        $r.Ok | Should Be $true
        $r.Detail | Should Be 'abierto'
        $lines = @(Get-Content -LiteralPath $record)
        $lines.Count | Should Be 1
        $rec = $lines[0] | ConvertFrom-Json
        $rec.kind | Should Be 'process'
        $rec.filePath | Should Be 'explorer.exe'
        @($rec.arguments).Count | Should Be 1
        $rec.arguments[0] | Should Be $d.Project

        Mock -ModuleName DriverOpen Invoke-Item { throw 'x' }
        $item = [pscustomobject]@{ Ok = $true; Detail = $null; Kind = 'item'; FilePath = (Join-Path $d.Logs 'session-1-a.log'); Arguments = @() }
        $out = @{ R = $null }
        { $out.R = Invoke-DriverOpen -Command $item } | Should Not Throw
        $out.R.Ok | Should Be $false
        $out.R.Detail | Should Be 'no se pudo abrir: x'
    }
}

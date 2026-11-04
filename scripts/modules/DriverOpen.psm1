# DriverOpen: accion "open" del dashboard (Ola 2c): abrir la carpeta del proyecto, un
# log de sesion o una terminal con "claude --resume" desde el equipo del driver.
#
# Se parte en dos para poder probarlo sin abrir nada: Resolve-DriverOpenCommand decide
# que se abre y valida todo (es pura, solo lee el disco) e Invoke-DriverOpen lo ejecuta.
# Nada de lo que llega en la orden se interpola en una cadena de comando: la carpeta, el
# log y el id de sesion se resuelven contra el disco y el historial, y los procesos se
# lanzan con cada argumento por separado (ver ProcessLauncher.psm1: Start-Process
# -ArgumentList une el arreglo sin comillas, por eso aqui se usa ProcessStartInfo).

$script:OpenLogNamePattern = '^session-[A-Za-z0-9.\-]+\.(log|jsonl)\z'
$script:OpenGuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'

function New-OpenCommand {
    param(
        [bool]$Ok,
        [string]$Detail = $null,
        [string]$Kind = $null,
        [string]$FilePath = $null,
        [string[]]$Arguments = @()
    )

    [pscustomobject]@{
        Ok        = $Ok
        Detail    = $Detail
        Kind      = $Kind
        FilePath  = $FilePath
        Arguments = [string[]]@($Arguments)
    }
}

# Valor de una propiedad de una entrada de history; $null si falta.
function Get-OpenValue {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# Entrada de history: con Iter, la ultima con ese iter; sin Iter, la ultima. Devuelve
# @{ Entry; Detail }; Detail es el rechazo si no hay entrada.
function Select-OpenEntry {
    param($History, $Iter)

    $entries = @($History | Where-Object { $null -ne $_ })
    if ($null -ne $Iter) {
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $value = Get-OpenValue -Object $entries[$i] -Name 'iter'
            if ($null -ne $value -and ($value -is [int] -or $value -is [long]) -and [long]$value -eq [long]$Iter) {
                return @{ Entry = $entries[$i]; Detail = $null }
            }
        }
        return @{ Entry = $null; Detail = "sin sesión para el iter $Iter" }
    }
    if ($entries.Count -eq 0) { return @{ Entry = $null; Detail = 'sin sesiones en el historial' } }
    return @{ Entry = $entries[$entries.Count - 1]; Detail = $null }
}

function Resolve-DriverOpenCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,
        [Parameter(Mandatory = $true)]
        [string]$LogsDir,
        [object[]]$History = @(),
        [Nullable[int]]$Iter = $null,
        [string]$RunningSessionId,
        [string]$WtPath,
        [string]$PwshPath
    )

    try {
        switch -CaseSensitive ($Target) {
            'folder' {
                if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
                    return (New-OpenCommand -Ok $false -Detail 'carpeta del proyecto inexistente')
                }
                return (New-OpenCommand -Ok $true -Kind 'process' -FilePath 'explorer.exe' -Arguments @($ProjectPath))
            }
            'log' {
                $sel = Select-OpenEntry -History $History -Iter $Iter
                if ($null -eq $sel.Entry) { return (New-OpenCommand -Ok $false -Detail $sel.Detail) }

                $name = Get-OpenValue -Object $sel.Entry -Name 'logPath'
                if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = Get-OpenValue -Object $sel.Entry -Name 'streamFile' }
                $leaf = $null
                if (-not [string]::IsNullOrWhiteSpace([string]$name)) { $leaf = Split-Path -Leaf ([string]$name) }
                if ([string]::IsNullOrEmpty($leaf) -or -not ($leaf -cmatch $script:OpenLogNamePattern)) {
                    return (New-OpenCommand -Ok $false -Detail 'nombre de log no admitido')
                }

                $sep = [string][IO.Path]::DirectorySeparatorChar
                $full = [IO.Path]::GetFullPath((Join-Path $LogsDir $leaf))
                $root = [IO.Path]::GetFullPath($LogsDir).TrimEnd('\', '/') + $sep
                if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return (New-OpenCommand -Ok $false -Detail 'log fuera de .driver-logs')
                }
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                    return (New-OpenCommand -Ok $false -Detail "log inexistente: $leaf")
                }
                return (New-OpenCommand -Ok $true -Kind 'item' -FilePath $full)
            }
            'terminal' {
                if ($null -eq $Iter -and -not [string]::IsNullOrEmpty($RunningSessionId)) {
                    return (New-OpenCommand -Ok $false -Detail 'terminal no disponible para la sesión en curso')
                }
                $sel = Select-OpenEntry -History $History -Iter $Iter
                if ($null -eq $sel.Entry) { return (New-OpenCommand -Ok $false -Detail $sel.Detail) }

                $id = Get-OpenValue -Object $sel.Entry -Name 'sessionId'
                if ($id -isnot [string] -or -not ($id -cmatch $script:OpenGuidPattern)) {
                    return (New-OpenCommand -Ok $false -Detail 'sesión sin id reanudable')
                }
                if (-not [string]::IsNullOrEmpty($RunningSessionId) -and $id -ceq $RunningSessionId) {
                    return (New-OpenCommand -Ok $false -Detail 'terminal no disponible para la sesión en curso')
                }

                # El id ya paso el patron de GUID: es lo unico que se interpola en el comando.
                $cmd = "claude --resume $id"
                # wt usa ';' como separador de comandos: una ruta con ';' no puede ir en sus argumentos.
                if (-not [string]::IsNullOrEmpty($WtPath) -and -not $ProjectPath.Contains(';')) {
                    $shell = if ([string]::IsNullOrEmpty($PwshPath)) { 'pwsh' } else { $PwshPath }
                    return (New-OpenCommand -Ok $true -Kind 'process' -FilePath $WtPath -Arguments @('-d', $ProjectPath, $shell, '-NoExit', '-Command', $cmd))
                }
                if ([string]::IsNullOrEmpty($PwshPath)) { return (New-OpenCommand -Ok $false -Detail 'pwsh no disponible') }
                return (New-OpenCommand -Ok $true -Kind 'process' -FilePath $PwshPath -Arguments @('-NoExit', '-WorkingDirectory', $ProjectPath, '-Command', $cmd))
            }
            default {
                return (New-OpenCommand -Ok $false -Detail "destino no admitido: $Target")
            }
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        return (New-OpenCommand -Ok $false -Detail "no se pudo resolver: $($_.Exception.Message)")
    }
}

function Invoke-DriverOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Command,
        [string]$RecordPath
    )

    try {
        if ($null -eq $Command -or $Command.Ok -ne $true) {
            $why = if ($null -ne $Command -and -not [string]::IsNullOrEmpty($Command.Detail)) { $Command.Detail } else { 'comando no válido' }
            return [pscustomobject]@{ Ok = $false; Detail = "no se pudo abrir: $why" }
        }

        if (-not [string]::IsNullOrEmpty($RecordPath)) {
            # Modo de prueba: registra lo que se habria abierto y no abre nada.
            $line = ([ordered]@{
                    kind      = $Command.Kind
                    filePath  = $Command.FilePath
                    arguments = [string[]]@($Command.Arguments)
                } | ConvertTo-Json -Compress)
            [System.IO.File]::AppendAllText($RecordPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
            return [pscustomobject]@{ Ok = $true; Detail = 'abierto' }
        }

        if ($Command.Kind -ceq 'item') {
            Invoke-Item -LiteralPath $Command.FilePath -ErrorAction Stop
        }
        else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Command.FilePath
            foreach ($a in @($Command.Arguments)) { [void]$psi.ArgumentList.Add([string]$a) }
            # Ventana propia: con UseShellExecute el hijo no comparte la consola del driver.
            $psi.UseShellExecute = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($null -ne $proc) { $proc.Dispose() }
        }
        return [pscustomobject]@{ Ok = $true; Detail = 'abierto' }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Detail = "no se pudo abrir: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Resolve-DriverOpenCommand, Invoke-DriverOpen

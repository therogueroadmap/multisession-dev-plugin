# ProcessLauncher: lanza un proceso hijo pasando cada argumento VERBATIM.
#
# Por que existe: "Start-Process -ArgumentList @(...)" une el array con espacios
# SIN entrecomillar los elementos que contienen espacios o saltos de linea. Un
# prompt multipalabra pasado por ese camino llega partido al hijo (el driver
# headless recibia "-p Ejecuta" y perdia el resto del prompt). Este launcher usa
# System.Diagnostics.ProcessStartInfo.ArgumentList, que entrecomilla cada arg de
# forma correcta (disponible en PowerShell 7 / .NET Core+).
#
# Drenaje: stdout y stderr se copian a sus archivos con Stream.CopyToAsync, en
# tareas .NET que no dependen de la cola de eventos de PowerShell. (Antes se
# usaban acciones de Register-ObjectEvent: corrian solo cuando el runspace
# procesaba eventos, de modo que tras WaitForExit() casi toda la salida seguia
# sin escribir y una carrera con Unregister-Event podia perder la cola del log,
# justo donde va la marca PLAN_STATUS.) Los archivos se abren sin buffer y con
# FileShare.ReadWrite: crecen en disco a medida que el hijo escribe, que es una
# de las senales del watchdog de liveness del driver. Se copian bytes crudos,
# sin recodificar.
#
# Fidelidad (B-3): los U+FFFD que aparecen en los .stream.jsonl no vienen de
# esta copia. Vienen dentro de resultados de herramientas (eventos user) que el
# CLI ya decodifico mal (salida de JVM o consola en la pagina de codigos del
# sistema). Los tests B-3 de ProcessLauncher.Tests.ps1 fijan que la copia es
# fiel byte a byte.

function Start-HeadlessProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$StdoutPath,

        [Parameter(Mandatory = $true)]
        [string]$StderrPath,

        [string]$WorkingDirectory,

        # Variables de entorno extra para el hijo. Sin este parametro, el hijo
        # hereda el entorno del proceso actual.
        [hashtable]$Environment,

        # Tope de espera del drenaje en Cleanup. Cubre el caso de un nieto que
        # heredo la tuberia y la mantiene abierta tras la salida del hijo.
        [int]$DrainTimeoutMs = 30000
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $share = [System.IO.FileShare]::ReadWrite
    $outFile = New-Object System.IO.FileStream($StdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share, 1)
    $errFile = New-Object System.IO.FileStream($StderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, $share, 1)

    try {
        [void]$proc.Start()
    }
    catch {
        $outFile.Dispose()
        $errFile.Dispose()
        throw
    }

    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outFile)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($errFile)
    $drainTimeout = $DrainTimeoutMs
    $errPath = $StderrPath

    # El caller debe invocar este scriptblock UNA vez, despues de que el proceso
    # termino (o fue matado). WaitForExit() NO garantiza que la salida este en
    # disco: la garantia la da este Cleanup. Camino degradado: cerrar tuberias,
    # esperar 2 s, nota en append tras cerrar.
    $cleanup = {
        $drained = $false
        try {
            $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), $drainTimeout)
        }
        catch {
            # WaitAll lanza AggregateException si alguna copia termino con error
            # (p.ej. tuberia rota tras un kill): las tareas ya terminaron.
            $drained = $true
        }
        if (-not $drained) {
            try { $proc.StandardOutput.Dispose() } catch {}
            try { $proc.StandardError.Dispose() } catch {}
            try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 2000) } catch {}
        }
        try { $outFile.Flush(); $outFile.Dispose() } catch {}
        try { $errFile.Flush(); $errFile.Dispose() } catch {}
        if (-not $drained) {
            try {
                $appendFile = New-Object System.IO.FileStream($errPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $note = [System.Text.Encoding]::UTF8.GetBytes("[ProcessLauncher] drenaje incompleto tras $drainTimeout ms; salida posiblemente truncada" + [Environment]::NewLine)
                $appendFile.Write($note, 0, $note.Length)
                $appendFile.Dispose()
            }
            catch {}
        }
    }.GetNewClosure()

    return [pscustomobject]@{
        Process = $proc
        Cleanup = $cleanup
    }
}

# Precedencia del techo de background de "claude -p"
# (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS) para cada sesion headless:
#   1. parametro explicito del driver  -> se exporta ese valor
#   2. variable ya presente en entorno -> se hereda (Env vacio)
#   3. ninguno                         -> se exporta '0' (esperar indefinidamente)
function Resolve-BackgroundCeilingEnv {
    param(
        [Parameter(Mandatory = $true)]
        [int]$BoundValue,

        [Parameter(Mandatory = $true)]
        [bool]$HasBound,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$InheritedValue
    )

    $name = 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'
    if ($HasBound) {
        return [pscustomobject]@{ Env = @{ $name = [string]$BoundValue }; Value = [string]$BoundValue; Source = 'parametro' }
    }
    if (-not [string]::IsNullOrEmpty($InheritedValue)) {
        return [pscustomobject]@{ Env = @{}; Value = $InheritedValue; Source = 'entorno' }
    }
    return [pscustomobject]@{ Env = @{ $name = '0' }; Value = '0'; Source = 'default' }
}

Export-ModuleMember -Function Start-HeadlessProcess, Resolve-BackgroundCeilingEnv

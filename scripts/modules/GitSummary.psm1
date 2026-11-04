# GitSummary: resumen del repo para el bloque git del status (rama, commits propios,
# diffstat y limpieza del arbol). Get-GitSummary nunca lanza: cualquier fallo queda
# en la propiedad error y el resto en $null, porque el driver lo llama en cada
# iteracion y un git lento o ausente no debe tumbarlo.

# Sin -Force: el driver y los tests ya importan GitWorkspace cuando hace falta.
Import-Module (Join-Path $PSScriptRoot 'GitWorkspace.psm1')

# Ejecuta un proceso con tope de tiempo. stdout y stderr se leen de forma asincrona
# ANTES de esperar la salida: si no, un buffer lleno bloquearia al hijo y la espera
# vencera siempre. Si vence el tope se mata el arbol de procesos y se devuelve
# TimedOut sin leer las salidas. Solo lanza si el proceso no puede iniciarse.
function Invoke-GitSummaryCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    # Salida de git en ingles: el parseo de --shortstat depende del idioma.
    $psi.Environment['LC_ALL'] = 'C'
    $psi.Environment['LANGUAGE'] = 'C'

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $budgetMs = $TimeoutSeconds * 1000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($budgetMs)) {
            try { $proc.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = $null; Stdout = ''; Stderr = ''; TimedOut = $true }
        }
        # Que el hijo salga no garantiza el EOF de las tuberias: un nieto que las
        # herede y siga vivo dejaria las lecturas esperando sin tope. La salida y el
        # drenaje comparten un plazo unico de TimeoutSeconds.
        $drained = $false
        try {
            $remainingMs = [Math]::Max(0, $budgetMs - [int]$sw.ElapsedMilliseconds)
            $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $remainingMs)
        }
        catch {
            # WaitAll lanza AggregateException si una lectura fallo: las tareas ya
            # terminaron y el GetResult() posterior relanza el error.
            $drained = $true
        }
        if (-not $drained) {
            try { $proc.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = $null; Stdout = ''; Stderr = ''; TimedOut = $true }
        }
        # El proceso ya salio; esta llamada solo asegura que ExitCode este disponible.
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
        }
    }
    finally {
        $proc.Dispose()
    }
}

# Corre un subcomando de git sobre el repo y devuelve su stdout. Lanza con el texto
# final del campo error si vence el tope o git sale con codigo distinto de 0.
function Invoke-GitSummaryStep {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Subcommand,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string[]]$GlobalArguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $all = @($GlobalArguments) + @('-C', $RepoRoot, $Subcommand) + @($Arguments)
    $r = Invoke-GitSummaryCommand -FilePath $GitPath -Arguments $all -TimeoutSeconds $TimeoutSeconds
    if ($r.TimedOut) {
        throw "git $Subcommand excedio $TimeoutSeconds s"
    }
    if ($r.ExitCode -ne 0) {
        $first = @(($r.Stderr -split "\r?\n") | Where-Object { $_.Trim() })[0]
        throw "git $Subcommand fallo (exit $($r.ExitCode)): $first"
    }
    return $r.Stdout
}

function Get-GitSummary {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [AllowNull()][AllowEmptyString()][string]$BaseBranch,
        [string]$GitPath = 'git',
        [int]$TimeoutSeconds = 15,
        [int]$MaxCommits = 10
    )

    try {
        if ([string]::IsNullOrWhiteSpace($BaseBranch)) {
            throw 'sin rama base (develop, main o master)'
        }

        $branch = (Invoke-GitSummaryStep -GitPath $GitPath -RepoRoot $RepoRoot -Subcommand 'rev-parse' -Arguments @('--abbrev-ref', 'HEAD') -TimeoutSeconds $TimeoutSeconds).Trim()

        $aheadText = (Invoke-GitSummaryStep -GitPath $GitPath -RepoRoot $RepoRoot -Subcommand 'rev-list' -Arguments @('--count', "$BaseBranch..HEAD") -TimeoutSeconds $TimeoutSeconds).Trim()
        $ahead = [int]$aheadText

        $logOut = Invoke-GitSummaryStep -GitPath $GitPath -RepoRoot $RepoRoot -Subcommand 'log' -Arguments @('--format=%h%x09%s', "-$MaxCommits", "$BaseBranch..HEAD") -TimeoutSeconds $TimeoutSeconds
        $commits = @(
            foreach ($line in ($logOut -split "\r?\n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $tab = $line.IndexOf("`t")
                if ($tab -ge 0) {
                    [pscustomobject][ordered]@{ hash = $line.Substring(0, $tab); subject = $line.Substring($tab + 1) }
                }
                else {
                    [pscustomobject][ordered]@{ hash = $line; subject = '' }
                }
            }
        )

        $statText = Invoke-GitSummaryStep -GitPath $GitPath -RepoRoot $RepoRoot -Subcommand 'diff' -Arguments @('--shortstat', "$BaseBranch...HEAD") -TimeoutSeconds $TimeoutSeconds
        $files = 0; $insertions = 0; $deletions = 0
        if ($statText -match '(\d+) files? changed') { $files = [int]$Matches[1] }
        if ($statText -match '(\d+) insertions?\(\+\)') { $insertions = [int]$Matches[1] }
        if ($statText -match '(\d+) deletions?\(-\)') { $deletions = [int]$Matches[1] }
        $diffstat = [pscustomobject][ordered]@{ files = $files; insertions = $insertions; deletions = $deletions }

        # --no-optional-locks: el resumen se pide mientras el agente trabaja y no debe
        # tomar el index.lock ni competir con sus comandos git.
        $porcelain = Invoke-GitSummaryStep -GitPath $GitPath -RepoRoot $RepoRoot -Subcommand 'status' -GlobalArguments @('--no-optional-locks') -Arguments @('--porcelain=v1', '-z', '--untracked-files=all') -TimeoutSeconds $TimeoutSeconds
        $clean = Test-PorcelainClean -Porcelain $porcelain

        return [pscustomobject][ordered]@{
            branch     = $branch
            baseBranch = $BaseBranch
            ahead      = $ahead
            commits    = $commits
            diffstat   = $diffstat
            clean      = $clean
            updatedAt  = (Get-Date).ToString('o')
            error      = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            branch     = $null
            baseBranch = $null
            ahead      = $null
            commits    = $null
            diffstat   = $null
            clean      = $null
            updatedAt  = (Get-Date).ToString('o')
            error      = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function Get-GitSummary

function Test-GitRepo {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-WorkspaceBaseBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    foreach ($b in @('develop', 'main', 'master')) {
        git -C $RepoRoot rev-parse --verify --quiet "refs/heads/$b" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $b }
    }
    return $null
}

function Get-PlanBranchName {
    param(
        [Parameter(Mandatory = $true)][string]$PlanFilePath,
        [AllowNull()][string]$Override
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($PlanFilePath)
    # Propone el nombre del feature: quita el prefijo de fecha YYYY-MM-DD- si existe.
    # Sin prefijo 'plan/'; el override -BranchName gana si se pasa.
    return ($leaf -replace '^\d{4}-\d{2}-\d{2}-', '')
}

# Filtro puro sobre la salida cruda de git status --porcelain=v1 -z
# --untracked-files=all: $true si, quitadas las entradas del driver, no queda nada.
# Lo comparten Test-WorkingTreeClean y Get-GitSummary (GitSummary.psm1).
function Test-PorcelainClean {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Porcelain)
    # El driver escribe .driver-status.json, .driver-dashboard.json (y su .tmp del
    # reemplazo atomico), .driver-logs/ y .driver-runs/ en la carpeta del plan antes
    # de validar el arbol; no cuentan como cambios del usuario. El servidor del
    # dashboard escribe la orden de control (.driver-control.json y su .tmp) en la
    # carpeta del plan.
    $entries = $Porcelain -split "`0" | Where-Object { $_ }
    $dirty = $entries | Where-Object {
        $path = if ($_.Length -gt 3 -and $_[2] -eq ' ') { $_.Substring(3) } else { $_ }
        -not ($path -match '(^|/)\.driver-status\.json$' -or $path -match '(^|/)\.driver-dashboard\.json(\.tmp)?$' -or $path -match '(^|/)\.driver-logs/' -or $path -match '(^|/)\.driver-runs/' -or $path -match '(^|/)\.driver-control\.json(\.tmp)?$')
    }
    return (@($dirty).Count -eq 0)
}

function Test-WorkingTreeClean {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    # -z evita el quoting de rutas con espacios y --untracked-files=all impide que
    # git colapse la carpeta entera en una sola entrada que esconda otros archivos.
    $out = git -C $RepoRoot status --porcelain=v1 -z --untracked-files=all 2>$null
    return (Test-PorcelainClean -Porcelain ($out -join ''))
}

function Test-BranchExists {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    git -C $RepoRoot rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-CurrentBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return (git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
}

function Initialize-WorkBranch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: '$RepoRoot' no es un repositorio git."
    }
    if (-not (Test-WorkingTreeClean -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: el working tree de '$RepoRoot' tiene cambios sin commitear. Confirma o descarta antes de lanzar el driver."
    }
    if (Test-BranchExists -RepoRoot $RepoRoot -Branch $Branch) {
        throw "GitWorkspace: la rama '$Branch' ya existe en un arranque limpio. Usa -BranchName para otro nombre o reanuda el run existente."
    }
    $base = Resolve-WorkspaceBaseBranch -RepoRoot $RepoRoot
    if (-not $base) {
        throw "GitWorkspace: no existe ninguna rama base (develop, main o master) en '$RepoRoot'."
    }
    git -C $RepoRoot checkout -b $Branch $base 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitWorkspace: fallo al crear la rama '$Branch' desde '$base'."
    }
    return $base
}

# Bootstrap sobre la rama ya activa (-UseCurrentBranch del driver): no crea ni
# cambia ramas; exige repo, working tree limpio y una rama con nombre.
function Use-CurrentWorkBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: '$RepoRoot' no es un repositorio git."
    }
    if (-not (Test-WorkingTreeClean -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: el working tree de '$RepoRoot' tiene cambios sin commitear. Confirma o descarta antes de lanzar el driver."
    }
    $branch = Get-CurrentBranch -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'HEAD') {
        throw "GitWorkspace: '$RepoRoot' tiene HEAD desacoplado; haz checkout de la rama de trabajo antes de lanzar el driver."
    }
    return $branch
}

# Subcarpetas de primer nivel que son repos git (.git carpeta o archivo:
# cubre worktrees y submodulos), ordenadas por nombre.
function Get-ChildGitRepos {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dirs = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue
    return @($dirs |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Sort-Object Name |
        ForEach-Object { $_.Name })
}

# M7 (corto plazo): sin -WorkDir, -ProjectPath debe ser un repo git. Si es una
# raiz multi-repo, el mensaje nombra sus repos y sugiere la salida correcta.
function Assert-ProjectIsRepo {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)
    if (Test-GitRepo -RepoRoot $ProjectPath) { return }
    $repos = @(Get-ChildGitRepos -Path $ProjectPath)
    if ($repos.Count -gt 0) {
        throw "GitWorkspace: '$ProjectPath' no es un repositorio git pero contiene los repos: $($repos -join ', '). Este driver es single-repo: usa -WorkDir <repo> con un plan de ese repo, o ejecuta el plan con my-subagent-driven-development si es multi-repo."
    }
    throw "GitWorkspace: '$ProjectPath' no es un repositorio git."
}

# Reanudacion legitima de un bootstrap cortado (fix 2): la rama del plan ya
# existe y el checkpoint es cold-start del mismo plan. Hace checkout de esa
# rama en vez de crearla. Exige repo, working tree limpio y rama existente.
function Resume-WorkBranch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch
    )
    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: '$RepoRoot' no es un repositorio git."
    }
    if (-not (Test-WorkingTreeClean -RepoRoot $RepoRoot)) {
        throw "GitWorkspace: el working tree de '$RepoRoot' tiene cambios sin commitear. Confirma o descarta antes de lanzar el driver."
    }
    if (-not (Test-BranchExists -RepoRoot $RepoRoot -Branch $Branch)) {
        throw "GitWorkspace: la rama '$Branch' no existe; no hay nada que retomar."
    }
    if ((Get-CurrentBranch -RepoRoot $RepoRoot) -ne $Branch) {
        git -C $RepoRoot checkout -q $Branch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "GitWorkspace: fallo el checkout de la rama '$Branch'."
        }
    }
    return $Branch
}

# Fix 2, solo al arranque: 'resume' si la rama del plan ya existe y el
# checkpoint es del mismo plan en cold-start (la sesion 1 se corto antes de
# cerrar el nivel 0). En re-entrada dentro de la misma corrida devuelve
# 'create' y Initialize-WorkBranch conserva su throw: es la guarda contra
# relanzar el nivel 0 sin fin hasta que exista M9.
function Resolve-BootstrapBranchAction {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch,
        [AllowNull()][object]$StateInfo,
        [bool]$IsFirstIteration = $false
    )
    if (-not $IsFirstIteration) { return 'create' }
    if ($null -eq $StateInfo -or -not $StateInfo.SamePlan -or $StateInfo.HasProgress) { return 'create' }
    if (-not (Test-BranchExists -RepoRoot $RepoRoot -Branch $Branch)) { return 'create' }
    return 'resume'
}

Export-ModuleMember -Function Test-GitRepo, Resolve-WorkspaceBaseBranch, Get-PlanBranchName, Test-PorcelainClean, Test-WorkingTreeClean, Test-BranchExists, Get-CurrentBranch, Initialize-WorkBranch, Use-CurrentWorkBranch, Get-ChildGitRepos, Assert-ProjectIsRepo, Resume-WorkBranch, Resolve-BootstrapBranchAction

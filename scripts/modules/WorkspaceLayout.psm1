function Resolve-RepoRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [AllowNull()][string]$WorkDir
    )
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { return $ProjectPath }
    return (Join-Path $ProjectPath $WorkDir)
}

function Get-EffectivePlansDir {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return (Join-Path $RepoRoot 'docs\superpowers\plans')
}

function Copy-PlanIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$PlanFilePath,
        [Parameter(Mandatory = $true)][string]$DestPlansDir
    )
    if (-not (Test-Path -LiteralPath $DestPlansDir)) {
        New-Item -ItemType Directory -Path $DestPlansDir -Force | Out-Null
    }
    $dest = Join-Path $DestPlansDir ([System.IO.Path]::GetFileName($PlanFilePath))
    if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $PlanFilePath -Destination $dest -Force
    }
    return $dest
}

function Get-PathRelativeTo {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )
    $baseNorm = $BasePath.TrimEnd('\', '/')
    if ($FullPath.StartsWith($baseNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($baseNorm.Length).TrimStart('\', '/')
    }
    return $FullPath
}

# Ruta contenida en otra, o igual a ella. Normaliza con GetFullPath (resuelve
# ..\ y .\) y exige frontera de separador: C:\repo2 no esta dentro de C:\repo.
function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $base = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full.Equals($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Fix 4 del tercer modo de fallo: sin -WorkDir, un plan fuera del repo hace que
# la sesion escriba .controller-state.json junto al plan, donde el driver no lo
# busca. Se rechaza al arranque con la causa y el comando correcto.
function Assert-PlanInsideRepo {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PlanFilePath
    )
    if (Test-PathWithin -BasePath $RepoRoot -Path $PlanFilePath) { return }

    $planFull = [System.IO.Path]::GetFullPath($PlanFilePath)
    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $planName = [System.IO.Path]::GetFileName($planFull)
    $cause = "El plan '$planFull' esta fuera del repo '$repoFull' y no se paso -WorkDir: la sesion guardaria el checkpoint (.controller-state.json) junto al plan y el driver no lo veria."

    # Convencion de monorepo: <X>\docs\superpowers\plans\<plan>, con el repo dentro de <X>.
    $plansDir = Split-Path -Parent $planFull
    $superDir = if ($plansDir) { Split-Path -Parent $plansDir } else { $null }
    $docsDir = if ($superDir) { Split-Path -Parent $superDir } else { $null }
    $container = if ($docsDir) { (Split-Path -Parent $docsDir).TrimEnd('\', '/') } else { $null }
    $isConventional = [bool]$container -and
        ((Split-Path -Leaf $plansDir) -eq 'plans') -and
        ((Split-Path -Leaf $superDir) -eq 'superpowers') -and
        ((Split-Path -Leaf $docsDir) -eq 'docs')

    if ($isConventional -and (Test-PathWithin -BasePath $container -Path $repoFull) -and
        -not $container.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $workDirRel = $repoFull.Substring($container.Length).TrimStart('\', '/')
        $hint = "Relanza con: -ProjectPath ""$container"" -WorkDir ""$workDirRel"" -PlanFile ""$planName"""
    }
    else {
        $hint = "Mueve el plan a '$repoFull\docs\superpowers\plans\' y relanza con -PlanFile $planName."
    }
    throw "$cause $hint"
}

Export-ModuleMember -Function Resolve-RepoRoot, Get-EffectivePlansDir, Copy-PlanIfMissing, Get-PathRelativeTo, Test-PathWithin, Assert-PlanInsideRepo

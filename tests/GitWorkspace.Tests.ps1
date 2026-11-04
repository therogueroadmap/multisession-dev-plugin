$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\GitWorkspace.psm1') -Force

function New-TempRepo {
    param([string[]]$Branches = @(), [switch]$Dirty)
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q | Out-Null
    git -C $repo config user.email 't@t.t' | Out-Null
    git -C $repo config user.name 'T' | Out-Null
    git -C $repo config commit.gpgsign false | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'x' -Encoding utf8
    git -C $repo add . | Out-Null
    git -C $repo commit -q -m 'init' | Out-Null
    if ($Branches.Count -gt 0) {
        git -C $repo branch -m $Branches[0] | Out-Null
        foreach ($b in ($Branches | Select-Object -Skip 1)) { git -C $repo branch $b | Out-Null }
        git -C $repo checkout -q $Branches[0] | Out-Null
    }
    if ($Dirty) { Set-Content -LiteralPath (Join-Path $repo 'dirty.txt') -Value 'y' -Encoding utf8 }
    return $repo
}

function New-MultiRepoRoot {
    param([string[]]$Repos = @(), [string[]]$Plain = @())
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($r in $Repos) {
        $p = Join-Path $root $r
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        git -C $p init -q | Out-Null
    }
    foreach ($d in $Plain) { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
    return $root
}

function Get-ThrownMessage {
    param([scriptblock]$Block)
    try { & $Block; return $null } catch { return $_.Exception.Message }
}


Describe 'GitWorkspace' {
    Context 'Resolve-WorkspaceBaseBranch' {
        It 'prefiere develop sobre main y master' {
            $repo = New-TempRepo -Branches @('main','develop','master')
            Resolve-WorkspaceBaseBranch -RepoRoot $repo | Should Be 'develop'
        }
        It 'usa main cuando no hay develop' {
            $repo = New-TempRepo -Branches @('main','master')
            Resolve-WorkspaceBaseBranch -RepoRoot $repo | Should Be 'main'
        }
        It 'usa master cuando solo existe master' {
            $repo = New-TempRepo -Branches @('master')
            Resolve-WorkspaceBaseBranch -RepoRoot $repo | Should Be 'master'
        }
        It 'devuelve $null si no hay ninguna de las tres' {
            $repo = New-TempRepo -Branches @('trabajo')
            Resolve-WorkspaceBaseBranch -RepoRoot $repo | Should BeNullOrEmpty
        }
    }

    Context 'Get-PlanBranchName' {
        It 'propone el nombre del feature quitando el prefijo de fecha YYYY-MM-DD-' {
            Get-PlanBranchName -PlanFilePath 'C:\x\docs\2026-09-11-bloque-b-web.md' |
                Should Be 'bloque-b-web'
        }
        It 'usa el leaf completo si no hay prefijo de fecha' {
            Get-PlanBranchName -PlanFilePath 'C:\x\p\mi-feature.md' |
                Should Be 'mi-feature'
        }
        It 'respeta el override' {
            Get-PlanBranchName -PlanFilePath 'C:\x\p.md' -Override 'mi-rama' |
                Should Be 'mi-rama'
        }
    }

    Context 'Test-WorkingTreeClean' {
        It 'true en repo limpio' {
            $repo = New-TempRepo -Branches @('main')
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $true
        }
        It 'false con cambios sin commitear' {
            $repo = New-TempRepo -Branches @('main') -Dirty
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $false
        }
        It 'true si solo hay artefactos del propio driver (status y logs)' {
            # El driver escribe .driver-status.json y .driver-logs/ antes de validar el arbol.
            $repo = New-TempRepo -Branches @('main')
            $plans = Join-Path $repo 'docs\plans dir'
            New-Item -ItemType Directory -Path (Join-Path $plans '.driver-logs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $plans '.driver-status.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $plans '.driver-logs\session-1.err.log') -Value 'x' -Encoding utf8
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $true
        }
        It 'true si solo hay artefactos del driver, incluido .driver-dashboard.json' {
            $repo = New-TempRepo -Branches @('main')
            $plans = Join-Path $repo 'docs\plans dir'
            New-Item -ItemType Directory -Path (Join-Path $plans '.driver-logs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $plans '.driver-status.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $plans '.driver-dashboard.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $plans '.driver-logs\session-1-20261027-103904.err.log') -Value 'x' -Encoding utf8
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $true
        }
        It 'true si solo hay artefactos del driver, incluido .driver-runs/' {
            $repo = New-TempRepo -Branches @('main')
            $plans = Join-Path $repo 'docs\superpowers\plans'
            New-Item -ItemType Directory -Path (Join-Path $plans '.driver-runs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $plans '.driver-status.json') -Value '{}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $plans '.driver-runs\20261027-221003-plan.json') -Value '{}' -Encoding utf8
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $true
        }
        It 'false si junto a los artefactos del driver hay otro cambio' {
            $repo = New-TempRepo -Branches @('main') -Dirty
            Set-Content -LiteralPath (Join-Path $repo '.driver-status.json') -Value '{}' -Encoding utf8
            Test-WorkingTreeClean -RepoRoot $repo | Should Be $false
        }
        It 'Test-PorcelainClean filtra las entradas del driver' {
            Test-PorcelainClean -Porcelain '' | Should Be $true
            Test-PorcelainClean -Porcelain "?? docs/superpowers/plans/.driver-status.json`0?? docs/superpowers/plans/.driver-logs/a.log`0" | Should Be $true
            Test-PorcelainClean -Porcelain "?? docs/superpowers/plans/.driver-dashboard.json.tmp`0 M src/a.ps1`0" | Should Be $false
        }
        It 'Test-PorcelainClean ignora la orden de control y su .tmp' {
            $porcelain = "?? docs/superpowers/plans/.driver-control.json`0?? docs/superpowers/plans/.driver-control.json.tmp`0"
            Test-PorcelainClean -Porcelain $porcelain | Should Be $true
            Test-PorcelainClean -Porcelain ($porcelain + " M src/a.ps1`0") | Should Be $false
        }
    }

    Context 'Initialize-WorkBranch (politica estricta de bootstrap)' {
        It 'crea la rama desde develop y hace checkout' {
            $repo = New-TempRepo -Branches @('main','develop')
            Initialize-WorkBranch -RepoRoot $repo -Branch 'plan/x'
            Get-CurrentBranch -RepoRoot $repo | Should Be 'plan/x'
        }
        It 'aborta si el working tree esta sucio' {
            $repo = New-TempRepo -Branches @('main') -Dirty
            { Initialize-WorkBranch -RepoRoot $repo -Branch 'plan/x' } | Should Throw 'GitWorkspace'
        }
        It 'aborta si la rama de trabajo ya existe' {
            $repo = New-TempRepo -Branches @('main')
            git -C $repo branch 'plan/x' | Out-Null
            { Initialize-WorkBranch -RepoRoot $repo -Branch 'plan/x' } | Should Throw 'GitWorkspace'
        }
        It 'aborta si no hay base develop/main/master' {
            $repo = New-TempRepo -Branches @('trabajo')
            { Initialize-WorkBranch -RepoRoot $repo -Branch 'plan/x' } | Should Throw 'GitWorkspace'
        }
    }

    Context 'Use-CurrentWorkBranch (bootstrap sobre la rama actual)' {
        It 'devuelve la rama actual sin crear ni cambiar ramas' {
            $repo = New-TempRepo -Branches @('feat/x','main')
            Use-CurrentWorkBranch -RepoRoot $repo | Should Be 'feat/x'
            Get-CurrentBranch -RepoRoot $repo | Should Be 'feat/x'
            (git -C $repo branch --list | Measure-Object).Count | Should Be 2
        }
        It 'aborta si el working tree esta sucio' {
            $repo = New-TempRepo -Branches @('feat/x') -Dirty
            { Use-CurrentWorkBranch -RepoRoot $repo } | Should Throw 'GitWorkspace'
        }
        It 'aborta con HEAD desacoplado' {
            $repo = New-TempRepo -Branches @('feat/x')
            git -C $repo checkout -q --detach | Out-Null
            { Use-CurrentWorkBranch -RepoRoot $repo } | Should Throw 'GitWorkspace'
        }
        It 'aborta si no es un repositorio git' {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            { Use-CurrentWorkBranch -RepoRoot $dir } | Should Throw 'GitWorkspace'
        }
    }

    Context 'Get-ChildGitRepos' {
        It 'lista solo las subcarpetas con .git, ordenadas' {
            $root = New-MultiRepoRoot -Repos @('web', 'api') -Plain @('docs')
            (@(Get-ChildGitRepos -Path $root) -join ',') | Should Be 'api,web'
        }
        It 'devuelve vacio si no hay subrepos' {
            $root = New-MultiRepoRoot -Plain @('docs')
            @(Get-ChildGitRepos -Path $root).Count | Should Be 0
        }
    }

    Context 'Assert-ProjectIsRepo (M7)' {
        It 'no lanza si ProjectPath es un repo git' {
            $repo = New-TempRepo -Branches @('main')
            { Assert-ProjectIsRepo -ProjectPath $repo } | Should Not Throw
        }
        It 'en una raiz multi-repo nombra los repos y sugiere -WorkDir o my-subagent-driven-development' {
            $root = New-MultiRepoRoot -Repos @('web', 'api')
            $msg = Get-ThrownMessage { Assert-ProjectIsRepo -ProjectPath $root }
            $msg.Contains('contiene los repos: api, web') | Should Be $true
            $msg.Contains('-WorkDir') | Should Be $true
            $msg.Contains('my-subagent-driven-development') | Should Be $true
        }
        It 'sin subrepos conserva el mensaje "no es un repositorio git"' {
            $root = New-MultiRepoRoot -Plain @('docs')
            $msg = Get-ThrownMessage { Assert-ProjectIsRepo -ProjectPath $root }
            $msg.Contains('no es un repositorio git') | Should Be $true
            $msg.Contains('contiene los repos') | Should Be $false
        }
    }

    Context 'Resume-WorkBranch (fix 2)' {
        It 'hace checkout de la rama existente y la devuelve' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            Resume-WorkBranch -RepoRoot $repo -Branch 'feat-x' | Should Be 'feat-x'
            Get-CurrentBranch -RepoRoot $repo | Should Be 'feat-x'
        }
        It 'aborta si el working tree esta sucio' {
            $repo = New-TempRepo -Branches @('main', 'feat-x') -Dirty
            { Resume-WorkBranch -RepoRoot $repo -Branch 'feat-x' } | Should Throw 'GitWorkspace'
        }
        It 'aborta si la rama no existe' {
            $repo = New-TempRepo -Branches @('main')
            { Resume-WorkBranch -RepoRoot $repo -Branch 'feat-x' } | Should Throw 'GitWorkspace'
        }
    }

    Context 'Resolve-BootstrapBranchAction (fix 2, solo al arranque)' {
        $coldSame = [pscustomobject]@{ SamePlan = $true; HasProgress = $false; CompletedCount = 0; CurrentLevel = 0 }
        It 'resume: primera iteracion, rama existente y cold-start del mismo plan' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $coldSame -IsFirstIteration $true | Should Be 'resume'
        }
        It 'create sin checkpoint' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $null -IsFirstIteration $true | Should Be 'create'
        }
        It 'create si el checkpoint es de otro plan' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            $other = [pscustomobject]@{ SamePlan = $false; HasProgress = $false; CompletedCount = 0; CurrentLevel = 0 }
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $other -IsFirstIteration $true | Should Be 'create'
        }
        It 'create si el checkpoint tiene avance' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            $progress = [pscustomobject]@{ SamePlan = $true; HasProgress = $true; CompletedCount = 1; CurrentLevel = 1 }
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $progress -IsFirstIteration $true | Should Be 'create'
        }
        It 'create en re-entrada dentro de la misma corrida' {
            $repo = New-TempRepo -Branches @('main', 'feat-x')
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $coldSame -IsFirstIteration $false | Should Be 'create'
        }
        It 'create si la rama no existe' {
            $repo = New-TempRepo -Branches @('main')
            Resolve-BootstrapBranchAction -RepoRoot $repo -Branch 'feat-x' -StateInfo $coldSame -IsFirstIteration $true | Should Be 'create'
        }
    }
}

$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\WorkspaceLayout.psm1') -Force

function Get-ThrownMessage {
    param([scriptblock]$Block)
    try { & $Block; return $null } catch { return $_.Exception.Message }
}

Describe 'WorkspaceLayout' {
    Context 'Resolve-RepoRoot' {
        It 'sin WorkDir devuelve ProjectPath' {
            Resolve-RepoRoot -ProjectPath 'C:\proj' -WorkDir $null | Should Be 'C:\proj'
        }
        It 'con WorkDir une ProjectPath y WorkDir' {
            Resolve-RepoRoot -ProjectPath 'C:\proj' -WorkDir 'demo-web' |
                Should Be (Join-Path 'C:\proj' 'demo-web')
        }
    }

    Context 'Get-EffectivePlansDir' {
        It 'devuelve <RepoRoot>\docs\superpowers\plans' {
            Get-EffectivePlansDir -RepoRoot 'C:\proj\web' |
                Should Be (Join-Path 'C:\proj\web' 'docs\superpowers\plans')
        }
    }

    Context 'Copy-PlanIfMissing' {
        It 'copia el plan al destino cuando no existe y devuelve la ruta destino' {
            $src = Join-Path $TestDrive 'origen\plan.md'
            New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
            Set-Content -LiteralPath $src -Value 'CONTENIDO' -Encoding utf8
            $dstDir = Join-Path $TestDrive 'destino'
            $result = Copy-PlanIfMissing -PlanFilePath $src -DestPlansDir $dstDir
            $result | Should Be (Join-Path $dstDir 'plan.md')
            (Get-Content -LiteralPath $result -Raw).Trim() | Should Be 'CONTENIDO'
        }
        It 'no sobrescribe un plan ya existente en destino' {
            $src = Join-Path $TestDrive 'o2\plan.md'
            New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
            Set-Content -LiteralPath $src -Value 'NUEVO' -Encoding utf8
            $dstDir = Join-Path $TestDrive 'd2'
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dstDir 'plan.md') -Value 'VIEJO' -Encoding utf8
            $result = Copy-PlanIfMissing -PlanFilePath $src -DestPlansDir $dstDir
            (Get-Content -LiteralPath $result -Raw).Trim() | Should Be 'VIEJO'
        }
    }

    Context 'Get-PathRelativeTo' {
        It 'devuelve la ruta relativa a la base' {
            $base = 'C:\proj\web'
            $full = Join-Path $base 'docs\superpowers\plans\p.md'
            Get-PathRelativeTo -BasePath $base -FullPath $full |
                Should Be 'docs\superpowers\plans\p.md'
        }
    }

    Context 'Test-PathWithin' {
        It 'true si la ruta esta dentro de la base, sin distinguir mayusculas' {
            Test-PathWithin -BasePath 'C:\Proj\Repo' -Path 'c:\proj\repo\docs\p.md' | Should Be $true
        }
        It 'true si la ruta es igual a la base, con o sin separador final' {
            Test-PathWithin -BasePath 'C:\proj\repo\' -Path 'C:\proj\repo' | Should Be $true
        }
        It 'false si la ruta esta fuera de la base' {
            Test-PathWithin -BasePath 'C:\proj\repo' -Path 'C:\proj\docs\p.md' | Should Be $false
        }
        It 'false con un prefijo hermano (repo frente a repo2)' {
            Test-PathWithin -BasePath 'C:\proj\repo' -Path 'C:\proj\repo2\p.md' | Should Be $false
        }
        It 'resuelve ..\ antes de comparar' {
            Test-PathWithin -BasePath 'C:\proj\repo' -Path 'C:\proj\repo\..\docs\p.md' | Should Be $false
        }
    }

    Context 'Assert-PlanInsideRepo' {
        It 'no lanza si el plan esta dentro del repo' {
            { Assert-PlanInsideRepo -RepoRoot 'C:\proj\repo' -PlanFilePath 'C:\proj\repo\docs\superpowers\plans\p.md' } | Should Not Throw
        }
        It 'con layout de monorepo sugiere -ProjectPath, -WorkDir y -PlanFile' {
            $mono = Join-Path $TestDrive 'mono'
            $plan = Join-Path $mono 'docs\superpowers\plans\2026-10-06-p.md'
            $repo = Join-Path $mono 'api'
            $msg = Get-ThrownMessage { Assert-PlanInsideRepo -RepoRoot $repo -PlanFilePath $plan }
            $msg.Contains('esta fuera del repo') | Should Be $true
            $msg.Contains("-ProjectPath ""$mono""") | Should Be $true
            $msg.Contains('-WorkDir "api"') | Should Be $true
            $msg.Contains('-PlanFile "2026-10-06-p.md"') | Should Be $true
        }
        It 'fuera del layout de monorepo sugiere mover el plan al repo' {
            $msg = Get-ThrownMessage { Assert-PlanInsideRepo -RepoRoot 'C:\proj\repo' -PlanFilePath 'C:\otros\p.md' }
            $msg.Contains('esta fuera del repo') | Should Be $true
            $msg.Contains('Mueve el plan') | Should Be $true
            $msg.Contains('C:\proj\repo\docs\superpowers\plans\') | Should Be $true
        }
    }
}

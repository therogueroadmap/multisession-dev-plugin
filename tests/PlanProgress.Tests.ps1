$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\PlanProgress.psm1') -Force

Describe 'Get-PlanProgress' {
    $planContent = @'
# Ejemplo Implementation Plan

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 1: Foo | none | 0 |
| Task 2: Bar | none | 0 |
| Task 3: Baz | Task 1 | 1 |
'@

    It 'calcula totalLevels y currentLevel cuando ambos archivos son validos' {
        $planPath = Join-Path $TestDrive 'plan.md'
        Set-Content -LiteralPath $planPath -Value $planContent
        $statePath = Join-Path $TestDrive '.controller-state.json'
        Set-Content -LiteralPath $statePath -Value '{"completed_levels": [0], "current_level": 1, "tasks": {}}'

        $progress = Get-PlanProgress -PlanFilePath $planPath -ControllerStatePath $statePath
        $progress.TotalLevels | Should Be 2
        $progress.CurrentLevel | Should Be 1
    }

    It 'ignora tablas ajenas al Dependency Map cuya ultima celda es numerica' {
        $content = @'
# Plan

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 1: Foo | none | 0 |
| Task 2: Bar | Task 1 | 1 |

## Decisiones

| # | Decision | Tarea |
|---|---|---|
| 1 | Algo | 21 |
| 2 | Otro | 9 |
'@
        $planPath = Join-Path $TestDrive 'plan-decisiones.md'
        Set-Content -LiteralPath $planPath -Value $content

        $progress = Get-PlanProgress -PlanFilePath $planPath -ControllerStatePath $null
        $progress.TotalLevels | Should Be 2
        ($progress.LevelTaskCounts -join ',') | Should Be '1,1'
    }

    It 'devuelve TotalLevels $null si el archivo del plan no existe' {
        $progress = Get-PlanProgress -PlanFilePath (Join-Path $TestDrive 'no-existe.md') -ControllerStatePath $null
        $progress.TotalLevels | Should Be $null
    }

    It 'devuelve CurrentLevel $null si el controller-state no existe' {
        $planPath = Join-Path $TestDrive 'plan-solo.md'
        Set-Content -LiteralPath $planPath -Value $planContent
        $progress = Get-PlanProgress -PlanFilePath $planPath -ControllerStatePath (Join-Path $TestDrive 'no-existe.json')
        $progress.CurrentLevel | Should Be $null
    }

    It 'devuelve CurrentLevel $null si el controller-state tiene JSON invalido, sin lanzar excepcion' {
        $statePath = Join-Path $TestDrive 'invalido.json'
        Set-Content -LiteralPath $statePath -Value '{ esto no es json valido'
        { Get-PlanProgress -PlanFilePath $null -ControllerStatePath $statePath } | Should Not Throw
        $progress = Get-PlanProgress -PlanFilePath $null -ControllerStatePath $statePath
        $progress.CurrentLevel | Should Be $null
    }

    It 'calcula levelTaskCounts contando tareas por nivel' {
        $planPath = Join-Path $TestDrive 'plan-counts.md'
        Set-Content -LiteralPath $planPath -Value $planContent
        $progress = Get-PlanProgress -PlanFilePath $planPath -ControllerStatePath $null
        $progress.LevelTaskCounts.Count | Should Be 2
        $progress.LevelTaskCounts[0] | Should Be 2
        $progress.LevelTaskCounts[1] | Should Be 1
    }

    It 'devuelve LevelTaskCounts $null si el archivo del plan no existe' {
        $progress = Get-PlanProgress -PlanFilePath (Join-Path $TestDrive 'no-existe-counts.md') -ControllerStatePath $null
        $progress.LevelTaskCounts | Should Be $null
    }

    It 'devuelve TotalLevels y LevelTaskCounts $null si el parseo del plan lanza una excepcion' {
        $dirComoArchivo = Join-Path $TestDrive 'plan-invalido-es-directorio'
        New-Item -ItemType Directory -Path $dirComoArchivo -Force | Out-Null
        { Get-PlanProgress -PlanFilePath $dirComoArchivo -ControllerStatePath $null } | Should Not Throw
        $progress = Get-PlanProgress -PlanFilePath $dirComoArchivo -ControllerStatePath $null
        $progress.TotalLevels | Should Be $null
        $progress.LevelTaskCounts | Should Be $null
    }
}

Describe 'Get-PlanBootstrapDecision' {
    $planTresNiveles = @'
# Ejemplo Implementation Plan

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 1: Foo | none | 0 |
| Task 2: Bar | none | 0 |
| Task 3: Baz | Task 1 | 1 |
| Task 4: Qux | Task 3 | 2 |
'@

    It 'Mode continue si PlanFilePath es null o vacio' {
        $decision = Get-PlanBootstrapDecision -PlanFilePath $null -ControllerStatePath (Join-Path $TestDrive '.controller-state.json') -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'continue'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should BeNullOrEmpty
        $decision.TotalLevels | Should BeNullOrEmpty

        $decision2 = Get-PlanBootstrapDecision -PlanFilePath '' -ControllerStatePath (Join-Path $TestDrive '.controller-state.json') -FinalReviewMarkerPath $null
        $decision2.Mode | Should Be 'continue'
    }

    It 'Mode bootstrap si no existe controller-state.json' {
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath (Join-Path $TestDrive 'no-existe.json') -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'bootstrap'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should BeNullOrEmpty
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode bootstrap sin lanzar excepcion si el controller-state es JSON invalido' {
        $statePath = Join-Path $TestDrive 'invalido-bootstrap.json'
        Set-Content -LiteralPath $statePath -Value '{ esto no es json valido'
        { Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null } | Should Not Throw
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'bootstrap'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should BeNullOrEmpty
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode bootstrap en cold-start aunque el plan coincida' {
        $statePath = Join-Path $TestDrive 'cold-start.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [], "current_level": 0, "tasks": {}}'
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'bootstrap'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should Be 0
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode bootstrap si el plan del estado es distinto (por nombre de archivo)' {
        $statePath = Join-Path $TestDrive 'otro-plan.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "docs/plans/otro-plan.md", "completed_levels": [0], "current_level": 1, "tasks": {}}'
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'bootstrap'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should Be 1
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode bootstrap sin lanzar excepcion si current_level no es numerico' {
        $statePath = Join-Path $TestDrive 'current-level-invalido.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [], "current_level": "no-es-un-numero", "tasks": {}}'
        { Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null } | Should Not Throw
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'bootstrap'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should BeNullOrEmpty
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode continue si hay avance parcial sobre el mismo plan (completed < total)' {
        $planPath = Join-Path $TestDrive 'feature-plan.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'avance-parcial.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [0, 1], "current_level": 2, "tasks": {}}'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath (Join-Path $TestDrive '.final-review-feature-plan.md')
        $decision.Mode | Should Be 'continue'
    }

    It 'Mode continue si el total de niveles es indeterminado (plan no encontrado en disco)' {
        $statePath = Join-Path $TestDrive 'avance-sin-plan.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [0, 1], "current_level": 2, "tasks": {}}'
        $decision = Get-PlanBootstrapDecision -PlanFilePath 'feature-plan.md' -ControllerStatePath $statePath -FinalReviewMarkerPath $null
        $decision.Mode | Should Be 'continue'
        ($decision.PSObject.Properties.Name -join ',') | Should Be 'Mode,Reason,CompletedBy,CompletedCount,TotalLevels'
        $decision.CompletedBy | Should BeNullOrEmpty
        $decision.CompletedCount | Should Be 2
        $decision.TotalLevels | Should BeNullOrEmpty
    }

    It 'Mode close si todos los niveles estan completos y no existe el marcador' {
        $planPath = Join-Path $TestDrive 'feature-plan.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'niveles-completos.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [0, 1, 2], "current_level": 3, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-feature-plan.md'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'close'
    }

    It 'Mode done si todos los niveles estan completos y existe el marcador' {
        $planPath = Join-Path $TestDrive 'feature-plan.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'niveles-completos-done.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "feature-plan.md", "completed_levels": [0, 1, 2], "current_level": 3, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-feature-plan.md'
        Set-Content -LiteralPath $markerPath -Value '# findings'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'done'
    }

    It 'D2: current_level >= total con completed_levels corto y sin marcador: close por current_level' {
        $planPath = Join-Path $TestDrive 'd2-close.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'd2-close.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "d2-close.md", "completed_levels": [0, 1], "current_level": 3, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-d2-close.md'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'close'
        $decision.CompletedBy | Should Be 'current_level'
        $decision.CompletedCount | Should Be 2
        $decision.TotalLevels | Should Be 3
        $decision.Reason | Should Be 'plan completo segun current_level, cierre pendiente'
    }

    It 'D2: current_level >= total con completed_levels corto y con marcador: done por current_level' {
        $planPath = Join-Path $TestDrive 'd2-done.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'd2-done.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "d2-done.md", "completed_levels": [0, 1], "current_level": 3, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-d2-done.md'
        Set-Content -LiteralPath $markerPath -Value '# findings'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'done'
        $decision.CompletedBy | Should Be 'current_level'
        $decision.CompletedCount | Should Be 2
        $decision.TotalLevels | Should Be 3
    }

    It 'D2: completed_levels completo gana: CompletedBy completed_levels' {
        $planPath = Join-Path $TestDrive 'd2-gana.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'd2-gana.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "d2-gana.md", "completed_levels": [0, 1, 2], "current_level": 3, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-d2-gana.md'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'close'
        $decision.CompletedBy | Should Be 'completed_levels'
        $decision.CompletedCount | Should Be 3
        $decision.Reason | Should Be 'niveles completos, cierre pendiente'
    }

    It 'D2: current_level por encima del total tambien completa el plan' {
        $planPath = Join-Path $TestDrive 'd2-encima.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'd2-encima.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "d2-encima.md", "completed_levels": [0], "current_level": 5, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-d2-encima.md'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'close'
        $decision.CompletedBy | Should Be 'current_level'
    }

    It 'D2: sin plan completo CompletedBy es nulo' {
        $planPath = Join-Path $TestDrive 'd2-nulo.md'
        Set-Content -LiteralPath $planPath -Value $planTresNiveles
        $statePath = Join-Path $TestDrive 'd2-nulo.json'
        Set-Content -LiteralPath $statePath -Value '{"plan": "d2-nulo.md", "completed_levels": [0, 1], "current_level": 2, "tasks": {}}'
        $markerPath = Join-Path $TestDrive '.final-review-d2-nulo.md'
        $decision = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath $statePath -FinalReviewMarkerPath $markerPath
        $decision.Mode | Should Be 'continue'
        $decision.CompletedBy | Should BeNullOrEmpty

        $decision2 = Get-PlanBootstrapDecision -PlanFilePath $planPath -ControllerStatePath (Join-Path $TestDrive 'no-existe.json') -FinalReviewMarkerPath $markerPath
        $decision2.Mode | Should Be 'bootstrap'
        $decision2.CompletedBy | Should BeNullOrEmpty
    }
}


function New-StateFile {
    param([string]$Dir, [string]$Json)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $p = Join-Path $Dir '.controller-state.json'
    Set-Content -LiteralPath $p -Value $Json
    return $p
}

Describe 'Get-ControllerStateInfo' {
    It '$null si el checkpoint no existe' {
        Get-ControllerStateInfo -ControllerStatePath (Join-Path $TestDrive 'no-existe.json') -PlanFilePath 'C:\x\2026-10-06-p.md' | Should BeNullOrEmpty
    }
    It '$null si el JSON es ilegible' {
        $p = New-StateFile -Dir (Join-Path $TestDrive 'ilegible') -Json '{no es json'
        Get-ControllerStateInfo -ControllerStatePath $p -PlanFilePath 'C:\x\2026-10-06-p.md' | Should BeNullOrEmpty
    }
    It 'cold-start del mismo plan: SamePlan y sin avance' {
        $p = New-StateFile -Dir (Join-Path $TestDrive 'cold') -Json '{"plan": "docs/superpowers/plans/2026-10-06-p.md", "completed_levels": [], "current_level": 0}'
        $info = Get-ControllerStateInfo -ControllerStatePath $p -PlanFilePath 'C:\x\2026-10-06-p.md'
        $info.SamePlan | Should Be $true
        $info.HasProgress | Should Be $false
    }
    It 'con avance: HasProgress, CompletedCount y CurrentLevel' {
        $p = New-StateFile -Dir (Join-Path $TestDrive 'avance') -Json '{"plan": "2026-10-06-p.md", "completed_levels": [0, 1], "current_level": 2}'
        $info = Get-ControllerStateInfo -ControllerStatePath $p -PlanFilePath 'C:\x\2026-10-06-p.md'
        $info.HasProgress | Should Be $true
        $info.CompletedCount | Should Be 2
        $info.CurrentLevel | Should Be 2
    }
    It 'otro plan: SamePlan falso' {
        $p = New-StateFile -Dir (Join-Path $TestDrive 'otro') -Json '{"plan": "2026-09-30-ola-previa.md", "completed_levels": [0], "current_level": 1}'
        $info = Get-ControllerStateInfo -ControllerStatePath $p -PlanFilePath 'C:\x\2026-10-06-p.md'
        $info.SamePlan | Should Be $false
    }
}

Describe 'Find-StrayControllerState' {
    It 'devuelve la ruta del checkpoint con avance del plan en la raiz' {
        $root = Join-Path $TestDrive 'stray1'
        $rootPlans = Join-Path $root 'docs\superpowers\plans'
        $effective = Join-Path $root 'api\docs\superpowers\plans'
        $expected = New-StateFile -Dir $rootPlans -Json '{"plan": "2026-10-06-p.md", "completed_levels": [0], "current_level": 1}'
        Find-StrayControllerState -PlanFilePath (Join-Path $effective '2026-10-06-p.md') -EffectivePlansDir $effective -CandidateDirs @($rootPlans, $rootPlans) |
            Should Be $expected
    }
    It 'ignora un candidato que es la carpeta efectiva y los candidatos vacios' {
        $effective = Join-Path $TestDrive 'stray2\api\docs\superpowers\plans'
        New-StateFile -Dir $effective -Json '{"plan": "2026-10-06-p.md", "completed_levels": [0], "current_level": 1}' | Out-Null
        Find-StrayControllerState -PlanFilePath (Join-Path $effective '2026-10-06-p.md') -EffectivePlansDir $effective -CandidateDirs @(($effective + '\'), $null, '') |
            Should BeNullOrEmpty
    }
    It 'ignora un checkpoint de otro plan' {
        $root = Join-Path $TestDrive 'stray3'
        $rootPlans = Join-Path $root 'docs\superpowers\plans'
        $effective = Join-Path $root 'api\docs\superpowers\plans'
        New-StateFile -Dir $rootPlans -Json '{"plan": "2026-09-30-ola-previa.md", "completed_levels": [0, 1], "current_level": 2}' | Out-Null
        Find-StrayControllerState -PlanFilePath (Join-Path $effective '2026-10-06-p.md') -EffectivePlansDir $effective -CandidateDirs @($rootPlans) |
            Should BeNullOrEmpty
    }
    It 'ignora un checkpoint cold-start del plan' {
        $root = Join-Path $TestDrive 'stray4'
        $rootPlans = Join-Path $root 'docs\superpowers\plans'
        $effective = Join-Path $root 'api\docs\superpowers\plans'
        New-StateFile -Dir $rootPlans -Json '{"plan": "2026-10-06-p.md", "completed_levels": [], "current_level": 0}' | Out-Null
        Find-StrayControllerState -PlanFilePath (Join-Path $effective '2026-10-06-p.md') -EffectivePlansDir $effective -CandidateDirs @($rootPlans) |
            Should BeNullOrEmpty
    }
}

Describe 'Compatibilidad: reanudacion con -ProjectPath raiz -WorkDir repo -PlanFile nombre' {
    It 'checkpoint actual en la carpeta efectiva: continue y sin checkpoint perdido, aunque la raiz guarde olas previas' {
        $planContent = @'
# Ejemplo Implementation Plan

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 1: Foo | none | 0 |
| Task 2: Bar | Task 1 | 1 |
'@
        $root = Join-Path $TestDrive 'compat'
        $rootPlans = Join-Path $root 'docs\superpowers\plans'
        $effective = Join-Path $root 'api\docs\superpowers\plans'
        New-Item -ItemType Directory -Path $rootPlans -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $rootPlans '2026-10-06-p.md') -Value $planContent
        New-StateFile -Dir $rootPlans -Json '{"plan": "2026-09-30-ola-previa.md", "completed_levels": [0, 1, 2], "current_level": 3}' | Out-Null
        $effState = New-StateFile -Dir $effective -Json '{"plan": "docs/superpowers/plans/2026-10-06-p.md", "completed_levels": [0], "current_level": 1, "tasks": {}}'
        $effPlan = Join-Path $effective '2026-10-06-p.md'
        Set-Content -LiteralPath $effPlan -Value $planContent

        $decision = Get-PlanBootstrapDecision -PlanFilePath $effPlan -ControllerStatePath $effState -FinalReviewMarkerPath (Join-Path $effective '.final-review-2026-10-06-p.md')
        $decision.Mode | Should Be 'continue'
        Find-StrayControllerState -PlanFilePath $effPlan -EffectivePlansDir $effective -CandidateDirs @($rootPlans, $rootPlans) |
            Should BeNullOrEmpty
    }
}

Describe 'Test-CheckpointAdvanced' {
    function New-Info {
        param([bool]$SamePlan, [int]$Completed)
        return [pscustomobject]@{ SamePlan = $SamePlan; HasProgress = ($Completed -gt 0); CompletedCount = $Completed; CurrentLevel = $Completed }
    }

    It 'Before nulo y After del mismo plan con un nivel: avanza' {
        Test-CheckpointAdvanced -Before $null -After (New-Info -SamePlan $true -Completed 1) | Should Be $true
    }
    It 'de 1 a 2 niveles completados: avanza' {
        Test-CheckpointAdvanced -Before (New-Info -SamePlan $true -Completed 1) -After (New-Info -SamePlan $true -Completed 2) | Should Be $true
    }
    It 'mismo conteo antes y despues: no avanza' {
        Test-CheckpointAdvanced -Before (New-Info -SamePlan $true -Completed 1) -After (New-Info -SamePlan $true -Completed 1) | Should Be $false
    }
    It 'After nulo (checkpoint ausente o ilegible): no avanza' {
        Test-CheckpointAdvanced -Before (New-Info -SamePlan $true -Completed 1) -After $null | Should Be $false
    }
    It 'After de otro plan: no avanza' {
        Test-CheckpointAdvanced -Before $null -After (New-Info -SamePlan $false -Completed 3) | Should Be $false
    }
    It 'Before de otro plan con 3 y After del mismo plan con 1: avanza (cuenta desde 0)' {
        Test-CheckpointAdvanced -Before (New-Info -SamePlan $false -Completed 3) -After (New-Info -SamePlan $true -Completed 1) | Should Be $true
    }
}

Describe 'Compatibilidad M9: avance medido sobre un checkpoint en formato viejo' {
    It 'plan absoluto y sin tasks: sin tocar el archivo no avanza; con un nivel mas avanza' {
        $dir = Join-Path $TestDrive 'compat-avance'
        $plan = Join-Path $dir '2026-09-20-viejo.md'
        $state = New-StateFile -Dir $dir -Json ('{"plan": "' + $plan.Replace('\', '\\') + '", "completed_levels": [0], "current_level": 1}')
        Set-Content -LiteralPath $plan -Value '# plan'

        $before = Get-ControllerStateInfo -ControllerStatePath $state -PlanFilePath $plan
        $before.SamePlan | Should Be $true
        $after = Get-ControllerStateInfo -ControllerStatePath $state -PlanFilePath $plan
        Test-CheckpointAdvanced -Before $before -After $after | Should Be $false

        Set-Content -LiteralPath $state -Value ('{"plan": "' + $plan.Replace('\', '\\') + '", "completed_levels": [0, 1], "current_level": 2}')
        $after2 = Get-ControllerStateInfo -ControllerStatePath $state -PlanFilePath $plan
        Test-CheckpointAdvanced -Before $before -After $after2 | Should Be $true
    }
}

Describe 'Get-SessionBudget (Fase 4, M12)' {
    It 'plan nuevo de 4 niveles con 1 reintento: (4 + cierre) x 2 = 10' {
        Get-SessionBudget -TotalLevels 4 -CompletedLevels 0 -FinalReviewDone $false -NoProgressRetries 1 | Should Be 10
    }
    It 'compatibilidad 3 (reanudacion): con 2 niveles completados cuenta solo lo pendiente = 6' {
        Get-SessionBudget -TotalLevels 4 -CompletedLevels 2 -FinalReviewDone $false -NoProgressRetries 1 | Should Be 6
    }
    It 'niveles completos y cierre hecho: minimo 1 paso = 2' {
        Get-SessionBudget -TotalLevels 4 -CompletedLevels 4 -FinalReviewDone $true -NoProgressRetries 1 | Should Be 2
    }
    It 'sin reintentos: igual a los pasos pendientes' {
        Get-SessionBudget -TotalLevels 3 -CompletedLevels 0 -FinalReviewDone $false -NoProgressRetries 0 | Should Be 4
    }
    It 'con 2 reintentos: pasos x 3' {
        Get-SessionBudget -TotalLevels 3 -CompletedLevels 1 -FinalReviewDone $false -NoProgressRetries 2 | Should Be 9
    }
    It 'completados por encima del total no da negativo' {
        Get-SessionBudget -TotalLevels 2 -CompletedLevels 5 -FinalReviewDone $false -NoProgressRetries 1 | Should Be 2
    }
    It 'TotalLevels nulo o 0: devuelve el fallback' {
        Get-SessionBudget -TotalLevels $null -CompletedLevels 0 -FinalReviewDone $false -NoProgressRetries 1 | Should Be 30
        Get-SessionBudget -TotalLevels 0 -CompletedLevels 0 -FinalReviewDone $false -NoProgressRetries 1 | Should Be 30
        Get-SessionBudget -TotalLevels $null -CompletedLevels 0 -FinalReviewDone $false -NoProgressRetries 1 -Fallback 12 | Should Be 12
    }
}

Describe 'Get-FinalReviewPublishName' {
    It 'publica solo nombres que el servidor acepta' {
        # Acentos armados con [char] para no depender de la codificacion del archivo.
        $ac = 'dise' + [char]0xF1 + 'o-' + [char]0xF1 + 'and' + [char]0xFA
        Get-FinalReviewPublishName -Path '.final-review-2026-10-27-falso.md' | Should Be '.final-review-2026-10-27-falso.md'
        $r = Get-FinalReviewPublishName -Path ('D:\x\docs\superpowers\plans\.final-review-' + $ac + '.md')
        $r | Should Be ('.final-review-' + $ac + '.md')
        Get-FinalReviewPublishName -Path '.final-review-a b.md' | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path 'final-review-x.md' | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path '.final-review-x.md.txt' | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path ('.final-review-n' + [char]0x0303 + '.md') | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path ('.final-review-a' + [char]0x203F + 'b.md') | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path ".final-review-a.md`n" | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path $null | Should BeNullOrEmpty
        Get-FinalReviewPublishName -Path '' | Should BeNullOrEmpty
    }
}

$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\PlanTasks.psm1') -Force

Describe 'PlanTasks (Ola 3: bloque tasks del status)' {
    $fixtureDir = Join-Path $moduleRoot 'tests\fixtures\plan-tasks'

    # El checkpoint real nombra al plan 2026-10-28-dashboard-ola-2c.md: se copia el plan
    # fixture con ese nombre para que cuente como el mismo plan.
    function Get-FixtureBlock {
        $plan = Join-Path $TestDrive '2026-10-28-dashboard-ola-2c.md'
        Copy-Item -LiteralPath (Join-Path $fixtureDir 'plan-ola-2c-map.md') -Destination $plan -Force
        return Get-PlanTasks -PlanFilePath $plan -ControllerStatePath (Join-Path $fixtureDir 'controller-state-ola-2c.json')
    }

    # Escribe un plan con Dependency Map en $TestDrive y devuelve su ruta.
    function New-SynthPlan {
        param([string[]]$Rows, [string]$Name = 'plan.md')
        $path = Join-Path $TestDrive $Name
        $lines = @('# Plan', '', '## Dependency Map', '', '| Task | Depends On | Level |', '|------|-----------|-------|') + $Rows + @('', '## File Structure', '')
        Set-Content -LiteralPath $path -Value ($lines -join "`n") -Encoding utf8
        return $path
    }

    function New-SynthState {
        param($Tasks, [string]$PlanName = 'plan.md', [string]$Name = 'state.json')
        $path = Join-Path $TestDrive $Name
        $state = [ordered]@{ plan = $PlanName; completed_levels = @(); current_level = 0; tasks = $Tasks }
        Set-Content -LiteralPath $path -Value ($state | ConvertTo-Json -Depth 6) -Encoding utf8
        return $path
    }

    It 'fixture real: 5 tareas con id, titulo y nivel del Dependency Map' {
        $block = Get-FixtureBlock
        $items = @($block.items)
        $items.Count | Should Be 5
        (@($items | ForEach-Object { $_.id }) -join '|') | Should Be 'Task 0|Task 1|Task 2|Task 3|Task 4'
        $items[1].title | Should Be 'Servidor: acciones `answer`, `retry` y `open` en `control_channel.py`'
        (@($items | ForEach-Object { $_.level }) -join ',') | Should Be '0,0,0,1,1'
    }

    It 'fixture real: estado, commit y fixCommits cruzados con el checkpoint' {
        $items = @((Get-FixtureBlock).items)
        foreach ($i in $items) { $i.status | Should Be 'done' }
        (@($items | ForEach-Object { $_.commit }) -join ',') | Should Be '7f01ae8,871ae07,01279f1,ace68d8,7c92197'
        (@($items[3].fixCommits) -join ',') | Should Be '2e2ff1a'
        (@($items[4].fixCommits) -join ',') | Should Be 'defa0e7'
        @($items[0].fixCommits).Count | Should Be 0
    }

    It 'clave de cruce: Task 1, T1, T1: nombre, task  1 y TASK 1 son la misma' {
        foreach ($t in @('Task 1', 'T1', 'T1: nombre', 'task  1', ' TASK 1 ', '**Task 1**', '`Task 1`')) {
            ConvertTo-PlanTaskKey -Text $t | Should Be '1'
        }
    }

    It 'clave de cruce: Task T0a, T0a y TASK 0A dan 0a; Task 10 no cruza con Task 1' {
        foreach ($t in @('Task T0a', 'T0a', 'TASK 0A')) {
            ConvertTo-PlanTaskKey -Text $t | Should Be '0a'
        }
        ConvertTo-PlanTaskKey -Text 'Task 10' | Should Be '10'
        (ConvertTo-PlanTaskKey -Text 'Task 10') -eq (ConvertTo-PlanTaskKey -Text 'Task 1') | Should Be $false
        ConvertTo-PlanTaskKey -Text $null | Should Be ''
        ConvertTo-PlanTaskKey -Text '' | Should Be ''
        ConvertTo-PlanTaskKey -Text '**' | Should Be ''
    }

    It 'clave de cruce: plan con T1 y checkpoint con Task 1 cruzan' {
        $plan = New-SynthPlan -Rows @('| T1: Foo | none | 0 |')
        $state = New-SynthState -Tasks ([ordered]@{ 'Task 1' = [ordered]@{ status = 'DONE'; commit = 'abc1234' } })
        $block = Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $state
        $block.items[0].id | Should Be 'T1'
        $block.items[0].title | Should Be 'Foo'
        $block.items[0].status | Should Be 'done'
        $block.items[0].commit | Should Be 'abc1234'
    }

    It 'estados: done, in_progress, pending y blocked sin distinguir mayusculas' {
        # Pares (entrada, esperado): un hashtable no admite claves que solo difieren en mayusculas.
        $pairs = @(
            @('DONE', 'done'), @('done', 'done'), @(' Done ', 'done'), @('DONE_WITH_CONCERNS', 'done'), @('complete', 'done'), @('COMPLETED', 'done'),
            @('IN_PROGRESS', 'in_progress'), @('in-progress', 'in_progress'), @('Running', 'in_progress'),
            @('PENDING', 'pending'), @('pending', 'pending'),
            @('BLOCKED', 'blocked'), @('needs_context', 'blocked'), @('Failed', 'blocked')
        )
        foreach ($pair in $pairs) {
            ConvertTo-PlanTaskStatus -Value $pair[0] | Should Be $pair[1]
        }
    }

    It 'estado desconocido se publica tal cual recortado a 40 y vacio vale pending' {
        ConvertTo-PlanTaskStatus -Value '  weird  ' | Should Be 'weird'
        $long = 'x' * 50
        (ConvertTo-PlanTaskStatus -Value $long).Length | Should Be 40
        ConvertTo-PlanTaskStatus -Value '' | Should Be 'pending'
        ConvertTo-PlanTaskStatus -Value '   ' | Should Be 'pending'
        ConvertTo-PlanTaskStatus -Value $null | Should Be 'pending'
        ConvertTo-PlanTaskStatus -Value 5 | Should Be 'pending'
        ConvertTo-PlanTaskStatus -Value @('DONE') | Should Be 'pending'
    }

    It 'tarea sin entrada en el checkpoint vale pending sin commit' {
        $plan = New-SynthPlan -Rows @('| Task 1: Foo | none | 0 |', '| Task 2: Bar | none | 1 |')
        $state = New-SynthState -Tasks ([ordered]@{ 'Task 1' = [ordered]@{ status = 'DONE'; commit = 'abc1234' } })
        $items = @((Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $state).items)
        $items[0].status | Should Be 'done'
        $items[1].status | Should Be 'pending'
        $items[1].commit | Should BeNullOrEmpty
        @($items[1].fixCommits).Count | Should Be 0
    }

    It 'hashes invalidos se descartan y fixCommits se recorta a 10' {
        $plan = New-SynthPlan -Rows @('| Task 1: A | none | 0 |', '| Task 2: B | none | 0 |', '| Task 3: C | none | 0 |', '| Task 4: D | none | 0 |', '| Task 5: E | none | 0 |')
        $fix = @('a000001', 'zzzzzzz') + @(2..12 | ForEach-Object { 'a' + $_.ToString('000000') })
        $state = New-SynthState -Tasks ([ordered]@{
                'Task 1' = [ordered]@{ status = 'DONE'; commit = 'xyz' }
                'Task 2' = [ordered]@{ status = 'DONE'; commit = 'abc12' }
                'Task 3' = [ordered]@{ status = 'DONE'; commit = ('a' * 41) }
                'Task 4' = [ordered]@{ status = 'DONE'; commit = ('A' * 40); fix_commits = $fix }
                'Task 5' = [ordered]@{ status = 'DONE'; commit = 'abc1234' }
            })
        $items = @((Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $state).items)
        $items[0].commit | Should BeNullOrEmpty
        $items[1].commit | Should BeNullOrEmpty
        $items[2].commit | Should BeNullOrEmpty
        $items[3].commit | Should Be ('A' * 40)
        $items[4].commit | Should Be 'abc1234'
        $expected = @(1..10 | ForEach-Object { 'a' + $_.ToString('000000') })
        @($items[3].fixCommits).Count | Should Be 10
        (@($items[3].fixCommits) -join ',') | Should Be ($expected -join ',')
    }

    It 'mas de 100 tareas: se publican 100 y truncated true; con 100 o menos no hay truncated' {
        $rows101 = @(1..101 | ForEach-Object { "| Task $_`: T$_ | none | 0 |" })
        $block = Get-PlanTasks -PlanFilePath (New-SynthPlan -Rows $rows101) -ControllerStatePath $null
        @($block.items).Count | Should Be 100
        $block.truncated | Should Be $true
        $block.items[99].id | Should Be 'Task 100'

        $rows100 = @(1..100 | ForEach-Object { "| Task $_`: T$_ | none | 0 |" })
        $block2 = Get-PlanTasks -PlanFilePath (New-SynthPlan -Rows $rows100) -ControllerStatePath $null
        @($block2.items).Count | Should Be 100
        (@($block2.Keys) -contains 'truncated') | Should Be $false
    }

    It 'title se recorta a 200 caracteres' {
        $long = 'a' * 300
        $block = Get-PlanTasks -PlanFilePath (New-SynthPlan -Rows @("| Task 1: $long | none | 0 |")) -ControllerStatePath $null
        $block.items[0].title.Length | Should Be 200

        # Un par sustituto en el limite no se parte: se corta en 199.
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $edge = ('a' * 199) + $emoji + 'bbb'
        $block2 = Get-PlanTasks -PlanFilePath (New-SynthPlan -Rows @("| Task 1: $edge | none | 0 |")) -ControllerStatePath $null
        $block2.items[0].title.Length | Should Be 199
        [char]::IsHighSurrogate($block2.items[0].title[198]) | Should Be $false
    }

    It 'filas invalidas se saltan: encabezado, separador, sin nivel y nivel no numerico' {
        $rows = @(
            '| Task 8: sin nivel | none | |',
            '| Task 9: nivel alto | none | alto |',
            '| | none | 2 |',
            '| ** | none | 3 |',
            '| Task 3: valida | none | 1 |'
        )
        $block = Get-PlanTasks -PlanFilePath (New-SynthPlan -Rows $rows) -ControllerStatePath $null
        @($block.items).Count | Should Be 1
        $block.items[0].id | Should Be 'Task 3'
        $block.items[0].level | Should Be 1
    }

    It 'sin Dependency Map, sin filas validas o sin plan devuelve null' {
        $sinMapa = Join-Path $TestDrive 'sin-mapa.md'
        Set-Content -LiteralPath $sinMapa -Value "# Plan`n`n| Task 1: Foo | none | 0 |`n" -Encoding utf8
        Get-PlanTasks -PlanFilePath $sinMapa -ControllerStatePath $null | Should BeNullOrEmpty

        $sinFilas = Join-Path $TestDrive 'sin-filas.md'
        Set-Content -LiteralPath $sinFilas -Value "# Plan`n`n## Dependency Map`n`n| Task | Depends On | Level |`n|---|---|---|`n" -Encoding utf8
        Get-PlanTasks -PlanFilePath $sinFilas -ControllerStatePath $null | Should BeNullOrEmpty

        Get-PlanTasks -PlanFilePath (Join-Path $TestDrive 'no-existe.md') -ControllerStatePath $null | Should BeNullOrEmpty
        Get-PlanTasks -PlanFilePath '' -ControllerStatePath $null | Should BeNullOrEmpty
        Get-PlanTasks -PlanFilePath $null -ControllerStatePath $null | Should BeNullOrEmpty
    }

    It 'checkpoint ausente o de otro plan: todas pending; checkpoint ilegible: null' {
        $plan = New-SynthPlan -Rows @('| Task 1: Foo | none | 0 |', '| Task 2: Bar | none | 1 |')

        $ausente = Get-PlanTasks -PlanFilePath $plan -ControllerStatePath (Join-Path $TestDrive 'no-existe.json')
        @($ausente.items).Count | Should Be 2
        $ausente.items[0].status | Should Be 'pending'
        $sinRuta = Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $null
        $sinRuta.items[1].status | Should Be 'pending'

        $otro = New-SynthState -Tasks ([ordered]@{ 'Task 1' = [ordered]@{ status = 'DONE'; commit = 'abc1234' } }) -PlanName 'otro-plan.md' -Name 'otro.json'
        $deOtro = Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $otro
        $deOtro.items[0].status | Should Be 'pending'
        $deOtro.items[0].commit | Should BeNullOrEmpty

        $roto = Join-Path $TestDrive 'roto.json'
        Set-Content -LiteralPath $roto -Value '{ esto no es json' -Encoding utf8
        Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $roto | Should BeNullOrEmpty

        # Una tarea sin fix serializa fixCommits como arreglo JSON vacio; con uno, arreglo de uno.
        $json = ConvertTo-Json -InputObject $ausente -Depth 6 -Compress
        $json | Should Match '"fixCommits":\[\]'
        $uno = New-SynthState -Tasks ([ordered]@{ 'Task 1' = [ordered]@{ status = 'DONE'; commit = 'abc1234'; fix_commits = @('def5678') } }) -Name 'uno.json'
        $jsonUno = ConvertTo-Json -InputObject (Get-PlanTasks -PlanFilePath $plan -ControllerStatePath $uno) -Depth 6 -Compress
        $jsonUno | Should Match '"fixCommits":\["def5678"\]'
    }

    It 'el bloque trae items y updatedAt en ese orden y cada item las 6 claves del contrato' {
        $block = Get-FixtureBlock
        (@($block.Keys) -join ',') | Should Be 'items,updatedAt'
        (@($block.items[0].Keys) -join ',') | Should Be 'id,title,level,status,commit,fixCommits'
        ($block.updatedAt -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') | Should Be $true
    }
}

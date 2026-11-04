$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverProfile.psm1') -Force

Describe 'DriverProfile' {
    $profilePath = Join-Path $moduleRoot 'scripts\profiles\plan.settings.json'

    $expectedAllow = @(
        'Read', 'Glob', 'Grep', 'Edit', 'Write', 'NotebookEdit', 'TodoWrite', 'Skill', 'Agent',
        'Bash', 'PowerShell', 'WebFetch', 'WebSearch', 'ToolSearch', 'Monitor', 'TaskStop', 'TaskOutput'
    )

    $listS = @(
        'git push',
        'git push *',
        'git -C * push*',
        'gh',
        'gh *',
        'git merge',
        'git merge *',
        'git -C * merge',
        'git -C * merge *',
        'git checkout master*',
        'git checkout main*',
        'git checkout develop*',
        'git switch master*',
        'git switch main*',
        'git switch develop*',
        'git -C * checkout master*',
        'git -C * checkout main*',
        'git -C * checkout develop*',
        'git -C * switch master*',
        'git -C * switch main*',
        'git -C * switch develop*',
        'git reset --hard*',
        'git -C * reset --hard*',
        'git branch -D*',
        'git branch -d*',
        'git -C * branch -D*',
        'git -C * branch -d*',
        'git -C ..*',
        'git -C "..*',
        'git --git-dir*',
        'git * --git-dir*',
        'git --work-tree*',
        'git * --work-tree*',
        'git remote add*',
        'git remote set-url*',
        'git -C * remote add*',
        'git -C * remote set-url*'
    )

    $mcpServers = @(
        'mcp__Atlassian',
        'mcp__plugin_engineering_atlassian',
        'mcp__claude_ai_Atlassian_Rovo',
        'mcp__plugin_render_render',
        'mcp__plugin_vercel_vercel'
    )

    # Escribe un perfil en $TestDrive y devuelve su ruta.
    function New-ProfileFile {
        param([string]$Name, [string]$Text)
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }

    It 'la plantilla parsea y no tiene BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($profilePath)
        $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasBom | Should Be $false

        $text = [System.IO.File]::ReadAllText($profilePath)
        { $text | ConvertFrom-Json } | Should Not Throw
        $json = $text | ConvertFrom-Json
        $names = @($json.PSObject.Properties | ForEach-Object { $_.Name })
        $names.Count | Should Be 1
        $names[0] | Should Be 'permissions'
    }

    It 'la plantilla no contiene bypassPermissions, defaultMode ni dangerously' {
        $text = [System.IO.File]::ReadAllText($profilePath)
        $text | Should Not Match 'bypassPermissions'
        $text | Should Not Match 'defaultMode'
        $text | Should Not Match 'dangerously'
    }

    It 'allow tiene exactamente las 17 herramientas en orden' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $allow = @($json.permissions.allow)
        $allow.Count | Should Be 17
        ($allow -join ',') | Should Be ($expectedAllow -join ',')
    }

    It 'deny tiene 79 entradas' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        @($json.permissions.deny).Count | Should Be 79
    }

    It 'deny tiene cada patron de la lista S con Bash' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $deny = @($json.permissions.deny)
        $listS.Count | Should Be 37
        foreach ($pattern in $listS) {
            ($deny -ccontains ('Bash(' + $pattern + ')')) | Should Be $true
        }
    }

    It 'deny tiene cada patron de la lista S con PowerShell' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $deny = @($json.permissions.deny)
        foreach ($pattern in $listS) {
            ($deny -ccontains ('PowerShell(' + $pattern + ')')) | Should Be $true
        }
    }

    It 'deny tiene los 5 servidores MCP de Jira, Atlassian y despliegue' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $deny = @($json.permissions.deny)
        foreach ($server in $mcpServers) {
            ($deny -ccontains $server) | Should Be $true
        }
    }

    It 'deny no niega git merge-base ni git commit' {
        $json = [System.IO.File]::ReadAllText($profilePath) | ConvertFrom-Json
        $deny = @($json.permissions.deny)
        foreach ($forbidden in @('Bash(git merge*)', 'Bash(git commit*)', 'Bash(git commit *)')) {
            ($deny -ccontains $forbidden) | Should Be $false
        }
    }

    It 'Resolve-DriverProfile devuelve la ruta absoluta del perfil dentro del runner' {
        $root = Join-Path $TestDrive 'r\scripts'
        $r = Resolve-DriverProfile -ScriptRoot $root
        $r | Should Be (Join-Path $TestDrive 'r\scripts\profiles\plan.settings.json')

        $relative = Resolve-DriverProfile -ScriptRoot 'scripts'
        [System.IO.Path]::IsPathRooted($relative) | Should Be $true
        $relative | Should Match 'profiles\\plan\.settings\.json$'
    }

    It 'Test-DriverProfile acepta la plantilla real' {
        $r = Test-DriverProfile -Path $profilePath
        $r.ok | Should Be $true
        $r.reason | Should BeNullOrEmpty
    }

    It 'Test-DriverProfile rechaza un archivo ausente o una ruta vacia' {
        foreach ($p in @((Join-Path $TestDrive 'no-existe.json'), '', $null)) {
            $r = Test-DriverProfile -Path $p
            $r.ok | Should Be $false
            $r.reason | Should Be 'no existe el perfil'
        }
    }

    It 'Test-DriverProfile rechaza un JSON mal formado' {
        $path = New-ProfileFile 'malo.json' '{ "permissions": { "allow": ["Read"], '
        $r = Test-DriverProfile -Path $path
        $r.ok | Should Be $false
        $r.reason | Should Be 'JSON inválido'
    }

    It 'Test-DriverProfile rechaza listas vacias o ausentes' {
        $emptyAllow = New-ProfileFile 'allow-vacia.json' '{ "permissions": { "allow": [], "deny": ["Bash(gh)"] } }'
        $r = Test-DriverProfile -Path $emptyAllow
        $r.ok | Should Be $false
        $r.reason | Should Be 'permissions.allow o permissions.deny vacía'

        $emptyDeny = New-ProfileFile 'deny-vacia.json' '{ "permissions": { "allow": ["Read"], "deny": [] } }'
        $r = Test-DriverProfile -Path $emptyDeny
        $r.ok | Should Be $false
        $r.reason | Should Be 'permissions.allow o permissions.deny vacía'

        $noPermissions = New-ProfileFile 'sin-permissions.json' '{ "otra": 1 }'
        $r = Test-DriverProfile -Path $noPermissions
        $r.ok | Should Be $false
        $r.reason | Should Be 'faltan permissions.allow o permissions.deny'

        $noDeny = New-ProfileFile 'sin-deny.json' '{ "permissions": { "allow": ["Read"] } }'
        $r = Test-DriverProfile -Path $noDeny
        $r.ok | Should Be $false
        $r.reason | Should Be 'faltan permissions.allow o permissions.deny'

        $single = New-ProfileFile 'un-elemento.json' '{ "permissions": { "allow": ["Read"], "deny": ["Bash(gh)"] } }'
        (Test-DriverProfile -Path $single).ok | Should Be $true
    }

    It 'Test-DriverProfile rechaza bypassPermissions y dangerously' {
        $bypass = New-ProfileFile 'bypass.json' '{ "defaultMode": "bypassPermissions", "permissions": { "allow": ["Read"], "deny": ["Bash(gh)"] } }'
        $r = Test-DriverProfile -Path $bypass
        $r.ok | Should Be $false
        $r.reason | Should Be 'el perfil contiene bypassPermissions o dangerously'

        $danger = New-ProfileFile 'danger.json' '{ "permissions": { "allow": ["Bash(claude --dangerously-skip-permissions)"], "deny": ["Bash(gh)"] } }'
        $r = Test-DriverProfile -Path $danger
        $r.ok | Should Be $false
        $r.reason | Should Be 'el perfil contiene bypassPermissions o dangerously'
    }
}

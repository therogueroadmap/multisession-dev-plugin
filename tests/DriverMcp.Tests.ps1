$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\DriverMcp.psm1') -Force

Describe 'DriverMcp' {
    $fixtureText = Get-Content -LiteralPath (Join-Path $moduleRoot 'tests\fixtures\mcp-list.txt') -Raw -Encoding utf8
    # Sin @(): Read-McpServerList devuelve el arreglo con una coma y @() lo anidaria (Count 1).
    $allNames = Read-McpServerList -Text $fixtureText

    # Inventario falso: cuenta sus llamadas en un hashtable compartido con la prueba.
    function New-FakeInventory([bool]$Ok, [string]$Text, [string]$ErrorText = $null) {
        $hits = @{ n = 0 }
        $sb = { $hits.n++; [pscustomobject]@{ ok = $Ok; text = $Text; error = $ErrorText } }.GetNewClosure()
        return [pscustomobject]@{ Hits = $hits; Block = $sb }
    }

    Context 'Read-McpServerList' {
        It 'lee los 33 servidores del fixture real, sin el encabezado' {
            $allNames.Count | Should Be 33
            ($allNames -ccontains 'claude.ai Atlassian Rovo') | Should Be $true
            ($allNames -ccontains 'plugin:productivity:google calendar') | Should Be $true
            ($allNames -ccontains 'plugin:vercel:vercel') | Should Be $true
            ($allNames -ccontains 'playwright') | Should Be $true
            ($allNames -ccontains 'pencil') | Should Be $true
            @($allNames | Where-Object { $_ -like 'Checking*' }).Count | Should Be 0
        }

        It 'texto vacio o solo el encabezado dan una lista vacia' {
            # La asercion de tipo distingue el arreglo vacio de $null ($null.Count tambien es 0).
            $a = Read-McpServerList -Text ''
            ($a -is [string[]]) | Should Be $true
            $a.Count | Should Be 0
            $b = Read-McpServerList -Text $null
            ($b -is [string[]]) | Should Be $true
            $b.Count | Should Be 0
            $c = Read-McpServerList -Text "Checking MCP server health…`n`n"
            ($c -is [string[]]) | Should Be $true
            $c.Count | Should Be 0
        }

        It 'no repite un nombre que aparece dos veces' {
            $t = "a: x - ok`na: y - ok`nb: z - ok"
            $names = Read-McpServerList -Text $t
            $names.Count | Should Be 2
            $names[0] | Should Be 'a'
            $names[1] | Should Be 'b'
        }
    }

    Context 'ConvertTo-McpToolPrefix' {
        It 'convierte el nombre del servidor en el prefijo de sus herramientas' {
            ConvertTo-McpToolPrefix -Name 'claude.ai Atlassian Rovo' | Should Be 'mcp__claude_ai_Atlassian_Rovo'
            ConvertTo-McpToolPrefix -Name 'plugin:vercel:vercel' | Should Be 'mcp__plugin_vercel_vercel'
            ConvertTo-McpToolPrefix -Name 'Atlassian' | Should Be 'mcp__Atlassian'
        }
    }

    Context 'Get-DriverMcpPlan' {
        It 'sin lista: --strict-mcp-config, modo none y sin inventario' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @() -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.args).Count | Should Be 1
            $plan.args[0] | Should Be '--strict-mcp-config'
            $plan.status.mode | Should Be 'none'
            @($plan.status.allowed).Count | Should Be 0
            $plan.status.blocked | Should BeNullOrEmpty
            $plan.status.reason | Should BeNullOrEmpty
            $plan.warning | Should BeNullOrEmpty
            $inv.Hits.n | Should Be 0
        }

        It 'una lista de elementos vacios o en blanco cuenta como vacia' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('', '   ') -ProfileMode $true -GetInventory $inv.Block
            $plan.ok | Should Be $true
            $plan.status.mode | Should Be 'none'
            $inv.Hits.n | Should Be 0
        }

        It 'modo perfil con una lista: FAILED mcp_requiere_unsafe sin inventario' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('playwright') -ProfileMode $true -GetInventory $inv.Block
            $plan.ok | Should Be $false
            $plan.cause | Should Be 'mcp_requiere_unsafe'
            $plan.reason | Should Match 'UnsafeSkipPermissions'
            $inv.Hits.n | Should Be 0
        }

        It "modo perfil con '*': tambien mcp_requiere_unsafe" {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('*') -ProfileMode $true -GetInventory $inv.Block
            $plan.ok | Should Be $false
            $plan.cause | Should Be 'mcp_requiere_unsafe'
        }

        It "'*' en Unsafe: hereda todo, sin argumentos y sin inventario" {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('*') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.args).Count | Should Be 0
            $plan.status.mode | Should Be 'inherit'
            $plan.status.reason | Should BeNullOrEmpty
            $inv.Hits.n | Should Be 0
        }

        It "'*' junto a otros nombres: FAILED mcp_lista_invalida" {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('*', 'playwright') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $false
            $plan.cause | Should Be 'mcp_lista_invalida'
            $inv.Hits.n | Should Be 0
        }

        It 'lista permitida: bloquea los demas con un solo --disallowedTools separado por comas' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('playwright') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.args).Count | Should Be 2
            $plan.args[0] | Should Be '--disallowedTools'
            $prefixes = @($plan.args[1] -split ',')
            $prefixes.Count | Should Be 32
            ($prefixes -ccontains 'mcp__plugin_vercel_vercel') | Should Be $true
            ($prefixes -ccontains 'mcp__claude_ai_Atlassian_Rovo') | Should Be $true
            ($prefixes -ccontains 'mcp__playwright') | Should Be $false
            $plan.status.mode | Should Be 'allowlist'
            @($plan.status.allowed).Count | Should Be 1
            @($plan.status.allowed)[0] | Should Be 'playwright'
            $plan.status.blocked | Should Be 32
            $plan.status.reason | Should BeNullOrEmpty
            $inv.Hits.n | Should Be 1
        }

        It 'recorta espacios y tolera duplicados' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @(' playwright ', 'playwright') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.status.allowed).Count | Should Be 1
            $plan.status.blocked | Should Be 32
        }

        It 'un elemento con comas (como llega con pwsh -File) se parte en varios nombres' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('playwright,pencil') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            $plan.status.mode | Should Be 'allowlist'
            @($plan.status.allowed).Count | Should Be 2
            $plan.status.blocked | Should Be 31
        }

        It 'la comparacion de nombres distingue mayusculas: FAILED mcp_desconocido con los disponibles' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp @('Playwright', 'NoExiste') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $false
            $plan.cause | Should Be 'mcp_desconocido'
            $plan.reason | Should Match 'Playwright, NoExiste'
            $plan.reason | Should Match 'Disponibles: .*playwright'
        }

        It 'una lista que cubre todo el inventario: modo allowlist sin argumentos y blocked 0' {
            $inv = New-FakeInventory $true $fixtureText
            $plan = Get-DriverMcpPlan -AllowMcp $allNames -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.args).Count | Should Be 0
            $plan.status.mode | Should Be 'allowlist'
            $plan.status.blocked | Should Be 0
        }

        It 'inventario fallido: hereda todo, avisa y conserva la lista pedida' {
            $inv = New-FakeInventory $false '' 'claude mcp list salio con 1'
            $plan = Get-DriverMcpPlan -AllowMcp @('playwright') -ProfileMode $false -GetInventory $inv.Block
            $plan.ok | Should Be $true
            @($plan.args).Count | Should Be 0
            $plan.status.mode | Should Be 'inherit'
            $plan.status.reason | Should Be 'inventario_fallido'
            @($plan.status.allowed)[0] | Should Be 'playwright'
            $plan.warning | Should Match 'Inventario de MCP fallido \(claude mcp list salio con 1\)'
        }

        It 'inventario que lanza o que no trae servidores: tambien inventario_fallido' {
            $plan = Get-DriverMcpPlan -AllowMcp @('playwright') -ProfileMode $false -GetInventory { throw 'boom' }
            $plan.ok | Should Be $true
            $plan.status.reason | Should Be 'inventario_fallido'
            $plan.warning | Should Match 'boom'

            $inv = New-FakeInventory $true "Checking MCP server health…`n"
            $plan2 = Get-DriverMcpPlan -AllowMcp @('playwright') -ProfileMode $false -GetInventory $inv.Block
            $plan2.status.reason | Should Be 'inventario_fallido'
            $plan2.warning | Should Match 'no se leyó ningún servidor'
        }
    }

    Context 'Invoke-McpInventory' {
        $pwshPath = (Get-Process -Id $PID).Path

        It 'devuelve la salida y ok cuando el proceso sale con 0' {
            $ps1 = Join-Path $TestDrive 'inv-ok.ps1'
            Set-Content -LiteralPath $ps1 -Value 'Write-Output ("args=" + ($args -join " ")); exit 0' -Encoding utf8
            $r = Invoke-McpInventory -File $pwshPath -PrefixArgs @('-NoProfile', '-File', $ps1)
            $r.ok | Should Be $true
            $r.text | Should Match 'args=mcp list'
            $r.error | Should BeNullOrEmpty
        }

        It 'devuelve ok false con el codigo de salida cuando el proceso falla' {
            $ps1 = Join-Path $TestDrive 'inv-fail.ps1'
            Set-Content -LiteralPath $ps1 -Value 'exit 3' -Encoding utf8
            $r = Invoke-McpInventory -File $pwshPath -PrefixArgs @('-NoProfile', '-File', $ps1)
            $r.ok | Should Be $false
            $r.error | Should Match 'salio con 3'
        }

        It 'mata el proceso y devuelve ok false si se vence el tope de tiempo' {
            $ps1 = Join-Path $TestDrive 'inv-hang.ps1'
            Set-Content -LiteralPath $ps1 -Value 'Start-Sleep -Seconds 30; exit 0' -Encoding utf8
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-McpInventory -File $pwshPath -PrefixArgs @('-NoProfile', '-File', $ps1) -TimeoutMs 2000
            $sw.Stop()
            $r.ok | Should Be $false
            $r.error | Should Match 'timeout'
            ($sw.Elapsed.TotalSeconds -lt 20) | Should Be $true
        }

        It 'no lanza si el ejecutable no existe' {
            $r = Invoke-McpInventory -File (Join-Path $TestDrive 'no-existe.exe')
            $r.ok | Should Be $false
            $r.error | Should Not BeNullOrEmpty
        }
    }
}

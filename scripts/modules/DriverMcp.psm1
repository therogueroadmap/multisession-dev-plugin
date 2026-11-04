# DriverMcp: servidores MCP que ven las sesiones que lanza el driver (Ola 6, DT-22..24).
#
# Sin -AllowMcp las sesiones van con --strict-mcp-config (ningun MCP). Con una lista, el driver
# hereda los MCP globales y oculta el resto con --disallowedTools, que tambien cubre los
# conectores de claude.ai; '*' hereda todo. El inventario sale de "claude mcp list" y solo se
# corre cuando hace falta. Todo es puro salvo Invoke-McpInventory.

function New-McpPlan {
    param([bool]$Ok, [string[]]$CliArgs = @(), $Status = $null, [string]$Cause = $null, [string]$Reason = $null, [string]$Warning = $null)

    [pscustomobject]@{ ok = $Ok; args = [string[]]@($CliArgs); status = $Status; cause = $Cause; reason = $Reason; warning = $Warning }
}

function New-McpStatus {
    param([string]$Mode, [string[]]$Allowed = @(), $Blocked = $null, [string]$Reason = $null)

    [ordered]@{ mode = $Mode; allowed = [string[]]@($Allowed); blocked = $Blocked; reason = $(if ($Reason) { $Reason } else { $null }) }
}

# Prefijo de las herramientas de un servidor: mcp__ + el nombre con todo lo que no sea [A-Za-z0-9_-] cambiado por _.
function ConvertTo-McpToolPrefix {
    param([Parameter(Mandatory = $true)][string]$Name)

    return 'mcp__' + ($Name -replace '[^A-Za-z0-9_-]', '_')
}

# Nombres de servidor de la salida de "claude mcp list", en orden y sin repetidos. Una linea es
# un servidor si tiene "<nombre>: <destino> - <estado>"; el nombre va hasta el primer ": ", asi
# que "plugin:productivity:google calendar" se lee entero. El encabezado y las vacias se ignoran.
function Read-McpServerList {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $names = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($line in ($Text -split '\r?\n')) {
            $m = [regex]::Match($line, '^(?<name>\S.*?): (?<rest>.*) - ')
            if ($m.Success -and -not $names.Contains($m.Groups['name'].Value)) { $names.Add($m.Groups['name'].Value) }
        }
    }
    # La coma evita que una lista vacia desaparezca al salir de la funcion.
    return , ([string[]]$names.ToArray())
}

# Corre "<File> <PrefixArgs> mcp list" con un tope de TimeoutMs; si se vence, mata el proceso.
# Nunca lanza: un fallo o el timeout vuelven en error con ok = $false.
function Invoke-McpInventory {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$PrefixArgs = @(),
        [int]$TimeoutMs = 60000
    )

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        foreach ($a in (@($PrefixArgs) + @('mcp', 'list'))) { [void]$psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Lectura asincrona de ambas tuberias: una llena bloquearia al hijo antes del timeout.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill($true) } catch { }
            return [pscustomobject]@{ ok = $false; text = ''; error = "claude mcp list no termino en $TimeoutMs ms (timeout)" }
        }
        $proc.WaitForExit()
        $text = (($outTask.GetAwaiter().GetResult()) -split '\r?\n') -join "`n"
        if ($proc.ExitCode -ne 0) { return [pscustomobject]@{ ok = $false; text = $text; error = "claude mcp list salio con $($proc.ExitCode)" } }
        return [pscustomobject]@{ ok = $true; text = $text; error = $null }
    }
    catch {
        return [pscustomobject]@{ ok = $false; text = ''; error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

# Decide los argumentos de MCP de las sesiones. GetInventory se invoca solo con una lista real en
# Unsafe y debe devolver { ok; text; error } (Invoke-McpInventory en el driver).
function Get-DriverMcpPlan {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$AllowMcp,
        [Parameter(Mandatory = $true)][bool]$ProfileMode,
        [Parameter(Mandatory = $true)][scriptblock]$GetInventory
    )

    $list = [System.Collections.Generic.List[string]]::new()
    # Con "pwsh -File", "-AllowMcp a,b" llega como un solo elemento "a,b": se parte por coma.
    foreach ($item in @($AllowMcp)) {
        if ($null -eq $item) { continue }
        foreach ($part in (([string]$item) -split ',')) {
            $t = $part.Trim()
            if ($t -and -not $list.Contains($t)) { $list.Add($t) }
        }
    }
    $allowed = [string[]]$list.ToArray()

    if ($allowed.Count -eq 0) {
        return New-McpPlan -Ok $true -CliArgs @('--strict-mcp-config') -Status (New-McpStatus -Mode 'none')
    }
    if ($ProfileMode) {
        return New-McpPlan -Ok $false -Cause 'mcp_requiere_unsafe' -Reason 'el perfil plan no permite herramientas MCP: -AllowMcp requiere -UnsafeSkipPermissions'
    }
    if ($allowed -ccontains '*') {
        if ($allowed.Count -gt 1) {
            return New-McpPlan -Ok $false -Cause 'mcp_lista_invalida' -Reason "-AllowMcp '*' no se combina con otros nombres"
        }
        return New-McpPlan -Ok $true -CliArgs @() -Status (New-McpStatus -Mode 'inherit')
    }

    $inv = $null
    try { $inv = & $GetInventory }
    catch { $inv = [pscustomobject]@{ ok = $false; text = ''; error = $_.Exception.Message } }

    $names = [string[]]@()
    if ($null -ne $inv -and $inv.ok) { $names = [string[]](Read-McpServerList -Text ([string]$inv.text)) }
    if ($names.Count -eq 0) {
        $why = if ($null -ne $inv -and $inv.error) { [string]$inv.error } else { 'no se leyó ningún servidor' }
        return New-McpPlan -Ok $true -CliArgs @() -Status (New-McpStatus -Mode 'inherit' -Allowed $allowed -Reason 'inventario_fallido') -Warning "Inventario de MCP fallido ($why): las sesiones heredan todos los MCP"
    }

    $unknown = @($allowed | Where-Object { $names -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        return New-McpPlan -Ok $false -Cause 'mcp_desconocido' -Reason ('MCP desconocidos en -AllowMcp: {0}. Disponibles: {1}' -f ($unknown -join ', '), ($names -join ', '))
    }

    $blocked = @($names | Where-Object { $allowed -cnotcontains $_ } | ForEach-Object { ConvertTo-McpToolPrefix -Name $_ })
    # Sin if-como-expresion: un @() asignado asi sale como $null y [string[]] lo vuelve un elemento vacio.
    $cli = @()
    if ($blocked.Count -gt 0) { $cli = @('--disallowedTools', ($blocked -join ',')) }
    return New-McpPlan -Ok $true -CliArgs $cli -Status (New-McpStatus -Mode 'allowlist' -Allowed $allowed -Blocked $blocked.Count)
}

Export-ModuleMember -Function ConvertTo-McpToolPrefix, Read-McpServerList, Invoke-McpInventory, Get-DriverMcpPlan

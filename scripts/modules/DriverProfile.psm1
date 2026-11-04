# DriverProfile: perfil de permisos "plan" para las sesiones que lanza el driver (Ola 3).
#
# El perfil vive en scripts\profiles\plan.settings.json y se pasa a claude con --settings.
# Los hooks de plugins y el settings.json del usuario o del proyecto se suman al perfil;
# el perfil no intenta anularlos. Resolve-DriverProfile solo calcula la ruta (no toca el
# disco) y Test-DriverProfile valida el archivo antes de lanzar nada.

function New-ProfileResult {
    param([bool]$Ok, [string]$Reason = $null)

    [pscustomobject]@{ ok = $Ok; reason = $Reason }
}

# Ruta absoluta del perfil dentro del runner. No comprueba que exista.
function Resolve-DriverProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot 'profiles\plan.settings.json'))
}

# Elementos de una lista de cadenas del perfil; $null si la propiedad falta, es null o algun
# elemento no es cadena (una lista vacia devuelve un arreglo vacio, no $null).
# Una lista de un solo elemento puede llegar de ConvertFrom-Json como escalar: @() la normaliza.
function Get-ProfileList {
    param($Object, [string]$Name)

    $p = $null
    if ($null -ne $Object) { $p = $Object.PSObject.Properties[$Name] }
    if ($null -eq $p -or $null -eq $p.Value) { return $null }

    $items = @($p.Value)
    foreach ($item in $items) {
        if ($item -isnot [string]) { return $null }
    }
    # La coma evita que una lista vacia desaparezca al salir de la funcion.
    return , $items
}

function Test-DriverProfile {
    param(
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-ProfileResult -Ok $false -Reason 'no existe el perfil'
    }

    try {
        $text = [System.IO.File]::ReadAllText($Path)
    }
    catch {
        return New-ProfileResult -Ok $false -Reason 'no existe el perfil'
    }

    if ($text -match '(?i)bypassPermissions|dangerously') {
        return New-ProfileResult -Ok $false -Reason 'el perfil contiene bypassPermissions o dangerously'
    }

    try {
        $json = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return New-ProfileResult -Ok $false -Reason 'JSON inválido'
    }

    $permissions = $null
    if ($null -ne $json) {
        $pp = $json.PSObject.Properties['permissions']
        if ($null -ne $pp) { $permissions = $pp.Value }
    }

    $allow = Get-ProfileList -Object $permissions -Name 'allow'
    $deny = Get-ProfileList -Object $permissions -Name 'deny'
    if ($null -eq $allow -or $null -eq $deny) {
        return New-ProfileResult -Ok $false -Reason 'faltan permissions.allow o permissions.deny'
    }

    if (@($allow).Count -eq 0 -or @($deny).Count -eq 0) {
        return New-ProfileResult -Ok $false -Reason 'permissions.allow o permissions.deny vacía'
    }

    return New-ProfileResult -Ok $true
}

Export-ModuleMember -Function Resolve-DriverProfile, Test-DriverProfile

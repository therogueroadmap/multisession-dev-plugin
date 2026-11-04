function Get-LastNonEmptyLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $lines = @(Get-Content -LiteralPath $Path)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $trimmed = $lines[$i].Trim()
        if ($trimmed.Length -gt 0) {
            return $trimmed
        }
    }
    return $null
}

# Cola del log: las ultimas MaxLines lineas NO vacias, recortadas, en orden de
# archivo. El driver busca la marca PLAN_STATUS dentro de esta ventana (M1): la
# marca puede no ser la ultima linea (texto colgante debajo), pero no se acepta
# una marca perdida muy arriba de un log largo.
function Get-LogTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 10000)]
        [int]$MaxLines
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $nonEmpty = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed.Length -gt 0) { $nonEmpty.Add($trimmed) }
    }

    $start = [Math]::Max(0, $nonEmpty.Count - $MaxLines)
    $tail = New-Object System.Collections.Generic.List[string]
    for ($i = $start; $i -lt $nonEmpty.Count; $i++) { $tail.Add($nonEmpty[$i]) }
    return $tail.ToArray()
}

Export-ModuleMember -Function Get-LastNonEmptyLine, Get-LogTail

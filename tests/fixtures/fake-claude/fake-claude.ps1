# claude falso para las pruebas de punta a punta del driver (PLAN_DRIVER_CLAUDE_PATH).
#
# No usa param() ni $args: el prompt multilinea debe llegar intacto, asi que lee los
# argumentos con [Environment]::GetCommandLineArgs() y toma los que siguen a la ruta
# de este script.
#
# Guion: JSON en $env:FAKE_CLAUDE_SCENARIO = arreglo de pasos. El contador de llamadas
# vive en "<guion>.count" (entero en texto) y cada llamada agrega una linea JSON
# { "n": <1..>, "args": [ ... ] } a "<guion>.calls.jsonl" (UTF-8).
#
# Paso i (i = contador):
#   { "exitCode": <int>, "stdout": [<lineas>], "stderr": [<lineas>],
#     "writeFiles": { "<ruta relativa al cwd>": "<contenido>" } | null, "sleepSeconds": <int> | 0 }
# Orden: escribe writeFiles (crea carpetas), duerme sleepSeconds, escribe stdout y
# stderr linea a linea, y sale con exitCode.
# Sin paso para la llamada i: escribe en stderr "fake-claude: sin paso para la llamada i"
# y sale con 99.

$ErrorActionPreference = 'Stop'

$scenarioPath = $env:FAKE_CLAUDE_SCENARIO
if (-not $scenarioPath) {
    [Console]::Error.WriteLine('fake-claude: falta FAKE_CLAUDE_SCENARIO')
    exit 98
}

# Argumentos que siguen a la ruta de este script en la linea de comandos.
$all = [Environment]::GetCommandLineArgs()
$selfIndex = -1
for ($i = 0; $i -lt $all.Length; $i++) {
    if ($all[$i] -ieq $PSCommandPath -or $all[$i] -like '*fake-claude.ps1') { $selfIndex = $i; break }
}
$callArgs = if ($selfIndex -ge 0 -and $selfIndex + 1 -lt $all.Length) { @($all[($selfIndex + 1)..($all.Length - 1)]) } else { @() }

# Contador de llamadas.
$countPath = "$scenarioPath.count"
$n = 0
if (Test-Path -LiteralPath $countPath) { $n = [int](Get-Content -LiteralPath $countPath -Raw).Trim() }
$n++
Set-Content -LiteralPath $countPath -Value ([string]$n) -Encoding ascii -NoNewline

# Registro de la llamada.
$record = [pscustomobject]@{ n = $n; args = @($callArgs) } | ConvertTo-Json -Compress -Depth 4
[System.IO.File]::AppendAllText("$scenarioPath.calls.jsonl", $record + "`n", [System.Text.UTF8Encoding]::new($false))

function Write-Utf8Line {
    param([System.IO.Stream]$Stream, [string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

$steps = @(Get-Content -LiteralPath $scenarioPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($n -gt $steps.Count) {
    [Console]::Error.WriteLine("fake-claude: sin paso para la llamada $n")
    exit 99
}
$step = $steps[$n - 1]

if ($null -ne $step.writeFiles) {
    foreach ($prop in $step.writeFiles.PSObject.Properties) {
        $target = Join-Path (Get-Location).Path $prop.Name
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($target, [string]$prop.Value, [System.Text.UTF8Encoding]::new($false))
    }
}

if ($step.sleepSeconds -and [int]$step.sleepSeconds -gt 0) { Start-Sleep -Seconds ([int]$step.sleepSeconds) }

$out = [Console]::OpenStandardOutput()
foreach ($line in @($step.stdout)) { if ($null -ne $line) { Write-Utf8Line -Stream $out -Text ([string]$line) } }
$err = [Console]::OpenStandardError()
foreach ($line in @($step.stderr)) { if ($null -ne $line) { Write-Utf8Line -Stream $err -Text ([string]$line) } }

exit ([int]$step.exitCode)

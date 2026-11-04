# Fase 4 (M4/M13): lectura del stdout de "claude -p --output-format stream-json"
# (JSONL, un evento por linea). Funciones puras: solo leen el archivo.
# El evento final {"type":"result"} NO es necesariamente la ultima linea (en el
# sondeo del 2026-10-07 le seguia un system/ui_status): se busca por tipo.
# Una sesion que espera subagentes en background emite un result por cada
# re-entrada (corrida de humo del 2026-10-07: 4). El texto y los campos
# acumulados (total_cost_usd, subagent_stats) salen del ultimo; duration_ms,
# num_turns y usage son del tramo y se suman.
# Del ultimo result tambien salen subtype y api_error_status (parseo defensivo:
# campo ausente, nulo o no numerico -> $null); los usa SessionRetry para clasificar
# el fallo (D1).

$script:EventTypePattern = '"type"\s*:\s*"(result|assistant)"'

function Read-SessionStream {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resultEvent = $null
    $resultEvents = New-Object System.Collections.Generic.List[object]
    $assistantTexts = New-Object System.Collections.Generic.List[string]

    # Un directorio o una ruta inexistente devuelve el objeto vacio sin lanzar.
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $fs = $null
        $reader = $null
        try {
            # Ruta absoluta: .NET resuelve rutas relativas contra su propio cwd, no el de PowerShell.
            $full = (Resolve-Path -LiteralPath $Path).ProviderPath
            # FileShare.ReadWrite: ProcessLauncher mantiene stdout abierto para escritura.
            $fs = New-Object System.IO.FileStream($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)

            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                # Filtro barato antes de deserializar: el JSONL de una sesion larga
                # pesa decenas de MB y solo interesan result y assistant.
                if ($line -notmatch $script:EventTypePattern) { continue }
                try {
                    $evt = $line | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    # Linea cortada (proceso matado a mitad de escritura): se ignora.
                    continue
                }

                if ($evt.type -eq 'result') {
                    $resultEvent = $evt
                    $resultEvents.Add($evt)
                }
                elseif ($evt.type -eq 'assistant' -and $null -eq $evt.parent_tool_use_id) {
                    # Solo el hilo principal: los mensajes de subagentes traen
                    # parent_tool_use_id y no contienen la marca de la sesion.
                    foreach ($block in @($evt.message.content)) {
                        if ($null -ne $block -and $block.type -eq 'text' -and $block.text) {
                            $assistantTexts.Add([string]$block.text)
                        }
                    }
                }
            }
        }
        catch {
            # Fallo de E/S (p. ej. IOException por bloqueo): se devuelve lo acumulado hasta aqui.
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $fs) { $fs.Dispose() }
        }
    }

    # subtype y api_error_status del ultimo result; PSObject.Properties no depende de
    # que la propiedad exista y el parseo nunca lanza.
    $subtype = $null
    $apiErrorStatus = $null
    if ($null -ne $resultEvent) {
        try {
            $subtypeProp = $resultEvent.PSObject.Properties['subtype']
            if ($null -ne $subtypeProp -and $null -ne $subtypeProp.Value) { $subtype = [string]$subtypeProp.Value }
            $apiProp = $resultEvent.PSObject.Properties['api_error_status']
            if ($null -ne $apiProp -and $null -ne $apiProp.Value) {
                $parsed = 0
                if ([int]::TryParse(([string]$apiProp.Value), [ref]$parsed)) { $apiErrorStatus = $parsed }
            }
        }
        catch {
            # Campo con forma inesperada: se deja en $null.
        }
    }

    $telemetry = $null
    if ($null -ne $resultEvent) {
        $killed = $null
        $k = $resultEvent.subagent_stats.killed
        if ($null -ne $k) { $killed = [int]$k.parent + [int]$k.user + [int]$k.system }

        # Suma de un campo por tramo; $null si ningun result lo trae.
        $sumOf = {
            param([scriptblock]$Get)
            $total = $null
            foreach ($r in $resultEvents) {
                $v = & $Get $r
                if ($null -ne $v) { $total = [long]$total + [long]$v }
            }
            return $total
        }

        # isError: verdadero si algun tramo fallo, aunque el ultimo terminara bien.
        $isError = $resultEvent.is_error
        foreach ($r in $resultEvents) { if ($r.is_error -eq $true) { $isError = $true } }

        $telemetry = [pscustomobject][ordered]@{
            costUsd             = $resultEvent.total_cost_usd
            durationMs          = & $sumOf { param($r) $r.duration_ms }
            numTurns            = & $sumOf { param($r) $r.num_turns }
            inputTokens         = & $sumOf { param($r) $r.usage.input_tokens }
            outputTokens        = & $sumOf { param($r) $r.usage.output_tokens }
            cacheReadTokens     = & $sumOf { param($r) $r.usage.cache_read_input_tokens }
            cacheCreationTokens = & $sumOf { param($r) $r.usage.cache_creation_input_tokens }
            subagentsKilled     = $killed
            subagentsFailed     = $resultEvent.subagent_stats.failed
            isError             = $isError
            terminalReason      = $resultEvent.terminal_reason
        }
    }

    return [pscustomobject]@{
        HasResult      = ($null -ne $resultEvent)
        ResultText     = if ($null -ne $resultEvent) { $resultEvent.result } else { $null }
        AssistantText  = ($assistantTexts -join "`n")
        Telemetry      = $telemetry
        Subtype        = $subtype
        ApiErrorStatus = $apiErrorStatus
    }
}

# Texto del .log derivado: el texto final de la sesion (mismo contenido que
# "claude -p" en modo texto) o, si no hubo result con texto (sesion truncada o
# matada), el texto del asistente del hilo principal como respaldo para el
# raspado de la marca (M1).
function Get-SessionLogText {
    param(
        [Parameter(Mandatory = $true)]
        $Stream
    )

    if ($Stream.HasResult -and -not [string]::IsNullOrEmpty($Stream.ResultText)) {
        return [string]$Stream.ResultText
    }
    if ($null -ne $Stream.AssistantText) {
        return [string]$Stream.AssistantText
    }
    return ''
}

# Objeto telemetry del evento de history: modelo y effort salen de la config del
# driver (siempre presentes); el resto, del result del stream o $null.
function New-SessionTelemetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$Effort,
        [AllowNull()]
        $StreamTelemetry
    )

    $fields = @('costUsd', 'durationMs', 'numTurns', 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheCreationTokens', 'subagentsKilled', 'subagentsFailed', 'isError', 'terminalReason')
    $t = [ordered]@{ model = $Model; effort = $Effort }
    foreach ($f in $fields) {
        $t[$f] = if ($null -ne $StreamTelemetry) { $StreamTelemetry.$f } else { $null }
    }
    return [pscustomobject]$t
}

Export-ModuleMember -Function Read-SessionStream, Get-SessionLogText, New-SessionTelemetry

# DriverNotify: aviso al terminar el driver (toast de Windows, respaldo msg.exe y webhook opcional).
#
# Por que el toast va por powershell.exe 5.1: pwsh 7 no carga los tipos WinRT
# (Windows.UI.Notifications), asi que el toast se lanza en un proceso hijo de
# Windows PowerShell con un script CONSTANTE. El texto variable (titulo y cuerpo)
# viaja en Base64 por variables de entorno del hijo y nunca se interpola en el
# script ni en la linea de comandos: un reason con comillas tipograficas no puede
# ejecutar codigo.
#
# El modulo nunca lanza: Send-DriverNotification atrapa cualquier fallo y lo deja
# como 'fallo' en el registro devuelto. No importa otros modulos del driver
# (recibe valores, no rutas de status). Ningun warning incluye la URL del webhook
# (puede llevar un topico secreto); como mucho el host.

$script:Middot = [string][char]0x00B7

# Script del toast (texto constante, ASCII). Se une con LF para que no dependa de
# los saltos de linea de este archivo.
$script:ToastScript = @(
    '$ErrorActionPreference = ''Stop''',
    'try {',
    '$t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:DRIVER_TOAST_TITLE_B64))',
    '$b = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:DRIVER_TOAST_BODY_B64))',
    '[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]',
    '[void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]',
    '$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)',
    '$nodes = $xml.GetElementsByTagName(''text'')',
    '[void]$nodes.Item(0).AppendChild($xml.CreateTextNode($t))',
    '[void]$nodes.Item(1).AppendChild($xml.CreateTextNode($b))',
    '$toast = New-Object Windows.UI.Notifications.ToastNotification($xml)',
    '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(''{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'').Show($toast)',
    'exit 0',
    '}',
    'catch { exit 1 }'
) -join "`n"

function Format-DriverNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [AllowNull()][AllowEmptyString()][string]$PlanFile,
        [int]$Sessions = 0,
        [Nullable[double]]$CostUsd,
        [Nullable[timespan]]$Duration,
        [AllowNull()][AllowEmptyString()][string]$DashboardUrl
    )

    $leaf = ''
    if (-not [string]::IsNullOrWhiteSpace($PlanFile)) {
        $leaf = [IO.Path]::GetFileNameWithoutExtension($PlanFile)
    }
    if ([string]::IsNullOrEmpty($leaf)) { $leaf = 'sin-plan' }
    $title = "Driver ${Status}: $leaf"

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($Reason)) {
        $text = $Reason
        if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
        $lines.Add($text)
    }

    $summary = "$Sessions sesiones"
    if ($null -ne $CostUsd) {
        $cost = ([double]$CostUsd).ToString('0.00', [cultureinfo]::InvariantCulture).Replace('.', ',')
        $summary += " $($script:Middot) $cost USD"
    }
    if ($null -ne $Duration) {
        $totalMin = [int][math]::Floor(([timespan]$Duration).TotalMinutes)
        $h = [int][math]::Floor($totalMin / 60)
        $m = $totalMin % 60
        $durText = if ($h -ge 1) { "$h h $m min" } else { "$m min" }
        $summary += " $($script:Middot) $durText"
    }
    $lines.Add($summary)

    if (-not [string]::IsNullOrEmpty($DashboardUrl)) { $lines.Add($DashboardUrl) }

    # Titulo ASCII para la cabecera Title del webhook: sin marcas diacriticas y
    # cualquier otro caracter fuera de ASCII imprimible pasa a '?'.
    $decomposed = $title.Normalize([Text.NormalizationForm]::FormD)
    $ascii = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -eq [Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ([int]$ch -ge 0x20 -and [int]$ch -le 0x7E) { [void]$ascii.Append($ch) } else { [void]$ascii.Append('?') }
    }

    $priority = if ($Status -in @('BLOCKED', 'FAILED', 'STOPPED_MAX_ITERATIONS', 'AWAITING')) { 'high' } else { 'default' }
    $tags = switch ($Status) {
        'DONE'                   { 'white_check_mark' }
        'BLOCKED'                { 'warning' }
        'FAILED'                 { 'x' }
        'STOPPED_MAX_ITERATIONS' { 'hourglass' }
        'AWAITING'               { 'raising_hand' }
        default                  { 'information_source' }
    }

    return [pscustomobject]@{
        Title      = $title
        Body       = ($lines -join "`n")
        AsciiTitle = $ascii.ToString()
        Priority   = $priority
        Tags       = $tags
    }
}

function Get-DriverToastLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body
    )

    $utf8 = [Text.Encoding]::UTF8
    return [pscustomobject]@{
        Script         = $script:ToastScript
        EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:ToastScript))
        Environment    = [ordered]@{
            DRIVER_TOAST_TITLE_B64 = [Convert]::ToBase64String($utf8.GetBytes($Title))
            DRIVER_TOAST_BODY_B64  = [Convert]::ToBase64String($utf8.GetBytes($Body))
        }
    }
}

function Test-DriverNotificationDue {
    [CmdletBinding()]
    param([AllowNull()]$Status)

    if ($null -eq $Status) { return $false }
    $gs = if ($Status.PSObject.Properties['globalStatus']) { [string]$Status.globalStatus } else { '' }
    if ($gs -notin @('DONE', 'BLOCKED', 'FAILED', 'STOPPED', 'STOPPED_MAX_ITERATIONS')) { return $false }

    if ($gs -eq 'STOPPED') {
        # DR-6: un STOPPED por Ctrl+C no avisa.
        $history = @()
        if ($Status.PSObject.Properties['history'] -and $null -ne $Status.history) { $history = @($Status.history) }
        if ($history.Count -gt 0) {
            $last = $history[$history.Count - 1]
            if ($last.PSObject.Properties['cause'] -and [string]$last.cause -eq 'manual') { return $false }
        }
        if ($Status.PSObject.Properties['reason'] -and [string]$Status.reason -eq 'Interrumpido con Ctrl+C') { return $false }
    }
    return $true
}

# Convierte un valor de fecha del status a hora local; $null si no es legible.
function ConvertTo-NotifyLocalDate {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value.ToLocalTime() }
        return $Value
    }
    if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime }
    try {
        return [datetimeoffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture).LocalDateTime
    }
    catch {
        return $null
    }
}

function Get-NotifyEventCost {
    param($HistoryEvent)

    if (-not $HistoryEvent.PSObject.Properties['telemetry'] -or $null -eq $HistoryEvent.telemetry) { return $null }
    if (-not $HistoryEvent.telemetry.PSObject.Properties['costUsd']) { return $null }
    $v = $HistoryEvent.telemetry.costUsd
    if ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [single]) { return [double]$v }
    return $null
}

function Get-DriverNotificationSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Status,
        [datetime]$Now = (Get-Date),
        [ValidateSet('sum', 'lastAttempt')][string]$CostMode = 'sum'
    )

    $started = $null
    if ($Status.PSObject.Properties['startedAt']) { $started = ConvertTo-NotifyLocalDate $Status.startedAt }

    $history = @()
    if ($Status.PSObject.Properties['history'] -and $null -ne $Status.history) { $history = @($Status.history) }

    # Eventos de esta corrida: timestamp >= startedAt (excluye lo heredado por D7).
    $run = New-Object System.Collections.Generic.List[object]
    foreach ($e in $history) {
        if ($null -ne $started) {
            $ts = $null
            if ($e.PSObject.Properties['timestamp']) { $ts = ConvertTo-NotifyLocalDate $e.timestamp }
            if ($null -eq $ts -or $ts -lt $started) { continue }
        }
        $run.Add($e)
    }

    $sessions = 0
    foreach ($e in $run) {
        # attempt no numerico no cuenta como sesion y nunca lanza.
        $n = 0
        if (-not $e.PSObject.Properties['attempt'] -or $null -eq $e.attempt) { $sessions++ }
        elseif ([int]::TryParse([string]$e.attempt, [ref]$n) -and $n -eq 0) { $sessions++ }
    }

    $costEvents = New-Object System.Collections.Generic.List[object]
    if ($CostMode -eq 'lastAttempt') {
        # Por cada iter, solo el ultimo evento (mayor attempt; a igualdad, el ultimo del history).
        $best = [ordered]@{}
        foreach ($e in $run) {
            $key = if ($e.PSObject.Properties['iter']) { [string]$e.iter } else { '' }
            # attempt no numerico se trata como 0.
            $att = 0
            if ($e.PSObject.Properties['attempt'] -and $null -ne $e.attempt) {
                $parsed = 0
                if ([int]::TryParse([string]$e.attempt, [ref]$parsed)) { $att = $parsed }
            }
            if (-not $best.Contains($key) -or $att -ge $best[$key].Attempt) {
                $best[$key] = [pscustomobject]@{ Attempt = $att; Event = $e }
            }
        }
        foreach ($k in $best.Keys) { $costEvents.Add($best[$k].Event) }
    }
    else {
        foreach ($e in $run) { $costEvents.Add($e) }
    }

    $cost = $null
    foreach ($e in $costEvents) {
        $c = Get-NotifyEventCost $e
        if ($null -ne $c) { $cost = [double]$cost + $c }
    }
    if ($null -ne $cost) { $cost = [math]::Round($cost, 6) }

    $duration = $null
    if ($null -ne $started) { $duration = $Now - $started }

    return [pscustomobject]@{
        Sessions = $sessions
        CostUsd  = $cost
        Duration = $duration
    }
}

function Invoke-DriverToast {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [int]$TimeoutSeconds = 15
    )

    $proc = $null
    try {
        $l = Get-DriverToastLaunch -Title $Title -Body $Body
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        foreach ($a in @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $l.EncodedCommand)) {
            [void]$psi.ArgumentList.Add($a)
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($key in $l.Environment.Keys) { $psi.Environment[[string]$key] = [string]$l.Environment[$key] }

        $proc = [Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { }
            return 'fallo'
        }
        if ($proc.ExitCode -eq 0) { return 'ok' }
        return 'fallo'
    }
    catch {
        return 'fallo'
    }
    finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
    }
}

function Invoke-DriverMsgFallback {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body
    )

    $savedExit = $global:LASTEXITCODE
    $proc = $null
    try {
        $text = ("$Title`n$Body").Replace('"', "'")
        $proc = Start-Process -FilePath 'msg.exe' -ArgumentList @($env:USERNAME, '/TIME:3600', "`"$text`"") -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill() } catch { }
            return 'fallo'
        }
        if ($proc.ExitCode -eq 0) { return 'msg' }
        return 'fallo'
    }
    catch {
        return 'fallo'
    }
    finally {
        if ($null -ne $proc) { try { $proc.Dispose() } catch { } }
        $global:LASTEXITCODE = $savedExit
    }
}

function Invoke-DriverWebhook {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$AsciiTitle,
        [Parameter(Mandatory = $true)][string]$Priority,
        [Parameter(Mandatory = $true)][string]$Tags,
        [int]$TimeoutSeconds = 10
    )

    try {
        $resp = Invoke-WebRequest -Method Post -Uri $Uri -Body ([Text.Encoding]::UTF8.GetBytes($Body)) `
            -ContentType 'text/plain; charset=utf-8' `
            -Headers @{ Title = $AsciiTitle; Priority = $Priority; Tags = $Tags } `
            -TimeoutSec $TimeoutSeconds -MaximumRetryCount 0 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        if ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300) { return 'ok' }
        return 'fallo'
    }
    catch {
        # El mensaje de la excepcion puede traer la URL: solo host y tipo.
        Write-Warning "El webhook del aviso fallo (host $($Uri.Host)): $($_.Exception.GetType().Name)"
        return 'fallo'
    }
}

function Send-DriverNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [AllowNull()][AllowEmptyString()][string]$PlanFile,
        [int]$Sessions = 0,
        [Nullable[double]]$CostUsd,
        [Nullable[timespan]]$Duration,
        [AllowNull()][AllowEmptyString()][string]$DashboardUrl,
        [AllowNull()][AllowEmptyString()][string]$NotifyUrl,
        [switch]$NoToast,
        [int]$ToastTimeoutSeconds = 15,
        [int]$WebhookTimeoutSeconds = 10
    )

    $result = [pscustomobject][ordered]@{
        sentAt      = (Get-Date).ToString('o')
        toast       = 'omitido'
        webhook     = 'omitido'
        webhookHost = $null
    }

    try {
        $fmt = Format-DriverNotification -Status $Status -Reason $Reason -PlanFile $PlanFile -Sessions $Sessions `
            -CostUsd $CostUsd -Duration $Duration -DashboardUrl $DashboardUrl

        if (-not $NoToast) {
            $toast = 'fallo'
            try {
                if ([string](Invoke-DriverToast -Title $fmt.Title -Body $fmt.Body -TimeoutSeconds $ToastTimeoutSeconds) -eq 'ok') { $toast = 'ok' }
            }
            catch { }
            if ($toast -ne 'ok') {
                try {
                    if ([string](Invoke-DriverMsgFallback -Title $fmt.Title -Body $fmt.Body) -eq 'msg') { $toast = 'msg' }
                }
                catch { }
            }
            if ($toast -eq 'fallo') { Write-Warning 'No se pudo mostrar el aviso (fallaron el toast y msg.exe).' }
            $result.toast = $toast
        }

        if (-not [string]::IsNullOrEmpty($NotifyUrl)) {
            $uri = $null
            $valid = [uri]::TryCreate($NotifyUrl, [System.UriKind]::Absolute, [ref]$uri) -and ($uri.Scheme -in @('http', 'https'))
            if (-not $valid) {
                $result.webhook = 'fallo'
                Write-Warning 'El webhook del aviso no se envio: la URL no es valida.'
            }
            else {
                $result.webhookHost = $uri.Host
                $hook = 'fallo'
                try {
                    if ([string](Invoke-DriverWebhook -Uri $uri -Body $fmt.Body -AsciiTitle $fmt.AsciiTitle -Priority $fmt.Priority `
                                -Tags $fmt.Tags -TimeoutSeconds $WebhookTimeoutSeconds) -eq 'ok') { $hook = 'ok' }
                }
                catch {
                    Write-Warning "El webhook del aviso fallo (host $($uri.Host)): $($_.Exception.GetType().Name)"
                }
                $result.webhook = $hook
            }
        }
    }
    catch {
        Write-Warning "El aviso fallo de forma inesperada: $($_.Exception.GetType().Name)"
    }

    return $result
}

Export-ModuleMember -Function Send-DriverNotification, Format-DriverNotification, Get-DriverToastLaunch, Test-DriverNotificationDue, Get-DriverNotificationSummary

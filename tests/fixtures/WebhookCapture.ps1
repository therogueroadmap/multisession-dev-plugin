# WebhookCapture: servidor HTTP minimo para probar webhooks (se carga con dot-source).
#
# Escucha en 127.0.0.1 con un puerto al azar (20000-29999, nunca fijo), acepta UNA
# conexion en un hilo aparte y vuelca la peticion recibida en un JSON:
#   { "requestLine": "...", "headers": { "<nombre en minusculas>": "<valor>" }, "bodyBase64": "..." }
# Lo usan DriverNotify.Tests.ps1 y las pruebas de punta a punta del driver.

function Start-WebhookCapture {
    param(
        [Parameter(Mandatory = $true)][string]$OutFile,
        [switch]$NoResponse
    )

    $listener = $null
    $port = 0
    for ($i = 0; $i -lt 20; $i++) {
        $port = Get-Random -Minimum 20000 -Maximum 30000
        $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), $port)
        try {
            $candidate.Start()
            $listener = $candidate
            break
        }
        catch {
            # puerto ocupado: prueba otro
        }
    }
    if (-not $listener) { throw 'WebhookCapture: no se pudo abrir un puerto libre tras 20 intentos' }

    $job = Start-ThreadJob -ArgumentList $listener, $OutFile, $NoResponse.IsPresent -ScriptBlock {
        param($listener, $outFile, $noResponse)

        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $buffer = New-Object byte[] 4096
            $received = New-Object System.IO.MemoryStream
            $headerEnd = -1

            # Lee hasta encontrar CRLFCRLF.
            while ($headerEnd -lt 0) {
                $n = $stream.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                $received.Write($buffer, 0, $n)
                $bytes = $received.ToArray()
                for ($k = 0; $k -le $bytes.Length - 4; $k++) {
                    if ($bytes[$k] -eq 13 -and $bytes[$k + 1] -eq 10 -and $bytes[$k + 2] -eq 13 -and $bytes[$k + 3] -eq 10) {
                        $headerEnd = $k
                        break
                    }
                }
            }
            if ($headerEnd -lt 0) { return }

            $all = $received.ToArray()
            $headerText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
            $lines = $headerText -split "`r`n"
            $requestLine = $lines[0]
            $headers = [ordered]@{}
            for ($j = 1; $j -lt $lines.Count; $j++) {
                $idx = $lines[$j].IndexOf(':')
                if ($idx -gt 0) {
                    $headers[$lines[$j].Substring(0, $idx).Trim().ToLowerInvariant()] = $lines[$j].Substring($idx + 1).Trim()
                }
            }

            # Cuerpo segun Content-Length.
            $contentLength = 0
            if ($headers.Contains('content-length')) { $contentLength = [int]$headers['content-length'] }
            $bodyStart = $headerEnd + 4
            $body = New-Object System.IO.MemoryStream
            if ($all.Length -gt $bodyStart) { $body.Write($all, $bodyStart, $all.Length - $bodyStart) }
            while ($body.Length -lt $contentLength) {
                $n = $stream.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                $body.Write($buffer, 0, $n)
            }

            $capture = [ordered]@{
                requestLine = $requestLine
                headers     = $headers
                bodyBase64  = [Convert]::ToBase64String($body.ToArray())
            }
            $json = $capture | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding($false)))

            if ($noResponse) {
                Start-Sleep -Seconds 30
            }
            else {
                $response = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($response, 0, $response.Length)
                $stream.Flush()
            }
        }
        finally {
            if ($client) { try { $client.Close() } catch { } }
            try { $listener.Stop() } catch { }
        }
    }

    return [pscustomobject]@{
        Port     = $port
        Url      = "http://127.0.0.1:$port/mi-topico-secreto"
        Listener = $listener
        Job      = $job
    }
}

function Stop-WebhookCapture {
    param([Parameter(Mandatory = $true)]$Capture)

    if ($null -eq $Capture) { return }
    try { if ($Capture.Listener) { $Capture.Listener.Stop() } } catch { }
    if ($Capture.Job) {
        try { Stop-Job -Job $Capture.Job -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $Capture.Job -Force -ErrorAction SilentlyContinue } catch { }
    }
}

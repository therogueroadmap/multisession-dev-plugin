$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\GitSummary.psm1') -Force

function New-TempRepo {
    param([string[]]$Branches = @(), [switch]$Dirty)
    $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q | Out-Null
    git -C $repo config user.email 't@t.t' | Out-Null
    git -C $repo config user.name 'T' | Out-Null
    git -C $repo config commit.gpgsign false | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'x' -Encoding utf8
    git -C $repo add . | Out-Null
    git -C $repo commit -q -m 'init' | Out-Null
    if ($Branches.Count -gt 0) {
        git -C $repo branch -m $Branches[0] | Out-Null
        foreach ($b in ($Branches | Select-Object -Skip 1)) { git -C $repo branch $b | Out-Null }
        git -C $repo checkout -q $Branches[0] | Out-Null
    }
    if ($Dirty) { Set-Content -LiteralPath (Join-Path $repo 'dirty.txt') -Value 'y' -Encoding utf8 }
    return $repo
}

# Repo con rama master explicita (no depende de init.defaultBranch). New-TempRepo ya
# hizo el commit init: se renombra la rama actual en vez de apuntar HEAD a una rama nueva.
function New-MasterRepo {
    $repo = New-TempRepo
    git -C $repo branch -M master | Out-Null
    return $repo
}

function Add-TestCommit {
    param([string]$Repo, [string]$Message)
    git -C $Repo add -A | Out-Null
    git -C $Repo -c user.name=t -c user.email=t@example.com commit -q -m $Message | Out-Null
}

Describe 'GitSummary' {
    It 'rama con dos commits frente a master: ahead, commits del mas nuevo al mas viejo y diffstat' {
        $repo = New-MasterRepo
        git -C $repo checkout -q -b feat/x | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value @('uno', 'dos') -Encoding utf8
        Add-TestCommit -Repo $repo -Message 'feat: uno'
        Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value @('uno', 'DOS') -Encoding utf8
        Add-TestCommit -Repo $repo -Message 'fix: dos'
        $r = Get-GitSummary -RepoRoot $repo -BaseBranch master
        $r.branch | Should Be 'feat/x'
        $r.baseBranch | Should Be 'master'
        $r.ahead | Should Be 2
        @($r.commits).Count | Should Be 2
        $r.commits[0].subject | Should Be 'fix: dos'
        $r.commits[1].subject | Should Be 'feat: uno'
        ($r.commits[0].hash -match '^[0-9a-f]{7,}$') | Should Be $true
        $r.diffstat.files | Should Be 1
        $r.diffstat.insertions | Should Be 2
        $r.diffstat.deletions | Should Be 0
        $r.clean | Should Be $true
        $r.error | Should BeNullOrEmpty
        $r.updatedAt | Should Not BeNullOrEmpty
        ($r.PSObject.Properties.Name -join ',') | Should Be 'branch,baseBranch,ahead,commits,diffstat,clean,updatedAt,error'
    }

    It 'sin commits propios: ahead 0, commits vacio y diffstat en cero' {
        $repo = New-MasterRepo
        git -C $repo checkout -q -b feat/y | Out-Null
        $r = Get-GitSummary -RepoRoot $repo -BaseBranch master
        $r.ahead | Should Be 0
        @($r.commits).Count | Should Be 0
        $r.diffstat.files | Should Be 0
        $r.diffstat.insertions | Should Be 0
        $r.diffstat.deletions | Should Be 0
        $r.error | Should BeNullOrEmpty
    }

    It 'clean es false con un archivo sin seguimiento y true si solo estan los archivos del driver' {
        $repo = New-MasterRepo
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs\superpowers\plans\.driver-logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo '.driver-status.json') -Value '{}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $repo 'docs\superpowers\plans\.driver-logs\x.log') -Value 'x' -Encoding utf8
        (Get-GitSummary -RepoRoot $repo -BaseBranch master).clean | Should Be $true
        Set-Content -LiteralPath (Join-Path $repo 'sucio.txt') -Value 'y' -Encoding utf8
        (Get-GitSummary -RepoRoot $repo -BaseBranch master).clean | Should Be $false
    }

    It 'base inexistente: error con el mensaje de git y el resto nulo, sin lanzar' {
        $repo = New-MasterRepo
        { Get-GitSummary -RepoRoot $repo -BaseBranch 'no-existe' } | Should Not Throw
        $r = Get-GitSummary -RepoRoot $repo -BaseBranch 'no-existe'
        ($r.error -match 'git rev-list fallo') | Should Be $true
        $r.branch | Should BeNullOrEmpty
        $r.baseBranch | Should BeNullOrEmpty
        $r.ahead | Should BeNullOrEmpty
        $r.commits | Should BeNullOrEmpty
        $r.diffstat | Should BeNullOrEmpty
        $r.clean | Should BeNullOrEmpty
        $r.updatedAt | Should Not BeNullOrEmpty
    }

    It 'base nula: error sin rama base y no ejecuta git' {
        $repo = New-MasterRepo
        (Get-GitSummary -RepoRoot $repo -BaseBranch $null).error | Should Be 'sin rama base (develop, main o master)'
        (Get-GitSummary -RepoRoot $repo -BaseBranch $null -GitPath 'C:\no\existe\git.exe').error | Should Be 'sin rama base (develop, main o master)'
    }

    It 'git ausente: error y nunca lanza' {
        $repo = New-MasterRepo
        $fake = Join-Path $TestDrive 'no-existe\git.exe'
        { Get-GitSummary -RepoRoot $repo -BaseBranch master -GitPath $fake } | Should Not Throw
        $r = Get-GitSummary -RepoRoot $repo -BaseBranch master -GitPath $fake
        $r.error | Should Not BeNullOrEmpty
        $r.branch | Should BeNullOrEmpty
        $r.ahead | Should BeNullOrEmpty
        $r.commits | Should BeNullOrEmpty
        $r.diffstat | Should BeNullOrEmpty
        $r.clean | Should BeNullOrEmpty
    }

    It 'Invoke-GitSummaryCommand corta a los TimeoutSeconds y mata el proceso' {
        $exe = (Get-Process -Id $PID).Path
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = & (Get-Module GitSummary) { param($e) Invoke-GitSummaryCommand -FilePath $e -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') -TimeoutSeconds 1 } $exe
        $sw.Stop()
        $r.TimedOut | Should Be $true
        $sw.Elapsed.TotalSeconds | Should BeLessThan 10
    }

    It 'Invoke-GitSummaryCommand no se cuelga si un nieto hereda las tuberias' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = & (Get-Module GitSummary) { param($e) Invoke-GitSummaryCommand -FilePath $e -Arguments @('/c', 'start /b ping -n 12 127.0.0.1') -TimeoutSeconds 2 } $env:ComSpec
            $sw.Stop()
            $r.TimedOut | Should Be $true
            $sw.Elapsed.TotalSeconds | Should BeLessThan 8
        }
        finally {
            # El ping nieto queda huerfano (su padre cmd ya salio): se limpia aqui.
            Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" |
                Where-Object { $_.CommandLine -match '-n 12 127\.0\.0\.1' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'Invoke-GitSummaryCommand usa un plazo unico para la salida y el drenaje' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            # El padre sale a los ~2 s y el nieto retiene las tuberias: sin plazo unico
            # tardaria ~6 s (2 s del padre mas 4 s de drenaje).
            $r = & (Get-Module GitSummary) { param($e) Invoke-GitSummaryCommand -FilePath $e -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul & start /b ping -n 15 127.0.0.1') -TimeoutSeconds 4 } $env:ComSpec
            $sw.Stop()
            $r.TimedOut | Should Be $true
            $sw.Elapsed.TotalSeconds | Should BeLessThan 5.2
        }
        finally {
            Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" |
                Where-Object { $_.CommandLine -match '-n 15 127\.0\.0\.1' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'como maximo MaxCommits commits y asuntos UTF-8 intactos' {
        $repo = New-MasterRepo
        git -C $repo checkout -q -b feat/z | Out-Null
        for ($i = 1; $i -le 11; $i++) {
            Set-Content -LiteralPath (Join-Path $repo "f$i.txt") -Value "$i" -Encoding utf8
            Add-TestCommit -Repo $repo -Message "feat: $i"
        }
        Set-Content -LiteralPath (Join-Path $repo 'f12.txt') -Value '12' -Encoding utf8
        $msgFile = Join-Path $TestDrive 'msg-utf8.txt'
        [System.IO.File]::WriteAllText($msgFile, "feat: añade ñandú`n", (New-Object System.Text.UTF8Encoding($false)))
        git -C $repo add -A | Out-Null
        git -C $repo -c user.name=t -c user.email=t@example.com commit -q -F $msgFile | Out-Null
        $r = Get-GitSummary -RepoRoot $repo -BaseBranch master
        $r.ahead | Should Be 12
        @($r.commits).Count | Should Be 10
        $r.commits[0].subject | Should Be 'feat: añade ñandú'
        @((Get-GitSummary -RepoRoot $repo -BaseBranch master -MaxCommits 3).commits).Count | Should Be 3
    }
}

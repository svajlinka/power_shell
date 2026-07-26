function projects {
    $f = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

    if (-not (Test-Path $f)) {
        Write-Warning "Hittar inte Windows Terminals settings.json"
        return
    }

    while ($true) {
        $profiler = (Get-Content $f -Raw | ConvertFrom-Json).profiles.list
        $allaNamn = @($profiler | ForEach-Object { $_.name })
        $lista    = @($profiler | Where-Object { -not $_.hidden } | ForEach-Object { $_.name } | Sort-Object)

        Write-Host ""
        for ($i = 0; $i -lt $lista.Count; $i++) {
            "{0,2}. {1}" -f ($i + 1), $lista[$i]
        }
        Write-Host "`n  a = lagg till ny   q = avsluta" -ForegroundColor DarkGray

        $svar = Read-Host "`nVal"

        if ([string]::IsNullOrWhiteSpace($svar)) { continue }
        if ($svar -eq 'q') { return }

        if ($svar -eq 'a') {
            $sokv = Read-Host "Sokvag (Enter = valj i utforskaren)"

            if ([string]::IsNullOrWhiteSpace($sokv)) {
                Add-Type -AssemblyName System.Windows.Forms
                $d = New-Object System.Windows.Forms.FolderBrowserDialog
                if ($d.ShowDialog() -ne 'OK') { continue }
                $sokv = $d.SelectedPath
            }

            $sokv = $sokv.Trim().Trim('"').TrimEnd('\')

            if (-not (Test-Path $sokv)) {
                Write-Warning "Sokvagen finns inte: $sokv"
                continue
            }

            $namn = Split-Path $sokv -Leaf

            if ($allaNamn -contains $namn) {
                Write-Warning "Profilen '$namn' finns redan."
                continue
            }

            Write-Host ""
            Write-Host "  Namn:   $namn"
            Write-Host "  Mapp:   $sokv"
            $ok = Read-Host "`nLagg till? (j/n)"
            if ($ok -ne 'j') {
                Write-Host "Avbrutet." -ForegroundColor DarkGray
                continue
            }

            Copy-Item $f "$f.bak" -Force
            $s = Get-Content $f -Raw | ConvertFrom-Json
            $ny = [PSCustomObject]@{
                name                     = $namn
                commandline              = "powershell.exe -NoExit -Command claude"
                startingDirectory        = $sokv
                tabTitle                 = $namn
                suppressApplicationTitle = $true
                guid                     = "{$([guid]::NewGuid())}"
            }
            $s.profiles.list = @($ny) + $s.profiles.list
            $s | ConvertTo-Json -Depth 20 | Set-Content $f -Encoding UTF8
            Write-Host "Lade till '$namn'." -ForegroundColor Green
            continue
        }

        foreach ($v in ($svar -split '\s+' | Where-Object { $_ })) {
            if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $lista.Count) {
                wt -w 0 nt -p $lista[[int]$v - 1]
                Start-Sleep -Milliseconds 300
            } else {
                Write-Warning "Ogiltigt: $v"
            }
        }
    }
}

Set-Alias p projects
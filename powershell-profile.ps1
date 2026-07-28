function Start-ProjectWindow {
    param(
        [string]$ProfileName,
        [string[]]$Commands = @('codex', 'codex', 'claude', 'claude')  # left to right
    )

    $q     = '"{0}"' -f $ProfileName
    $shell = 'powershell.exe -NoExit -Command'
    $parts = @("-w new nt -p $q $shell $($Commands[0])")

    # Each sp splits the focused pane, so the fraction must shrink to get equal columns.
    for ($i = 1; $i -lt $Commands.Count; $i++) {
        $share = ($Commands.Count - $i) / ($Commands.Count - $i + 1)
        $size  = $share.ToString('0.####', [cultureinfo]::InvariantCulture)
        $parts += "sp -V -s $size -p $q $shell $($Commands[$i])"
    }
    $parts += 'mf first'

    Start-Process wt -ArgumentList ($parts -join ' ; ')
}

function Get-ProjectProfileName {
    param([string]$Path)

    $folderName = Split-Path $Path -Leaf
    return "$folderName (d $Path)"
}

function projects {
    $settingsFile = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"

    if (-not (Test-Path $settingsFile)) {
        Write-Warning "Cannot find Windows Terminal's settings.json"
        return
    }

    while ($true) {
        $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        $profiles = $settings.profiles.list
        $allNames = @($profiles | ForEach-Object { $_.name })
        $list     = @($profiles | Where-Object { -not $_.hidden } | Sort-Object -Property name)

        Write-Host ""
        for ($i = 0; $i -lt $list.Count; $i++) {
            "{0,2}. {1}" -f ($i + 1), $list[$i].name
        }
        Write-Host "`n  a = add new   r = remove   q = quit" -ForegroundColor DarkGray

        $answer = Read-Host "`nChoice"

        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        if ($answer -eq 'q') { return }

        if ($answer -eq 'a') {
            $path = Read-Host "Path (Enter = browse)"

            if ([string]::IsNullOrWhiteSpace($path)) {
                Add-Type -AssemblyName System.Windows.Forms
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                if ($dialog.ShowDialog() -ne 'OK') { continue }
                $path = $dialog.SelectedPath
            }

            $path = $path.Trim().Trim('"').TrimEnd('\')

            if (-not (Test-Path $path)) {
                Write-Warning "Path does not exist: $path"
                continue
            }

            $name = Get-ProjectProfileName -Path $path

            if ($allNames -contains $name) {
                Write-Warning "Profile '$name' already exists."
                continue
            }

            Write-Host ""
            Write-Host "  Name:   $name"
            Write-Host "  Folder: $path"
            $confirm = Read-Host "`nAdd? (y/n)"
            if ($confirm -ne 'y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            Copy-Item $settingsFile "$settingsFile.bak" -Force
            $newProfile = [PSCustomObject]@{
                name                     = $name
                commandline              = "powershell.exe -NoExit -Command claude"
                startingDirectory        = $path
                tabTitle                 = $name
                suppressApplicationTitle = $true
                guid                     = "{$([guid]::NewGuid())}"
            }
            $settings.profiles.list = @($newProfile) + $settings.profiles.list
            $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding UTF8
            Write-Host "Added '$name'." -ForegroundColor Green
            continue
        }

        if ($answer -eq 'r') {
            $removeAnswer = Read-Host "Numbers to remove (space or comma separated)"
            $choices = @($removeAnswer -split '[,\s]+' | Where-Object { $_ })

            if ($choices.Count -eq 0) {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            $invalidChoices = @($choices | Where-Object {
                $_ -notmatch '^\d+$' -or [int]$_ -lt 1 -or [int]$_ -gt $list.Count
            })
            if ($invalidChoices.Count -gt 0) {
                Write-Warning "Invalid: $($invalidChoices -join ', ')"
                continue
            }

            $selectedProfiles = @($choices |
                ForEach-Object { $list[[int]$_ - 1] } |
                Sort-Object -Property guid -Unique)

            $nonProjectProfiles = @($selectedProfiles | Where-Object {
                $_.commandline -ne 'powershell.exe -NoExit -Command claude' -or
                [string]::IsNullOrWhiteSpace($_.startingDirectory)
            })
            if ($nonProjectProfiles.Count -gt 0) {
                Write-Warning "Cannot remove non-project profile(s): $($nonProjectProfiles.name -join ', ')"
                continue
            }

            Write-Host ""
            $selectedProfiles | ForEach-Object { Write-Host "  $($_.name)" }
            $confirm = Read-Host "`nRemove these profiles? (y/n)"
            if ($confirm -ne 'y') {
                Write-Host "Cancelled." -ForegroundColor DarkGray
                continue
            }

            $selectedGuids = @($selectedProfiles | ForEach-Object { "$($_.guid)" })
            Copy-Item $settingsFile "$settingsFile.bak" -Force
            $settings.profiles.list = @($settings.profiles.list | Where-Object {
                $selectedGuids -notcontains "$($_.guid)"
            })
            $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsFile -Encoding UTF8
            Write-Host "Removed $($selectedProfiles.Count) profile(s)." -ForegroundColor Green
            continue
        }

        foreach ($choice in ($answer -split '[,\s]+' | Where-Object { $_ })) {
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $list.Count) {
                Start-ProjectWindow -ProfileName $list[[int]$choice - 1].name
                Start-Sleep -Milliseconds 300
            } else {
                Write-Warning "Invalid: $choice"
            }
        }
    }
}

Set-Alias p projects

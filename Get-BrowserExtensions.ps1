# Tanium Sensor: Browser Extensions (Chrome / Edge)
#
# Result Type : Table
# Columns     : User | Browser | Profile | Extension Name | Extension ID | Version | State | Store
# Delimiter   : | (pipe)

function Read-JsonFile {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
}

function Get-ExtensionSettings {
    param([string]$ProfilePath)
    foreach ($file in @('Secure Preferences', 'Preferences')) {
        $path = Join-Path $ProfilePath $file
        if (-not (Test-Path $path)) { continue }
        try {
            $json = Read-JsonFile $path
            if ($json.extensions.settings) { return $json.extensions.settings }
        } catch {}
    }
    return $null
}

function Resolve-LocalizedName {
    param([string]$RawName, [string]$VersionDir)
    if ($RawName -notmatch '^__MSG_(.+)__$') { return $RawName }
    $msgKey = $Matches[1]

    $defaultLocale = 'en'
    try {
        $m = Read-JsonFile (Join-Path $VersionDir 'manifest.json')
        if ($m.default_locale) { $defaultLocale = $m.default_locale }
    } catch {}

    foreach ($locale in @($defaultLocale, 'en', 'en_US', 'en_GB')) {
        $msgFile = Join-Path $VersionDir "_locales\$locale\messages.json"
        if (-not (Test-Path $msgFile)) { continue }
        try {
            $msgs = Read-JsonFile $msgFile
            $prop = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $msgKey } | Select-Object -First 1
            if ($prop -and $prop.Value.message) { return $prop.Value.message }
        } catch {}
    }
    return $RawName
}

function Get-ExtensionName {
    param([string]$PrefsName, [string]$ProfilePath, [string]$ExtId)
    if ($PrefsName) { return $PrefsName }

    $extPath = Join-Path $ProfilePath "Extensions\$ExtId"
    $versionDirs = Get-ChildItem $extPath -Directory -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending
    foreach ($vd in $versionDirs) {
        $mfPath = Join-Path $vd.FullName 'manifest.json'
        if (-not (Test-Path $mfPath)) { continue }
        try {
            $mf = Read-JsonFile $mfPath
            if ($mf.name) { return Resolve-LocalizedName -RawName $mf.name -VersionDir $vd.FullName }
        } catch {}
    }
    return 'Unknown'
}

function Get-ExtensionState {
    param($ExtObj)
    $state         = $ExtObj.state
    $disableReason = $ExtObj.disable_reasons

    if ($state -eq 3) { return 'Disabled (Policy/Blocklist)' }
    if ($state -eq 0) { return 'Disabled' }
    if ($disableReason -and @($disableReason).Count -gt 0) { return 'Disabled' }
    return 'Enabled'
}

$excludedProfiles = @(
    'Administrator',
    'Public',
    'Default'
)

$excludedProfilesWildcard = @(
    'defaultuser*'
)

function Test-ExcludedProfile {
    param([string]$Name)
    if ($excludedProfiles -contains $Name) { return $true }
    foreach ($pattern in $excludedProfilesWildcard) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

$browsers = @(
    [PSCustomObject]@{ Name = 'Chrome'; RelPath = 'AppData\Local\Google\Chrome\User Data' },
    [PSCustomObject]@{ Name = 'Edge';   RelPath = 'AppData\Local\Microsoft\Edge\User Data' }
)

$profilePattern = '^(Default|Guest Profile|Profile \d+)$'

foreach ($userDir in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
    if (Test-ExcludedProfile $userDir.Name) { continue }

    foreach ($browser in $browsers) {
        $udPath = Join-Path $userDir.FullName $browser.RelPath
        if (-not (Test-Path $udPath -PathType Container)) { continue }

        foreach ($profileDir in (Get-ChildItem $udPath -Directory -ErrorAction SilentlyContinue |
                                  Where-Object { $_.Name -match $profilePattern })) {

            $settings = Get-ExtensionSettings -ProfilePath $profileDir.FullName
            if (-not $settings) { continue }

            foreach ($prop in $settings.PSObject.Properties) {
                $extId  = $prop.Name
                $extObj = $prop.Value

                if ($extObj.location -eq 5) { continue }
                if ($extObj.was_installed_by_default -eq $true) { continue }

                $extPath = Join-Path $profileDir.FullName "Extensions\$extId"
                if (-not (Test-Path $extPath)) { continue }

                $extName = Get-ExtensionName `
                    -PrefsName $extObj.manifest.name `
                    -ProfilePath $profileDir.FullName `
                    -ExtId $extId

                $store = switch -Regex ($extObj.manifest.update_url) {
                    'clients2\.google\.com' { 'Chrome Web Store'; break }
                    'edge\.microsoft\.com'  { 'Edge Add-ons'; break }
                    default                 { 'Other' }
                }

                Write-Output ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f
                    $userDir.Name,
                    $browser.Name,
                    $profileDir.Name,
                    $extName,
                    $extId,
                    $extObj.manifest.version,
                    (Get-ExtensionState $extObj),
                    $store)
            }
        }
    }
}

<#
.SYNOPSIS
    Tanium Sensor: Device Management Identifiers & Sync Times
.DESCRIPTION
    Reports the following for the local device:
      - Device Name and Domain Name
      - Intune Device ID and Last Sync Time
      - Entra (Azure AD) Device ID
      - SCCM Client GUID and Last Sync Time (hardware inventory)
    
    Designed for co-managed (SCCM + Intune) environments with a mix
    of Hybrid Azure AD Joined and Azure AD Joined devices.

    In co-management scenarios the Intune Device ID is the Entra
    Device ID.  The Intune last-sync time is derived from the
    EnterpriseMgmt scheduled tasks that the MDM client creates.

    Columns: DeviceName | DomainName | IntuneDeviceID | IntuneLastSync | EntraDeviceID | SCCMClientGUID | SCCMLastSync
#>


$DeviceName = $env:COMPUTERNAME
$DomainName = try { (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain } catch { $env:USERDNSDOMAIN }
if (-not $DomainName) { $DomainName = "N/A" }

# Entra (Azure AD) Device ID
$EntraDeviceID = "N/A"

try {
    # CloudDomainJoin registry (AAD Joined and most Hybrid Joined)
    $joinInfoPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
    if (Test-Path $joinInfoPath) {
        $joinKeys = Get-ChildItem -Path $joinInfoPath -ErrorAction SilentlyContinue
        foreach ($jk in $joinKeys) {
            if ($jk.PSChildName -match '^[{(]?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[)}]?$') {
                $EntraDeviceID = $jk.PSChildName
                break
            }
        }
    }

    # AAD device certificate — Subject CN is the Device ID
    if ($EntraDeviceID -eq "N/A") {
        $aadCerts = Get-ChildItem -Path "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Issuer -like "*MS-Organization-Access*" }
        foreach ($cert in $aadCerts) {
            if ($cert.Subject -match 'CN=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $EntraDeviceID = $Matches[1]
                break
            }
        }
    }

    # AADResourceID in the Enrollments registry
    if ($EntraDeviceID -eq "N/A") {
        $enrollBase = "HKLM:\SOFTWARE\Microsoft\Enrollments"
        if (Test-Path $enrollBase) {
            foreach ($key in (Get-ChildItem -Path $enrollBase -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.PSObject.Properties.Name -contains "AADResourceID" -and $props.AADResourceID) {
                    $EntraDeviceID = $props.AADResourceID
                    break
                }
            }
        }
    }

    # dsregcmd /status
    if ($EntraDeviceID -eq "N/A") {
        $dsreg = & dsregcmd /status 2>&1 | Out-String
        if ($dsreg -match 'DeviceId\s*:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $EntraDeviceID = $Matches[1]
        }
    }
}
catch {
}

# Intune Device ID & Last Sync Time
$IntuneDeviceID = "N/A"
$IntuneLastSync = "N/A"

try {
    # Intune Device ID
    $enrollmentBasePath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    $enrollmentGUID     = $null

    if (Test-Path $enrollmentBasePath) {
        foreach ($key in (Get-ChildItem -Path $enrollmentBasePath -ErrorAction SilentlyContinue)) {
            if ($key.PSChildName -notmatch '^[0-9a-fA-F]{8}-') { continue }

            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }

            $eType = $props.EnrollmentType

            if ($eType -in @(6, 13, 14, 15, 18)) {
                $enrollmentGUID = $key.PSChildName

                # Check if a dedicated Intune device ID is stored (pure Intune enrollments)
                if ($props.PSObject.Properties.Name -contains "EntDMID" -and $props.EntDMID) {
                    $IntuneDeviceID = $props.EntDMID
                }
                break
            }
        }
    }

    # If no dedicated EntDMID was found, use the Entra Device ID
    if ($IntuneDeviceID -eq "N/A" -and $EntraDeviceID -ne "N/A") {
        $IntuneDeviceID = $EntraDeviceID
    }

    # Intune Last Sync
    # EnterpriseMgmt scheduled tasks (most reliable for co-managed)
    if ($enrollmentGUID) {
        $emTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
                   Where-Object { $_.TaskPath -like "*EnterpriseMgmt*$enrollmentGUID*" }
        
        $latestRun = $null
        foreach ($t in $emTasks) {
            $taskInfo = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            if ($taskInfo -and $taskInfo.LastRunTime -and $taskInfo.LastRunTime -gt (Get-Date "2000-01-01")) {
                if (-not $latestRun -or $taskInfo.LastRunTime -gt $latestRun) {
                    $latestRun = $taskInfo.LastRunTime
                }
            }
        }
        if ($latestRun) {
            $IntuneLastSync = $latestRun.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    # any EnterpriseMgmt task
    if ($IntuneLastSync -eq "N/A") {
        $emTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
                   Where-Object { $_.TaskPath -like "*EnterpriseMgmt*" }
        
        $latestRun = $null
        foreach ($t in $emTasks) {
            $taskInfo = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            if ($taskInfo -and $taskInfo.LastRunTime -and $taskInfo.LastRunTime -gt (Get-Date "2000-01-01")) {
                if (-not $latestRun -or $taskInfo.LastRunTime -gt $latestRun) {
                    $latestRun = $taskInfo.LastRunTime
                }
            }
        }
        if ($latestRun) {
            $IntuneLastSync = $latestRun.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    # MDM event log (Event 209 = successful check-in)
    if ($IntuneLastSync -eq "N/A") {
        $mdmLog = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational" -FilterXPath "*[System[EventID=209]]" -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($mdmLog) {
            $IntuneLastSync = $mdmLog.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
}
catch {
    # Silently continue
}

# ConfigMgr Client GUID & Last Sync Time
$SCCMClientGUID = "N/A"
$SCCMLastSync   = "N/A"

try {
    # WMI
    $smsClient = Get-WmiObject -Namespace "root\ccm" -Class "CCM_Client" -ErrorAction SilentlyContinue
    if ($smsClient) {
        $SCCMClientGUID = $smsClient.ClientId
    }
    else {
        # Registry
        $smsRegPath = "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client"
        if (Test-Path $smsRegPath) {
            $smsReg = Get-ItemProperty -Path $smsRegPath -ErrorAction SilentlyContinue
            if ($smsReg.PSObject.Properties.Name -contains "Device Management Client Identifier") {
                $SCCMClientGUID = $smsReg."Device Management Client Identifier"
            }
        }
    }

    # Last hardware inventory cycle
    $invAction = Get-WmiObject -Namespace "root\ccm\invagt" -Class "InventoryActionStatus" -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000001}'" -ErrorAction SilentlyContinue
    if ($invAction -and $invAction.LastReportDate) {
        $SCCMLastSync = [System.Management.ManagementDateTimeConverter]::ToDateTime($invAction.LastReportDate).ToString("yyyy-MM-dd HH:mm:ss")
    }
    else {
        # last policy evaluation
        $policyEval = Get-WmiObject -Namespace "root\ccm\Policy" -Class "CCM_PolicyAgent_Configuration" -ErrorAction SilentlyContinue
        if ($policyEval -and $policyEval.LastPolicyEvaluationTime) {
            $SCCMLastSync = $policyEval.LastPolicyEvaluationTime
        }
    }
}
catch {
}

# Output
$output = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f `
    $DeviceName,
    $DomainName,
    $IntuneDeviceID,
    $IntuneLastSync,
    $EntraDeviceID,
    $SCCMClientGUID,
    $SCCMLastSync

Write-Output $output

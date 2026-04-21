#Windows Defender:AM Running Mode

try {
    $status = Get-MpComputerStatus -ErrorAction Stop
    Write-Output $status.AMRunningMode
}
catch {
    Write-Output "No result returned."
}

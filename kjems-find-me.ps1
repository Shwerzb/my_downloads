<# Finds how ManageEngine still manages this PC (incl. MDM enrollment). Read-only. #>
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""); return }
$ErrorActionPreference="SilentlyContinue"
New-Item 'C:\KJEMS' -ItemType Directory -Force|Out-Null
Start-Transcript -Path 'C:\KJEMS\find-me.txt' -Force | Out-Null
function H($t){ Write-Host ""; Write-Host "==== $t ====" -ForegroundColor Cyan }

H "MDM ENROLLMENTS (this is how ManageEngine re-applies at login)"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' | Where-Object { $_.PSChildName -match '^[0-9A-F\-]{36}$' } | ForEach-Object {
  $p=Get-ItemProperty $_.PSPath
  if($p.ProviderID -or $p.DiscoveryServiceFullURL -or $p.UPN){
    Write-Host ("  Enrollment {0}" -f $_.PSChildName)
    Write-Host ("     ProviderID: {0}" -f $p.ProviderID)
    Write-Host ("     Server:     {0}" -f $p.DiscoveryServiceFullURL)
    Write-Host ("     EnrollType: {0}   User: {1}" -f $p.EnrollmentType,$p.UPN)
  }
}
H "dsregcmd MDM lines"
(dsregcmd /status) | Select-String -Pattern 'MDMUrl|MdmEnrollmentUrl|Device Auth|Domain Joined|Workplace|Tenant' | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }

H "SERVICES mentioning ME/DC/UEMS/Endpoint"
Get-CimInstance Win32_Service | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match 'ManageEngine|UEMS|DesktopCentral|Endpoint Central|dcagent|AdventNet' } | ForEach-Object { Write-Host ("  {0} [{1}/{2}] {3}" -f $_.Name,$_.State,$_.StartMode,$_.PathName) }

H "SCHEDULED TASKS referencing ManageEngine/UEMS/dc"
Get-ScheduledTask | Where-Object { ($_.Actions.Execute -join ' ') -match 'ManageEngine|UEMS|dcagent|AdventNet' } | ForEach-Object { Write-Host ("  {0}{1} [{2}] -> {3}" -f $_.TaskPath,$_.TaskName,$_.State,($_.Actions.Execute -join ';')) }

H "UNINSTALL entries"
foreach($k in "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"){
  Get-ItemProperty $k | Where-Object { $_.DisplayName -match 'ManageEngine|Endpoint Central|Desktop Central|UEMS' } | ForEach-Object { Write-Host ("  {0}" -f $_.DisplayName); Write-Host ("     Uninstall: {0}" -f $_.UninstallString) }
}

H "PolicyManager providers (MDM-applied policy sources)"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers' | ForEach-Object { Write-Host ("  " + $_.PSChildName) }

Stop-Transcript | Out-Null
Write-Host ""; Write-Host "Saved to C:\KJEMS\find-me.txt -- open it and paste the whole thing back." -ForegroundColor Green

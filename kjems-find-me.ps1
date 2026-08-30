<# Finds every ManageEngine component so it can be removed. Read-only. #>
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""); return }
$ErrorActionPreference="SilentlyContinue"
$out="C:\KJEMS\find-me.txt"; New-Item 'C:\KJEMS' -ItemType Directory -Force|Out-Null; ""|Out-File $out
function H($t){ Write-Host ""; Write-Host "==== $t ====" -ForegroundColor Cyan }

H "SERVICES (name/display/path mentioning ME / DC / UEMS / Endpoint)"
Get-CimInstance Win32_Service | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match 'ManageEngine|UEMS|DesktopCentral|Endpoint Central|dcagent|dcservice|MEDC' } |
  ForEach-Object { Write-Host ("  {0}  [{1}/{2}]  {3}" -f $_.Name,$_.State,$_.StartMode,$_.PathName) }

H "PROCESSES running from ManageEngine"
Get-Process | Where-Object { $_.Path -match 'ManageEngine|UEMS' } | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.ProcessName,$_.Path) }

H "SCHEDULED TASKS referencing ManageEngine/UEMS"
Get-ScheduledTask | Where-Object { ($_.Actions.Execute -join ' ') -match 'ManageEngine|UEMS|dcagent' } |
  ForEach-Object { Write-Host ("  {0}\{1}  [{2}]  -> {3}" -f $_.TaskPath,$_.TaskName,$_.State,($_.Actions.Execute -join ';')) }

H "UNINSTALL entries (Programs and Features)"
foreach($k in "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"){
  Get-ItemProperty $k | Where-Object { $_.DisplayName -match 'ManageEngine|Endpoint Central|Desktop Central|UEMS' } |
    ForEach-Object { Write-Host ("  {0}" -f $_.DisplayName); Write-Host ("     Uninstall: {0}" -f $_.UninstallString); Write-Host ("     Quiet:     {0}" -f $_.QuietUninstallString) }
}

H "UNINSTALLER exes in the ManageEngine tree"
Get-ChildItem 'C:\Program Files (x86)\ManageEngine','C:\Program Files\ManageEngine' -Recurse -Filter *.exe |
  Where-Object { $_.Name -match 'uninst|remove|UEMSAgentUninstall|DCAgentUninstall' } | ForEach-Object { Write-Host ("  {0}" -f $_.FullName) }

H "Agent registry (may hold uninstall code / server)"
foreach($p in "HKLM:\SOFTWARE\WOW6432Node\AdventNet\DesktopCentral\DCAgent","HKLM:\SOFTWARE\AdventNet\ManageEngine"){ if(Test-Path $p){ Write-Host ("  key: {0}" -f $p) } }
"" | Out-File $out -Append
Write-Host ""; Write-Host "Copy everything above back to Claude." -ForegroundColor Green

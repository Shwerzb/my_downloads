<#
  kjems-mdm-unenroll.ps1
  Force-removes the ManageEngine (MEMDM) MDM enrollment from THIS PC, as SYSTEM.
  Use ONLY to migrate this machine off ManageEngine. REBOOT afterward.
  Auto-detects the MEMDM enrollment GUID (works on any of your PCs).
#>
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){ Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""); return }
$ErrorActionPreference="SilentlyContinue"
New-Item 'C:\KJEMS' -ItemType Directory -Force | Out-Null

# --- payload runs as SYSTEM (enrollment/OMADM keys are SYSTEM-owned) ---
$payload = @'
$ErrorActionPreference="SilentlyContinue"
$log="C:\KJEMS\mdm-unenroll.txt"; "MDM unenroll $(Get-Date)" | Out-File $log
function L($t){ $t | Out-File $log -Append }
$root="HKLM:\SOFTWARE\Microsoft\Enrollments"
$targets=@()
Get-ChildItem $root | Where-Object { $_.PSChildName -match '^[0-9A-Fa-f\-]{36}$' } | ForEach-Object {
  $p=Get-ItemProperty $_.PSPath
  if($p.ProviderID -eq 'MEMDM' -or $p.DiscoveryServiceFullURL -match 'manageengine'){ $targets += $_.PSChildName }
}
L ("Targets: " + ($targets -join ', '))
foreach($id in $targets){
  Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$id\" | Unregister-ScheduledTask -Confirm:$false
  try { $svc=New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder("\Microsoft\Windows\EnterpriseMgmt").DeleteFolder($id,0) } catch { L ("taskfolder: "+$_.Exception.Message) }
  foreach($k in @(
    "HKLM:\SOFTWARE\Microsoft\Enrollments\$id",
    "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$id",
    "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$id",
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$id",
    "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$id",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$id",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$id",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$id"
  )){ Remove-Item $k -Recurse -Force; L ("del: $k") }
}
$still = @(Get-ChildItem $root | Where-Object { (Get-ItemProperty $_.PSPath).ProviderID -eq 'MEMDM' })
L ("MEMDM remaining after removal: " + $still.Count)
'@
Set-Content 'C:\KJEMS\_mdmrm.ps1' -Value $payload -Encoding UTF8 -Force

Write-Host "Running MDM removal as SYSTEM..." -ForegroundColor Yellow
schtasks /Create /TN "KJEMS_MDMRemove" /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\KJEMS\_mdmrm.ps1" /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F | Out-Null
schtasks /Run /TN "KJEMS_MDMRemove" | Out-Null
Start-Sleep -Seconds 15
schtasks /Delete /TN "KJEMS_MDMRemove" /F | Out-Null
Remove-Item 'C:\KJEMS\_mdmrm.ps1' -Force

Write-Host ""; Write-Host "=== Result ===" -ForegroundColor Cyan
Get-Content 'C:\KJEMS\mdm-unenroll.txt'
Write-Host ""; Write-Host "If 'MEMDM remaining after removal: 0', REBOOT this PC, then re-run the provisioning with -ResetDispatcher." -ForegroundColor Green

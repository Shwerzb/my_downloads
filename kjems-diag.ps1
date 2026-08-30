<#
  kjems-diag.ps1 -- read-only diagnosis of why the kiosk lockdown isn't sticking.
  Self-elevates, prints to the window, and saves C:\KJEMS\kjems-diag.txt.
  Nothing is changed on the machine.
#>
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
    return
}

$ErrorActionPreference = "SilentlyContinue"
New-Item 'C:\KJEMS' -ItemType Directory -Force | Out-Null
$out = "C:\KJEMS\kjems-diag.txt"
Start-Transcript -Path $out -Force | Out-Null

function H($t){ Write-Host ""; Write-Host "==== $t ====" -ForegroundColor Cyan }

H "Windows build"
(Get-CimInstance Win32_OperatingSystem).Caption + "  " + [Environment]::OSVersion.Version.ToString()

H "Leftover Local Group Policy (should be GONE after running the script)"
foreach($f in "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol","$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol"){
  if(Test-Path $f){ $b=[IO.File]::ReadAllBytes($f); $amz=([Text.Encoding]::Unicode.GetString($b) -match 'amazon'); Write-Host ("PRESENT: $f  ({0} bytes, amazon={1})" -f $b.Length,$amz) -ForegroundColor Yellow }
  else { Write-Host "gone: $f" -ForegroundColor Green }
}

$sid = (Get-LocalUser -Name kioskUser0).SID.Value
Write-Host "kioskUser0 SID: $sid"
$loaded=$false; $key="HKU\$sid"
if(-not (Test-Path "Registry::HKEY_USERS\$sid")){ & reg.exe load "HKU\KJDIAG" "C:\Users\kioskUser0\NTUSER.DAT" | Out-Null; $key="HKU\KJDIAG"; $loaded=$true; Start-Sleep -Milliseconds 400 } else { Write-Host "(kioskUser0 hive already loaded -- likely logged in)" }

H "Chrome URLBlocklist (should be: 1 = *)"
& reg.exe query "$key\Software\Policies\Google\Chrome\URLBlocklist"
H "Chrome URLAllowlist (should be your EMS sites, NOT amazon.com)"
& reg.exe query "$key\Software\Policies\Google\Chrome\URLAllowlist"
H "Taskbar Start Layout policy (should point to taskbar-layout.xml)"
& reg.exe query "$key\Software\Policies\Microsoft\Windows\Explorer" /v StartLayoutFile

if($loaded){ [GC]::Collect(); Start-Sleep -Milliseconds 600; & reg.exe unload "HKU\KJDIAG" | Out-Null }

H "Taskbar layout file"
Write-Host ("C:\ProgramData\KJEMS\taskbar-layout.xml exists: " + (Test-Path 'C:\ProgramData\KJEMS\taskbar-layout.xml'))

H "Chrome cloud management (HKLM)"
& reg.exe query "HKLM\Software\Policies\Google\Chrome" /v CloudManagementEnrollmentToken

H "Other management still on this PC"
Write-Host ("ManageEngine folder: " + (Test-Path 'C:\Program Files (x86)\ManageEngine'))
Write-Host ("Intune agent running: " + ((Get-Process 'Microsoft.Management.Services.IntuneWindowsAgent' -EA SilentlyContinue|Measure-Object).Count))
Write-Host "ManageEngine services (RUNNING = it will re-apply lockdown):"
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'ManageEngine|UEMS|DesktopCentral' } | ForEach-Object { Write-Host ("  {0} [{1}] {2}" -f $_.Name,$_.State,$_.PathName) }
Get-Process | Where-Object { $_.Path -match 'ManageEngine|UEMS' } | ForEach-Object { Write-Host ("  proc: {0}" -f $_.Path) }

H "kioskUser0 profiles (want ONE clean entry, NO orphans, NO temp)"
$pl2 = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
Get-ChildItem $pl2 | ForEach-Object {
  $img=(Get-ItemProperty $_.PSPath -EA SilentlyContinue).ProfileImagePath
  $st =(Get-ItemProperty $_.PSPath -EA SilentlyContinue).State
  if ($img -like '*kioskUser0*' -or $img -like '*TEMP*' -or $_.PSChildName -like '*.bak') {
    Write-Host ("  {0}  {1}  State={2}" -f $_.PSChildName,$img,$st) -ForegroundColor Yellow
  }
}
H "C:\Users folders for the dispatcher"
Get-ChildItem 'C:\Users' -Directory -EA SilentlyContinue | Where-Object { $_.Name -like 'kioskUser0*' -or $_.Name -like 'TEMP*' } | ForEach-Object { Write-Host ("  " + $_.Name) }

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Saved to $out -- copy the text above (or that file) back to Claude." -ForegroundColor Green

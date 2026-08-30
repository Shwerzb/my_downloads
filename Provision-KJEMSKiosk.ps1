<#
===============================================================================
 Provision-KJEMSKiosk.ps1
 One-shot provisioning for KJ EMS dispatcher kiosk PCs (replaces ManageEngine).

 WHAT IT DOES (in order):
   1.  Relax the local password policy so short passwords are allowed
   2.  Create the local ADMIN account   (skips if it already exists)
   3.  Create the dispatcher account     (skips if it already exists)
   4.  Set passwords + "never expires"
   5.  Create the dispatcher profile on disk WITHOUT needing an interactive
       logon (Win32 CreateProfile) so per-user settings can be applied in one pass
   6.  Install software (VC++, Chrome, ScreenConnect, Bria, Jabra, Lexip)
   7.  Apply the Chrome kiosk policy (allow/block list, extensions, hardening)
       to the DISPATCHER ONLY  -- the admin keeps a normal Chrome
   8.  Import Chrome bookmarks
   9.  Disable Windows 11 widgets, set wallpaper/lock screen
   9b. Block Edge for the dispatcher + kill Microsoft first-login prompts
       ("finish setting up your device", privacy screen, tips, suggested apps)
   10. Disable Google / Edge / OneDrive updaters
   11. Dispatcher desktop lockdown (settings visibility, OneDrive off,
       recycle bin hidden, volume shortcut, startup programs)
   12. Bria auto-launch scheduled task
   13. Lexip default-profile cleanup
   14. Print a COLOR-CODED summary of every step (OK / FAIL / SKIP + reason)

 HOW TO RUN:
   Right-click > Run with PowerShell (as Administrator), or from an elevated prompt:
       powershell -ExecutionPolicy Bypass -File ".\Provision-KJEMSKiosk.ps1"

 NOTES:
   * Everything is wrapped so ONE failed step never aborts the rest.
   * A full transcript is written to C:\ProgramData\KJEMS\Provision_<timestamp>.log
   * Installers with no download URL are expected in an "Installers" folder next
     to this script (see the $Software table). Edit that table for your files.
===============================================================================
#>

param(
    # Delete the dispatcher profile first so it is recreated fresh (taskbar / Start
    # pins reliably apply only to a brand-new profile). The dispatcher must be
    # signed out. The account itself is kept.
    [switch]$ResetDispatcher
)

# ---------------------------------------------------------------------------
#  Self-elevate: relaunch as Administrator (UAC prompt) if not already elevated
# ---------------------------------------------------------------------------
$__isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $__isAdmin) {
    if (-not $PSCommandPath) {
        Write-Host "Run this as a .ps1 file (not pasted into the console) so it can request elevation." -ForegroundColor Red
        exit 1
    }
    Write-Host "Requesting administrator rights -- approve the UAC prompt..." -ForegroundColor Yellow
    try {
        $relaunchArgs = @("-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
        if ($ResetDispatcher) { $relaunchArgs += "-ResetDispatcher" }
        Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList $relaunchArgs
    } catch {
        Write-Host "Elevation was cancelled -- the script did not run." -ForegroundColor Red
        exit 1
    }
    exit
}

# =============================================================================
#  CONFIG  --  EDIT THESE VALUES
# =============================================================================

# ---- Accounts ---------------------------------------------------------------
$DispatcherUser     = "kioskUser0"
$DispatcherPassword = ""                  # blank = dispatcher logs in with NO password
$DispatcherFullName = "Dispatcher"

$AdminUser          = "Berish"           # local admin account name
$AdminFullName      = "Berish"
# NOTE: the admin password is NOT stored here -- the script prompts you to type
#       it (twice, hidden) when it runs.

# ---- Chrome kiosk -----------------------------------------------------------
$KioskUrl = "https://hatzalahweb.datavanced.com"

$ChromeExtensionIds = @(
    "mhepdhfghgjcpkkcaeajofhgknanaopl",
    "hdhinadidafjejdhmfkjgnolgimiaplp"
)

$ChromeStartupSites = @(
    $KioskUrl
)

$ChromeAllowedSites = @(
    "https://hatzalahweb.datavanced.com/*",
    "chrome-extension://mhepdhfghgjcpkkcaeajofhgknanaopl/*",
    "chrome-extension://hdhinadidafjejdhmfkjgnolgimiaplp/*",
    "https://clients2.google.com/*",
    "https://clients4.google.com/*",
    "https://clients5.google.com/*",
    "https://clients6.google.com/*",
    "https://chrome.google.com/*",
    "https://chromewebstore.google.com/*",
    "https://*.googleusercontent.com/*",
    "https://*.gstatic.com/*",
    "https://www.google.com/maps",
    "hatzalahweb.datavanced.com",
    "*.creativeemssolutions.com/*",
    "*.creativeems.com/*",
    "https://www.teamconnectapp.com/*",
    "teamconnectapp.com",
    "creativeemssolutions.com",
    "creativeems.com",
    "*.datavanced.com/*",
    "*.teamconnectapp.com/*",
    "*.screenconnect.com/*",
    "*.7831212.com/*",
    "*.7830112.com/*",
    "https://cloud.samsara.com/*",
    "cloud.samsara.com",
    "google.com/maps",
    "maps.google.com",
    "http://maps.google.com/*",
    "*.google.com/maps/*"
)

$ChromeWebStoreUpdateUrl = "https://clients2.google.com/service/update2/crx"

# Sites granted Location (geolocation) + Pop-up permission in the dispatcher Chrome
$ChromeSitePermissionUrls = @(
    "hatzalahweb.datavanced.com",
    "[*.]teamconnectapp.com"
)

# ---- Dispatcher blocked apps -------------------------------------------------
# The dispatcher is BLOCKED from launching these executables (matched by file
# name). A blocklist keeps the Windows shell fully working (taskbar, volume,
# tray, startup apps) -- a strict allowlist breaks all of that. Add any other
# apps you want to keep the dispatcher out of.
$DispatcherBlockedExes = @(
    "msedge.exe",                                          # Edge -- stay on Chrome
    "iexplore.exe","firefox.exe","opera.exe","brave.exe","chromium.exe",  # other browsers
    "cmd.exe","powershell.exe","powershell_ise.exe","pwsh.exe",           # shells
    "regedit.exe","regedt32.exe",                          # registry
    "taskmgr.exe",                                         # task manager
    "mmc.exe","gpedit.exe","secpol.exe","lusrmgr.exe","compmgmt.exe",     # admin consoles
    "msconfig.exe","control.exe","cscript.exe","wscript.exe",             # config/scripting
    "WinStore.App.exe"                                     # Microsoft Store
)

# ---- Software to install ----------------------------------------------------
# Each entry:
#   Name    = friendly label shown in the summary
#   Detect  = text matched against installed program names; if found -> SKIP
#   Url     = download URL (leave "" to use a local file from .\Installers)
#   File    = filename in .\Installers  (used when Url is "" OR as download target)
#   Args    = silent install switches
#   Kind    = 'msi' or 'exe'
#
# Apps without a public silent URL (Bria/Jabra/Lexip): drop the installer in the
# "Installers" folder next to this script using the File name shown, or set Url.
$Software = @(
    @{ Name='Microsoft Visual C++ 2015-2022 x64'; Detect='Visual C++ 2015-2022 Redistributable (x64)';
       Url='https://aka.ms/vs/17/release/vc_redist.x64.exe'; File='vc_redist.x64.exe';
       Args='/install /quiet /norestart'; Kind='exe' }

    @{ Name='Google Chrome';                       Detect='Google Chrome';
       Url='https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; File='googlechromestandaloneenterprise64.msi';
       Args='/qn /norestart'; Kind='msi' }

    @{ Name='ScreenConnect (KJEMS)';               Detect='ScreenConnect Client';
       Url='https://kjems.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest'; File='screenconnect.msi';
       Args='/qn /norestart'; Kind='msi' }

    @{ Name='Bria Enterprise';                     Detect='Bria Enterprise';
       Url='https://www.counterpath.com/EnterpriseForWindows'; File='Bria_Enterprise.msi';
       Args='/qn /norestart'; Kind='msi' }   # 301/302 -> S3 -> Bria_Enterprise_6.8.8_*.msi

    @{ Name='Jabra Direct';                        Detect='Jabra Direct';
       Url='https://jabraxpressonlineprdstor.blob.core.windows.net/jdo/JabraDirectSetup.exe'; File='JabraDirectSetup.exe';
       Args='/install /quiet /norestart'; Kind='exe' }   # Advanced Installer pkg; fallback: /exenoui /qn

    @{ Name='Lexip Control Software 4';            Detect='Lexip Control Software';
       Url='https://lcs.lexip.co/download/lcp/win'; File='lexip_control_software_4.exe';
       Args='/install /quiet /norestart'; Kind='exe' }   # Advanced Installer pkg; fallback: /exenoui /qn
)

# ---- Paths ------------------------------------------------------------------
$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$InstallersDir = Join-Path $ScriptDir "Installers"
$BookmarksSrc  = Join-Path $ScriptDir "Bookmarks"              # Chrome Bookmarks JSON file (optional)
$WallpaperSrc  = Join-Path $ScriptDir "wallpaper-noclock.png"  # desktop + lock screen image
$WallpaperUrl  = "https://raw.githubusercontent.com/Shwerzb/my_downloads/main/wallpaper-noclock.png"  # auto-downloaded if missing
$LogDir        = "C:\ProgramData\KJEMS"

# =============================================================================
#  END CONFIG  --  no need to edit below
# =============================================================================

$ErrorActionPreference = "Stop"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "Provision_$stamp.log"
Start-Transcript -Path $LogFile -Append | Out-Null

# ---- Win32 CreateProfile (materialize a profile without interactive logon) ---
if (-not ("KJEMS.ProfileHelper" -as [type])) {
    Add-Type -Namespace KJEMS -Name ProfileHelper -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("userenv.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@
}

# ---- Step runner + colored output -------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]

function Write-Banner {
    param([string]$Text)
    $line = "=" * 78
    Write-Host ""
    Write-Host $line          -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor White
    Write-Host $line          -ForegroundColor DarkCyan
}

# Call this inside a step's action to record a deliberate skip with a reason.
function Skip-Step { param([string]$Reason) throw ("SKIP::" + $Reason) }

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Host ("  -> {0} ..." -f $Name) -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = "OK"; $detail = ""
    try {
        $out = & $Action
        if ($out) { $detail = ($out | Out-String).Trim() }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -like "SKIP::*") { $status = "SKIP"; $detail = $msg.Substring(6) }
        else                      { $status = "FAIL"; $detail = $msg }
    }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    switch ($status) {
        "OK"   { Write-Host ("     [ OK ] {0}  ({1}s)" -f $Name, $secs) -ForegroundColor Green }
        "SKIP" { Write-Host ("     [SKIP] {0}  -- {1}"  -f $Name, $detail) -ForegroundColor Yellow }
        "FAIL" { Write-Host ("     [FAIL] {0}  -- {1}"  -f $Name, $detail) -ForegroundColor Red }
    }
    $script:Results.Add([pscustomobject]@{ Step=$Name; Status=$status; Detail=$detail; Seconds=$secs })
}

# ---- Small helpers ----------------------------------------------------------
function Set-RegValue {
    param([string]$Path,[string]$Name,[string]$Type,$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Get-UserSid {
    param([string]$UserName)
    return (Get-LocalUser -Name $UserName -ErrorAction Stop).SID.Value
}

# Runs a scriptblock with the user's hive loaded. Passes the registry root
# ("Registry::HKEY_USERS\<sid>") to the block. Only unloads if we loaded it.
function Use-UserHive {
    param([string]$Sid,[string]$NtUserDat,[scriptblock]$Body)
    $hiveArg = "HKU\$Sid"
    $loaded  = $false
    if (-not (Test-Path "Registry::HKEY_USERS\$Sid")) {
        if (-not (Test-Path $NtUserDat)) { throw "NTUSER.DAT not found: $NtUserDat" }
        & reg.exe load $hiveArg "$NtUserDat" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg load failed for $NtUserDat (exit $LASTEXITCODE)" }
        $loaded = $true
        Start-Sleep -Milliseconds 500
    }
    try {
        & $Body "Registry::HKEY_USERS\$Sid"
    }
    finally {
        if ($loaded) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 700
            & reg.exe unload $hiveArg | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Start-Sleep -Milliseconds 1000
                & reg.exe unload $hiveArg | Out-Null
            }
        }
    }
}

function Read-NewPassword {
    param([string]$Prompt)
    while ($true) {
        $p1 = Read-Host "$Prompt" -AsSecureString
        $p2 = Read-Host "  Confirm password"           -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $b2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ([string]::IsNullOrEmpty($b1)) { Write-Host "  Password cannot be empty. Try again." -ForegroundColor Yellow; continue }
        if ($b1 -ne $b2)                  { Write-Host "  Passwords did not match. Try again."  -ForegroundColor Yellow; continue }
        return $p1
    }
}

function Ensure-Shortcut {
    param([string]$Exe,[string]$Name)
    $dir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
    $lnk = Join-Path $dir "$Name.lnk"
    if (-not (Test-Path $lnk)) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath       = $Exe
        $sc.WorkingDirectory = Split-Path $Exe
        $sc.Save()
    }
    return $lnk
}

function Get-UninstallInfo {
    param([string]$NamePattern)
    foreach ($k in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*$NamePattern*" } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Test-AppInstalled {
    param([string]$NamePattern)
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($k in $keys) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like "*$NamePattern*" }
        if ($hit) { return $true }
    }
    return $false
}

# =============================================================================
#  START
# =============================================================================
try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray'; Clear-Host } catch {}
Write-Banner "KJ EMS Kiosk Provisioning   |   $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host   "  Log file: $LogFile" -ForegroundColor DarkGray
Write-Host   ""

# Ask for the admin password only if the admin account doesn't already exist
# (typed twice, hidden, never written to the log/file)
if (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) {
    $AdminSecurePassword = $null
    Write-Host ("  Admin account '{0}' already exists -- keeping its current password." -f $AdminUser) -ForegroundColor Yellow
} else {
    $AdminSecurePassword = Read-NewPassword "  Enter a password for the new admin account '$AdminUser'"
}

# -----------------------------------------------------------------------------
# 1. Relax password policy
# -----------------------------------------------------------------------------
Write-Banner "1. Password policy"
Invoke-Step "Relax local password policy" {
    $cfg = "$env:TEMP\kjems_secpol.cfg"
    $sdb = "$env:TEMP\kjems_secpol.sdb"
    secedit /export /cfg $cfg /areas SECURITYPOLICY | Out-Null
    $c = Get-Content $cfg
    $c = $c -replace "PasswordHistorySize = \d+",  "PasswordHistorySize = 0"
    $c = $c -replace "MaximumPasswordAge = \d+",   "MaximumPasswordAge = -1"
    $c = $c -replace "MinimumPasswordAge = \d+",   "MinimumPasswordAge = 0"
    $c = $c -replace "MinimumPasswordLength = \d+", "MinimumPasswordLength = 0"
    $c = $c -replace "PasswordComplexity = \d+",   "PasswordComplexity = 0"
    $c = $c -replace "ClearTextPassword = \d+",    "ClearTextPassword = 0"
    Set-Content -Path $cfg -Value $c -Force
    secedit /configure /db $sdb /cfg $cfg /areas SECURITYPOLICY /overwrite /quiet | Out-Null
    Remove-Item $cfg,$sdb -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\net.exe" accounts /minpwlen:0 /maxpwage:unlimited /minpwage:0 | Out-Null
}

# -----------------------------------------------------------------------------
# 2 & 3. Create accounts (skip if they already exist)
# -----------------------------------------------------------------------------
Write-Banner "2. Local accounts"

Invoke-Step "Create admin account '$AdminUser'" {
    if (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) { Skip-Step "already exists" }
    New-LocalUser -Name $AdminUser -Password $AdminSecurePassword -FullName $AdminFullName `
        -AccountNeverExpires -PasswordNeverExpires -ErrorAction Stop | Out-Null
    Add-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Users"          -Member $AdminUser -ErrorAction SilentlyContinue
}

Invoke-Step "Create dispatcher account '$DispatcherUser'" {
    if (Get-LocalUser -Name $DispatcherUser -ErrorAction SilentlyContinue) { Skip-Step "already exists" }
    if ([string]::IsNullOrEmpty($DispatcherPassword)) {
        New-LocalUser -Name $DispatcherUser -NoPassword -FullName $DispatcherFullName `
            -AccountNeverExpires -ErrorAction Stop | Out-Null
    } else {
        $sec = ConvertTo-SecureString $DispatcherPassword -AsPlainText -Force
        New-LocalUser -Name $DispatcherUser -Password $sec -FullName $DispatcherFullName `
            -AccountNeverExpires -PasswordNeverExpires -ErrorAction Stop | Out-Null
    }
    Add-LocalGroupMember -Group "Users" -Member $DispatcherUser -ErrorAction SilentlyContinue
    Set-LocalUser -Name $DispatcherUser -PasswordNeverExpires $true -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# 4. Set passwords / never expires (also fixes existing accounts)
# -----------------------------------------------------------------------------
Invoke-Step "Apply passwords + never-expires" {
    if (Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) {
        if ($AdminSecurePassword) {
            Set-LocalUser -Name $AdminUser -Password $AdminSecurePassword -PasswordNeverExpires $true -ErrorAction Stop
        } else {
            Set-LocalUser -Name $AdminUser -PasswordNeverExpires $true -ErrorAction Stop
        }
    }
    if (Get-LocalUser -Name $DispatcherUser -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrEmpty($DispatcherPassword)) {
            Set-LocalUser -Name $DispatcherUser -Password (New-Object System.Security.SecureString) -PasswordNeverExpires $true -ErrorAction Stop
        } else {
            $sec = ConvertTo-SecureString $DispatcherPassword -AsPlainText -Force
            Set-LocalUser -Name $DispatcherUser -Password $sec -PasswordNeverExpires $true -ErrorAction Stop
        }
        # Update the display name too (create step is skipped for existing accounts)
        Set-LocalUser -Name $DispatcherUser -FullName $DispatcherFullName -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# 5. Materialize dispatcher profile on disk (no interactive logon needed)
# -----------------------------------------------------------------------------
Write-Banner "3. Dispatcher profile"

Invoke-Step "Reset dispatcher profile (-ResetDispatcher)" {
    if (-not $ResetDispatcher) { Skip-Step "not requested" }
    $sid = $null
    try { $sid = Get-UserSid $DispatcherUser } catch {}
    if (-not $sid) { Skip-Step "dispatcher account not found" }

    $prof = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
    if ($prof -and $prof.Loaded) { throw "dispatcher is signed in -- sign it out, then re-run" }

    if ($prof) {
        Remove-CimInstance -InputObject $prof -ErrorAction Stop
        "deleted profile for $DispatcherUser -- it will be recreated fresh"
    } else {
        $p = Join-Path "C:\Users" $DispatcherUser
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        "no registered profile; cleaned any leftover folder"
    }
}

Invoke-Step "Create dispatcher profile on disk" {
    $sid = Get-UserSid $DispatcherUser
    $profileDir = Join-Path "C:\Users" $DispatcherUser
    if (Test-Path (Join-Path $profileDir "NTUSER.DAT")) { Skip-Step "profile already exists" }
    $sb  = New-Object System.Text.StringBuilder 260
    $res = [KJEMS.ProfileHelper]::CreateProfile($sid, $DispatcherUser, $sb, $sb.Capacity)
    # 0 = success ; 0x800700B7 (-2147024713) = already exists
    if ($res -ne 0 -and $res -ne -2147024713) {
        throw ("CreateProfile failed: 0x{0:X8}" -f $res)
    }
    Start-Sleep -Seconds 1
}

# Resolve dispatcher paths for later steps
$DispSid        = $null
try { $DispSid = Get-UserSid $DispatcherUser } catch {}
$DispProfile    = Join-Path "C:\Users" $DispatcherUser
$DispNtUser     = Join-Path $DispProfile "NTUSER.DAT"
$DispChromeDef  = Join-Path $DispProfile "AppData\Local\Google\Chrome\User Data\Default"
$DispStartup    = Join-Path $DispProfile "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
$WallpaperDest  = Join-Path $LogDir "kjems-wallpaper.png"

# -----------------------------------------------------------------------------
# 6. Install software
# -----------------------------------------------------------------------------
Write-Banner "4. Software installation"
if (-not (Test-Path $InstallersDir)) { New-Item -Path $InstallersDir -ItemType Directory -Force | Out-Null }

foreach ($app in $Software) {
    Invoke-Step "Install $($app.Name)" {
        if (Test-AppInstalled $app.Detect) { Skip-Step "already installed" }

        # Locate a source: prefer a local file, else download the URL
        $localFile = Join-Path $InstallersDir $app.File
        $source    = $null
        if (Test-Path $localFile) {
            $source = $localFile
        }
        elseif ($app.Url) {
            $source = Join-Path $env:TEMP $app.File
            Write-Host "        downloading..." -ForegroundColor DarkGray
            try {
                Invoke-WebRequest -Uri $app.Url -OutFile $source -UseBasicParsing -ErrorAction Stop
            } catch {
                # fall back to curl.exe (handles some redirects/CDNs better)
                & curl.exe -L $app.Url -o $source
                if (-not (Test-Path $source)) { throw "download failed: $($_.Exception.Message)" }
            }
        }
        else {
            Skip-Step "no installer -- put '$($app.File)' in $InstallersDir or set a Url"
        }

        # Install
        if ($app.Kind -eq 'msi') {
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$source`" $($app.Args)" -Wait -PassThru
        } else {
            $p = Start-Process $source -ArgumentList $app.Args -Wait -PassThru
        }
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            throw "installer exit code $($p.ExitCode)"
        }
        if ($p.ExitCode -eq 3010) { "installed (reboot required)" }
    }
}

# -----------------------------------------------------------------------------
# 7. Chrome kiosk policy  (DISPATCHER ONLY)
# -----------------------------------------------------------------------------
Write-Banner "5. Chrome kiosk lockdown (dispatcher only)"
Invoke-Step "Apply Chrome policy to $DispatcherUser" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        $base = "$root\Software\Policies\Google\Chrome"
        New-Item -Path $base -Force | Out-Null

        # Allowlist
        $allow = "$base\URLAllowlist"
        Remove-Item $allow -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $allow -Force | Out-Null
        $i = 1; foreach ($s in $ChromeAllowedSites) { Set-RegValue $allow "$i" String $s; $i++ }

        # Blocklist (everything not on the allowlist)
        $block = "$base\URLBlocklist"
        Remove-Item $block -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $block -Force | Out-Null
        Set-RegValue $block "1" String "*"

        # Force-install + pin extensions
        $force = "$base\ExtensionInstallForcelist"
        Remove-Item $force -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $force -Force | Out-Null
        $i = 1; foreach ($ext in $ChromeExtensionIds) {
            Set-RegValue $force "$i" String "$ext;$ChromeWebStoreUpdateUrl"; $i++
            $ep = "$base\Extensions\$ext"; New-Item -Path $ep -Force | Out-Null
            Set-RegValue $ep "ToolbarPin" String "force_pinned"
        }

        # Startup / new tab / home
        Set-RegValue $base "RestoreOnStartup" DWord 4
        $su = "$base\RestoreOnStartupURLs"
        Remove-Item $su -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $su -Force | Out-Null
        $i = 1; foreach ($u in $ChromeStartupSites) { Set-RegValue $su "$i" String $u; $i++ }
        Set-RegValue $base "NewTabPageLocation"  String $KioskUrl
        Set-RegValue $base "HomepageIsNewTabPage" DWord 0
        Set-RegValue $base "HomepageLocation"     String $KioskUrl
        Set-RegValue $base "ShowHomeButton"       DWord 1

        # Hardening
        Set-RegValue $base "IncognitoModeAvailability"  DWord 1
        Set-RegValue $base "DeveloperToolsAvailability" DWord 2
        Set-RegValue $base "DownloadRestrictions"       DWord 3
        Set-RegValue $base "PromptForDownloadLocation"  DWord 0
        Set-RegValue $base "PrintingEnabled"            DWord 0
        Set-RegValue $base "PasswordManagerEnabled"     DWord 0
        Set-RegValue $base "AutofillAddressEnabled"     DWord 0
        Set-RegValue $base "AutofillCreditCardEnabled"  DWord 0
        Set-RegValue $base "TaskManagerEndProcessEnabled" DWord 0
        Set-RegValue $base "DefaultBrowserSettingEnabled"  DWord 0   # no "make Chrome default" prompt

        # Per-site permissions: allow Location + Pop-ups for the EMS sites
        foreach ($permKey in @("GeolocationAllowedForUrls","PreciseGeolocationAllowedForUrls","PopupsAllowedForUrls")) {
            $kp = "$base\$permKey"
            Remove-Item -Path $kp -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path $kp -Force | Out-Null
            $j = 1
            foreach ($u in $ChromeSitePermissionUrls) { Set-RegValue $kp "$j" String $u; $j++ }
        }
    }
}

# -----------------------------------------------------------------------------
# 8. Bookmarks
# -----------------------------------------------------------------------------
Invoke-Step "Import Chrome bookmarks" {
    if (-not (Test-Path $BookmarksSrc)) { Skip-Step "no 'Bookmarks' file next to script" }
    try { Get-Content $BookmarksSrc -Raw | ConvertFrom-Json | Out-Null }
    catch { throw "Bookmarks file is not valid JSON" }
    if (-not (Test-Path $DispChromeDef)) { New-Item -Path $DispChromeDef -ItemType Directory -Force | Out-Null }
    $dest = Join-Path $DispChromeDef "Bookmarks"
    if (Test-Path $dest) { Copy-Item $dest "$dest.backup" -Force }
    Copy-Item $BookmarksSrc $dest -Force
    if ((Get-FileHash $BookmarksSrc).Hash -ne (Get-FileHash $dest).Hash) { throw "copied bookmarks do not match source" }
}

# -----------------------------------------------------------------------------
# 9. Disable Windows 11 widgets
# -----------------------------------------------------------------------------
Write-Banner "6. Desktop hardening"
Invoke-Step "Disable Windows 11 widgets" {
    # Machine-wide policy disables the widgets board + lock-screen widgets for
    # everyone -- this is what actually turns widgets off.
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests"      DWord 0
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "DisableWidgetsOnLockScreen" DWord 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "DisableWidgetsBoard"        DWord 1

    # Per-user taskbar button is cosmetic on top of the above -- best-effort so a
    # transient hive hiccup can't fail the whole step.
    if ($DispSid) {
        try {
            Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
                param($root)
                Set-RegValue "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" DWord 0
            }
        } catch {
            "widgets disabled machine-wide; taskbar-button tweak skipped ($($_.Exception.Message))"
        }
    }
}

Invoke-Step "Set EMS desktop + lock screen wallpaper" {
    # Download the wallpaper if it isn't sitting next to the script
    if (-not (Test-Path $WallpaperSrc) -and $WallpaperUrl) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
            Invoke-WebRequest -Uri $WallpaperUrl -OutFile $WallpaperSrc -UseBasicParsing -ErrorAction Stop
        } catch {
            & curl.exe -L $WallpaperUrl -o $WallpaperSrc 2>$null
        }
    }
    if (-not (Test-Path $WallpaperSrc)) { Skip-Step "wallpaper not found and download failed" }
    Copy-Item $WallpaperSrc $WallpaperDest -Force

    # Lock screen for ALL users (machine policy)
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "LockScreenImage" String $WallpaperDest

    # Desktop wallpaper enforced for the dispatcher (10 = Fill)
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $sys = "$root\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            Set-RegValue $sys "Wallpaper"      String $WallpaperDest
            Set-RegValue $sys "WallpaperStyle" String "10"
            $cpd = "$root\Control Panel\Desktop"
            Set-RegValue $cpd "Wallpaper"      String $WallpaperDest
            Set-RegValue $cpd "WallpaperStyle" String "10"
            Set-RegValue $cpd "TileWallpaper"  String "0"
        }
    }
}

Invoke-Step "Suppress Microsoft first-login prompts & suggestions" {
    # Machine-wide: skip the OOBE privacy screen, no first-logon animation,
    # kill consumer/cloud "suggested" content and web search in Start
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE" "DisablePrivacyExperience" DWord 1
    Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "EnableFirstLogonAnimation" DWord 0
    $cc = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Set-RegValue $cc "DisableWindowsConsumerFeatures"     DWord 1
    Set-RegValue $cc "DisableConsumerAccountStateContent" DWord 1
    Set-RegValue $cc "DisableCloudOptimizedContent"       DWord 1
    Set-RegValue $cc "DisableSoftLanding"                 DWord 1
    $ws = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    Set-RegValue $ws "AllowCortana"          DWord 0
    Set-RegValue $ws "DisableWebSearch"      DWord 1
    Set-RegValue $ws "ConnectedSearchUseWeb" DWord 0

    # Per-user (dispatcher): disable "suggested content", tips, and the
    # "Let's finish setting up your device" (SCOOBE) prompt + advertising ID
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $cdm = "$root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            $off = @(
                "ContentDeliveryAllowed","OemPreInstalledAppsEnabled","PreInstalledAppsEnabled",
                "PreInstalledAppsEverEnabled","SilentInstalledAppsEnabled","SoftLandingEnabled",
                "SystemPaneSuggestionsEnabled","RotatingLockScreenEnabled","RotatingLockScreenOverlayEnabled",
                "SubscribedContent-310093Enabled","SubscribedContent-338387Enabled","SubscribedContent-338388Enabled",
                "SubscribedContent-338389Enabled","SubscribedContent-338393Enabled","SubscribedContent-353694Enabled",
                "SubscribedContent-353696Enabled","SubscribedContent-353698Enabled"
            )
            foreach ($v in $off) { Set-RegValue $cdm $v DWord 0 }
            Set-RegValue "$root\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" DWord 0
            Set-RegValue "$root\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" DWord 0
        }
    }
}

Invoke-Step "Block Microsoft Edge for $DispatcherUser" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        # Edge policy: no first-run wizard, no default-browser nag, no sign-in/sync/background/promos
        $edge = "$root\Software\Policies\Microsoft\Edge"
        Set-RegValue $edge "HideFirstRunExperience"                        DWord 1
        Set-RegValue $edge "DefaultBrowserSettingEnabled"                  DWord 0
        Set-RegValue $edge "BackgroundModeEnabled"                         DWord 0
        Set-RegValue $edge "StartupBoostEnabled"                           DWord 0
        Set-RegValue $edge "BrowserSignin"                                 DWord 0
        Set-RegValue $edge "SyncDisabled"                                  DWord 1
        Set-RegValue $edge "PromotionalTabsEnabled"                        DWord 0
        Set-RegValue $edge "ShowRecommendationsEnabled"                    DWord 0
        Set-RegValue $edge "SpotlightExperiencesAndRecommendationsEnabled" DWord 0
        Set-RegValue $edge "EdgeShoppingAssistantEnabled"                  DWord 0
        Set-RegValue $edge "PersonalizationReportingEnabled"               DWord 0
        # (Edge is also fully prevented from launching by the app allowlist step.)
    }
}

# -----------------------------------------------------------------------------
# Power + default browser
# -----------------------------------------------------------------------------
Write-Banner "8. Power plan & default browser"

Invoke-Step "Power: max performance, screen never off, no sleep" {
    # Prefer Ultimate Performance (this box is Win11 Pro for Workstations), else High Performance
    $ult  = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $high = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    powercfg -duplicatescheme $ult 2>$null | Out-Null
    $active = $high
    if ((powercfg /list 2>$null) -match $ult) { $active = $ult }
    powercfg -setactive $active 2>$null

    # Never turn off display / sleep / disk / hibernate (AC + DC)
    foreach ($t in @("monitor-timeout-ac","monitor-timeout-dc","standby-timeout-ac","standby-timeout-dc",
                      "disk-timeout-ac","disk-timeout-dc","hibernate-timeout-ac","hibernate-timeout-dc")) {
        powercfg -change $t 0 2>$null
    }

    # Kill the lock-screen display-off timeout as well
    powercfg /setacvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 8EC4B3A5-6868-48c2-BE75-4F3044BE88A7 0 2>$null
    powercfg /setdcvalueindex SCHEME_CURRENT 7516b95f-f776-4464-8c53-06167f40cc99 8EC4B3A5-6868-48c2-BE75-4F3044BE88A7 0 2>$null

    # Keep USB devices (headset/phone) alive -- disable USB selective suspend
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
    powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null

    powercfg -hibernate off 2>$null
    powercfg -setactive SCHEME_CURRENT 2>$null
}

Invoke-Step "Set Chrome as default browser" {
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { Skip-Step "Chrome not installed" }

    # Windows only honors default-app changes via machine default associations.
    # Set Chrome for every web protocol + file type it handles.
    $xml = Join-Path $LogDir "kjems-default-apps.xml"
    $assoc = @('<?xml version="1.0" encoding="UTF-8"?>','<DefaultAssociations>')
    foreach ($id in @("http","https","ftp","mailto",
                      ".htm",".html",".shtml",".xht",".xhtml",".svg",".webp",".pdf",".mhtml")) {
        $assoc += ('  <Association Identifier="{0}" ProgId="ChromeHTML" ApplicationName="Google Chrome" />' -f $id)
    }
    $assoc += '</DefaultAssociations>'
    Set-Content -Path $xml -Encoding UTF8 -Force -Value $assoc
    & dism.exe /Online /Import-DefaultAppAssociations:"$xml" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM import failed (exit $LASTEXITCODE)" }
    "applies at the dispatcher's next fresh login"
}

# -----------------------------------------------------------------------------
# Start menu cleanup
# -----------------------------------------------------------------------------
Write-Banner "9. Start menu cleanup"

Invoke-Step "Pin only allowed apps + hide Recommended" {
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $bria = @(
        "C:\Program Files (x86)\CounterPath\Bria Enterprise\BriaEnterprise.exe",
        "C:\Program Files\CounterPath\Bria Enterprise\BriaEnterprise.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    # Build the pinned-apps JSON (backslashes are pre-escaped for JSON)
    $items = @()
    if ($chrome) {
        Ensure-Shortcut -Exe $chrome -Name "Google Chrome" | Out-Null
        $items += '{"desktopAppLink":"%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Google Chrome.lnk"}'
    }
    if ($bria) {
        Ensure-Shortcut -Exe $bria -Name "Bria Enterprise" | Out-Null
        $items += '{"desktopAppLink":"%ALLUSERSPROFILE%\\Microsoft\\Windows\\Start Menu\\Programs\\Bria Enterprise.lnk"}'
    }

    if ($items.Count) {
        $json = '{"pinnedList":[' + ($items -join ',') + ']}'
        $sp = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"
        Set-RegValue $sp "ConfigureStartPins"             String $json
        Set-RegValue $sp "ConfigureStartPins_ProviderSet" DWord  1
    }

    # Hide the Recommended section ("Get Started", recent files). The GP value
    # is ignored on Win11 Pro, so also set the CSP policy under PolicyManager --
    # that's the path that actually took effect for the pins above.
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "HideRecommendedSection" DWord 1
    $spRec = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"
    Set-RegValue $spRec "HideRecommendedSection"             DWord 1
    Set-RegValue $spRec "HideRecommendedSection_ProviderSet" DWord 1

    # Per-user: stop tracking recent docs/apps + turn off "iris" recommendations
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $adv = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-RegValue $adv "Start_TrackDocs"           DWord 0
            Set-RegValue $adv "Start_TrackProgs"          DWord 0
            Set-RegValue $adv "Start_IrisRecommendations" DWord 0
        }
    }

    if (-not $items.Count) { "Chrome/Bria not installed yet -- pins not set" }
}

Invoke-Step "Remove Microsoft bloatware apps" {
    $patterns = @(
        "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.BingSearch",
        "Microsoft.GamingApp","Microsoft.Xbox*","Microsoft.ZuneMusic","Microsoft.ZuneVideo",
        "Microsoft.MicrosoftSolitaireCollection","Microsoft.People","Microsoft.windowscommunicationsapps",
        "Microsoft.Todos","Microsoft.PowerAutomateDesktop","*Clipchamp*","*Teams*","MicrosoftTeams",
        "Microsoft.WindowsFeedbackHub","Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub",
        "*WhatsApp*","*LinkedIn*","*Spotify*","*Disney*","*Facebook*","*Instagram*","*Prime*","*TikTok*",
        "Microsoft.549981C3F5F10","Microsoft.MixedReality.Portal","Microsoft.OutlookForWindows"
    )
    $removed = 0
    foreach ($p in $patterns) {
        Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; $removed++ } catch {}
        }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $p } |
            ForEach-Object { try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null } catch {} }
    }
    "removed $removed installed package(s) + matching provisioned packages"
}

# -----------------------------------------------------------------------------
# 10. Disable Google / Edge / OneDrive updaters
# -----------------------------------------------------------------------------
Invoke-Step "Disable Google/Edge/OneDrive updaters" {
    $gu = "HKLM:\SOFTWARE\Policies\Google\Update"
    Set-RegValue $gu "UpdateDefault" DWord 0
    Set-RegValue $gu "Update{8A69D345-D564-463C-AFF1-A69D9E530F96}" DWord 0
    Set-RegValue $gu "AutoUpdateCheckPeriodMinutes" DWord 0

    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "gupdate*" -or $_.Name -like "GoogleUpdater*" -or $_.Name -like "edgeupdate*" } |
        ForEach-Object {
            try { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue; Set-Service $_.Name -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
        }

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like "*GoogleUpdate*" -or $_.TaskName -like "*GoogleUpdater*" -or
                       $_.TaskName -like "*MicrosoftEdgeUpdate*" -or $_.TaskName -like "*OneDrive Standalone Update*" } |
        ForEach-Object { try { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null } catch {} }
}

# -----------------------------------------------------------------------------
# 11. Dispatcher desktop lockdown (per-user)
# -----------------------------------------------------------------------------
Invoke-Step "Dispatcher per-user lockdown (settings, OneDrive, recycle bin)" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        # Only show Wi-Fi / sound / bluetooth in Settings
        $exp = "$root\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        Set-RegValue $exp "SettingsPageVisibility" String "showonly:network-wifi;sound;bluetooth"
        # Remove OneDrive auto-start
        Remove-ItemProperty -Path "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
        # Hide Recycle Bin icon
        Set-RegValue "$root\Software\Microsoft\Windows\CurrentVersion\Policies\NonEnum" "{645FF040-5081-101B-9F08-00AA002F954E}" DWord 1
    }
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
}

Invoke-Step "Add Volume Control shortcut to dispatcher desktop" {
    $desktop = Join-Path $DispProfile "Desktop"
    if (-not (Test-Path $desktop)) { New-Item -Path $desktop -ItemType Directory -Force | Out-Null }
    $lnk = Join-Path $desktop "Volume Control.lnk"
    if (Test-Path $lnk) { Skip-Step "already present" }
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = "$env:windir\System32\SndVol.exe"
    $sc.WorkingDirectory = "$env:windir\System32"
    $sc.IconLocation     = "$env:windir\System32\SndVol.exe,0"
    $sc.Description       = "Volume Control"
    $sc.Save()
}

Invoke-Step "Set dispatcher startup apps (Chrome, Lexip)" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    # Bria starts via its own logon scheduled task (below). Jabra Direct starts
    # itself in the background/tray via its own installer autostart, so we do NOT
    # launch its window here.

    # Chrome exe
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    # Lexip exe -- resolve from its uninstall entry (DisplayIcon or InstallLocation)
    $lexip = $null
    $info = Get-UninstallInfo "Lexip Control Software"
    if ($info) {
        if ($info.DisplayIcon) {
            $cand = ($info.DisplayIcon -replace ',\s*\d+\s*$','').Trim('"')
            if ($cand -and (Test-Path $cand)) { $lexip = $cand }
        }
        if (-not $lexip -and $info.InstallLocation -and (Test-Path $info.InstallLocation)) {
            $lexip = Get-ChildItem $info.InstallLocation -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'Lexip' } | Select-Object -First 1 -ExpandProperty FullName
        }
    }

    $script:_StartChrome = $chrome
    $script:_StartLexip  = $lexip

    # Register under the dispatcher's per-user Run key (starts them at that user's
    # login; Chrome opens the kiosk URL via the RestoreOnStartup policy)
    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        $run = "$root\Software\Microsoft\Windows\CurrentVersion\Run"
        if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
        if ($script:_StartChrome) { Set-RegValue $run "GoogleChrome" String ('"{0}"' -f $script:_StartChrome) }
        if ($script:_StartLexip)  { Set-RegValue $run "LexipControl" String ('"{0}"' -f $script:_StartLexip) }
        # Remove any foreground Jabra launcher a previous run added -- Jabra runs
        # itself in the tray, and this entry was popping its window open.
        Remove-ItemProperty -Path $run -Name "JabraDirect" -ErrorAction SilentlyContinue
    }

    if (-not $chrome) { throw "Chrome not installed -- cannot start it at login" }
    if (-not $lexip)  { "Chrome start set; Lexip exe not found (install Lexip first)" }
}

Invoke-Step "Pin Chrome + Bria to the taskbar (dispatcher)" {
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $bria = @(
        "C:\Program Files (x86)\CounterPath\Bria Enterprise\BriaEnterprise.exe",
        "C:\Program Files\CounterPath\Bria Enterprise\BriaEnterprise.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $links = @()
    if ($chrome) { $links += (Ensure-Shortcut -Exe $chrome -Name "Google Chrome") }
    if ($bria)   { $links += (Ensure-Shortcut -Exe $bria   -Name "Bria Enterprise") }
    if ($links.Count -eq 0) { Skip-Step "neither Chrome nor Bria installed yet" }

    # LayoutModification.xml applied to the dispatcher profile before first logon.
    # PinListPlacement="Replace" also clears the default Edge/Store taskbar pins.
    $pins = ($links | ForEach-Object {
        '        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $_
    }) -join "`r`n"

    $xml = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">',
        '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
        '    <defaultlayout:TaskbarLayout>',
        '      <taskbar:TaskbarPinList>',
        $pins,
        '      </taskbar:TaskbarPinList>',
        '    </defaultlayout:TaskbarLayout>',
        '  </CustomTaskbarLayoutCollection>',
        '</LayoutModificationTemplate>'
    )

    # Write the layout to the dispatcher profile AND the Default profile, so a
    # freshly created dispatcher profile also picks it up at first sign-in.
    foreach ($base in @($DispProfile, "C:\Users\Default")) {
        $shellDir = Join-Path $base "AppData\Local\Microsoft\Windows\Shell"
        if (-not (Test-Path $shellDir)) { New-Item -Path $shellDir -ItemType Directory -Force | Out-Null }
        Set-Content -Path (Join-Path $shellDir "LayoutModification.xml") -Value $xml -Encoding UTF8 -Force
    }

    # If the dispatcher already signed in once, its taskbar is already built and
    # ignores the file -- clear the cached taskbar pins so it rebuilds from our
    # layout on next logon.
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $tb = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
            Remove-ItemProperty -Path $tb -Name "Favorites"        -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $tb -Name "FavoritesResolve" -ErrorAction SilentlyContinue
        }
    }

    "pinned: " + (($links | ForEach-Object { Split-Path $_ -Leaf }) -join ", ")
}

Invoke-Step "Block config/escape apps for the dispatcher (DisallowRun)" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    $script:_BlockedExes = @($DispatcherBlockedExes | Where-Object { $_ } | Sort-Object -Unique)

    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        $exp = "$root\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"

        # IMPORTANT: remove any old allowlist (RestrictRun) -- that one breaks the
        # Win11 shell (dead volume flyout, "Restrictions" popup at login).
        Remove-ItemProperty -Path $exp -Name "RestrictRun" -ErrorAction SilentlyContinue
        Remove-Item -Path "$exp\RestrictRun" -Recurse -Force -ErrorAction SilentlyContinue

        # Blocklist mode -- everything works EXCEPT the listed apps
        Set-RegValue $exp "DisallowRun" DWord 1
        $dr = "$exp\DisallowRun"
        Remove-Item -Path $dr -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $dr -Force | Out-Null
        $i = 1
        foreach ($exe in $script:_BlockedExes) { Set-RegValue $dr "$i" String $exe; $i++ }
    }

    "blocked: " + ($script:_BlockedExes -join ", ")
}

# -----------------------------------------------------------------------------
# 12. Bria auto-launch scheduled task
# -----------------------------------------------------------------------------
Write-Banner "7. Bria auto-launch"
Invoke-Step "Register Bria logon task for $DispatcherUser" {
    $briaPaths = @(
        "C:\Program Files (x86)\CounterPath\Bria Enterprise\BriaEnterprise.exe",
        "C:\Program Files\CounterPath\Bria Enterprise\BriaEnterprise.exe"
    )
    $bria = $briaPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $bria) { Skip-Step "Bria not installed yet" }

    $action  = New-ScheduledTaskAction -Execute $bria
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $DispatcherUser
    $trigger.Delay = "PT30S"
    $principal = New-ScheduledTaskPrincipal -UserId $DispatcherUser -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName "Launch Bria for Dispatcher" -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

# -----------------------------------------------------------------------------
# 13. Lexip default-profile cleanup (dispatcher)
# -----------------------------------------------------------------------------
Invoke-Step "Clean Lexip default profiles for dispatcher" {
    $lexip = Join-Path $DispProfile "AppData\Local\Lexip\Profils"
    if (-not (Test-Path $lexip)) { Skip-Step "no Lexip profiles folder" }
    Get-ChildItem -Path $lexip -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================
#  SUMMARY
# =============================================================================
$ok   = @($script:Results | Where-Object { $_.Status -eq "OK"   }).Count
$skip = @($script:Results | Where-Object { $_.Status -eq "SKIP" }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Banner "SUMMARY   |   OK: $ok   SKIP: $skip   FAIL: $fail"
foreach ($r in $script:Results) {
    switch ($r.Status) {
        "OK"   { $c="Green";  $tag="[ OK ]" }
        "SKIP" { $c="Yellow"; $tag="[SKIP]" }
        "FAIL" { $c="Red";    $tag="[FAIL]" }
    }
    $line = "  {0}  {1,-52}" -f $tag, $r.Step
    if ($r.Detail -and $r.Status -ne "OK") { $line += "  -- " + $r.Detail }
    Write-Host $line -ForegroundColor $c
}
Write-Host ""
if ($fail -gt 0) {
    Write-Host "  $fail step(s) FAILED. See details above and the log:" -ForegroundColor Red
    Write-Host "  $LogFile" -ForegroundColor Red
} else {
    Write-Host "  All steps completed with no failures. Reboot recommended." -ForegroundColor Green
}
Write-Host ""

# CSV summary alongside the log
$script:Results | Export-Csv -Path (Join-Path $LogDir "Provision_$stamp.csv") -NoTypeInformation -Encoding UTF8

Stop-Transcript | Out-Null
if ($fail -gt 0) { exit 1 } else { exit 0 }

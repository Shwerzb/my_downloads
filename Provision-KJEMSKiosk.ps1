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
       -- fully unattended: silent switches with fallbacks, hidden windows and a
       per-installer timeout, so the run NEVER waits for a keypress
   7.  Apply the Chrome kiosk policy (allow/block list, extensions, hardening)
       to the DISPATCHER ONLY  -- the admin keeps a normal Chrome
   8.  Put the EMS links on the Chrome BOOKMARKS BAR (not the desktop)
   9.  Disable Windows 11 widgets, set wallpaper/lock screen
   9b. Block Edge for the dispatcher + kill Microsoft first-login prompts
       ("finish setting up your device", privacy screen, tips, suggested apps)
   10. Disable Google / Edge / OneDrive updaters
   11. Dispatcher desktop lockdown (settings visibility, OneDrive off,
       recycle bin hidden, clean desktop -- no Volume/Edge/web shortcuts)
   12. Bria auto-launch scheduled task
   12b Jabra Direct + Lexip Control auto-launch MINIMISED TO THE SYSTEM TRAY
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
$DispatcherUser     = "kioskUser1"        # dispatcher account (fresh name; was kioskUser0)
$DispatcherPassword = ""                  # blank = dispatcher logs in with NO password
$DispatcherFullName = "Dispatcher"

# Old dispatcher accounts to FULLY delete on every run (account + all profiles/
# folders/ProfileList entries). Migrating off the ManageEngine-tainted kioskUser0.
$LegacyDispatcherUsers = @("kioskUser0")

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

# EMS links placed on the dispatcher's Chrome BOOKMARKS BAR (name -> URL).
# These are browser bookmarks -- nothing is put on the Windows desktop.
$ChromeBookmarks = @(
    @{ Name = "Hatzalah Web"; Url = "https://hatzalahweb.datavanced.com" },
    @{ Name = "Team Connect"; Url = "https://www.teamconnectapp.com" },
    @{ Name = "Maps";         Url = "https://www.google.com/maps" },
    @{ Name = "PCR";          Url = "https://www.creativeemssolutions.com" }   # <-- set your real PCR URL
)

# Shortcuts that must NOT be on the dispatcher desktop (deleted on every run)
$DesktopShortcutsToRemove = @(
    "Volume Control", "Microsoft Edge",
    "Hatzalah Web", "Team Connect", "Maps", "PCR"
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
#   ArgsList= ordered list of silent-install switch sets. The first set the
#             package does not reject as an invalid command line is used, so an
#             installer that wants a different switch style still runs unattended
#             (nothing ever opens a window or waits for a keypress).
#   Kind    = 'msi' or 'exe'
#
# Apps without a public silent URL (Bria/Jabra/Lexip): drop the installer in the
# "Installers" folder next to this script using the File name shown, or set Url.
$MsiSilent = @('/qn /norestart', '/quiet /norestart')
$ExeSilent = @('/install /quiet /norestart', '/exenoui /qn', '/quiet', '/silent', '/S', '/s')

$Software = @(
    @{ Name='Microsoft Visual C++ 2015-2022 x64'; Detect='Visual C++ 2015-2022 Redistributable (x64)';
       Url='https://aka.ms/vs/17/release/vc_redist.x64.exe'; File='vc_redist.x64.exe';
       ArgsList=@('/install /quiet /norestart'); Kind='exe' }

    @{ Name='Google Chrome';                       Detect='Google Chrome';
       Url='https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; File='googlechromestandaloneenterprise64.msi';
       ArgsList=$MsiSilent; Kind='msi' }

    @{ Name='ScreenConnect (KJEMS)';               Detect='ScreenConnect Client';
       Url='https://kjems.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest'; File='screenconnect.msi';
       ArgsList=$MsiSilent; Kind='msi' }

    @{ Name='Bria Enterprise';                     Detect='Bria Enterprise';
       Url='https://www.counterpath.com/EnterpriseForWindows'; File='Bria_Enterprise.msi';
       ArgsList=$MsiSilent; Kind='msi' }   # 301/302 -> S3 -> Bria_Enterprise_6.8.8_*.msi

    @{ Name='Jabra Direct';                        Detect='Jabra Direct';
       Url='https://jabraxpressonlineprdstor.blob.core.windows.net/jdo/JabraDirectSetup.exe'; File='JabraDirectSetup.exe';
       ArgsList=$ExeSilent; Kind='exe' }   # Advanced Installer pkg -- switch set auto-detected

    @{ Name='Lexip Control Software 4';            Detect='Lexip Control Software';
       Url='https://lcs.lexip.co/download/lcp/win'; File='lexip_control_software_4.exe';
       ArgsList=$ExeSilent; Kind='exe' }   # Advanced Installer pkg -- switch set auto-detected
)

# ---- Paths ------------------------------------------------------------------
$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$InstallersDir = Join-Path $ScriptDir "Installers"
$BookmarksSrc  = Join-Path $ScriptDir "Bookmarks"              # Chrome Bookmarks JSON file (optional)
$WallpaperSrc  = Join-Path $ScriptDir "wallpaper-noclock.png"  # desktop + lock screen image
$WallpaperUrl  = "https://raw.githubusercontent.com/Shwerzb/my_downloads/main/wallpaper-noclock.png"  # auto-downloaded if missing
$LogDir        = "C:\ProgramData\KJEMS"

# Remove leftover LOCAL Group Policy (old ADMX / ManageEngine config) that would
# otherwise override this script's registry policies at every logon. Backups are
# saved next to the originals as Registry.pol.kjems-bak.
$RemoveLocalGroupPolicy = $true

# =============================================================================
#  END CONFIG  --  no need to edit below
# =============================================================================

$ErrorActionPreference = "Stop"
# No PowerShell progress banner (that is the blue/yellow strip Invoke-WebRequest
# paints over the top of the console) and never stop to ask a question -- this
# script must run start to finish without a keypress.
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference  = 'None'
$WarningPreference  = 'SilentlyContinue'
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

# ---- Console progress bar ---------------------------------------------------
# Draws (and re-draws in place) a bar like
#     Google Chrome  [##############......]  71.4%   82.1 / 115.0 MB  9.8 MB/s
# The transcript only gets a line per whole percent, so the log stays readable.
$script:_BarWidth = 30
$script:_CanRedraw = $true
try { $null = $Host.UI.RawUI.CursorPosition } catch { $script:_CanRedraw = $false }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:0.00} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:0.0} MB"  -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:0} KB"    -f ($Bytes / 1KB)) }
    return ("{0} B" -f [int]$Bytes)
}

function Write-ProgressBar {
    param([string]$Label, [double]$Percent, [string]$Right = "", [switch]$Done)
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $fill = [int][math]::Round($script:_BarWidth * ($Percent / 100))
    $bar  = ("#" * $fill) + ("." * ($script:_BarWidth - $fill))
    $text = ("        {0,-22} [{1}] {2,5:0.0}%  {3}" -f $Label, $bar, $Percent, $Right)
    $color = if ($Done) { "Green" } else { "Cyan" }
    if ($script:_CanRedraw) {
        Write-Host ("`r" + $text.PadRight(96)) -NoNewline -ForegroundColor $color
        if ($Done) { Write-Host "" }
    } else {
        Write-Host $text -ForegroundColor $color
    }
}

# Marquee for downloads whose size the server does not report
function Write-SpinBar {
    param([string]$Label, [int]$Tick, [string]$Right = "")
    $pos  = $Tick % ($script:_BarWidth - 3)
    $bar  = ("." * $pos) + "###" + ("." * ($script:_BarWidth - 3 - $pos))
    $text = ("        {0,-22} [{1}]         {2}" -f $Label, $bar, $Right)
    if ($script:_CanRedraw) { Write-Host ("`r" + $text.PadRight(96)) -NoNewline -ForegroundColor Cyan }
    elseif ($Tick % 20 -eq 0) { Write-Host $text -ForegroundColor Cyan }
}

# Streaming download with the bar above. Writes to <OutFile>.part first so a
# half-finished file is never mistaken for a good installer.
function Invoke-Download {
    param([string]$Url, [string]$OutFile, [string]$Label = "downloading")

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch {}

    $part = "$OutFile.part"
    Remove-Item $part -Force -ErrorAction SilentlyContinue

    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent         = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KJEMS-Provision"
    $req.AllowAutoRedirect = $true
    $req.Timeout           = 60000
    $req.ReadWriteTimeout  = 180000
    $resp = $req.GetResponse()
    try {
        $total  = 0
        try { $total = [int64]$resp.ContentLength } catch {}
        $in  = $resp.GetResponseStream()
        $out = [IO.File]::Open($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buf     = New-Object byte[] 262144
            $got     = [int64]0
            $lastPct = -1
            $tick    = 0
            $clock   = [Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $n = $in.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $got += $n
                $secs  = [math]::Max($clock.Elapsed.TotalSeconds, 0.001)
                $speed = Format-Size ($got / $secs)
                if ($total -gt 0) {
                    $pct = 100.0 * $got / $total
                    if ([int]$pct -ne $lastPct) {
                        $lastPct = [int]$pct
                        Write-ProgressBar $Label $pct ("{0} / {1}  {2}/s" -f (Format-Size $got), (Format-Size $total), $speed)
                    }
                } else {
                    $tick++
                    if ($tick % 4 -eq 0) { Write-SpinBar $Label $tick ("{0}  {1}/s" -f (Format-Size $got), $speed) }
                }
            }
            $clock.Stop()
            Write-ProgressBar $Label 100 ("{0}  done in {1:0}s" -f (Format-Size $got), $clock.Elapsed.TotalSeconds) -Done
        } finally { $out.Close(); $in.Close() }
    } finally { $resp.Close() }

    if (-not (Test-Path $part) -or (Get-Item $part).Length -eq 0) { throw "download produced an empty file" }
    Move-Item $part $OutFile -Force
    return $OutFile
}

# Download with a curl.exe fallback (some CDNs behave better with it)
function Get-Installer {
    param([string]$Url, [string]$OutFile, [string]$Label)
    try {
        return (Invoke-Download -Url $Url -OutFile $OutFile -Label $Label)
    } catch {
        $first = $_.Exception.Message
        Write-Host ("        {0,-22} retrying with curl..." -f $Label) -ForegroundColor DarkGray
        & curl.exe -sSL --fail --retry 2 -o "$OutFile" "$Url" 2>&1 | Out-Null
        if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return $OutFile }
        throw "download failed: $first"
    }
}

# Runs an installer completely unattended: hidden window, no console inherited,
# a hard timeout, and a walk through the candidate silent-switch sets so we never
# fall back to an interactive UI that waits for a click or a keypress.
function Invoke-Installer {
    param(
        [string]$Source,
        [string]$Kind,
        [string[]]$ArgSets,
        [int]$TimeoutSec = 900
    )
    if (-not $ArgSets -or $ArgSets.Count -eq 0) { $ArgSets = @('') }
    $last = "no attempt made"

    foreach ($set in $ArgSets) {
        if ($Kind -eq 'msi') {
            $exe = "$env:SystemRoot\System32\msiexec.exe"
            $arg = ('/i "{0}" {1}' -f $Source, $set).Trim()
        } else {
            $exe = $Source
            $arg = "$set".Trim()
        }

        $sp = @{ FilePath = $exe; PassThru = $true; WindowStyle = 'Hidden' }
        if ($arg) { $sp.ArgumentList = $arg }
        $p = Start-Process @sp

        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            $last = "no response after ${TimeoutSec}s -- installer was killed"
            continue
        }
        $code = $p.ExitCode

        if ($code -eq 0)    { return "" }
        if ($code -eq 3010) { return "installed (reboot required)" }
        if ($code -eq 1641) { return "installed (installer requested a reboot)" }
        if ($code -eq 1638) { return "a newer version is already installed" }

        $last = "exit code $code"
        # 1619/1620/1639/87/2/1 => the package did not like these switches; the
        # next set in the list gets a turn. Anything else is a real failure.
        if ($code -notin @(1, 2, 87, 1619, 1620, 1639)) { break }
    }
    throw $last
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

# Completely remove a local account: the account itself + every profile
# (incl. orphaned/temp), its ProfileList entry, and its C:\Users folder(s).
function Remove-UserAndProfiles {
    param([string]$Name)
    if (-not $Name) { return }
    $live = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.Loaded -and $_.LocalPath -like "C:\Users\$Name*" }
    if ($live) { throw "$Name is signed in -- sign it out, then re-run" }

    if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $Name -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "C:\Users\$Name*" } |
        ForEach-Object { Remove-CimInstance -InputObject $_ -ErrorAction SilentlyContinue }
    $pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    Get-ChildItem $pl | ForEach-Object {
        $img = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($img -like "C:\Users\$Name*") { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$Name*" } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
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

Invoke-Step "Remove leftover Local Group Policy (old ADMX / ManageEngine)" {
    if (-not $RemoveLocalGroupPolicy) { Skip-Step "disabled in config" }
    $removed = @()
    foreach ($f in @(
        "$env:SystemRoot\System32\GroupPolicy\User\Registry.pol",
        "$env:SystemRoot\System32\GroupPolicy\Machine\Registry.pol")) {
        if (Test-Path $f) {
            Copy-Item $f "$f.kjems-bak" -Force -ErrorAction SilentlyContinue   # backup first
            Remove-Item $f -Force -ErrorAction Stop
            $removed += ((Split-Path (Split-Path $f -Parent) -Leaf) + "\Registry.pol")
        }
    }
    # Per-user local GPOs (rare), if present
    Get-ChildItem "$env:SystemRoot\System32\GroupPolicyUsers" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $rp = Join-Path $_.FullName "User\Registry.pol"
        if (Test-Path $rp) { Remove-Item $rp -Force -ErrorAction SilentlyContinue; $removed += "$($_.Name)\User\Registry.pol" }
    }
    if ($removed.Count -eq 0) { Skip-Step "no leftover Local GPO found" }
    & gpupdate.exe /force 2>&1 | Out-Null
    "removed + gpupdate: " + ($removed -join ", ")
}

# -----------------------------------------------------------------------------
# 2 & 3. Create accounts (skip if they already exist)
# -----------------------------------------------------------------------------
Write-Banner "2. Local accounts"

Invoke-Step "Remove legacy dispatcher account(s)" {
    $done = @()
    foreach ($u in $LegacyDispatcherUsers) {
        if (-not $u -or $u -eq $DispatcherUser) { continue }
        $exists = (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) -or
                  (Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$u*" })
        if ($exists) { Remove-UserAndProfiles $u; $done += $u }
    }
    if (-not $done.Count) { Skip-Step "no legacy accounts present" }
    "fully removed: " + ($done -join ", ")
}

Invoke-Step "Deep-clean dispatcher profile (-ResetDispatcher)" {
    if (-not $ResetDispatcher) { Skip-Step "not requested" }
    Remove-UserAndProfiles $DispatcherUser
    "purged '$DispatcherUser' account + all its profiles/folders/ProfileList entries -- a clean profile is created next"
}

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

Invoke-Step "Scrub leftover kiosk lockdown policies (ManageEngine/GPO)" {
    if (-not $DispSid) { Skip-Step "no dispatcher profile yet" }
    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        # Old ManageEngine/GPO lockdown accumulates in these two keys
        # (NoPinningToTaskbar, DisableControlCenter, NoRun, NoDesktop, LockTaskbar,
        # HideTaskViewButton, ...) and breaks the taskbar + volume flyout. Wipe
        # both keys entirely; our later steps re-add ONLY the values we want
        # (SettingsPageVisibility, DisallowRun, StartLayoutFile).
        foreach ($k in @(
            "$root\Software\Policies\Microsoft\Windows\Explorer",
            "$root\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer")) {
            Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    "wiped leftover Explorer lockdown policies (taskbar pinning / volume / Start)"
}

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
            $source = Get-Installer -Url $app.Url -OutFile $source -Label $app.Name
        }
        else {
            Skip-Step "no installer -- put '$($app.File)' in $InstallersDir or set a Url"
        }

        # Install -- silent, hidden, timed out; never waits for input
        Write-Host ("        {0,-22} installing..." -f $app.Name) -ForegroundColor DarkGray
        Invoke-Installer -Source $source -Kind $app.Kind -ArgSets $app.ArgsList
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

        # Bookmarks bar: the EMS links live IN the browser, so the bar is always
        # visible and the dispatcher cannot rename or delete the bookmarks.
        Set-RegValue $base "BookmarkBarEnabled"            DWord 1
        Set-RegValue $base "ShowAppsShortcutInBookmarkBar" DWord 0
        Set-RegValue $base "EditBookmarksEnabled"          DWord 0

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

Invoke-Step "Put EMS links on the Chrome bookmarks bar" {
    # These used to be desktop shortcuts. They are now real Chrome bookmarks,
    # sitting on the bookmarks bar of the dispatcher's Chrome profile.
    if (-not $ChromeBookmarks -or $ChromeBookmarks.Count -eq 0) { Skip-Step "no bookmarks configured" }
    if (Test-Path $BookmarksSrc) { Skip-Step "a custom 'Bookmarks' file was imported -- leaving it untouched" }
    if (-not (Test-Path $DispChromeDef)) { New-Item -Path $DispChromeDef -ItemType Directory -Force | Out-Null }

    function ConvertTo-JsonText { param([string]$Text) ($Text -replace '\\', '\\' ) -replace '"', '\"' }

    # Chrome timestamps: microseconds since 1601-01-01 UTC
    $epoch = New-Object DateTime(1601, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))
    $now   = [long](([datetime]::UtcNow - $epoch).TotalMilliseconds * 1000)

    $kids = @()
    $id   = 2
    foreach ($b in $ChromeBookmarks) {
        if (-not $b.Url) { continue }
        $kids += ('            {{ "date_added": "{0}", "id": "{1}", "name": "{2}", "type": "url", "url": "{3}" }}' -f `
                  $now, $id, (ConvertTo-JsonText $b.Name), (ConvertTo-JsonText $b.Url))
        $id++
    }
    if (-not $kids.Count) { Skip-Step "no bookmark URLs configured" }

    $json = @"
{
   "roots": {
      "bookmark_bar": {
         "children": [
$($kids -join ",`r`n")
         ],
         "date_added": "$now", "date_modified": "$now", "id": "1", "name": "Bookmarks bar", "type": "folder"
      },
      "other":  { "children": [], "date_added": "$now", "id": "$id",       "name": "Other bookmarks",  "type": "folder" },
      "synced": { "children": [], "date_added": "$now", "id": "$($id + 1)", "name": "Mobile bookmarks", "type": "folder" }
   },
   "version": 1
}
"@

    # Chrome refuses a UTF-8 BOM here, and the stale .bak would be restored over
    # our file on the next launch -- so write raw UTF-8 and drop the backup.
    $dest = Join-Path $DispChromeDef "Bookmarks"
    [IO.File]::WriteAllText($dest, $json, (New-Object Text.UTF8Encoding($false)))
    Remove-Item (Join-Path $DispChromeDef "Bookmarks.bak") -Force -ErrorAction SilentlyContinue

    "bookmarks bar: " + (($ChromeBookmarks | ForEach-Object { $_.Name }) -join ", ")
}

# -----------------------------------------------------------------------------
# 9. Disable Windows 11 widgets
# -----------------------------------------------------------------------------
Write-Banner "6. Desktop hardening"
Invoke-Step "Disable Windows 11 widgets" {
    # Machine-wide policy disables the widgets board + lock-screen widgets.
    # Best-effort: on Intune/MDM-managed devices the Dsh policy key can be locked
    # ("unauthorized operation"), which must not fail the whole step.
    $notes = @()
    foreach ($v in @(
        @{ N="AllowNewsAndInterests"; V=0 },
        @{ N="DisableWidgetsOnLockScreen"; V=1 },
        @{ N="DisableWidgetsBoard"; V=1 })) {
        try { Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" $v.N DWord $v.V }
        catch { $notes += $v.N }
    }
    # Per-user taskbar button
    if ($DispSid) {
        try {
            Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
                param($root)
                Set-RegValue "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" DWord 0
            }
        } catch { $notes += "TaskbarDa" }
    }
    if ($notes.Count) { "some keys locked (likely Intune/MDM), skipped: " + ($notes -join ", ") }
}

Invoke-Step "Set EMS desktop + lock screen wallpaper" {
    # Download the wallpaper if it isn't sitting next to the script
    if (-not (Test-Path $WallpaperSrc) -and $WallpaperUrl) {
        try { Get-Installer -Url $WallpaperUrl -OutFile $WallpaperSrc -Label "Wallpaper" | Out-Null } catch {}
    }
    if (-not (Test-Path $WallpaperSrc)) { Skip-Step "wallpaper not found and download failed" }
    Copy-Item $WallpaperSrc $WallpaperDest -Force

    # Lock screen for ALL users (machine policy)
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "LockScreenImage" String $WallpaperDest

    # Desktop wallpaper enforced for the dispatcher (6 = Fit to screen)
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $sys = "$root\Software\Microsoft\Windows\CurrentVersion\Policies\System"
            Set-RegValue $sys "Wallpaper"      String $WallpaperDest
            Set-RegValue $sys "WallpaperStyle" String "6"
            $cpd = "$root\Control Panel\Desktop"
            Set-RegValue $cpd "Wallpaper"      String $WallpaperDest
            Set-RegValue $cpd "WallpaperStyle" String "6"
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
    # Fully disable Microsoft OneDrive (no sync, don't run) + keep it off startup
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" DWord 1
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSync"     DWord 1
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Keep apps allowed to run in the background (don't let Windows suspend them)
    Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" DWord 1

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

Invoke-Step "Clean dispatcher desktop (no Volume / Edge / web shortcuts)" {
    # The EMS links are bookmarks inside Chrome now, and the volume flyout on the
    # taskbar replaces the old SndVol shortcut -- so the desktop stays empty.
    $desktops = @(
        (Join-Path $DispProfile "Desktop"),
        (Join-Path $env:PUBLIC   "Desktop"),
        "C:\Users\Default\Desktop"
    ) | Where-Object { Test-Path $_ }

    $removed = @()
    foreach ($d in $desktops) {
        foreach ($n in $DesktopShortcutsToRemove) {
            foreach ($ext in @("lnk", "url")) {
                Get-ChildItem -Path $d -Filter "$n*.$ext" -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    $removed += $_.Name
                }
            }
        }
    }

    # Stop Edge from dropping its desktop icon back on every update
    $eu = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
    Set-RegValue $eu "CreateDesktopShortcutDefault" DWord 0
    Set-RegValue $eu "RemoveDesktopShortcutDefault" DWord 1

    if (-not $removed.Count) { "desktop already clean" }
    else { "removed: " + (($removed | Sort-Object -Unique) -join ", ") }
}

Invoke-Step "Set dispatcher startup app (Chrome -> Hatzalah Web)" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
    # Chrome is the ONLY thing that opens a window at logon, and it opens straight
    # onto Hatzalah Web. Bria, Jabra Direct and Lexip Control each start from their
    # own logon scheduled task -- Jabra and Lexip land in the system tray.

    # Chrome exe
    $chrome = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    # Lexip exe -- the MAIN control panel is lcp.exe (NOT updater.exe and NOT the
    # firmware_update\LexipFwUpd.exe tool that just prints usage and waits).
    $lexip = $null
    $info = Get-UninstallInfo "Lexip Control Software"
    if ($info -and $info.InstallLocation -and (Test-Path $info.InstallLocation)) {
        $lexip = Get-ChildItem $info.InstallLocation -Filter "lcp.exe" -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
        if (-not $lexip) {
            $lexip = Get-ChildItem $info.InstallLocation -Filter *.exe -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notmatch 'updater|FwUpd|firmware' } |
                     Select-Object -First 1 -ExpandProperty FullName
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
        if ($script:_StartChrome) {
            Set-RegValue $run "GoogleChrome" String ('"{0}" --start-maximized "{1}"' -f $script:_StartChrome, $KioskUrl)
        }
        # Jabra and Lexip must NOT be in the Run key -- Explorer starts Run-key apps
        # in the foreground, which is what kept popping their windows open. They are
        # started minimised to the tray by their own logon tasks instead.
        Remove-ItemProperty -Path $run -Name "LexipControl" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $run -Name "JabraDirect"  -ErrorAction SilentlyContinue
    }

    if (-not $chrome) { throw "Chrome not installed -- cannot start it at login" }
    "Chrome starts at logon on $KioskUrl"
}

Invoke-Step "Pin Chrome + Bria to the taskbar (dispatcher)" {
    if (-not $DispSid) { throw "dispatcher SID not found" }
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

    # Current supported method (Win11 24H2/25H2): the profile "Shell folder" file
    # is IGNORED since 24H2 -- the "Start Layout" policy must point to the XML.
    # Write the XML to a stable machine path:
    $layoutPath = Join-Path $LogDir "taskbar-layout.xml"
    Set-Content -Path $layoutPath -Value $xml -Encoding UTF8 -Force

    # Legacy fallback for older builds: also drop it in the profile Shell folders.
    foreach ($base in @($DispProfile, "C:\Users\Default")) {
        $shellDir = Join-Path $base "AppData\Local\Microsoft\Windows\Shell"
        if (-not (Test-Path $shellDir)) { New-Item -Path $shellDir -ItemType Directory -Force | Out-Null }
        Set-Content -Path (Join-Path $shellDir "LayoutModification.xml") -Value $xml -Encoding UTF8 -Force
    }

    $script:_LayoutPath = $layoutPath
    Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
        param($root)
        # NOTE: StartLayoutFile + LockedStartLayout can blank/break the Win11 shell
        # on 24H2/25H2 (and stop Run-key apps like Chrome from launching), so we do
        # NOT set them. Make sure any from an earlier run are cleared.
        $exp = "$root\Software\Policies\Microsoft\Windows\Explorer"
        Remove-ItemProperty -Path $exp -Name "StartLayoutFile"   -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $exp -Name "LockedStartLayout" -ErrorAction SilentlyContinue
        # Force the taskbar to rebuild from the layout
        $tb = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        Remove-ItemProperty -Path $tb -Name "Favorites"        -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $tb -Name "FavoritesResolve" -ErrorAction SilentlyContinue
    }

    "taskbar layout written (apps also auto-start): " + (($links | ForEach-Object { Split-Path $_ -Leaf }) -join ", ")
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
# 12b. Jabra Direct + Lexip Control -- start as BACKGROUND / SYSTEM TRAY apps
# -----------------------------------------------------------------------------
Write-Banner "7b. Background (system tray) apps"

# Strips a vendor's own foreground autostart (Run keys + Startup shortcuts) so the
# tray task below is the only thing that launches the app.
function Remove-VendorAutostart {
    param([string]$Match)
    $script:_VendorMatch = $Match
    foreach ($k in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")) {
        if (-not (Test-Path $k)) { continue }
        $props = Get-ItemProperty -Path $k
        foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" })) {
            if ($p.Name -like "*$Match*" -or "$($p.Value)" -like "*$Match*") {
                Remove-ItemProperty -Path $k -Name $p.Name -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($d in @((Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp"), $DispStartup)) {
        if ($d -and (Test-Path $d)) {
            Get-ChildItem -Path $d -Filter "*.lnk" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$Match*" } |
                ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($DispSid) {
        Use-UserHive -Sid $DispSid -NtUserDat $DispNtUser -Body {
            param($root)
            $run = "$root\Software\Microsoft\Windows\CurrentVersion\Run"
            if (Test-Path $run) {
                $props = Get-ItemProperty -Path $run
                foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" })) {
                    if ($p.Name -like "*$($script:_VendorMatch)*" -or "$($p.Value)" -like "*$($script:_VendorMatch)*") {
                        Remove-ItemProperty -Path $run -Name $p.Name -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}

# Logon task that runs the tray launcher. A scheduled task is used (not the Run
# key) because the Task Scheduler service is not subject to the dispatcher's
# DisallowRun policy, and because it can run completely hidden.
function Register-TrayAppTask {
    param([string]$TaskName, [string]$Exe, [string]$Arguments = "", [string]$Delay = "PT25S")
    $helper = Join-Path $LogDir "Start-TrayApp.ps1"
    $psExe  = Join-Path $PSHOME "powershell.exe"
    $a = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Path "{1}"' -f $helper, $Exe
    if ($Arguments) { $a += (' -Arguments "{0}"' -f $Arguments) }

    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $a
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $DispatcherUser
    $trigger.Delay = $Delay
    $principal = New-ScheduledTaskPrincipal -UserId $DispatcherUser -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

Invoke-Step "Install the system-tray launcher helper" {
    $helper = Join-Path $LogDir "Start-TrayApp.ps1"
    $body = @'
<#
  Start-TrayApp.ps1 -- KJ EMS kiosk
  Starts an application and parks it in the notification area (system tray):
  the app runs in the background, its window never greets the dispatcher.
#>
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Arguments = "",
    [int]$WaitSec   = 90,
    [int]$SettleSec = 8
)
if (-not (Test-Path $Path)) { exit 1 }

Add-Type -Namespace KJEMS -Name Win -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@

$SW_HIDE = 0
$SW_MINIMIZE = 6
$name = [IO.Path]::GetFileNameWithoutExtension($Path)

$sp = @{ FilePath = $Path; PassThru = $true; WindowStyle = 'Minimized' }
if ($Arguments) { $sp.ArgumentList = $Arguments }
try { $null = Start-Process @sp } catch { exit 1 }

# As soon as a window appears, minimise it (that is what puts these apps in the tray)
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $WaitSec) {
    Start-Sleep -Milliseconds 500
    $wins = @(Get-Process -Name $name -ErrorAction SilentlyContinue |
              Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($wins.Count -gt 0) {
        foreach ($w in $wins) { [KJEMS.Win]::ShowWindow($w.MainWindowHandle, $SW_MINIMIZE) | Out-Null }
        break
    }
}

# Electron/Qt apps like to re-show their window a moment after starting -- give
# them time to settle, then tuck the window away so only the tray icon is left.
Start-Sleep -Seconds $SettleSec
for ($i = 0; $i -lt 3; $i++) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
        ForEach-Object { [KJEMS.Win]::ShowWindow($_.MainWindowHandle, $SW_HIDE) | Out-Null }
    Start-Sleep -Seconds 2
}
exit 0
'@
    Set-Content -Path $helper -Value $body -Encoding UTF8 -Force
    "helper: $helper"
}

Invoke-Step "Jabra Direct: start in the system tray at logon" {
    $jabra = @(
        "C:\Program Files (x86)\Jabra\Direct6\jabra-direct.exe",
        "C:\Program Files\Jabra\Direct6\jabra-direct.exe",
        "C:\Program Files (x86)\Jabra\Direct\jabra-direct.exe",
        "C:\Program Files\Jabra\Direct\jabra-direct.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $jabra) {
        foreach ($root in @("C:\Program Files (x86)\Jabra", "C:\Program Files\Jabra")) {
            if (-not (Test-Path $root)) { continue }
            $jabra = Get-ChildItem $root -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'jabra[- ]?direct\.exe$' } |
                     Select-Object -First 1 -ExpandProperty FullName
            if ($jabra) { break }
        }
    }
    if (-not $jabra) {
        $info = Get-UninstallInfo "Jabra Direct"
        if ($info -and $info.InstallLocation -and (Test-Path $info.InstallLocation)) {
            $jabra = Get-ChildItem $info.InstallLocation -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'jabra' -and $_.Name -notmatch 'updat|uninst|crash|report|setup' } |
                     Select-Object -First 1 -ExpandProperty FullName
        }
    }
    if (-not $jabra) { Skip-Step "Jabra Direct not installed yet" }

    Remove-VendorAutostart -Match "jabra"
    Register-TrayAppTask -TaskName "KJEMS Jabra Direct (tray)" -Exe $jabra -Delay "PT25S"
    "tray launch: $jabra"
}

Invoke-Step "Lexip Control: start in the system tray at logon" {
    $lexip = $script:_StartLexip
    if (-not $lexip) {
        $info = Get-UninstallInfo "Lexip Control Software"
        if ($info -and $info.InstallLocation -and (Test-Path $info.InstallLocation)) {
            $lexip = Get-ChildItem $info.InstallLocation -Filter "lcp.exe" -Recurse -ErrorAction SilentlyContinue |
                     Select-Object -First 1 -ExpandProperty FullName
        }
    }
    if (-not $lexip) { Skip-Step "Lexip Control Software not installed yet" }

    Remove-VendorAutostart -Match "lexip"
    Register-TrayAppTask -TaskName "KJEMS Lexip Control (tray)" -Exe $lexip -Delay "PT35S"
    "tray launch: $lexip"
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

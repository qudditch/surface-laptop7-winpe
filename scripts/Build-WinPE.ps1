<#
.SYNOPSIS
    Builds an ARM64 Windows PE image (bootable ISO) for Surface Laptop 7
    (Snapdragon X Elite), with the Surface / Qualcomm platform drivers
    injected so that the built-in keyboard, touchpad and touchscreen work
    while WinPE is running.

.DESCRIPTION
    Based on the caccialdo gist "How to reinstall Windows 11 Home on a
    Snapdragon X Elite device", extended with offline driver injection.

    The driver list lives in scripts\winpe-drivers.txt - edit that file to
    add or remove packages (it is intentionally data, not code).

    The WinRE driver (mshidkmdf) is not part of the ADK WinPE image, so it is
    extracted from the Windows install image (install.esd) and copied into
    the boot image.  That makes SurfaceHidMiniDriver (the built-in keyboard)
    installable inside WinPE.

    The built-in keyboard package itself must be the Windows PE build from
    Microsoft's SurfaceHidMini_WinPE.zip (folder SurfaceHidMini_WinPE_ARM),
    not the Windows 11 build in the driver MSI.  The manifest points at the
    copy extracted under drivers\...\surfacehidminiwinpearm.

.PARAMETER DriverProfile
    Manifest (default) = only the packages listed in winpe-drivers.txt.
    All                = every *.inf under the driver root (slower, bigger).

.PARAMETER UsbDrive
    Optional.  Writes the finished WinPE to this USB drive (e.g. "E:") with
    MakeWinPEMedia /UFD.  THE TARGET IS ERASED.  Requires -Force.

.EXAMPLE
    .\Build-WinPE.ps1

.EXAMPLE
    .\Build-WinPE.ps1 -DriverProfile All

.NOTES
    Must run elevated (the script opens a UAC prompt if it is not).
#>
[CmdletBinding()]
param(
    [string] $Workspace,
    [string] $DriverRoot,
    [string] $Manifest,
    [ValidateSet('Manifest', 'All')]
    [string] $DriverProfile = 'Manifest',
    [string] $InstallImage,
    [string] $OutputIso,
    [int]    $ScratchSpaceMB = 1024,
    [switch] $SkipMshidkmdf,
    [switch] $UseExBootManager,
    [string] $UsbDrive,
    [switch] $Force,
    [switch] $KeepWork
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    throw 'This script must run elevated. Right-click PowerShell -> Run as administrator, or start it with Start-Process -Verb RunAs.'
}

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
if (-not $Workspace)      { $Workspace      = Split-Path -Parent $PSScriptRoot }
if (-not $DriverRoot)     { $DriverRoot     = Join-Path $Workspace 'drivers\SurfaceLaptop7\SurfaceUpdate' }
if (-not $Manifest)       { $Manifest       = Join-Path $PSScriptRoot 'winpe-drivers.txt' }
if (-not $InstallImage)   { $InstallImage   = Join-Path $Workspace 'install.esd' }
if (-not $OutputIso)      { $OutputIso      = Join-Path $Workspace 'out\WinPE_SurfaceLaptop7_arm64.iso' }

$AdkRoot       = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
$WinPERoot     = Join-Path $AdkRoot 'Windows Preinstallation Environment'
$DeployTools   = Join-Path $AdkRoot 'Deployment Tools'
$Copype        = Join-Path $WinPERoot 'copype.cmd'
$MakeWinPE     = Join-Path $WinPERoot 'MakeWinPEMedia.cmd'
$Dism          = Join-Path $env:SystemRoot 'System32\Dism.exe'
$RegExe        = Join-Path $env:SystemRoot 'System32\reg.exe'

$OutDir        = Join-Path $Workspace 'out'
$LogDir        = Join-Path $OutDir 'logs'
$WorkRoot      = Join-Path $OutDir 'work'
$WinPeWork     = Join-Path $WorkRoot 'winpe_arm64'
$MountDir      = Join-Path $WinPeWork 'mount'
$BootWim       = Join-Path $WinPeWork 'media\sources\boot.wim'
$CacheDir      = Join-Path $OutDir 'cache\mshidkmdf'
$EsdMount      = Join-Path $WorkRoot 'esd_mount'

# Surface Laptop 7 (Snapdragon) needs the Windows PE build of the Surface HID
# Mini driver (Microsoft's separate SurfaceHidMini_WinPE.zip), not the Windows
# 11 build inside the driver MSI's 'hidmini' folder.  The manifest must list
# this folder and must NOT list 'hidmini'.
$PeHidMiniEntry = 'surfacehidminiwinpearm'

New-Item -ItemType Directory -Force -Path $OutDir, $LogDir, $WorkRoot | Out-Null

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "Build-WinPE_$stamp.log"
Start-Transcript -Path $logFile -Force | Out-Null

$script:Failures = @()
$script:Injected = @()
$mounted = $false
$peHidMiniStageInf = $null

function Write-Step([string] $Text) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host "  $Text"
    Write-Host ('=' * 78)
}

function Invoke-Dism {
    param([string[]] $Arguments)
    Write-Host ("> dism " + ($Arguments -join ' '))
    # Pipe to Out-Host so DISM's stdout does not end up in the function's
    # output stream; otherwise the caller receives an array (output + exit
    # code) and every "-ne 0" test would look like a failure.
    & $Dism @Arguments | Out-Host
    return $LASTEXITCODE
}

# --------------------------------------------------------------------------
# Sanity checks
# --------------------------------------------------------------------------
Write-Step 'Checking prerequisites'

foreach ($p in @($Copype, $MakeWinPE, $Dism)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p  (is the Windows ADK + WinPE add-on installed?)" }
}
if (-not (Test-Path -LiteralPath (Join-Path $WinPERoot 'arm64\en-us\winpe.wim'))) {
    throw "The ADK does not contain the ARM64 WinPE files: $WinPERoot\arm64"
}
if (-not (Test-Path -LiteralPath $DriverRoot)) { throw "Driver root not found: $DriverRoot" }
if (-not (Test-Path -LiteralPath $Manifest))  { throw "Driver manifest not found: $Manifest" }

# These are normally set by the "Deployment and Imaging Tools Environment"
# shortcut (DandISetEnv.bat).  Set them here so the script can be started from
# a plain elevated PowerShell window.
$env:WinPERoot   = $WinPERoot
$env:DISMRoot    = Join-Path $DeployTools 'amd64\Dism'
$env:OSCDImgRoot = Join-Path $DeployTools 'amd64\Oscdimg'
$env:PATH = (Join-Path $DeployTools 'amd64') + ';' + $env:DISMRoot + ';' + $env:OSCDImgRoot + ';' + $env:PATH

Write-Host "Workspace   : $Workspace"
Write-Host "Driver root : $DriverRoot"
Write-Host "Manifest    : $Manifest"
Write-Host "Install img : $InstallImage"
Write-Host "Output ISO  : $OutputIso"
Write-Host "Scratch     : $ScratchSpaceMB MB"

# --------------------------------------------------------------------------
# 1. copype
# --------------------------------------------------------------------------
Write-Step 'Step 1/7  Creating a clean WinPE ARM64 working copy (copype)'

Write-Host 'Cleaning up stale DISM mounts (if any)...'
# /Cleanup-Mountpoints only drops *orphaned* mount records.  A mount left
# behind by an aborted run is still valid, so the image file stays locked and
# Remove-Item below would fail.  Unmount explicitly first; the work tree is
# thrown away anyway, so Discard is correct and its errors are ignored.
foreach ($staleMount in @($MountDir, $EsdMount)) {
    if (Test-Path -LiteralPath $staleMount) {
        & $Dism /Unmount-Image "/MountDir:$staleMount" /Discard | Out-Null
    }
}
& $Dism /Cleanup-Mountpoints | Out-Null

# Give the WIM filter driver a moment to release the image file.
function Remove-WorkTree([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($n = 1; $n -le 20; $n++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return }
        catch {
            if ($n -eq 20) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}
Remove-WorkTree $WinPeWork
Remove-WorkTree $EsdMount

& cmd.exe /c "`"$Copype`" arm64 `"$WinPeWork`""
if ($LASTEXITCODE -ne 0) { throw "copype failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $BootWim)) { throw "copype did not produce $BootWim" }

# --------------------------------------------------------------------------
# 2. Mount boot.wim
# --------------------------------------------------------------------------
Write-Step 'Step 2/7  Mounting boot.wim'

New-Item -ItemType Directory -Force -Path $MountDir | Out-Null
$rc = Invoke-Dism @('/Mount-Image', "/ImageFile:$BootWim", '/Index:1', "/MountDir:$MountDir")
if ($rc -ne 0) { throw "Dism /Mount-Image failed with exit code $rc" }

$mounted = $true

try {
    # ----------------------------------------------------------------------
    # 3. mshidkmdf (needed by SurfaceHidMiniDriver)
    # ----------------------------------------------------------------------
    Write-Step 'Step 3/7  Adding mshidkmdf (HID KMDF framework) to WinPE'

    if ($SkipMshidkmdf) {
        Write-Host 'Skipped (user requested). The built-in keyboard driver may not install.' -ForegroundColor Yellow
    }
    else {
        $cacheInf = Join-Path $CacheDir 'mshidkmdf.inf'
        $cacheSys = Join-Path $CacheDir 'mshidkmdf.sys'

        if (-not ((Test-Path -LiteralPath $cacheInf) -and (Test-Path -LiteralPath $cacheSys))) {
            if (-not (Test-Path -LiteralPath $InstallImage)) {
                throw "install image not found: $InstallImage (needed to extract mshidkmdf). Use -InstallImage or -SkipMshidkmdf."
            }
            New-Item -ItemType Directory -Force -Path $EsdMount, $CacheDir | Out-Null

            # DISM cannot mount ESD (or SWM) images - export index 1 to a WIM first.
            $extractImage = $InstallImage
            $tempWim = $null
            if ($InstallImage -match '\.(esd|swm)$') {
                $tempWim = Join-Path $OutDir 'cache\install-extract.wim'
                if (-not (Test-Path -LiteralPath $tempWim)) {
                    Write-Host "Exporting index 1 of $InstallImage to a temporary WIM (DISM cannot mount ESD/SWM directly)."
                    Write-Host 'This is a one-time step - it can take 10-20 minutes.'
                    $rc = Invoke-Dism @('/Export-Image',
                                        "/SourceImageFile:$InstallImage",
                                        '/SourceIndex:1',
                                        "/DestinationImageFile:$tempWim",
                                        '/Compress:fast')
                    if ($rc -ne 0) { throw "Dism /Export-Image failed (exit $rc)." }
                }
                else {
                    Write-Host "Reusing exported WIM: $tempWim"
                }
                $extractImage = $tempWim
            }

            Write-Host "Mounting $extractImage read-only and extracting mshidkmdf..."
            $rc = Invoke-Dism @('/Mount-Image', "/ImageFile:$extractImage", '/Index:1', "/MountDir:$EsdMount", '/ReadOnly')
            if ($rc -ne 0) { throw "Could not mount the install image read-only (exit $rc)." }

            try {
                $srcInf = Join-Path $EsdMount 'Windows\INF\mshidkmdf.inf'
                $srcSys = Join-Path $EsdMount 'Windows\System32\drivers\mshidkmdf.sys'
                if (-not (Test-Path -LiteralPath $srcInf)) { throw "mshidkmdf.inf not found inside the install image." }
                if (-not (Test-Path -LiteralPath $srcSys)) { throw "mshidkmdf.sys not found inside the install image." }

                Copy-Item -LiteralPath $srcInf -Destination $cacheInf -Force
                Copy-Item -LiteralPath $srcSys -Destination $cacheSys -Force

                # Catalog files for the HID miniport package (used to validate mshidkmdf.inf).
                $catRootRel = 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
                $srcCatRoot = Join-Path $EsdMount $catRootRel
                if (Test-Path -LiteralPath $srcCatRoot) {
                    $cats = Get-ChildItem -LiteralPath $srcCatRoot -Filter '*HIDMiniports*.cat' -ErrorAction SilentlyContinue
                    if ($cats) {
                        New-Item -ItemType Directory -Force -Path (Join-Path $CacheDir 'CatRoot') | Out-Null
                        $cats | Copy-Item -Destination (Join-Path $CacheDir 'CatRoot') -Force
                        Write-Host ("Cached catalogs: " + (($cats | ForEach-Object Name) -join ', '))
                    }
                    else {
                        Write-Warning 'No *HIDMiniports*.cat found in the install image; continuing without catalog.'
                    }
                }
            }
            finally {
                & $Dism /Unmount-Image "/MountDir:$EsdMount" /Discard | Out-Null
                if ($tempWim -and -not $KeepWork) {
                    Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            Write-Host 'Using cached mshidkmdf files.'
        }

        # WinPE ships mshidkmdf.sys in System32\drivers already (it is the
        # binary half of the package) but not mshidkmdf.inf, which is what
        # "Include=mshidkmdf.inf" needs.  The existing .sys is a SYSTEM-owned
        # sparse/reparse entry inside the WIM and cannot be overwritten, so
        # only add it when it is really absent.
        $dstInf = Join-Path $MountDir 'Windows\INF\mshidkmdf.inf'
        $dstSys = Join-Path $MountDir 'Windows\System32\drivers\mshidkmdf.sys'

        Copy-Item -LiteralPath $cacheInf -Destination $dstInf -Force

        if (Test-Path -LiteralPath $dstSys) {
            Write-Host 'mshidkmdf.sys is already in the WinPE image (inbox) - keeping it.'
        }
        else {
            Copy-Item -LiteralPath $cacheSys -Destination $dstSys -Force
            Write-Host 'mshidkmdf.sys copied from the install image.'
        }

        $cacheCatRoot = Join-Path $CacheDir 'CatRoot'
        if (Test-Path -LiteralPath $cacheCatRoot) {
            $dstCatRoot = Join-Path $MountDir 'Windows\System32\CatRoot\{F750E6C3-38EE-11D1-85E5-00C04FC295EE}'
            New-Item -ItemType Directory -Force -Path $dstCatRoot | Out-Null
            Get-ChildItem -LiteralPath $cacheCatRoot -Filter '*.cat' |
                Copy-Item -Destination $dstCatRoot -Force
        }
        # Also register mshidkmdf as a driver package of its own.  On a normal
        # Windows install it lives in the driver store as part of the
        # Microsoft-OneCore-HIDMiniports package; having it there as well as
        # in Windows\INF makes "Include=mshidkmdf.inf" resolve no matter which
        # search path SetupAPI consults during PnP enumeration.
        $stagedPkg = Join-Path $WorkRoot 'driverstage\mshidkmdf'
        New-Item -ItemType Directory -Force -Path $stagedPkg | Out-Null
        Copy-Item -LiteralPath $cacheInf -Destination $stagedPkg -Force
        Copy-Item -LiteralPath $cacheSys -Destination $stagedPkg -Force
        if (Test-Path -LiteralPath $cacheCatRoot) {
            Get-ChildItem -LiteralPath $cacheCatRoot -Filter '*.cat' |
                Copy-Item -Destination $stagedPkg -Force
        }
        $rc = Invoke-Dism @("/Image:$MountDir", '/Add-Driver',
                            "/Driver:$(Join-Path $stagedPkg 'mshidkmdf.inf')",
                            "/LogPath:$LogDir\dism-add-driver.log")
        if ($rc -eq 0) { Write-Host 'mshidkmdf registered as a driver package.' -ForegroundColor Green }
        else { Write-Warning 'Could not register mshidkmdf as a package (the Windows\INF copy is still in place).' }

        Write-Host 'mshidkmdf added.' -ForegroundColor Green

        # Stage a copy of the Surface HID Mini package next to mshidkmdf.* so
        # that "Include=mshidkmdf.inf" also resolves from the package folder
        # while DISM adds the driver.
        $peHidMiniSrc = Join-Path $DriverRoot $PeHidMiniEntry
        $peHidMiniStage = Join-Path $WorkRoot "driverstage\$PeHidMiniEntry"
        if (Test-Path -LiteralPath $peHidMiniSrc) {
            New-Item -ItemType Directory -Force -Path $peHidMiniStage | Out-Null
            Copy-Item -Path (Join-Path $peHidMiniSrc '*') -Destination $peHidMiniStage -Force
            Copy-Item -LiteralPath $cacheInf -Destination $peHidMiniStage -Force
            Copy-Item -LiteralPath $cacheSys -Destination $peHidMiniStage -Force
            $peHidMiniStageInf = Join-Path $peHidMiniStage 'SurfaceHidMiniDriver.inf'
        }
        else {
            Write-Warning "Surface HID Mini WinPE package not found: $peHidMiniSrc"
            Write-Warning 'Download SurfaceHidMini_WinPE.zip from Microsoft and extract SurfaceHidMini_WinPE_ARM here.'
        }
    }

    # ----------------------------------------------------------------------
    # 4. Driver injection
    # ----------------------------------------------------------------------
    Write-Step 'Step 4/7  Injecting drivers into WinPE'

    $required = @(
        $PeHidMiniEntry,            # built-in keyboard (Surface HID Mini, WinPE build)
        'surfaceserialhubdriver',   # keyboard transport
        'surfaceintegrationdriver',
        'qci2c8380',
        'qcspi8380',                # touchpad
        'qcgpi8380',                # GPIO interrupt controller
        'qcgpio8380',
        'qcpmicgpio8380'
    )

    $toInject = @()   # list of @{ Name; Inf }

    if ($DriverProfile -eq 'All') {
        # 'hidmini' holds the Windows 11 build of Surface HID Mini.  Injecting it
        # next to the WinPE build makes PnP prefer the newer Windows build and
        # the built-in keyboard stays dead, so it is never added to WinPE.
        Get-ChildItem -LiteralPath $DriverRoot -Recurse -Filter '*.inf' |
            Where-Object { (Split-Path $_.DirectoryName -Leaf) -ne 'hidmini' } |
            ForEach-Object {
                $toInject += [pscustomobject]@{ Name = (Split-Path $_.DirectoryName -Leaf); Inf = $_.FullName }
            }
        if (Get-ChildItem -LiteralPath $DriverRoot -Recurse -Directory -Filter 'hidmini') {
            Write-Warning "-DriverProfile All: skipped 'hidmini' (Windows 11 build of Surface HID Mini)."
            Write-Warning 'Only surfacehidminiwinpearm (Windows PE build) may be injected.'
        }
    }
    else {
        $entries = Get-Content -LiteralPath $Manifest |
            ForEach-Object { ($_ -split '#', 2)[0].Trim() } |
            Where-Object { $_ }

        foreach ($entry in $entries) {
            $dir = Join-Path $DriverRoot $entry
            if (-not (Test-Path -LiteralPath $dir)) {
                Write-Warning "Manifest entry not found (skipped): $entry"
                continue
            }
            $infs = Get-ChildItem -LiteralPath $dir -Filter '*.inf' -File
            if (-not $infs) {
                Write-Warning "No .inf in $dir (skipped)"
                continue
            }
            foreach ($inf in $infs) {
                $infPath = $inf.FullName
                if ($entry -eq $PeHidMiniEntry -and $peHidMiniStageInf -and (Test-Path -LiteralPath $peHidMiniStageInf)) {
                    $infPath = $peHidMiniStageInf
                }
                $toInject += [pscustomobject]@{ Name = $entry; Inf = $infPath }
            }
        }
    }

    Write-Host ("Driver packages to add: " + $toInject.Count)

    $i = 0
    foreach ($item in $toInject) {
        $i++
        Write-Progress -Activity 'Adding drivers' -Status $item.Name -PercentComplete (($i / [math]::Max($toInject.Count,1)) * 100)
        & $Dism /Image:"$MountDir" /Add-Driver "/Driver:$($item.Inf)" "/LogPath:$LogDir\dism-add-driver.log"
        if ($LASTEXITCODE -eq 0) {
            $script:Injected += $item.Name
        }
        else {
            $script:Failures += [pscustomobject]@{ Name = $item.Name; Inf = $item.Inf }
            Write-Warning "Add-Driver failed: $($item.Name)"
        }
    }
    Write-Progress -Activity 'Adding drivers' -Completed

    $failedRequired = $script:Failures | Where-Object { $required -contains $_.Name }
    if ($failedRequired) {
        $failedRequired | ForEach-Object { Write-Host "  FAILED: $($_.Name)" -ForegroundColor Red }
        throw 'A required input driver could not be injected. See out\logs\dism-add-driver.log.'
    }

    # ----------------------------------------------------------------------
    # 5. WinPE settings
    # ----------------------------------------------------------------------
    Write-Step 'Step 5/7  Configuring WinPE (scratch space)'

    $hivePath = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
    & $RegExe load 'HKLM\WINPE_OFFLINE' $hivePath | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $RegExe add 'HKLM\WINPE_OFFLINE\Microsoft\Windows NT\CurrentVersion\WinPE' /v ScratchSpace /t REG_DWORD /d $ScratchSpaceMB /f | Out-Null
        & $RegExe unload 'HKLM\WINPE_OFFLINE' | Out-Null
        Write-Host "ScratchSpace = $ScratchSpaceMB MB"
    }
    else {
        Write-Warning 'Could not load the offline SOFTWARE hive; leaving scratch space at the default.'
    }

    # Driver report, handy when debugging on the device.
    $report = Join-Path $MountDir 'Windows\System32\WinPE-DriverReport.cmd'
    @(
        '@echo off',
        'echo === Added driver packages ===',
        'dism /online /get-drivers /format:table',
        'echo.',
        'echo === Input devices / problems ===',
        'pnputil /enum-devices /class Keyboard',
        'pnputil /enum-devices /class Mouse',
        'pnputil /enum-devices /class HIDClass',
        'echo.',
        'echo === Disks / volumes ===',
        'echo list disk > %TEMP%\dp.txt',
        'echo list volume >> %TEMP%\dp.txt',
        'diskpart /s %TEMP%\dp.txt',
        'del %TEMP%\dp.txt'
    ) | Set-Content -LiteralPath $report -Encoding ASCII
    Write-Host 'Added X:\Windows\System32\WinPE-DriverReport.cmd (diagnostics).'

    # ----------------------------------------------------------------------
    # 6. Commit
    # ----------------------------------------------------------------------
    Write-Step 'Step 6/7  Committing changes'

    & $Dism /Unmount-Image "/MountDir:$MountDir" /Commit
    if ($LASTEXITCODE -ne 0) { throw "Dism /Unmount-Image /Commit failed ($LASTEXITCODE)" }
    $mounted = $false

    # ----------------------------------------------------------------------
    # 7. ISO
    # ----------------------------------------------------------------------
    Write-Step 'Step 7/7  Creating the bootable ISO'

    if (Test-Path -LiteralPath $OutputIso) {
        # A mounted copy of the previous ISO (e.g. left over from a manual look at
        # the image) holds a lock on the file and makes both the delete and
        # oscdimg fail.  Unmount it first; ask the user to close anything else.
        $mounted = Get-DiskImage -ImagePath $OutputIso -ErrorAction SilentlyContinue
        if ($mounted -and $mounted.Attached) {
            Write-Host 'Dismounting the previously mounted output ISO...'
            Dismount-DiskImage -ImagePath $OutputIso -ErrorAction SilentlyContinue | Out-Null
        }
        try { Remove-Item -LiteralPath $OutputIso -Force -ErrorAction Stop }
        catch {
            throw "Cannot replace $OutputIso - it is still in use. Dismount the ISO or close whatever has it open, then re-run."
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputIso) | Out-Null

    $bootexArg = ''
    if ($UseExBootManager) { $bootexArg = ' /bootex' }

    & cmd.exe /c "`"$MakeWinPE`" /ISO `"$WinPeWork`" `"$OutputIso`"$bootexArg"
    if ($LASTEXITCODE -ne 0) { throw "MakeWinPEMedia /ISO failed ($LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $OutputIso)) { throw 'ISO was not created.' }

    $bw = Get-Item -LiteralPath $BootWim
    $iso = Get-Item -LiteralPath $OutputIso
    Write-Host ''
    Write-Host ("boot.wim : {0:N0} MB" -f ($bw.Length / 1MB))
    Write-Host ("ISO      : {0:N0} MB  -> $($iso.FullName)" -f ($iso.Length / 1MB))

    # ----------------------------------------------------------------------
    # Optional USB write
    # ----------------------------------------------------------------------
    if ($UsbDrive) {
        Write-Step "Writing WinPE to USB $UsbDrive (destructive)"
        if (-not $Force) { throw 'Refusing to erase a USB drive without -Force.' }

        # MakeWinPEMedia /UFD only formats the existing volume and marks it
        # "active", which fails on GPT disks ("the disk is not MBR").  Build a
        # clean GPT layout with a real EFI system partition instead - that is
        # what Surface firmware expects.
        $letter = $UsbDrive.TrimEnd(':', '\')
        $vol = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $usb = Get-Disk -Number $vol.DiskNumber
        if ($usb.BusType -ne 'USB')          { throw "$UsbDrive ($($usb.FriendlyName)) is not a USB disk." }
        if ($usb.IsSystem -or $usb.IsBoot)   { throw "$UsbDrive is the system/boot disk - refusing." }
        Write-Host ("Target: disk {0} {1}, {2:N0} GB" -f $usb.Number, $usb.FriendlyName, ($usb.Size / 1GB))
        Write-Host 'This erases the whole USB disk.' -ForegroundColor Yellow

        Clear-Disk -Number $usb.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        Initialize-Disk -Number $usb.Number -PartitionStyle GPT -ErrorAction Stop
        $espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $null = New-Partition -DiskNumber $usb.Number -Size 2GB -GptType $espGuid -DriveLetter $letter
        Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel 'WINPE' -Confirm:$false | Out-Null

        $mediaRoot = Join-Path $WinPeWork 'media'
        & robocopy.exe $mediaRoot "${letter}:\" /E /J /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) writing to $UsbDrive" }
        if (-not (Test-Path -LiteralPath "${letter}:\EFI\Boot\bootaa64.efi")) {
            throw 'The USB stick does not contain EFI\Boot\bootaa64.efi - it will not boot.'
        }
        Write-Host "WinPE written to $letter`: (FAT32, EFI system partition)." -ForegroundColor Green
    }

    # ----------------------------------------------------------------------
    # Summary
    # ----------------------------------------------------------------------
    Write-Step 'Summary'
    Write-Host ("Injected packages : " + $script:Injected.Count)
    if ($script:Failures.Count -gt 0) {
        Write-Host ("Failed packages   : " + $script:Failures.Count) -ForegroundColor Yellow
        $script:Failures | ForEach-Object { Write-Host ("  - " + $_.Name) -ForegroundColor Yellow }
        Write-Host '  (details: out\logs\dism-add-driver.log)'
    }
    Write-Host "Log: $logFile"
}
catch {
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if ($mounted) {
        Write-Host 'Discarding the mounted WinPE image...'
        & $Dism /Unmount-Image "/MountDir:$MountDir" /Discard | Out-Null
    }
    throw
}
finally {
    if (-not $KeepWork) {
        # keep out\work for now only if the user asked; otherwise clean up
        if (Test-Path -LiteralPath $WinPeWork) {
            try { Remove-Item -LiteralPath $WinPeWork -Recurse -Force } catch {}
        }
    }
    Stop-Transcript | Out-Null
}

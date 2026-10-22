<#
.SYNOPSIS
    Creates the second (NTFS) USB stick from the caccialdo guide: the install
    image, the partition script, ApplyImage.bat and optionally the Surface
    driver package.

.DESCRIPTION
    Two modes:

      Folder mode (default)
        Stages everything into out\InstallMedia.  Copy that folder to an
        NTFS-formatted USB stick yourself, or run this script again with
        -UsbDisk to do it automatically.

      USB mode (-UsbDisk N)
        Erases disk N (must be a USB disk, never the system disk), creates a
        single NTFS partition labelled WININSTALL and copies the staged
        content onto it.  Requires -Force.

    Swapping the install image later:
        Put the new install.esd (or .wim / .swm) in the workspace and run
        this script again.  Nothing in WinPE has to be rebuilt; ApplyImage.bat
        auto-detects the file and lets you pick the image index at run time.

.EXAMPLE
    .\New-InstallMedia.ps1
.EXAMPLE
    .\New-InstallMedia.ps1 -Image D:\ISO\install.esd
.EXAMPLE
    .\New-InstallMedia.ps1 -UsbDisk 2 -Force
#>
[CmdletBinding()]
param(
    [string] $Workspace,
    [string] $Image,
    [string] $Destination,
    [switch] $SkipDrivers,
    [int]    $UsbDisk = -1,
    [switch] $Force,
    [switch] $AllowWinPERemoval
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $Workspace)   { $Workspace   = Split-Path -Parent $PSScriptRoot }
if (-not $Image)       { $Image       = Join-Path $Workspace 'install.esd' }
if (-not $Destination) { $Destination = Join-Path $Workspace 'out\InstallMedia' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Copy-Tree {
    param([string] $Source, [string] $Target)
    $null = New-Item -ItemType Directory -Force -Path $Target
    & robocopy.exe $Source $Target /E /J /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) copying $Source" }
}

Write-Host "Workspace   : $Workspace"
Write-Host "Install img : $Image"
Write-Host "Destination : $Destination"

if (-not (Test-Path -LiteralPath $Image)) { throw "Install image not found: $Image" }

# --------------------------------------------------------------------------
# Stage the tree
# --------------------------------------------------------------------------
Write-Host ''
Write-Host 'Staging install media...'

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# Remove any previous image (esd / wim / split swm parts)
Get-ChildItem -LiteralPath $Destination -File |
    Where-Object { $_.Name -match '^(install(\.esd|\.wim|\d*\.swm))$' -or $_.Name -match '^install\d+\.swm$' } |
    Remove-Item -Force

Write-Host "  copying image -> $Destination"
& robocopy.exe (Split-Path -Parent $Image) $Destination (Split-Path -Leaf $Image) /J /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) copying the image" }

# Split images: copy the sibling install*.swm parts as well
if ($Image -match '\.swm$') {
    Get-ChildItem -LiteralPath (Split-Path -Parent $Image) -Filter 'install*.swm' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force
    }
}

foreach ($f in @('ApplyImage.bat', 'CreatePartitions.txt', 'Install-Drivers.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $Destination -Force
}

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'READ-ME-KO.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'READ-ME-KO.txt') -Destination $Destination -Force
}

if (-not $SkipDrivers) {
    $drv = Join-Path $Workspace 'drivers'
    if (Test-Path -LiteralPath $drv) {
        Write-Host '  copying drivers\ (Surface Laptop 7 package, used only by Install-Drivers.ps1)'
        Copy-Tree -Source $drv -Target (Join-Path $Destination 'drivers')
    }
    else {
        Write-Warning "No drivers folder at $drv (skipped)"
    }
}

$total = (Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host ("Staged {0:N0} MB in {1}" -f ($total / 1MB), $Destination) -ForegroundColor Green

# --------------------------------------------------------------------------
# Optional: write to a USB disk
# --------------------------------------------------------------------------
if ($UsbDisk -ge 0) {
    if (-not (Test-Admin)) { throw 'Writing to a USB disk requires an elevated PowerShell window.' }
    if (-not $Force)       { throw 'Refusing to erase a disk without -Force. Re-run with -Force if you are sure.' }

    $disk = Get-Disk -Number $UsbDisk
    if ($disk.IsSystem -or $disk.IsBoot) { throw "Disk $UsbDisk is the system/boot disk - refusing." }
    if ($disk.BusType -ne 'USB')         { throw "Disk $UsbDisk is not a USB disk (BusType=$($disk.BusType)) - refusing." }

    Write-Host ''
    Write-Host ("WARNING: disk {0} ({1}, {2:N0} GB) will be erased." -f $UsbDisk, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Yellow

    # This clean wipes the whole disk, including a WinPE partition created by
    # Build-WinPE.ps1.  Say so explicitly before doing it.
    $existing = @(Get-Partition -DiskNumber $UsbDisk -ErrorAction SilentlyContinue |
        ForEach-Object {
            $label = try { (Get-Volume -Partition $_ -ErrorAction Stop).FileSystemLabel } catch { '' }
            "{0}: {1:N1} GB {2} {3}" -f $_.PartitionNumber, ($_.Size / 1GB), $_.Type, $label
        })
    if ($existing) {
        Write-Host '  partitions on this disk:' -ForegroundColor Yellow
        $existing | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        if ($existing -match 'WINPE') {
            if (-not $AllowWinPERemoval) {
                throw ("Disk $UsbDisk carries a WinPE partition. Erasing it would leave you without a bootable WinPE stick. To add the install media next to WinPE, create an NTFS partition with New-Partition -UseMaximumSize (see README section 2). Pass -AllowWinPERemoval if you really want to wipe it.")
            }
            Write-Host '  A WinPE partition was found and -AllowWinPERemoval was given: it will be deleted.' -ForegroundColor Red
        }
    }

    $dp = Join-Path $env:TEMP 'winpe-installmedia-diskpart.txt'
    @(
        "select disk $UsbDisk",
        'clean',
        'create partition primary',
        'format fs=ntfs quick label="WININSTALL"',
        'assign',
        'exit'
    ) | Set-Content -LiteralPath $dp -Encoding ASCII

    & diskpart.exe /s $dp
    Remove-Item -LiteralPath $dp -Force
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE)" }

    Start-Sleep -Seconds 2
    $part = Get-Partition -DiskNumber $UsbDisk | Where-Object DriveLetter | Select-Object -First 1
    if (-not $part) { throw 'Could not determine the drive letter of the new partition.' }
    $target = "$($part.DriveLetter):\"

    Write-Host "Copying to $target ..."
    & robocopy.exe $Destination $target /E /J /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

    Write-Host ''
    Write-Host "Install media written to $target" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green

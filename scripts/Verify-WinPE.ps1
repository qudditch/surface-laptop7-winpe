<#
.SYNOPSIS
    Checks that a built WinPE image really contains the Surface input drivers.

.DESCRIPTION
    Mounts boot.wim read-only (from an ISO or a copype work folder) and reports:

      * whether mshidkmdf.inf / .sys are in Windows\INF and System32\drivers
      * which Surface / Qualcomm driver packages made it into the driver store
      * whether the surfacehidmini package is the Windows PE build (the only
        one that brings up the built-in keyboard) or the Windows 11 build

    Use this after Build-WinPE.ps1, or on a WinPE USB/ISO you did not build
    yourself.  Must run elevated.

.PARAMETER Source
    Path to boot.wim, or to a folder that contains sources\boot.wim
    (out\work\winpe_arm64 or a mounted WinPE ISO).

.EXAMPLE
    .\Verify-WinPE.ps1 -Source .\out\work\winpe_arm64
#>
[CmdletBinding()]
param(
    [string] $Source = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out\work\winpe_arm64'),
    [switch] $KeepMount
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell window.'
}

$Dism = Join-Path $env:SystemRoot 'System32\Dism.exe'

$bootWim = if (Test-Path -LiteralPath $Source -PathType Container) {
    Join-Path $Source 'media\sources\boot.wim'
}
else { $Source }
if (-not (Test-Path -LiteralPath $bootWim)) { throw "boot.wim not found: $bootWim" }

$mount = Join-Path $env:TEMP ('winpe-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $mount | Out-Null

Write-Host "Mounting $bootWim (read-only)..."
& $Dism /Mount-Image "/ImageFile:$bootWim" /Index:1 "/MountDir:$mount" /ReadOnly | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Dism /Mount-Image failed ($LASTEXITCODE)" }

try {
    $ok = $true

    Write-Host ''
    Write-Host '== mshidkmdf (HID KMDF framework) ==' -ForegroundColor Cyan
    foreach ($rel in @('Windows\INF\mshidkmdf.inf',
                       'Windows\System32\drivers\mshidkmdf.sys')) {
        $p = Join-Path $mount $rel
        if (Test-Path -LiteralPath $p) { Write-Host "  OK      $rel" -ForegroundColor Green }
        else { Write-Host "  MISSING $rel" -ForegroundColor Red; $ok = $false }
    }

    Write-Host ''
    Write-Host '== Added driver packages (driver store) ==' -ForegroundColor Cyan
    $repo = Join-Path $mount 'Windows\System32\DriverStore\FileRepository'
    $packages = if (Test-Path -LiteralPath $repo) {
        Get-ChildItem -LiteralPath $repo -Directory | Select-Object -ExpandProperty Name
    } else { @() }

    $required = @{
        'surfacehidmini'          = 'built-in keyboard (variant checked below)'
        'surfaceserialhubdriver'  = 'keyboard transport (SSH)'
        'surfaceintegrationdriver'= 'Surface integration'
        'qci2c8380'               = 'I2C controller'
        'qcspi8380'               = 'SPI controller (touchpad)'
        'qcgpi8380'               = 'GPIO interrupt controller (GPI)'
        'qcgpio8380'              = 'GPIO controller'
        'qcpmicgpio8380'          = 'PMIC GPIO'
    }
    foreach ($name in ($required.Keys | Sort-Object)) {
        $hit = $packages | Where-Object { $_ -like "$name*" } | Select-Object -First 1
        if ($hit) { Write-Host ("  OK      {0,-26} {1}" -f $name, $required[$name]) -ForegroundColor Green }
        else      { Write-Host ("  MISSING {0,-26} {1}" -f $name, $required[$name]) -ForegroundColor Red; $ok = $false }
    }

    $hidkmdfPkg = $packages | Where-Object { $_ -like 'mshidkmdf*' } | Select-Object -First 1
    if ($hidkmdfPkg) { Write-Host ("  OK      {0,-26} {1}" -f 'mshidkmdf', 'HID KMDF package') -ForegroundColor Green }
    else { Write-Host ("  INFO    {0,-26} {1}" -f 'mshidkmdf', 'only in Windows\INF (still resolvable)') }

    Write-Host ''
    Write-Host ("  total packages in driver store: {0}" -f @($packages).Count)

    Write-Host ''
    Write-Host '== Surface HID Mini variant (built-in keyboard) ==' -ForegroundColor Cyan
    # The Windows 11 build (driver MSI 'hidmini' folder) and the Windows PE build
    # (Microsoft's SurfaceHidMini_WinPE.zip) use the same INF name, so the driver
    # store folder name cannot tell them apart.  The PE build additionally
    # registers mshidkmdf as an associated service of the device in
    # [SurfaceHidMini.Inst.NT.Services]; the Windows 11 build only does that in
    # the W10 section.  Only the PE build brings up a Surface Laptop 7 keyboard.
    $hidPkgs = @($packages | Where-Object { $_ -like 'surfacehidmini*' })
    if ($hidPkgs.Count -eq 0) {
        Write-Host '  MISSING surfacehidmini package' -ForegroundColor Red
        $ok = $false
    }
    elseif ($hidPkgs.Count -gt 1) {
        Write-Host ("  FAIL    {0} Surface HID Mini packages in the driver store:" -f $hidPkgs.Count) -ForegroundColor Red
        foreach ($p in $hidPkgs) { Write-Host "            $p" }
        Write-Host '          Exactly one package (the Windows PE build) may be present.'
        Write-Host '          With two, PnP picks the newest DriverVer - the Windows build -'
        Write-Host '          and the keyboard stays dead.'
        $ok = $false
    }
    else {
        $hidDir = Join-Path $repo $hidPkgs[0]
        Write-Host "  package $($hidPkgs[0])"
        Get-ChildItem -LiteralPath $hidDir -File | Select-Object -ExpandProperty Name |
            ForEach-Object { Write-Host "    $_" }
        if (-not (Test-Path -LiteralPath (Join-Path $hidDir 'mshidkmdf.sys'))) {
            Write-Host '  NOTE: mshidkmdf.sys is not inside the package folder.'
            Write-Host '        It is resolved from Windows\INF at install time; the check above'
            Write-Host '        already confirms the file is present in the image.'
        }

        $hidInf = Join-Path $hidDir 'SurfaceHidMiniDriver.inf'
        if (-not (Test-Path -LiteralPath $hidInf)) {
            Write-Host '  MISSING SurfaceHidMiniDriver.inf inside the package folder' -ForegroundColor Red
            $ok = $false
        }
        else {
            $infText = Get-Content -LiteralPath $hidInf -Raw
            $ver = if ($infText -match '(?im)^\s*DriverVer\s*=\s*([^\r\n;]+)') { $Matches[1].Trim() } else { 'unknown' }
            Write-Host ("  DriverVer: {0}" -f $ver)

            $ntServices = if ($infText -match '(?ims)^\s*\[SurfaceHidMini\.Inst\.NT\.Services\]\s*(.*?)(?=^\s*\[|\z)') { $Matches[1] } else { '' }
            if ($ntServices -match '(?im)^\s*AddService\s*=\s*mshidkmdf\s*,') {
                Write-Host '  OK      Windows PE build (mshidkmdf is an associated service)' -ForegroundColor Green
            }
            else {
                Write-Host '  FAIL    Windows 11 build - mshidkmdf is not registered in' -ForegroundColor Red
                Write-Host '          [SurfaceHidMini.Inst.NT.Services], so the keyboard will not work'
                Write-Host '          in WinPE.  Extract SurfaceHidMini_WinPE.zip, take the'
                Write-Host '          SurfaceHidMini_WinPE_ARM folder, and rebuild with it.'
                $ok = $false
            }
        }
    }

    Write-Host ''
    if ($ok) { Write-Host 'RESULT: OK - the built-in keyboard/touchpad stack is present.' -ForegroundColor Green }
    else     { Write-Host 'RESULT: problems found - see MISSING lines above.' -ForegroundColor Red }
}
finally {
    if ($KeepMount) { Write-Host "Left mounted at $mount" }
    else {
        & $Dism /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
        Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
    }
}

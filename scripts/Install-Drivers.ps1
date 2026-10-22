<#
.SYNOPSIS
    Installs the Surface Laptop 7 driver package on a running Windows 11 ARM64
    installation (run after OOBE, from the install USB or a copy of it).

.DESCRIPTION
    Adds every INF under drivers\SurfaceLaptop7\SurfaceUpdate to the driver
    store and installs matching devices, then optionally runs the Surface
    MSI (which also installs the services/software components).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File E:\Install-Drivers.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Drivers.ps1 -RunMsi
#>
[CmdletBinding()]
param(
    [string] $DriverRoot = (Join-Path $PSScriptRoot 'drivers\SurfaceLaptop7\SurfaceUpdate'),
    [switch] $RunMsi
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

if (-not (Test-Path -LiteralPath $DriverRoot)) { throw "Driver root not found: $DriverRoot" }

Write-Host "Adding driver packages from $DriverRoot ..."
& pnputil.exe /add-driver (Join-Path $DriverRoot '*.inf') /subdirs /install
if ($LASTEXITCODE -ne 0) {
    Write-Warning "pnputil reported $LASTEXITCODE - some packages may need a reboot or the MSI."
}

if ($RunMsi) {
    $msi = Get-ChildItem -LiteralPath (Split-Path -Parent $DriverRoot) -Filter '*.msi' |
        Select-Object -First 1
    if ($msi) {
        Write-Host "Running $($msi.Name) ..."
        $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
        Write-Host "MSI exit code: $($p.ExitCode)"
    }
    else {
        Write-Warning 'No Surface MSI found next to the SurfaceUpdate folder.'
    }
}

Write-Host ''
Write-Host 'Done. A reboot is recommended.' -ForegroundColor Green

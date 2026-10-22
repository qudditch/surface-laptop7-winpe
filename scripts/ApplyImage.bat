@echo off
rem ===========================================================================
rem  ApplyImage.bat  -  apply an install.esd / install.wim / install*.swm
rem                      to W:\ and make it bootable (WinPE side)
rem
rem  Usage, from the WinPE command prompt:
rem
rem      diskpart /s <media>\CreatePartitions.txt
rem      <media>\ApplyImage.bat
rem
rem  Optional arguments:
rem
rem      ApplyImage.bat [image-file] [image-index] [/drivers] [/copyimage]
rem
rem      image-file   install.esd, install.wim or install.swm.
rem                   Default: auto-detect in the folder of this script.
rem      image-index  WIM/ESD index to apply.  Default: list and ask (1).
rem      /drivers     also inject .\drivers into the offline Windows image
rem                   (slower, only needed if you want the full Surface
rem                   driver package baked in; the 26H2 image already
rem                   carries the basic Surface drivers).
rem      /copyimage   follow the original guide and copy the install image
rem                   to R:\ (needs the 15 GB "Recovery image" partition).
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "MEDIA=%~dp0"
if "%MEDIA:~-1%"=="\" set "MEDIA=%MEDIA:~0,-1%"

set "IMAGE="
set "IDX="
set "DO_DRIVERS=0"
set "DO_COPYIMG=0"

rem --- argument parsing -----------------------------------------------------
:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="/drivers"   ( set "DO_DRIVERS=1" & shift & goto :parse )
if /i "%~1"=="/copyimage" ( set "DO_COPYIMG=1" & shift & goto :parse )
if not defined IMAGE ( set "IMAGE=%~1" & shift & goto :parse )
if not defined IDX   ( set "IDX=%~1"   & shift & goto :parse )
shift
goto :parse
:parsed

if defined IMAGE if not exist "%IMAGE%" (
    echo ERROR: image not found: "%IMAGE%"
    exit /b 1
)

rem --- auto-detect the install image ---------------------------------------
if not defined IMAGE (
    for %%N in (install.esd install.wim install.swm) do (
        if not defined IMAGE if exist "%MEDIA%\%%N" set "IMAGE=%MEDIA%\%%N"
    )
)
if not defined IMAGE (
    echo.
    echo ERROR: no install.esd / install.wim / install.swm found in:
    echo        %MEDIA%
    echo.
    echo Put the image next to this script, or pass it as the first argument.
    exit /b 1
)

rem --- sanity checks --------------------------------------------------------
if not exist W:\ (
    echo.
    echo ERROR: W: does not exist.
    echo Run the partition layout first:
    echo     diskpart /s "%MEDIA%\CreatePartitions.txt"
    exit /b 1
)
if not exist S:\ (
    echo ERROR: S: ^(EFI system partition^) does not exist - run CreatePartitions.txt first.
    exit /b 1
)

echo.
echo Media      : %MEDIA%
echo Image      : "%IMAGE%"
echo Target     : W:\
echo.

if not defined IDX (
    echo Available images in this file:
    echo ---------------------------------------------------------------
    dism /Get-WimInfo /WimFile:"%IMAGE%"
    echo ---------------------------------------------------------------
    set /p "IDX=Image index to apply [1]: "
)

if not defined IDX set "IDX=1"

echo.
echo Applying image index !IDX! ... this takes a while, do not close the window.
dism /Apply-Image /ImageFile:"%IMAGE%" /Index:!IDX! /ApplyDir:W:\
if errorlevel 1 (
    echo.
    echo ERROR: DISM /Apply-Image failed. The image was not applied.
    exit /b 1
)

rem --- optional: inject the full Surface driver package offline -------------
if "%DO_DRIVERS%"=="1" (
    if exist "%MEDIA%\drivers" (
        echo.
        echo Injecting drivers from "%MEDIA%\drivers" into W:\ ...
        dism /Image:W:\ /Add-Driver /Driver:"%MEDIA%\drivers" /Recurse
        if errorlevel 1 echo WARNING: one or more driver packages could not be added.
    ) else (
        echo WARNING: /drivers given but "%MEDIA%\drivers" does not exist.
    )
)

rem --- optional: keep a copy of the image on R: (original guide) ------------
if "%DO_COPYIMG%"=="1" (
    if exist R:\ (
        echo.
        echo Copying the install image to R:\ ...
        copy /y "%IMAGE%" R:\
    ) else (
        echo WARNING: /copyimage given but R: does not exist.
    )
)

rem --- Windows RE ------------------------------------------------------------
set "WINRE=W:\Windows\System32\Recovery\winre.wim"
if exist "%WINRE%" (
    if not exist T:\Recovery\WindowsRE md T:\Recovery\WindowsRE
    copy /y "%WINRE%" T:\Recovery\WindowsRE\winre.wim >nul
    if errorlevel 1 echo WARNING: could not copy winre.wim to T:
) else (
    echo WARNING: "%WINRE%" not found; Recovery Environment will not be registered.
)

rem --- boot files ------------------------------------------------------------
echo.
echo Creating UEFI boot files on S: ...
bcdboot W:\Windows /s S: /f UEFI
if errorlevel 1 (
    echo WARNING: bcdboot reported an error.
)

rem --- register the recovery image -----------------------------------------
if exist W:\Windows\System32\reagentc.exe (
    echo Registering the recovery image ...
    W:\Windows\System32\reagentc.exe /setreimage /path T:\Recovery\WindowsRE /target W:\Windows
    if errorlevel 1 echo WARNING: reagentc could not register the recovery image.
)

echo.
echo ===========================================================================
echo  The image has been applied and the boot files were created.
echo.
echo  Next:
echo    1. Remove the WinPE USB stick (and the install stick if you like).
echo    2. Shut down WinPE:      wpeutil shutdown
echo    3. Power the Surface on normally - Windows Setup / OOBE will start.
echo ===========================================================================
echo.
exit /b 0

<#
.SYNOPSIS
Package drivers into a CAB file for attestation signing.

.DESCRIPTION
This script will create a CAB file that contains one or more drivers for
submission to Microsoft as part of the attestation signing process[1].

To use this script, create a directory structure like this:

  drivers
  ├── driver1
  │   ├── driver1.inf
  │   └── driver1.sys
  └── driver2
      ├── driver2.inf
      └── driver2.sys

Use the top-level directory with the -Source parameter.

NOTE: This script will NOT take care of signing the files within the CAB. If
the files within the CAB should be signed, sign them before running this
script.

References:
[1]
https://docs.microsoft.com/en-us/windows-hardware/drivers/dashboard/attestation-signing-a-kernel-driver-for-public-release

.EXAMPLE
PS> New-CAB.ps1 -Source drivers
Create a CAB package with the contents of the "drivers" directory.

#>

Param (
  [Parameter(Mandatory=$true,Position=0)]
  [ValidateNotNullOrEmpty()]
  [String]
  # Specifies the path to the directory that will be packaged.
  $Source,

  [Parameter(Position=1)]
  [ValidateNotNullOrEmpty()]
  [String]
  # Specifies the output path for the CAB package.
  $Destination = "data1.cab"
)

###############################################################################
# Functions
###############################################################################

<#
.SYNOPSIS
Find the Windows SDK.
#>
function Find-WDK {
  If (-Not([string]::IsNullOrEmpty("${env:WindowsSdkDir}")) -And -Not([string]::IsNullOrEmpty("${env:WindowsSDKVersion}"))) { return }

  If (-Not([string]::IsNullOrEmpty("${env:WindowsSdkDir}"))) {
    $artifact = Get-ChildItem -Path "${env:WindowsSdkDir}/bin/*/x64/*" -Filter "signtool.exe" -ErrorAction SilentlyContinue | Sort-Object | Select-Object -Last 1 | ForEach-Object { $_.FullName }
  } ElseIf (-Not([string]::IsNullOrEmpty("${env:WDKContentRoot}"))) {
    $artifact = Get-ChildItem -Path "${env:WDKContentRoot}/bin/*/x64/*" -Filter "signtool.exe" -ErrorAction SilentlyContinue | Sort-Object | Select-Object -Last 1 | ForEach-Object { $_.FullName }
  } Else {
    $artifact = Get-ChildItem -Path "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/*" -Filter "signtool.exe" -ErrorAction SilentlyContinue | Sort-Object | Select-Object -Last 1 | ForEach-Object { $_.FullName }
  }

  If (-Not([string]::IsNullOrEmpty("$artifact"))) {
    $WindowsSDKVersion = Split-Path -Path "$artifact" -Parent | Split-Path -Parent | Split-Path -Leaf -Resolve
    $WindowsSdkDir = Split-Path -Path "$artifact" -Parent | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
    [System.Environment]::SetEnvironmentVariable("WindowsSDKVersion", $WindowsSDKVersion)
    [System.Environment]::SetEnvironmentVariable("WindowsSdkDir", $WindowsSdkDir)
    Write-Host "Using Windows SDK version ${WindowsSDKVersion} at: ${WindowsSdkDir}" -ForegroundColor Yellow
  } Else {
    throw "Failed to find supported Windows SDK."
  }
}

###############################################################################
# Definitions
###############################################################################

# Stop the script when an unhandled error is encountered
$ErrorActionPreference = "Stop"

# Error codes
$ERR_INVALID_SOURCE = 2
$ERR_BAD_INF        = 3
$ERR_MAKECAB        = 4

# Path for the DDF file used to generate the CAB file
$ddfName = "setup.ddf"

# Header for the DDF file used to generate the CAB file
$ddfContent = @"
.OPTION EXPLICIT
.Set CabinetNameTemplate=data1.cab
.Set CompressionType=MSZIP
.Set Cabinet=on
.Set Compress=on
.Set CabinetFileCountThreshold=0
.Set FolderFileCountThreshold=0
.Set FolderSizeThreshold=0
.Set MaxCabinetSize=0
.Set MaxDiskFileCount=0
.Set MaxDiskSize=0

"@

###############################################################################
# Find Prerequisites
###############################################################################

#
# Check running OS platform
#
$platform = [System.Environment]::OSversion.Platform
If (-Not($platform -in @( "Win32NT" ))) {
  Write-Error "Platform is not supported: ${platform}" -ErrorAction Stop
}

#
# Find inf2cat
#
Find-WDK
$inf2cat = "${env:WindowsSdkDir}/bin/x86/inf2cat.exe"
If (-Not(Test-Path "$inf2cat")) {
  throw "Failed to find inf2cat.exe in Windows SDK."
}

###############################################################################
# Run
###############################################################################

If (-Not(Test-Path "$Source")) {
  Write-Host "ERROR: Path does not exist: ${Source}" -ForegroundColor Red
  Exit $ERR_INVALID_SOURCE
}

If (-Not(Get-ChildItem -Path "$Source" -Directory)) {
  Write-Host "ERROR: Source path does not contain any subdirectories." -ForegroundColor Red
  Exit $ERR_INVALID_SOURCE
}

$SourceSubdirs = Get-ChildItem -Path "$Source" -Directory

$SourceSubdirs | ForEach-Object {
  $Subdir = Split-Path "$_" -Leaf
  If ($Subdir -ieq "disk1") { Continue }

  # Make sure we have exactly one INF file
  $InfFiles = Get-ChildItem "${Source}/${Subdir}/*.inf"
  If ($InfFiles.Count -eq 0) {
    Write-Host "ERROR: Source subdirectory does not contain an INF file: ${Subdir}" -ForegroundColor Red
    Exit $ERR_INVALID_SOURCE
  }
  If ($InfFiles.Count -gt 1) {
    Write-Host "ERROR: Source subdirectory contains multiple INF files: ${Subdir}" -ForegroundColor Red
    Exit $ERR_INVALID_SOURCE
  }
  # Get a CAT file name based upon the INF file name
  $CatName = (Split-Path $InfFiles[0] -Leaf).Replace(".inf", ".cat")

  # Make sure we have at most one CAT file, and that its name matches the INF
  # file name
  $CatFiles = Get-ChildItem "${Source}/${Subdir}/*.cat"
  If ($CatFiles.Count -gt 1) {
    Write-Host "ERROR: Source directory contains multiple CAT files: ${Subdir}" -ForegroundColor Red
    Exit $ERR_INVALID_SOURCE
  }
  If ($CatFiles.Count -ne 0) {
    If ((Split-Path $CatFiles[0] -Leaf) -ine "$CatName") {
      Write-Host "ERROR: Source directory contains CAT file that does not match INF file: ${Subdir}" -ForegroundColor Red
      Write-Host (Split-Path $CatFiles[0] -Leaf)
      Write-Host "$CatName"
      Exit $ERR_INVALID_SOURCE
    }
    # If the CAT file is older than the INF file, remove it
    If (Test-Path $CatFiles[0] -OlderThan $InfFiles[0].LastWriteTime) {
      Remove-Item $CatFiles[0] | Out-Null
    }
  }

  # Create a CAT file from the INF file, if needed
  If (-Not(Test-Path (Join-Path -Path "${Source}/${Subdir}" -ChildPath "$CatName"))) {
    Push-Location "${Source}/${Subdir}"
    & $inf2cat /os:10_x64 /verbose /driver:.
    If ($LASTEXITCODE -ne 0) {
      Write-Host "ERROR: inf2cat exited with code: ${LASTEXITCODE}" -ForegroundColor Red
      Pop-Location
      Exit $ERR_BAD_INF
    }
    Pop-Location
  }

  # Add the files in this subdirectory to the DDF list
  $ddfContent = `
    $ddfContent + `
    [Environment]::NewLine + `
    [Environment]::NewLine + `
    ".Set DestinationDir=${Subdir}" + `
    [Environment]::NewLine
  [String[]] $files = @()
  Get-ChildItem -Path "${Source}/${Subdir}" -Name -File -Recurse | ForEach-Object {
    $files += @( "${Source}/${Subdir}/${_}" )
  }
  $ddfContent = $ddfContent + '"' + ($files -join ('"' + [Environment]::NewLine + '"')) + '"'
}

Push-Location "$Source"
Try {
  Write-Host "Writing cabinet definition at: ${ddfName}..."
  $ddfContent | Out-File -FilePath "$ddfName" -Encoding UTF8

  Write-Host "Creating new cabinet..." -ForegroundColor Yellow
  $proc = Start-Process -FilePath "makecab.exe" `
    -ArgumentList @( `
      "/F", "$ddfName" `
    ) `
    -NoNewWindow -Wait -PassThru
  If (0 -ne $proc.ExitCode) {
    throw "Failed to create new cabinet."
  }

  Pop-Location

  Move-Item "${Source}\disk1\data1.cab" "$Destination"
  Remove-Item "${Source}\disk1" | Out-Null
} Catch {
  Write-Host $_.Exception.ItemName -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Pop-Location
  Exit $ERR_MAKECAB
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green

<#
.SYNOPSIS
Sign a file using a code signing certificate.

.DESCRIPTION
This script will sign a file using a code signing certificate installed on the
system. It will enumerate available code signing certificates, and if more than
one is found, it will prompt for one to be selected unless the serial number or
thumbprint of the desired certificate is specified.

If an intermediate certificate is needed and available, it will be included.

.EXAMPLE
PS> Set-FileSignature.ps1 -Path myfile.sys
Sign the file "myfile.sys"

#>

#
# This script uses signtool instead of Set-AuthenticodeSignature because the
# latter does not currently support SHA2 timestamps.
# See: https://github.com/PowerShell/PowerShell/issues/1752
#

Param (
  [Parameter(Mandatory=$true,Position=0)]
  [ValidateNotNullOrEmpty()]
  [String]
  # Specifies the path to the file that will be signed.
  $Path,

  [String]
  # Specifies the hash algorithm to use. Only SHA256 is supported.
  $HashAlgorithm = "SHA256",

  [String]
  # Specifies the RFC-3161 timestamp server to use.
  $TimestampURL = "http://timestamp.digicert.com",

  [String]
  # Specifies the SHA1 thumbprint of the certificate to use.
  $Thumbprint = $null
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
$ERR_BAD_ARGS       = 1
$ERR_NO_CERT        = 2
$ERR_SIGNING_FAILED = 3

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
# Find signtool
#
Find-WDK
$signtool = "${env:WindowsSdkDir}/bin/${env:WindowsSDKVersion}/x64/signtool.exe"
If (-Not(Test-Path "$signtool")) {
  throw "Failed to find signtool.exe in Windows SDK."
}

###############################################################################
# Run
###############################################################################

# Make sure the specified path is valid
If (-Not(Test-Path "$Path")) {
  Write-Host "ERROR: File does not exist: ${Path}" -ForegroundColor Red
  Exit $ERR_BAD_ARGS
}

# Find all code signing certificates
$Certificates = Get-ChildItem -Path Cert: -CodeSigningCert -Recurse

# Filter certificates against any specified Thumbprint
If (-Not([string]::IsNullOrEmpty("$Thumbprint"))) {
  $Certificates = $Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint }
}

# Make sure we found at least one usable certificate
If ($Certificates.Count -eq 0) {
  Write-Host "ERROR: No code signing certificate was found." -ForegroundColor Red
  Exit $ERR_NO_CERT
}

# If we found more than one certificate, prompt the user to pick one
If ($Certificates.Count -gt 1) {
  Write-Host "Multiple certificates found. Please select one:" -ForegroundColor Yellow
  for ($i = 0; $i -lt $Certificates.Count; $i++) {
    $Certificates[$i] | Add-Member -NotePropertyName Number -NotePropertyValue $i
  }
  $Certificates | Format-List -Property Number, FriendlyName, Subject, NotAfter, SerialNumber, Thumbprint
  $sel = Read-Host -Prompt "Certificate number"
} Else {
  $sel = 0
}
$Certificate = ( $Certificates | Select-Object -Index $sel )

# Where to store the intermediate certificate file, if needed
$IntermediateBundlePath = "intermediate.cer"

Write-Host "Preparing to sign:" -ForegroundColor Yellow
Write-Host "  File: ${Path}" -ForegroundColor Yellow
Write-Host "  Certificate: $(Split-Path -Path $Certificate.PSPath -NoQualifier)" -ForegroundColor Yellow
Write-Host "  Hash Algorithm: ${HashAlgorithm}" -ForegroundColor Yellow
Write-Host "  Timestamp Server: ${TimestampURL}" -ForegroundColor Yellow

# If the certificate is not self-signed, dump the intermediate certificate to a
# file as required for signtool.
If ($Certificate.Issuer -ne $Certificate.Subject) {
  Get-ChildItem -Path Cert: -Recurse | Where-Object { $_.Subject -eq $Certificate.Issuer } | ForEach-Object {
    Export-Certificate -Cert $_ -FilePath "$IntermediateBundlePath" | Out-Null
    $IntCerFlag = "/ac"
    $IntCerArg = "$IntermediateBundlePath"
  }
} Else {
  $IntCerFlag = ""
  $IntCerArg = ""
}

# The default behavior of signtool is to open a user store. If the certificate
# is in a LocalMachine store, we need to add the /sm flag.
$Store = (Split-Path -Path $Certificate.PSPath -NoQualifier).Split("\")[0]
If ($Store -eq "LocalMachine") {
  $StoreFlag = "/sm"
} Else {
  $StoreFlag = ""
}
Try {

#  Set-AuthenticodeSignature `
#    -FilePath "$Path" `
#    -Certificate $Certificate[0] `
#    -HashAlgorithm "$HashAlgorithm" `
#    -TimestampServer "$TimestampURL"

  & "$signtool" sign /v /ph `
    /fd "$HashAlgorithm" `
    $StoreFlag `
    /a /sha1 "$($Certificate.Thumbprint)" `
    $IntCerFlag $IntCerArg `
    /tr "$TimestampURL" /td "$HashAlgorithm" `
    "$Path"

  If (-Not($LASTEXITCODE) -eq 0) { throw "signtool exited with exit code: ${LASTEXITCODE}" }

} Catch {
  Write-Host $_.Exception.ItemName -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host "ERROR: Signing failed." -ForegroundColor Red
  Exit $ERR_SIGNING_FAILED
}

Write-Host "File signed successfully." -ForegroundColor Green

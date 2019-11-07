<#
.SYNOPSIS
Create a self-signed code signing certificate for testing purposes.

.PARAMETER Subject
Specify the subject name for the new certificate.

.EXAMPLE
PS> CreateSelfSignedCert.ps1 -Subject "CN=My Test Code Signing Certificate"

#>

#
# This script uses signtool instead of Set-AuthenticodeSignature because the
# latter does not currently support SHA2 timestamps.
# See: https://github.com/PowerShell/PowerShell/issues/1752
#

Param (
  [Parameter(Position=0)]
  [ValidateNotNullOrEmpty()]
  [String]
  $Subject = "CN=Test Code Signing Certificate"
)


Push-Location -Path "Cert:\CurrentUser\My"
New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject "$Subject" `
  -KeyAlgorithm "RSA" `
  -HashAlgorithm "SHA256" `
  -Confirm
Pop-Location

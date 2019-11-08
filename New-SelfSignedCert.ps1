<#
.SYNOPSIS
Create a self-signed code signing certificate for testing purposes.

.EXAMPLE
PS> New-SelfSignedCert.ps1 -Subject "CN=My Test Code Signing Certificate"

#>

Param (
  [Parameter(Position=0)]
  [ValidateNotNullOrEmpty()]
  [String]
  # Specify the subject name for the new certificate.
  $Subject = "CN=Test Code Signing Certificate"
)

Push-Location -Path "Cert:\CurrentUser\My"
New-SelfSignedCertificate `
  -Type CodeSigningCert `
  -Subject "$Subject" `
  -KeyAlgorithm "RSA" `
  -HashAlgorithm "SHA256"
Pop-Location

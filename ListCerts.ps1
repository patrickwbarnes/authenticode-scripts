<#
.SYNOPSIS
List available code signing certificates.

.EXAMPLE
PS> ListCerts.ps1

#>

$Certificates = Get-ChildItem -Path Cert: -CodeSigningCert -Recurse

$Certificates | ForEach-Object {
  Write-Host "======================================================================"
  $_ | Format-List -Property *
}
Write-Host "======================================================================"

Write-Host "$($Certificates.Count) certificates found."

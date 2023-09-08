param (
    $keyVaultName, 
    $certificateName,
    $intermediateName = "mycompany-local-intermediate"
)

# Stop on error
$ErrorActionPreference = "Stop"


if ($null -eq $keyVaultName) {
    $keyVaultName = read-host -Prompt "Please enter the key vault name" 
}

if ($null -eq $certificateName) {
    $certificateName = read-host -Prompt "Please enter the certicate name for which you want to sign the CSR" 
}

if ($null -eq $intermediateName) {
    $intermediateName = read-host -Prompt "Please enter the name of the intermediate certificate" 
}

try {
    $tempPassword = [guid]::NewGuid().ToString()

    Write-Host -ForegroundColor green "Downloading CSR from Key Vault"
    $csr = az keyvault certificate pending show --vault-name $keyVaultName --name $certificateName --query csr --output tsv

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # break the CSR into 64 character lines and add the header and footer
    Write-Output "-----BEGIN CERTIFICATE REQUEST-----" > "$certificateName.csr"
    Write-Output ($csr -replace "(.{64})", "`$1`n") >> "$certificateName.csr"
    Write-Output "-----END CERTIFICATE REQUEST-----" >> "$certificateName.csr"

    # Download the intermediate certificate
    Write-Host -ForegroundColor green "Downloading intermediate certificate from Key Vault"
    $key=az keyvault secret show --name $intermediateName --vault-name $keyVaultName --query value --output tsv

    if ($LASTEXITCODE -ne 0)  { exit $LASTEXITCODE }

    $pfx=[Convert]::FromBase64String($key)

    #write the pfx to a file
    [System.IO.File]::WriteAllBytes("$intermediateName.pfx", $pfx)

    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, "", [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

    Write-Host -ForegroundColor green "Exporting intermediate certificate to PEM format"
    $certBase64 = [System.Convert]::ToBase64String($cert.RawData);
    # base64 encode the certificate
    Write-Output "-----BEGIN CERTIFICATE-----" > "$intermediateName.crt"
    Write-Output ($certBase64 -replace "(.{64})", "`$1`n") >> "$intermediateName.crt"
    Write-Output "-----END CERTIFICATE-----" >> "$intermediateName.crt"

    Write-Host -ForegroundColor green "Exporting intermediate private key to PEM format"
    $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert);
    if( $null -eq $key ) {
        $key = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPrivateKey($cert);
    }
    if( $null -eq $key ) {
        $key = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($cert);
    }
    if( $null -eq $key ) {
        Write-Error "No private key found. Aborting."
        exit 1
    }

    # ⚠️ Can only export encrypted private keys using X509Certificate2
    # https://github.com/dotnet/runtime/issues/77590#issuecomment-1295100267
    $params=[System.Security.Cryptography.PbeParameters]::new([System.Security.Cryptography.PbeEncryptionAlgorithm]::Aes128Cbc, [System.Security.Cryptography.HashAlgorithmName]::SHA256, 1);
    $key.ExportEncryptedPkcs8PrivateKeyPem($tempPassword, $params) > "$intermediateName.key"
    $tempPassword > "$intermediateName.key.pass"

    Write-Host -ForegroundColor green "Signing CSR with intermediate certificate"
    &"step" certificate sign --profile csr --password-file="$intermediateName.key.pass" --not-after=8760h --bundle "$certificateName.csr" "$intermediateName.crt" "$intermediateName.key" > "$certificateName.crt"

    if ($LASTEXITCODE -ne 0)  { exit $LASTEXITCODE }

    Write-Host -ForegroundColor green "Upload certificate to Key Vault"
    az keyvault certificate pending merge --vault-name $keyVaultName --name $certificateName --file "$certificateName.crt"
}
finally {
    Write-Host -ForegroundColor green "Cleaning up"
    Remove-Item "$certificateName.*"
    Remove-Item "$intermediateName.*"
}
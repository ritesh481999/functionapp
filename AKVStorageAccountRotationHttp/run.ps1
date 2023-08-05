using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

function GenerateSasToken($storageAccountName, $containerName, $validityPeriodDays){
    # Import Azure Storage module
    Import-Module Azure.Storage

    # Define permissions for the SAS token
    $sasTokenPermissions = @{
        "Read" = $true
        "Write" = $true
        "List" = $true
    }

    # Define start and expiry times for the SAS token
    $start = Get-Date
    $expiry = $start.AddDays($validityPeriodDays)

    # Create a new Shared Access Policy
    $sasPolicy = New-AzStorageContainerSASToken -Context $storageAccountName.Context `
        -ExpiryTime $expiry `
        -StartTime $start `
        -FullUri `
        -Name $containerName `
        -Permission $sasTokenPermissions

    return $sasPolicy
}

function AddSecretToKeyVault($keyVaultName, $secretName, $secretValue, $expiryDate, $tags){
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $secretValue -Tag $tags -Expires $expiryDate
}

function RoatateSecret($keyVaultName, $secretName){
    #Retrieve Secret
    $secret = (Get-AzKeyVaultSecret -VaultName $keyVAultName -Name $secretName)
    Write-Host "Secret Retrieved"
    
    #Retrieve Secret Info
    $validityPeriodDays = $secret.Tags["ValidityPeriodDays"]
    $credentialId =  $secret.Tags["CredentialId"]
    $providerAddress = $secret.Tags["ProviderAddress"]
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"

    # Get Credential Id to rotate - alternate credential
    $alternateCredentialId = GetAlternateCredentialId $credentialId
    Write-Host "Alternate credential id: $alternateCredentialId"

    # Regenerate alternate access SAS token
    $storageAccountName = ($providerAddress -split '/')[8]
    $containerName = "your_container_name"  # Replace with your actual container name
    $newSasToken = GenerateSasToken -storageAccountName $storageAccountName -containerName $containerName -validityPeriodDays $validityPeriodDays
    Write-Host "SAS Token regenerated for container '$containerName' with $validityPeriodDays days validity."

    # Add new SAS token to Key Vault
    $newSecretVersionTags = @{
        "ValidityPeriodDays" = $validityPeriodDays
        "CredentialId" = $alternateCredentialId
        "ProviderAddress" = $providerAddress
    }

    $expiryDate = (Get-Date).AddDays([int]$validityPeriodDays).ToUniversalTime()
    $secretValue = ConvertTo-SecureString "$newSasToken" -AsPlainText -Force
    AddSecretToKeyVault $keyVAultName $secretName $secretValue $expiryDate $newSecretVersionTags

    Write-Host "New SAS token added to Key Vault. Secret Name: $secretName"
}

# Rest of the code remains the same...


# Write to the Azure Functions log stream.
Write-Host "HTTP trigger function processed a request."

Try{
    #Validate request paramaters
    $keyVAultName = $Request.Query.KeyVaultName
    $secretName = $Request.Query.SecretName
    if (-not $keyVAultName -or -not $secretName ) {
        $status = [HttpStatusCode]::BadRequest
        $body = "Please pass a KeyVaultName and SecretName on the query string"
        break
    }
    
    Write-Host "Key Vault Name: $keyVAultName"
    Write-Host "Secret Name: $secretName"
    
    #Rotate secret
    Write-Host "Rotation started. Secret Name: $secretName"
    RoatateSecret $keyVAultName $secretName

    $status = [HttpStatusCode]::Ok
    $body = "Secret Rotated Successfully"
     
}
Catch{
    $status = [HttpStatusCode]::InternalServerError
    $body = "Error during secret rotation"
    Write-Error "Secret Rotation Failed: $_.Exception.Message"
}
Finally
{
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $status
        Body = $body
    })
}


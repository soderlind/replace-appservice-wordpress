using './site.bicep'

param siteName = 'example-wordpress-app'
param appServicePlanResourceId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/serverfarms/<plan>'
param registryName = '<registry>'

// Digest printed by the build-image workflow. A floating tag would silently deploy anything.
param imageVersion = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'

param managedIdentity = {
  resourceId: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity>'
  clientId: '<client-id>'
}

// Key Vault references, resolved at runtime by keyVaultReferenceIdentity — not literal values.
param databaseSettings = {
  host: '@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/DBHOST)'
  name: '@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/DBNAME)'
  username: '@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/DBUSER)'
  password: '@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/DBPASSWORD)'
}

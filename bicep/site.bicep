// Trimmed excerpt: the parts of an App Service definition that the image swap actually touches.
// Networking, private endpoints, diagnostics, the plan, the registry, the identity and the vault
// are assumed to exist already — this is not a complete environment.

@description('Name of the App Service site.')
param siteName string

param location string = resourceGroup().location

@description('Resource ID of the Linux App Service plan.')
param appServicePlanResourceId string

@description('Name of the Azure Container Registry holding the image.')
param registryName string

param imageName string = 'wordpress'

@description('Immutable digest (sha256:...) printed by build-image.yml. A plain tag also works.')
param imageVersion string

@description('User-assigned identity with AcrPull on the registry and secret read on the vault.')
param managedIdentity managedIdentityType

@description('Key Vault reference strings for the credentials wp-config.php reads via getenv().')
param databaseSettings databaseSettingsType

type managedIdentityType = {
  resourceId: string
  clientId: string
}

type databaseSettingsType = {
  host: string
  name: string
  username: string

  @secure()
  password: string
}

// Digests are pinned with @, tags with :. Prefer the digest — a tag can be overwritten.
var imageReference = startsWith(imageVersion, 'sha256:')
  ? '${registryName}.azurecr.io/${imageName}@${imageVersion}'
  : '${registryName}.azurecr.io/${imageName}:${imageVersion}'

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: siteName
  location: location
  // Was 'app,linux' under the Microsoft image. Check the what-if shows Modify, not Delete.
  kind: 'app,linux,container'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.resourceId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlanResourceId
    httpsOnly: true
    keyVaultReferenceIdentity: managedIdentity.resourceId
    siteConfig: {
      alwaysOn: true
      linuxFxVersion: 'DOCKER|${imageReference}'
      // Pull with the user-assigned identity rather than registry admin credentials.
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: managedIdentity.clientId
      healthCheckPath: '/'
      httpLoggingEnabled: true
      detailedErrorLoggingEnabled: true
      appSettings: [
        {
          name: 'DATABASE_HOST'
          value: databaseSettings.host
        }
        {
          name: 'DATABASE_NAME'
          value: databaseSettings.name
        }
        {
          name: 'DATABASE_USERNAME'
          value: databaseSettings.username
        }
        {
          name: 'DATABASE_PASSWORD'
          value: databaseSettings.password
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${registryName}.azurecr.io'
        }
        {
          // Mounts the persistent Azure Files share at /home, where the WordPress install lives.
          // Without this the image serves an empty document root.
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'true'
        }
        {
          // Adds /home/site/ini so per-site PHP overrides can be dropped on the share.
          name: 'PHP_INI_SCAN_DIR'
          value: '/usr/local/etc/php/conf.d:/home/site/ini'
        }
        {
          name: 'WEBSITES_CONTAINER_START_TIME_LIMIT'
          value: '600'
        }
        {
          name: 'WP_MEMORY_LIMIT'
          value: '512M'
        }
        {
          name: 'WP_MAX_MEMORY_LIMIT'
          value: '512M'
        }
      ]
    }
  }
}

output defaultHostname string = site.properties.defaultHostName

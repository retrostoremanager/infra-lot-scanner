@description('Environment name: dev or prod')
@allowed(['dev', 'prod'])
param environment string = 'dev'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Application name prefix')
param appName string = 'lot-scanner'

@description('Name prefix of the existing gamedb deployment (infra-gamedb) whose Postgres server hosts the lotscanner database, and whose Function App serves the catalog API this app calls.')
param gamedbAppName string = 'gamedb'

@description('The lotscanner database name, must match infra-gamedb main.bicep\'s lotscannerDatabaseName output for the same environment.')
param lotscannerDatabaseName string = 'lotscanner-${environment}'

@description('Anthropic (Claude) API key for AI item identification.')
@secure()
param anthropicApiKey string

@description('Shared JWT signing secret -- must match fn-mystore\'s JwtAuthentication__SecretKey so this app accepts the same employee tokens.')
@secure()
param jwtAuthenticationSecretKey string

@description('Object ID of the GitHub Actions service principal for Key Vault secret sync')
param ghActionsServicePrincipalObjectId string = ''

@description('CORS origins for the Function App')
param additionalCorsOrigins array = []

@description('Tags to apply to resources')
param tags object = {
  Environment: environment
  Project: appName
  ManagedBy: 'Bicep'
}

var keyVaultName = '${appName}-kv-${environment}'
var functionAppName = '${appName}-func-${environment}'
var storageAccountName = replace('${appName}stg${environment}', '-', '')
var storageAccountNameLower = toLower(storageAccountName)
var gamedbPostgresServerFqdn = '${gamedbAppName}-postgres-${environment}.postgres.database.azure.com'
var gamedbFunctionAppUrl = 'https://${gamedbAppName}-func-${environment}.azurewebsites.net/api'

// Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableRbacAuthorization: true
  }
}

// Storage Account for Function App (also backs the lot-scan-photos blob container and
// the lot-scan-identify queue -- see fn-lot-scanner's PhotoStorageService/Program.cs)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountNameLower
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// Anthropic/JWT secrets provisioned directly from secure params (simple values, no
// interpolation needed). The lotscanner Postgres connection string is NOT provisioned
// here -- it requires the admin password that infra-gamedb's deploy already holds as a
// GitHub secret, so it's constructed and written to this Key Vault by this repo's own
// deploy workflow instead (same approach infra-gamedb uses for GameDbConnectionString).
resource anthropicApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AnthropicApiKey'
  properties: {
    value: anthropicApiKey
  }
}

resource jwtAuthenticationSecretKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'JwtAuthenticationSecretKey'
  properties: {
    value: jwtAuthenticationSecretKey
  }
}

// Function App -- Flex Consumption (Linux), provisioned OUT-OF-BAND via the Azure CLI,
// NOT by this Bicep template. Migrated 2026-11-24 off classic Windows Consumption (Y1)
// after that host runtime proved unable to reliably specialize .NET 9/10
// isolated-worker apps on this subscription's scale unit (identical
// FileNotFoundException crash on mystore-func-prod the same day, confirmed via
// extensive live debugging to be a platform/host issue, not an app-level one -- see
// infra-mystore's main.bicep history for the full investigation). This supersedes the
// earlier (2026-10-08/09) Linux Consumption attempt noted below, which failed for
// different reasons (every request 503'd despite "Running" state) -- Flex Consumption
// is a separate, newer product line from classic Linux Consumption and is not subject
// to that same failure.
//
// Flex Consumption's Bicep resource shape is comparatively immature and risks a
// repeat outage if hand-rolled and subtly wrong, so the app and its Y1-era serverfarm
// are intentionally NOT modeled as managed resources here anymore. To recreate it,
// use recreate-flex-with-core-tools.yml (az functionapp create
// --flexconsumption-location, then deploy code with `func azure functionapp publish`
// -- classic zip-deploy methods including az functionapp deployment source
// config-zip, az functionapp deploy, and Azure/functions-action all silently no-op
// against Flex Consumption).
resource functionApp 'Microsoft.Web/sites@2023-01-01' existing = {
  name: functionAppName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccountNameLower};EndpointSuffix=${az.environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

var functionAppSettings = {
  AzureWebJobsStorage: storageConnectionString
  // Flex Consumption rejects WEBSITE_CONTENTAZUREFILECONNECTIONSTRING,
  // WEBSITE_CONTENTSHARE, FUNCTIONS_EXTENSION_VERSION, and FUNCTIONS_WORKER_RUNTIME as
  // app settings outright ("invalid for Flex Consumption sites") -- those classic/
  // Windows Consumption settings are no longer here for that reason. Deployment
  // package location, runtime, and worker type are instead part of the Function App's
  // functionAppConfig, set when the app is created (see
  // recreate-flex-with-core-tools.yml).
  ASPNETCORE_ENVIRONMENT: environment
  ConnectionStrings__lotscanner: '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}.vault.azure.net/secrets/LotScannerDbConnectionString/)'
  // Set directly rather than as a Key Vault reference -- isolated-worker Function Apps
  // don't reliably resolve @Microsoft.KeyVault(...) app settings at runtime (same
  // gotcha infra-gamedb/infra-mystore already hit for their connection strings; this
  // avoids it for these two instead of adding more post-deploy sync-script steps). The
  // values still live in Key Vault too (see the secret resources above) for visibility.
  Anthropic__ApiKey: anthropicApiKey
  JwtAuthentication__SecretKey: jwtAuthenticationSecretKey
  ApiGamedb__BaseUrl: gamedbFunctionAppUrl
  Blob__ConnectionString: storageConnectionString
  Blob__ContainerName: 'lot-scan-photos'
}

module functionAppSettingsModule 'modules/function-app-settings.bicep' = {
  name: '${functionAppName}-appsettings'
  params: {
    functionAppName: functionApp.name
    appSettings: functionAppSettings
    currentAppSettings: list('${functionApp.id}/config/appsettings', '2022-09-01').properties
  }
}

// Grant Function App access to Key Vault
resource functionAppKeyVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant GitHub Actions access to Key Vault
resource ghActionsKeyVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ghActionsServicePrincipalObjectId)) {
  name: guid(keyVault.id, ghActionsServicePrincipalObjectId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: ghActionsServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultName string = keyVault.name
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.name}.azurewebsites.net'
output storageAccountName string = storageAccountNameLower
output gamedbPostgresServerFqdn string = gamedbPostgresServerFqdn
output lotscannerDatabaseName string = lotscannerDatabaseName

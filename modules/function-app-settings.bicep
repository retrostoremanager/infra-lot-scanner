@description('Name of the Function App')
param functionAppName string

@description('App settings to set/override')
param appSettings object

@description('Current app settings (empty on first deploy)')
param currentAppSettings object

resource functionApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: functionAppName
}

resource appSettingsConfig 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(currentAppSettings, appSettings)
}

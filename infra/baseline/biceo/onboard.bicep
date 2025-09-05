targetScope = 'resourceGroup'

@description('Base name prefix used for resource names (lowercase letters, numbers, hyphens).')
@minLength(3)
@maxLength(40)
param namePrefix string

@description('Deployment location. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Environment tag (dev/test/prod).')
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string = 'dev'

@description('Standard tags applied to all resources.')
param tags object = {
  owner: 'someone@contoso.gov'
  costCenter: '0000'
  env: environment
}

@description('Address space for the VNet.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Workload subnet CIDR.')
param workloadSubnetPrefix string = '10.10.1.0/24'

@description('Management subnet CIDR.')
param managementSubnetPrefix string = '10.10.2.0/24'

@description('Feature flags to toggle optional resources.')
param features object = {
  vnet: true
  storage: true
  keyVault: true
  logAnalytics: true
  appInsights: true
}

var normalizedPrefix = toLower(replace(namePrefix, ' ', '-'))

// ---------- Network ----------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (features.vnet) {
  name: '${normalizedPrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: workloadSubnetPrefix
        }
      }
      {
        name: 'snet-management'
        properties: {
          addressPrefix: managementSubnetPrefix
        }
      }
    ]
  }
}

// ---------- Storage ----------
var storageName = toLower('st${uniqueString(resourceGroup().id, normalizedPrefix)}')

resource st 'Microsoft.Storage/storageAccounts@2023-01-01' = if (features.storage) {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    // Public network access can be disabled later if you add private endpoints.
    publicNetworkAccess: 'Enabled'
  }
}

// ---------- Log Analytics ----------
resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (features.logAnalytics) {
  name: '${normalizedPrefix}-law'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    sku: {
      name: 'PerGB2018'
    }
  }
}

// ---------- Application Insights (connected to LAW) ----------
resource appi 'Microsoft.Insights/components@2020-02-02' = if (features.appInsights) {
  name: '${normalizedPrefix}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    WorkspaceResourceId: features.logAnalytics ? law.id : null
  }
  dependsOn: [
    law
  ]
}

// ---------- Key Vault (RBAC) ----------
// Ensure KV name is <= 24 chars: 'kv' (2) + 8 from prefix (no hyphens) + 13 from uniqueString = 23
var kvName = toLower('kv${take(replace(normalizedPrefix, '-', ''), 8)}${uniqueString(resourceGroup().id, normalizedPrefix)}')

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = if (features.keyVault) {
  name: kvName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    // Prefer Azure RBAC over access policies
    enableRbacAuthorization: true
    sku: {
      name: 'standard'
      family: 'A'
    }
    // Keep public access enabled unless you add private endpoints/firewall rules
    // to avoid provisioning failures during initial onboarding.
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 90
  }
}

// ---------- Outputs ----------
output vnetId string = features.vnet ? vnet.id : ''
output workloadSubnetId string = features.vnet ? resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-workload') : ''
output managementSubnetId string = features.vnet ? resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-management') : ''
output storageAccountId string = features.storage ? st.id : ''
output keyVaultId string = features.keyVault ? kv.id : ''
output logAnalyticsId string = features.logAnalytics ? law.id : ''
output appInsightsId string = features.appInsights ? appi.id : ''

@description('The Azure region into which the resources should be deployed.')
param location string = resourceGroup().location
param utcValue string = utcNow()

///////////////////     Identity and authorization for deployment scripts   //////////////////////////////

param privateEndpointApproverRoleName string = 'Private Endpoint Approver - Custom Role'

resource privateEndpointApproverRoleDef 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(privateEndpointApproverRoleName)
  properties: {
    roleName: privateEndpointApproverRoleName
    description: 'Approves private endpoints at the resource group level for automated deployments'
    type: 'customRole'
    permissions: [
      {
        actions: [
          'Microsoft.EventHub/namespaces/privateEndpointConnections/write'
          'Microsoft.Storage/storageAccounts/privateEndpointConnections/write'
          'Microsoft.Devices/IotHubs/privateEndpointConnections/write'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

resource deploymentScriptUMI 'Microsoft.ManagedIdentity/userAssignedIdentities@2022-01-31-preview' = {
  name: 'deploymentScripts-umi'
  location: location
}

var readerRoleID = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerRole 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: resourceGroup()
  name: readerRoleID
}

resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid('${deploymentScriptUMI.id}-${readerRole.id}')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: readerRole.id
    principalId: deploymentScriptUMI.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource privateEndpointApproverAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid('${deploymentScriptUMI.id}-${privateEndpointApproverRoleDef.id}')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: privateEndpointApproverRoleDef.id
    principalId: deploymentScriptUMI.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

///////////////////      STORAGE ACCOUNT -- target resource    //////////////////////////////
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: substring('mpeapprsa${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: false
  }
}

///////////////////      EVENT HUBS NAMESPACE -- target resource      //////////////////////////////
resource eventHubNamespace 'Microsoft.EventHub/namespaces@2022-10-01-preview' = {
  name: substring('mpe-appr-ehn-${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
  }
}

///////////////////      IoT HUB -- target resource    //////////////////////////////
resource newIotHub 'Microsoft.Devices/IotHubs@2022-04-30-preview' = {
  name: substring('mpe-appr-iot-${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  sku: {
    capacity: 1
    name: 'S1'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
  }
}

///////////////////      STREAM ANALYTICS CLUSTER - PaaS resource   //////////////////////////////
resource streamAnalyticsCluster 'Microsoft.StreamAnalytics/clusters@2020-03-01' = {
  name: substring('mpe-appr-sa-${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  sku: {
    capacity: 120
    name: 'DefaultV2'
  }
  properties: null
}

///////////////////     STREAM ANALYTICS MPEs    //////////////////////////////
resource streamAnalyticsToStorageMPE 'Microsoft.StreamAnalytics/clusters/privateEndpoints@2020-03-01' = {
  name: 'sa-to-sr-mpe'
  parent: streamAnalyticsCluster
  properties: {
    manualPrivateLinkServiceConnections: [
      {
        properties: {
          groupIds: [
            'blob'
          ]
          privateLinkServiceConnectionState: {}
          privateLinkServiceId: storageAccount.id
        }
      }
    ]
  }
}

resource streamAnalyticsToEventHubsNamespaceMPE 'Microsoft.StreamAnalytics/clusters/privateEndpoints@2020-03-01' = {
  name: 'sa-to-ehn-mpe'
  parent: streamAnalyticsCluster
  properties: {
    manualPrivateLinkServiceConnections: [
      {
        properties: {
          groupIds: [
            'namespace'
          ]
          privateLinkServiceConnectionState: {}
          privateLinkServiceId: eventHubNamespace.id
        }
      }
    ]
  }
}

resource streamAnalyticsToIotHubMPE 'Microsoft.StreamAnalytics/clusters/privateEndpoints@2020-03-01' = {
  name: 'sa-to-iot-mpe'
  parent: streamAnalyticsCluster
  properties: {
    manualPrivateLinkServiceConnections: [
      {
        properties: {
          groupIds: [
            'iotHub'
          ]
          privateLinkServiceConnectionState: {}
          privateLinkServiceId: newIotHub.id
        }
      }
    ]
  }
}

///////////////////     Decoy VNET and Private Endpoint   //////////////////////////////
//The purpose of this decoy vnet and private endpoint is to prove that the
//approval script approves the private endpoint connections that correspond with the MPE and leaves
//unrelated private endpoint connections alone.
resource decoyVirtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'decoy-vnet-mpe-approver'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'decoy-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

resource decoyPrivateEndpointToStrorageAccount 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'decoy-pe-vnet-to-sa'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'decoy-pec-vnet-to-sa'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
    subnet: {
      id: decoyVirtualNetwork.properties.subnets[0].id
    }
  }
}

///////////////////    Start of MPE Approval      //////////////////////////////

//The mpesToAutoApprove object contains the minimum information needed for the 
//PowerShell script to identify the MPEs, identify the corresponding PEC, subsequently approve the PECs.
var mpesToAutoApproveASA = [
  {
    resourceId: streamAnalyticsToIotHubMPE.id
    name: streamAnalyticsToIotHubMPE.name
    privateLinkResourceId: newIotHub.id
  }
  {
    resourceId: streamAnalyticsToStorageMPE.id
    name: streamAnalyticsToStorageMPE.name
    privateLinkResourceId: storageAccount.id
  }
  {
    resourceId: streamAnalyticsToEventHubsNamespaceMPE.id
    name: streamAnalyticsToEventHubsNamespaceMPE.name
    privateLinkResourceId: eventHubNamespace.id
  }
]

//this output is only for debugging purposes.
output mpesToAutoApproveASA array = mpesToAutoApproveASA

//need to convert the mpesToAutoApprove object to base64 because ultimately bicep compiles into JSON
//and JSON within JSON is always a challenge.
var mpesToApproveAsBase64ASA = base64(string(mpesToAutoApproveASA))

resource approveMPEDeploymentScriptASA 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  dependsOn: [
    readerRoleAssignment
    privateEndpointApproverAssignment
  ]
  name: 'approve_managed_private_endpoints_asa'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentScriptUMI.id}': {}
    }
  }
  properties: {
    forceUpdateTag: utcValue
    azPowerShellVersion: '8.0'
    timeout: 'PT10M'
    arguments: '-mpesToApproveAsBase64 ${mpesToApproveAsBase64ASA}'
    scriptContent: loadTextContent('approveMPE.ps1')
    cleanupPreference: 'OnExpiration'
    retentionInterval: 'PT23H'
  }
}

///////////////////      Datafactory + MPEs        //////////////////////////////
resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: substring('mpe-appr-adf-${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  properties: {
    publicNetworkAccess: 'Disabled'
  }
}

resource managedVirtualNetwork 'Microsoft.DataFactory/factories/managedVirtualNetworks@2018-06-01' = {
  name: 'default'
  parent: dataFactory
  properties: {}
}

resource storageToADFMPE 'Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01' = {
  name: 'adf-to-sr-mpe'
  parent: managedVirtualNetwork
  properties: {
    fqdns: ['${storageAccount.name}.dfs.core.windows.net']
    groupId: 'dfs'
    privateLinkResourceId: storageAccount.id
  }
}

resource eventHubToADFMPE 'Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01' = {
  name: 'adf-to-eh-mpe'
  parent: managedVirtualNetwork
  properties: {
    fqdns: ['${eventHubNamespace.name}.servicebus.windows.net']
    groupId: 'namespace'
    privateLinkResourceId: eventHubNamespace.id
  }
}

///////////////////       MPE Approval      //////////////////////////////

//The mpesToAutoApprove object contains the minimum information needed for the 
//PowerShell script to identify the MPEs, identify the corresponding PEC, subsequently approve the PECs.
var mpesToAutoApproveADF = [
  {
    resourceId: storageToADFMPE.id
    name: '${dataFactory.name}.${storageToADFMPE.name}'
    privateLinkResourceId: storageAccount.id
  }
  {
    resourceId: eventHubToADFMPE.id
    name: '${dataFactory.name}.${eventHubToADFMPE.name}'
    privateLinkResourceId: eventHubNamespace.id
  }
]

//this output is here for debugging purposes.
output mpesToAutoApproveADF array = mpesToAutoApproveADF

//need to convert the mpesToAutoApprove object to base64 because ultimately bicep compiles into JSON
//and JSON within JSON is always a challenge.
var mpesToApproveAsBase64ADF = base64(string(mpesToAutoApproveADF))

resource approveMPEDeploymentScriptADF 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  dependsOn: [
    readerRoleAssignment
    privateEndpointApproverAssignment
  ]
  name: 'approve_managed_private_endpoints_adf'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentScriptUMI.id}': {}
    }
  }
  properties: {
    forceUpdateTag: utcValue
    azPowerShellVersion: '8.0'
    timeout: 'PT10M'
    arguments: '-mpesToApproveAsBase64 ${mpesToApproveAsBase64ADF}'
    scriptContent: loadTextContent('approveMPE.ps1')
    cleanupPreference: 'OnExpiration'
    retentionInterval: 'PT23H'
  }
}

///////////////////      ADX + MPEs        //////////////////////////////
resource kustoCluster 'Microsoft.Kusto/clusters@2023-05-02' = {
  name: substring('mpe-appr-adx-${uniqueString(resourceGroup().id)}', 0, 20)
  location: location
  sku: {
    name: 'Dev(No SLA)_Standard_E2a_v4'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    publicNetworkAccess: 'Disabled'

    enableStreamingIngest: false
    enablePurge: false
    enableDiskEncryption: false
    enableDoubleEncryption: false

    enableAutoStop: false
  }
}

var MPEs = [
  { name: 'adx-to-sr-mpe', groupId: 'dfs', privateLinkResourceId: storageAccount.id }
  { name: 'adx-to-eh-mpe', groupId: 'namespace', privateLinkResourceId: eventHubNamespace.id }
]

@batchSize(1)
resource managedPrivateEndpoints 'Microsoft.Kusto/clusters/managedPrivateEndpoints@2022-12-29' = [
  for mpe in MPEs: {
    name: mpe.Name
    parent: kustoCluster
    properties: {
      groupId: mpe.groupId
      privateLinkResourceId: mpe.privateLinkResourceId
    }
  }
]

///////////////////       MPE Approval      //////////////////////////////
var mpesToAutoApproveADX = [
  {
    resourceId: managedPrivateEndpoints[0].id
    name: managedPrivateEndpoints[0].name
    privateLinkResourceId: managedPrivateEndpoints[0].properties.privateLinkResourceId
  }
  {
    resourceId: managedPrivateEndpoints[1].id
    name: managedPrivateEndpoints[1].name
    privateLinkResourceId: managedPrivateEndpoints[1].properties.privateLinkResourceId
  }
]

output mpesToAutoApproveADX array = mpesToAutoApproveADX

var mpesToApproveAsBase64ADX = base64(string(mpesToAutoApproveADX))

resource approveMPEDeploymentScriptADX 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  dependsOn: [
    readerRoleAssignment
    privateEndpointApproverAssignment
  ]
  name: 'approve_managed_private_endpoints_adx'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentScriptUMI.id}': {}
    }
  }
  properties: {
    forceUpdateTag: utcValue
    azPowerShellVersion: '8.0'
    timeout: 'PT10M'
    arguments: '-mpesToApproveAsBase64 ${mpesToApproveAsBase64ADX}'
    scriptContent: loadTextContent('approveMPE.ps1')
    cleanupPreference: 'OnExpiration'
    retentionInterval: 'PT23H'
  }
}

@description('Location for all resources. Leave the default value.')
param location string = resourceGroup().location

// CMD parameters
@description('Short name for location')
param shortLocation string

@description('Object ID for your Azure AD user identity (see the README.md file in the Azure Quickstart guide for instructions on how to get your Azure AD user object ID).')
param azureADObjectID string

@description('Name of the project')
@maxLength(5)
param projectName string

// Specify a parameter with certain allowed values
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string

@description('''
Name of the Azure Data Lake Storage Gen2 storage account. Storage account name requirements:
- Storage account names must be between 3 and 24 characters in length and may contain numbers and lowercase letters only.
- Your storage account name must be unique within Azure. No two storage accounts can have the same name.
''')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'sa${projectName}${environment}${uniqueString(resourceGroup().id)}'

@description('Name of the Azure Data Factory instance.')
param azureDataFactoryName string = 'adf-${projectName}-${shortLocation}-${environment}'



param databricksWorkspaceName string = 'dbs_${projectName}'

var storageAccountSku = (environment == 'prod') ? 'Standard_GRS' : 'Standard_LRS'

var managedResourceGroupName = 'databricks-rg-${databricksWorkspaceName}-${uniqueString(databricksWorkspaceName, resourceGroup().id)}'

var databricksSku = 'standard' //(environment == 'prod') ? 'premium' : 'trial'

// Values for Azure KeyVault
var akvRoleIdMapping = {
  'Key Vault Secrets User': '4633458b-17de-408a-b874-0445c86b69e6'
}

@description('Do you want to deploy a new Azure Key Vault instance (true or false)? Leave default name if you choose false.')
param deployAzureKeyVault bool = true

@description('''
Name of the Azure Key Vault. Key Vault name requirements:
- Key vault names must be between 3 and 24 characters in length and may contain numbers, letters, and dashes only.
''')
@minLength(3)
@maxLength(24)
param azureKeyVaultName string = 'kv-${projectName}-${shortLocation}-${environment}-001'

var akvRoleName = 'Key Vault Secrets User'

// Defining roles for RBAC security

@description('This is the built-in Storage Blob Data Contributor role')
resource sbdcRoleDefinitionResourceId 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

@description('This is the built-in Databricks Contributor role')
resource dbsRoleDefinitionResourceId 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
}


// Storage account

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageAccountSku
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    isHnsEnabled: false
  }
}


@description('Assigns the user to Storage Blob Data Contributor Role')
resource userRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, azureADObjectID, sbdcRoleDefinitionResourceId.id)
  properties: {
    roleDefinitionId: sbdcRoleDefinitionResourceId.id
    principalId: azureADObjectID
  }
}



resource databricksWorkspace 'Microsoft.Databricks/workspaces@2018-04-01' = {
  name: databricksWorkspaceName
  location: location
  sku: {
    name: databricksSku
  }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)
    authorizations: []
  }

}


// Azure Data Factory

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: azureDataFactoryName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
}

@description('Assigns the ADF Managed Identity to Storage Blob Data Contributor Role')
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, dataFactory.id, sbdcRoleDefinitionResourceId.id)
  properties: {
    roleDefinitionId: sbdcRoleDefinitionResourceId.id
    principalId: dataFactory.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Assigns the user to Databricks workspace Contributor Role')
resource userDbsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: databricksWorkspace
  name: guid(databricksWorkspace.id, azureADObjectID, dbsRoleDefinitionResourceId.id)
  properties: {
    roleDefinitionId: dbsRoleDefinitionResourceId.id
    principalId: azureADObjectID
  }
}

@description('Assigns the ADF Managed Identity to Databricks workspace Contributor Role')
resource adfDbsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: databricksWorkspace
  name: guid(databricksWorkspace.id, dataFactory.id, dbsRoleDefinitionResourceId.id)
  properties: {
    roleDefinitionId: dbsRoleDefinitionResourceId.id
    principalId: dataFactory.identity.principalId
    principalType: 'ServicePrincipal'
  }
}



// Azure KeyVault

resource akv 'Microsoft.KeyVault/vaults@2022-07-01' = if (deployAzureKeyVault) {
  name: azureKeyVaultName
  location: location
  properties: {
    enableRbacAuthorization: true
    tenantId: subscription().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource userAkvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAzureKeyVault) {
  name: guid(akvRoleIdMapping[akvRoleName],azureADObjectID,akv.id)
  scope: akv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', akvRoleIdMapping[akvRoleName])
    principalId: azureADObjectID
  }
}

resource spAkvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAzureKeyVault) {
  name: guid(akvRoleIdMapping[akvRoleName],dataFactory.id,akv.id)
  scope: akv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', akvRoleIdMapping[akvRoleName])
    principalId: dataFactory.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource azureKeyVaultLinkedService 'Microsoft.DataFactory/factories/linkedservices@2018-06-01' = if(deployAzureKeyVault){
  parent: dataFactory
  name: '${azureKeyVaultName}-linkedService'
  properties: {
    type: 'AzureKeyVault'
    typeProperties: {
      baseUrl: akv.properties.vaultUri
    }
  }
}

@description('Name of the Azure AI Services resource (shows up natively in Azure AI Foundry)')
@minLength(2)
@maxLength(64)
param aiServicesName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('Model name to deploy. Must be a model supported in the target region — run deploy.ps1 to see the live list.')
param modelName string

@description('Version of the model to deploy. Leave empty to use the latest default version.')
param modelVersion string = ''

@description('Model format returned by az cognitiveservices model list (e.g. OpenAI, AzureAI, Azure).')
param modelFormat string = 'OpenAI'

@description('Deployment capacity in thousands of tokens per minute.')
param deploymentCapacity int = 10

@description('Deployment SKU name. Use GlobalStandard for newer models (gpt-4o, gpt-5, o3). Use Standard for older models.')
param modelSkuName string = 'GlobalStandard'

// Resolve the effective model version (empty string = let Azure pick the default)
var effectiveModelVersion = empty(modelVersion) ? null : modelVersion

// Azure AI Services: shows up natively in Azure AI Foundry and is also
// OpenAI-SDK-compatible (supports both .services.ai.azure.com and .openai.azure.com endpoints).
resource aiServices 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: aiServicesName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    customSubDomainName: aiServicesName
    disableLocalAuth: false
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: modelName
  sku: {
    name: modelSkuName
    capacity: deploymentCapacity
  }
  properties: {
    model: {
      format: modelFormat
      name: modelName
      version: effectiveModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

output aiServicesResourceId string = aiServices.id
// Primary AI Services endpoint (used by Foundry and the Azure AI SDK)
output aiServicesEndpoint string = aiServices.properties.endpoint
// OpenAI-SDK-compatible endpoint (for VS Code, GitHub Copilot, legacy tools)
output openAICompatibleEndpoint string = 'https://${aiServicesName}.openai.azure.com/'
output modelDeploymentName string = modelDeployment.name
output modelNameUsed string = modelName

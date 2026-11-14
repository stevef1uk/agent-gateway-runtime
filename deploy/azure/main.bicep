@description('Short prefix for resources in this dedicated resource group.')
param namePrefix string

@description('Azure region.')
param location string

@description('Azure subscription containing this deployment.')
param subscriptionId string

@description('Dedicated resource group for wizard-created Emotion apps.')
param emotionResourceGroupName string

@description('Existing user-assigned managed identity name in this resource group.')
param runtimeIdentityName string

@description('Client ID of the existing user-assigned managed identity.')
param runtimeIdentityClientId string

@description('Existing RBAC-enabled Key Vault URI.')
param keyVaultUri string

@description('Key Vault secret names mapped to runtime secret references.')
param secretNames object

@description('PostgreSQL namespace shared by all services.')
param postgresNamespace string

@description('OIDC issuer URL.')
param oidcIssuerUrl string

@description('OIDC client/application ID.')
param oidcClientId string

@description('Comma-separated web administrator email allowlist.')
param webAdminEmails string

@description('Immutable, prebuilt service image references.')
param images object

@description('Immutable, prebuilt Emotion bridge image.')
param emotionImage string

@description('Optional private registry credentials configuration.')
param privateRegistry object = {
  server: ''
  username: ''
  passwordSecretName: 'registry-password'
}

var managedTags = {
  application: 'agent-gateway'
  managedBy: 'agent-gateway-runtime-azure'
  deployment: namePrefix
}

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: runtimeIdentityName
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-aca'
  location: location
  tags: managedTags
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
  }
}

var commonEnv = [
  {
    name: 'PERSISTENCE'
    value: 'postgres'
  }
  {
    name: 'POSTGRES_NAMESPACE'
    value: postgresNamespace
  }
  {
    name: 'JWT_ISSUER'
    value: 'agent-gateway'
  }
  {
    name: 'DATABASE_URL'
    secretRef: 'database-url'
  }
  {
    name: 'JWT_SECRET'
    secretRef: 'jwt-secret'
  }
  {
    name: 'LICENCE_TOKEN'
    secretRef: 'licence-token'
  }
  {
    name: 'AUTHZ_URL'
    value: 'http://${namePrefix}-authz'
  }
]

var services = [
  {
    name: 'authz'
    image: images.authz
    port: 8081
    external: false
    minReplicas: 1
    maxReplicas: 2
    env: concat(commonEnv, [
      {
        name: 'AUTHZ_ADDR'
        value: ':8081'
      }
      {
        name: 'OIDC_ISSUER_URL'
        value: oidcIssuerUrl
      }
      {
        name: 'OIDC_CLIENT_ID'
        value: oidcClientId
      }
      {
        name: 'MANAGED_REGO_ENABLED'
        value: '1'
      }
      {
        name: 'GATEWAY_ADMIN_TOKEN'
        secretRef: 'gateway-admin-token'
      }
    ])
  }
  {
    name: 'gateway'
    image: images.gateway
    port: 8080
    external: true
    minReplicas: 0
    maxReplicas: 2
    env: concat(commonEnv, [
      {
        name: 'GATEWAY_ADDR'
        value: ':8080'
      }
      {
        name: 'GATEWAY_ADMIN_TOKEN'
        secretRef: 'gateway-admin-token'
      }
      {
        name: 'MANAGED_UPSTREAMS_ENABLED'
        value: '1'
      }
      {
        name: 'UPSTREAM_STRIP_CREDENTIALS'
        value: '1'
      }
    ])
  }
  {
    name: 'tokensvc'
    image: images.tokensvc
    port: 8082
    external: true
    minReplicas: 0
    maxReplicas: 2
    env: concat(commonEnv, [
      {
        name: 'TOKENSVC_ADDR'
        value: ':8082'
      }
    ])
  }
  {
    name: 'web'
    image: images.web
    port: 8083
    external: true
    minReplicas: 1
    maxReplicas: 2
    env: concat(commonEnv, [
      {
        name: 'WEB_ADDR'
        value: ':8083'
      }
      {
        name: 'TOKENSVC_URL'
        value: 'http://${namePrefix}-tokensvc'
      }
      {
        name: 'GATEWAY_URL'
        value: 'http://${namePrefix}-gateway'
      }
      {
        name: 'GATEWAY_MCP_URL'
        value: 'http://${namePrefix}-gateway'
      }
      {
        name: 'MANAGED_UPSTREAMS_ENABLED'
        value: '1'
      }
      {
        name: 'OIDC_ISSUER_URL'
        value: oidcIssuerUrl
      }
      {
        name: 'OIDC_CLIENT_ID'
        value: oidcClientId
      }
      {
        name: 'OIDC_CLIENT_SECRET'
        secretRef: 'oidc-client-secret'
      }
      {
        name: 'MANAGED_PROFILE'
        value: '1'
      }
      {
        name: 'MANAGED_REGO_ENABLED'
        value: '1'
      }
      {
        name: 'WEB_ADMIN_EMAILS'
        value: webAdminEmails
      }
      {
        name: 'GATEWAY_ADMIN_TOKEN'
        secretRef: 'gateway-admin-token'
      }
      {
        name: 'WEB_IDP_RELAY'
        value: '0'
      }
      {
        name: 'AZURE_CLIENT_ID'
        value: runtimeIdentityClientId
      }
      {
        name: 'AZURE_EMOTION_SUBSCRIPTION_ID'
        value: subscriptionId
      }
      {
        name: 'AZURE_EMOTION_RESOURCE_GROUP'
        value: emotionResourceGroupName
      }
      {
        name: 'AZURE_EMOTION_LOCATION'
        value: location
      }
      {
        name: 'AZURE_EMOTION_ENVIRONMENT_ID'
        value: environment.id
      }
      {
        name: 'AZURE_EMOTION_APP_NAME'
        value: '${namePrefix}-emotion'
      }
      {
        name: 'AZURE_EMOTION_IMAGE'
        value: emotionImage
      }
    ])
  }
]

resource containerApps 'Microsoft.App/containerApps@2024-03-01' = [for service in services: {
  name: '${namePrefix}-${service.name}'
  location: location
  tags: managedTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runtimeIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: concat([
        {
          name: 'database-url'
          keyVaultUrl: '${keyVaultUri}/secrets/${secretNames.databaseUrl}'
          identity: runtimeIdentity.id
        }
        {
          name: 'jwt-secret'
          keyVaultUrl: '${keyVaultUri}/secrets/${secretNames.jwtSecret}'
          identity: runtimeIdentity.id
        }
        {
          name: 'gateway-admin-token'
          keyVaultUrl: '${keyVaultUri}/secrets/${secretNames.gatewayAdminToken}'
          identity: runtimeIdentity.id
        }
        {
          name: 'licence-token'
          keyVaultUrl: '${keyVaultUri}/secrets/${secretNames.licenceToken}'
          identity: runtimeIdentity.id
        }
        {
          name: 'oidc-client-secret'
          keyVaultUrl: '${keyVaultUri}/secrets/${secretNames.oidcClientSecret}'
          identity: runtimeIdentity.id
        }
      ], empty(privateRegistry.server) ? [] : [
        {
          name: privateRegistry.passwordSecretName
          keyVaultUrl: '${keyVaultUri}/secrets/${privateRegistry.passwordSecretName}'
          identity: runtimeIdentity.id
        }
      ])
      registries: empty(privateRegistry.server) ? [] : [
        {
          server: privateRegistry.server
          username: privateRegistry.username
          passwordSecretRef: privateRegistry.passwordSecretName
        }
      ]
      ingress: {
        external: service.external
        targetPort: service.port
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: service.name
          image: service.image
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: service.env
          probes: [
            {
              type: 'Readiness'
              httpGet: {
                path: '/readyz'
                port: service.port
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: service.minReplicas
        maxReplicas: service.maxReplicas
      }
    }
  }
}]

output environmentId string = environment.id
output runtimeIdentityId string = runtimeIdentity.id
output runtimePrincipalId string = runtimeIdentity.properties.principalId

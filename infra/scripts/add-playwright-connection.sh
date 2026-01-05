#!/bin/bash
set -e

# Post-deployment script to add Playwright connection to AI Foundry
# Uses Entra ID authentication (no manual tokens required)
#
# ⚠️  WARNING: FOR DEMO/DEVELOPMENT PURPOSES ONLY
# This implementation uses a short-lived access token (~75 min) as a static ApiKey credential,
# which is NOT recommended for production environments. Production systems should use:
#   1. Managed Identity with proper Entra ID authentication (not ApiKey authType)
#   2. Custom RBAC role with least privilege (not Contributor role)
#   3. Automatic token rotation and credential management
# Microsoft explicitly warns: "Access tokens function like long-lived passwords and are more
# susceptible to being compromised. We strongly recommend Entra ID for enhanced security."
#
# Prerequisites:
# - Azure CLI logged in
# - Contributor/Owner role on Playwright workspace (already assigned in Bicep)
# - AI Foundry and Playwright workspace deployed

echo "Adding Playwright connection to AI Foundry..."

# Get parameters from environment or azd
RESOURCE_GROUP="${AZURE_AI_FOUNDRY_RESOURCE_GROUP:-$(azd env get-value AZURE_AI_FOUNDRY_RESOURCE_GROUP)}"
SUBSCRIPTION_ID="${AZURE_AI_FOUNDRY_SUBSCRIPTION_ID:-$(azd env get-value AZURE_AI_FOUNDRY_SUBSCRIPTION_ID)}"
# Get location from resource group since it's not in outputs
LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)

# Get AI Foundry name from environment
AI_FOUNDRY_NAME="${AZURE_AI_FOUNDRY_NAME:-$(azd env get-value AZURE_AI_FOUNDRY_NAME)}"

if [ -z "$AI_FOUNDRY_NAME" ]; then
  echo "ERROR: AI Foundry name not found in environment (AZURE_AI_FOUNDRY_NAME)"
  exit 1
fi

echo "Found AI Foundry: $AI_FOUNDRY_NAME"

# Get Playwright workspace details
PLAYWRIGHT_WORKSPACE=$(az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.LoadTestService/playwrightWorkspaces" \
  --query "[0]" \
  --output json)

if [ -z "$PLAYWRIGHT_WORKSPACE" ] || [ "$PLAYWRIGHT_WORKSPACE" == "null" ]; then
  echo "ERROR: Playwright workspace not found in resource group $RESOURCE_GROUP"
  exit 1
fi

PLAYWRIGHT_WORKSPACE_NAME=$(echo "$PLAYWRIGHT_WORKSPACE" | jq -r '.name')
PLAYWRIGHT_WORKSPACE_ID=$(echo "$PLAYWRIGHT_WORKSPACE" | jq -r '.id')
PLAYWRIGHT_LOCATION=$(echo "$PLAYWRIGHT_WORKSPACE" | jq -r '.location')

echo "Found Playwright workspace: $PLAYWRIGHT_WORKSPACE_NAME in $PLAYWRIGHT_LOCATION"

# Construct workspace endpoint
PLAYWRIGHT_ENDPOINT="wss://${PLAYWRIGHT_LOCATION}.api.playwright.microsoft.com/playwrightworkspaces/${PLAYWRIGHT_WORKSPACE_NAME}/browsers"

echo "Playwright endpoint: $PLAYWRIGHT_ENDPOINT"

# Get Entra ID access token for Azure Management API
echo "Getting Entra ID access token..."
ACCESS_TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)

# Create connection using REST API
echo "Creating Playwright connection in AI Foundry..."

CONNECTION_API_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${AI_FOUNDRY_NAME}/connections/Playwright?api-version=2025-04-01-preview"

# Connection payload
# Uses ApiKey authType with the Entra ID token as the key
CONNECTION_PAYLOAD=$(cat <<EOF
{
  "properties": {
    "category": "Serverless",
    "target": "${PLAYWRIGHT_ENDPOINT}",
    "authType": "ApiKey",
    "isSharedToAll": true,
    "credentials": {
      "key": "${ACCESS_TOKEN}"
    },
    "metadata": {
      "Type": "Playwright",
      "ApiType": "Azure",
      "ApiVersion": "2024-07-01-preview",
      "ResourceId": "${PLAYWRIGHT_WORKSPACE_ID}"
    }
  }
}
EOF
)

# Make REST API call
RESPONSE=$(curl -s -X PUT "$CONNECTION_API_URL" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$CONNECTION_PAYLOAD")

# Check for errors
if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
  echo "ERROR: Failed to create Playwright connection"
  echo "$RESPONSE" | jq '.error'
  exit 1
fi

echo "[OK] Playwright connection created successfully!"
echo ""
echo "Connection details:"
echo "  Name: Playwright"
echo "  Target: $PLAYWRIGHT_ENDPOINT"
echo "  Auth: Entra ID (via access token)"
echo "  Workspace: $PLAYWRIGHT_WORKSPACE_NAME"

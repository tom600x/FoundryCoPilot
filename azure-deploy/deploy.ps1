#Requires -Version 7.0

param(
    # If omitted you will be prompted after region/model selection
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = '',

    # If omitted the script scans all regions and lets you pick one that has models
    [Parameter(Mandatory=$false)]
    [string]$Location = '',

    # If omitted you pick from the live model list for the chosen region
    [Parameter(Mandatory=$false)]
    [string]$ModelName = '',

    [Parameter(Mandatory=$false)]
    [string]$ModelVersion = '',

    # Auto-detected from the live model list; override only if needed
    [Parameter(Mandatory=$false)]
    [string]$ModelFormat = '',

    [Parameter(Mandatory=$false)]
    [int]$DeploymentCapacity = 10
)

# Check if already logged in; only prompt login if not
$accountInfo = az account show --output json 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Host "Logging in to Azure..."
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure login failed. Exiting."
        exit 1
    }
}

# List subscriptions
$subscriptions = az account list --output json | ConvertFrom-Json
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    Write-Error "No subscriptions found. Exiting."
    exit 1
}

Write-Host "Available subscriptions:"
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "$i`: $($subscriptions[$i].name) ($($subscriptions[$i].id))"
}

[int]$selection = Read-Host "Enter the number of the subscription to use"

if ($selection -ge 0 -and $selection -lt $subscriptions.Count) {
    $selectedSubscription = $subscriptions[$selection]
    Write-Host "Selected subscription: $($selectedSubscription.name)"
    az account set --subscription $selectedSubscription.id
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to set subscription. Exiting."
        exit 1
    }
} else {
    Write-Error "Invalid subscription selection. Exiting."
    exit 1
}

# ── Discover existing Azure AI Foundry Hubs in this subscription ──────────────
# Done BEFORE region/model selection so the Hub's location can pre-fill region.
Write-Host ""
Write-Host "Looking for Azure AI Foundry Hubs in subscription '$($selectedSubscription.name)'..."

$foundryHubs = @()
$hubsRaw = az rest --method get `
    --url "https://management.azure.com/subscriptions/$($selectedSubscription.id)/providers/Microsoft.MachineLearningServices/workspaces?api-version=2024-10-01" `
    --output json 2>$null | ConvertFrom-Json
if ($hubsRaw -and $hubsRaw.value) {
    $foundryHubs = @($hubsRaw.value | Where-Object { $_.kind -eq 'Hub' })
}

$selectedHub    = $null
$createNewHub   = $false
$newHubName     = ''
$newProjectName = ''
if ($foundryHubs.Count -eq 0) {
    Write-Host "No Foundry Hubs found in this subscription (existing AI Services accounts will be checked next)."
    Write-Host ""
    $hubCreate = Read-Host "Create a new Azure AI Foundry Hub and Project? (Y/N)"
    if ($hubCreate -match '^[Yy]$') {
        $createNewHub   = $true
        $newHubName     = Read-Host "Enter a name for the new Foundry Hub"
        if ($newHubName -eq '') { Write-Error "Hub name is required."; exit 1 }
        $newProjectName = Read-Host "Enter a name for the Foundry Project under this Hub"
        if ($newProjectName -eq '') { Write-Error "Project name is required."; exit 1 }
        Write-Host "Will create Hub '$newHubName' and Project '$newProjectName' after model deployment."
    } else {
        Write-Host "Skipping Hub creation. Will check for existing AI Services accounts next."
    }
} else {
    Write-Host ""
    Write-Host "Found $($foundryHubs.Count) Foundry Hub(s):"
    Write-Host ("{0,-5} {1,-30} {2,-20} {3}" -f "#", "Hub Name", "Resource Group", "Location")
    Write-Host ("-" * 80)
    for ($i = 0; $i -lt $foundryHubs.Count; $i++) {
        $h = $foundryHubs[$i]
        $hRG = ($h.id -split '/')[4]
        Write-Host ("{0,-5} {1,-30} {2,-20} {3}" -f $i, $h.name, $hRG, $h.location)
    }
    Write-Host ("{0,-5} {1}" -f "S", "Skip — create AI Services standalone (connect manually later)")
    Write-Host ""
    $hubInput = Read-Host "Enter Hub number to connect to, or S to skip"
    if ($hubInput -match '^\d+$') {
        [int]$hubSel = $hubInput
        if ($hubSel -lt 0 -or $hubSel -ge $foundryHubs.Count) {
            Write-Error "Invalid Hub selection. Exiting."; exit 1
        }
        $selectedHub = $foundryHubs[$hubSel]
        $selectedHubRG = ($selectedHub.id -split '/')[4]
        Write-Host "Will connect AI Services resource to Hub: $($selectedHub.name) (RG: $selectedHubRG)"
        # Pre-fill Location from the Hub if not already specified
        if ($Location -eq '') {
            $Location = $selectedHub.location
            Write-Host "Pre-filling region from Hub location: $Location"
        }
    } else {
        Write-Host "Skipping Hub connection — AI Services resource will be standalone."
    }
}


# ── Discover existing Azure AI Services accounts in this subscription ─────────
Write-Host ""
Write-Host "Looking for existing Azure AI Services accounts in this subscription..."

$aiServicesAccounts = @()
$aiAccountsRaw = az rest --method get `
    --url "https://management.azure.com/subscriptions/$($selectedSubscription.id)/providers/Microsoft.CognitiveServices/accounts?api-version=2024-10-01" `
    --output json 2>$null | ConvertFrom-Json
if ($aiAccountsRaw -and $aiAccountsRaw.value) {
    $aiServicesAccounts = @($aiAccountsRaw.value | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' })
}

$useExistingAccount = $false
$aiServicesName     = ''
$aiServicesRG       = ''

if ($aiServicesAccounts.Count -gt 0) {
    Write-Host ""
    Write-Host "Found $($aiServicesAccounts.Count) existing AI Services account(s):"
    Write-Host ("{0,-5} {1,-35} {2,-20} {3}" -f "#", "Account Name", "Resource Group", "Location")
    Write-Host ("-" * 85)
    for ($i = 0; $i -lt $aiServicesAccounts.Count; $i++) {
        $a   = $aiServicesAccounts[$i]
        $aRG = ($a.id -split '/')[4]
        Write-Host ("{0,-5} {1,-35} {2,-20} {3}" -f $i, $a.name, $aRG, $a.location)
    }
    Write-Host ("{0,-5} {1}" -f "N", "Create a NEW AI Services account")
    Write-Host ""
    $accountInput = Read-Host "Enter account number to add a model to, or N to create new"
    if ($accountInput -match '^\d+$') {
        [int]$accountSel = $accountInput
        if ($accountSel -lt 0 -or $accountSel -ge $aiServicesAccounts.Count) {
            Write-Error "Invalid account selection. Exiting."; exit 1
        }
        $pickedAccount      = $aiServicesAccounts[$accountSel]
        $aiServicesName     = $pickedAccount.name
        $aiServicesRG       = ($pickedAccount.id -split '/')[4]
        $useExistingAccount = $true
        Write-Host "Using existing account: $aiServicesName (RG: $aiServicesRG)"
        if ($Location -eq '') {
            $Location = $pickedAccount.location
            Write-Host "Pre-filling region from account location: $Location"
        }
    } else {
        Write-Host "Will create a new AI Services account."
    }
} else {
    Write-Host "No existing AI Services accounts found. A new one will be created."
}

# ── List available models ─────────────────────────────────────────────────────
if ($useExistingAccount) {
    # Query models directly from the existing account — most accurate, no region scan needed
    Write-Host ""
    Write-Host "Listing models available to deploy on '$aiServicesName'..."
    $accountModels = az cognitiveservices account list-models `
        --name $aiServicesName `
        --resource-group $aiServicesRG `
        --output json 2>$null | ConvertFrom-Json
    if (-not $accountModels -or $accountModels.Count -eq 0) {
        Write-Error "Could not retrieve available models for '$aiServicesName'. Verify the account exists and you have Contributor access."
        exit 1
    }
    $modelEntries = @(
        $accountModels |
            ForEach-Object {
                $skuNames = if ($_.skus) { @($_.skus | ForEach-Object { $_.name }) } else { @('GlobalStandard') }
                $bestSku  = if ($skuNames -contains 'GlobalStandard')      { 'GlobalStandard' }
                            elseif ($skuNames -contains 'DataZoneStandard') { 'DataZoneStandard' }
                            elseif ($skuNames -contains 'Standard')         { 'Standard' }
                            elseif ($skuNames.Count -gt 0)                  { $skuNames[0] }
                            else                                             { 'GlobalStandard' }
                [PSCustomObject]@{ Name = $_.name; Format = $_.format; Version = $_.version; BestSku = $bestSku }
            } |
            Sort-Object Name, Version -Unique
    )
} else {
    # New account — scan regions via REST API (more reliable than az cognitiveservices model list)
    $knownRegions = @(
        'swedencentral', 'eastus', 'eastus2', 'westus', 'westus3',
        'northcentralus', 'southcentralus', 'australiaeast', 'canadaeast',
        'francecentral', 'germanywestcentral', 'japaneast', 'koreacentral',
        'norwayeast', 'polandcentral', 'southindia', 'spaincentral', 'uksouth'
    )
    $regionsToScan = if ($Location -ne '') { @($Location) } else { $knownRegions }

    Write-Host ""
    Write-Host "Scanning regions for available models (via REST API)..."
    Write-Host ""

    $regionResults = @()
    foreach ($region in $regionsToScan) {
        Write-Host -NoNewline "  $region ... "
        $modelsRaw = az rest --method get `
            --url "https://management.azure.com/subscriptions/$($selectedSubscription.id)/providers/Microsoft.CognitiveServices/locations/$region/models?api-version=2024-10-01" `
            --output json 2>$null | ConvertFrom-Json
        $standardModels = @()
        if ($modelsRaw -and $modelsRaw.value) {
            # Group by model name+version so each model appears once with its best available SKU
            $modelGroups = $modelsRaw.value | Group-Object { "$($_.model.name)|$($_.model.version)" }
            $standardModels = @($modelGroups | ForEach-Object {
                # NOTE: $_.skuName from this REST API is the ACCOUNT sku (S0/F0),
                # NOT the deployment sku. For new AIServices accounts GlobalStandard
                # is the correct deployment sku for all modern models.
                $first = $_.Group | Select-Object -First 1
                [PSCustomObject]@{ model = $first.model; skuName = 'GlobalStandard' }
            })
        }
        $cnt = $standardModels.Count
        if ($cnt -gt 0) {
            Write-Host "$cnt model(s)"
            $regionResults += [PSCustomObject]@{ Name = $region; Count = $cnt; Models = $standardModels }
        } else {
            Write-Host "none"
        }
    }

    if ($regionResults.Count -eq 0) {
        Write-Host ""
        Write-Error "No Standard models found for this subscription in any scanned region."
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  1. Request Azure OpenAI access: https://aka.ms/oai/access"
        Write-Host "  2. Register the provider: az provider register --namespace Microsoft.CognitiveServices"
        Write-Host "  3. Re-run and pick an EXISTING AI Services account to add a model to it."
        exit 1
    }

    $regionResults = @($regionResults | Sort-Object Count -Descending)
    Write-Host ""
    Write-Host "Regions with available models (sorted by count):"
    Write-Host ("{0,-5} {1,-22} {2,-8} {3}" -f "#", "Region", "Models", "Sample models")
    Write-Host ("-" * 80)
    for ($i = 0; $i -lt $regionResults.Count; $i++) {
        $r      = $regionResults[$i]
        $sample = ($r.Models | Select-Object -First 3 | ForEach-Object { $_.model.name }) -join ', '
        Write-Host ("{0,-5} {1,-22} {2,-8} {3}" -f $i, $r.Name, $r.Count, $sample)
    }
    Write-Host ""

    if ($Location -eq '') {
        [int]$regionSel = Read-Host "Enter the number of the region to use"
        if ($regionSel -lt 0 -or $regionSel -ge $regionResults.Count) {
            Write-Error "Invalid region selection. Exiting."; exit 1
        }
        $selectedRegion = $regionResults[$regionSel]
        $Location       = $selectedRegion.Name
        Write-Host "Selected region: $Location"
    } else {
        $selectedRegion = $regionResults | Where-Object { $_.Name -eq $Location } | Select-Object -First 1
        if (-not $selectedRegion) {
            Write-Error "Location '$Location' has no available models for this subscription."; exit 1
        }
    }

    $modelEntries = @(
        $selectedRegion.Models |
            ForEach-Object {
                [PSCustomObject]@{ Name = $_.model.name; Format = $_.model.format; Version = $_.model.version; BestSku = $_.skuName }
            } |
            Sort-Object Name, Version -Unique
    )
}

# ── Model selection ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Available models:"
Write-Host ("{0,-5} {1,-35} {2,-12} {3,-20} {4}" -f "#", "Name", "Format", "SKU", "Version")
Write-Host ("-" * 90)
for ($i = 0; $i -lt $modelEntries.Count; $i++) {
    $m = $modelEntries[$i]
    Write-Host ("{0,-5} {1,-35} {2,-12} {3,-20} {4}" -f $i, $m.Name, $m.Format, $m.BestSku, $m.Version)
}
Write-Host ""

if ($ModelName -eq '') {
    [int]$modelSel = Read-Host "Enter the number of the model to deploy"
    if ($modelSel -lt 0 -or $modelSel -ge $modelEntries.Count) {
        Write-Error "Invalid model selection. Exiting."; exit 1
    }
    $chosen            = $modelEntries[$modelSel]
    $ModelName         = $chosen.Name
    $ModelFormat       = $chosen.Format
    $DeploymentSkuName = $chosen.BestSku
    if ($ModelVersion -eq '') { $ModelVersion = $chosen.Version }
    Write-Host "Selected: $ModelName  Format: $ModelFormat  SKU: $DeploymentSkuName  Version: $ModelVersion"
} else {
    $match = $modelEntries | Where-Object { $_.Name -eq $ModelName } | Select-Object -First 1
    if (-not $match) { Write-Error "Model '$ModelName' not found. Exiting."; exit 1 }
    if ($ModelFormat -eq '') { $ModelFormat = $match.Format }
    if ($ModelVersion -eq '') { $ModelVersion = $match.Version }
    $DeploymentSkuName = $match.BestSku
    Write-Host "Model '$ModelName'  Format: $ModelFormat  SKU: $DeploymentSkuName  Version: $ModelVersion"
}

# ── Check available quota ─────────────────────────────────────────────────────
$checkLocation = if ($useExistingAccount -and $Location -eq '') {
    ($aiServicesAccounts | Where-Object { $_.name -eq $aiServicesName } | Select-Object -First 1).location
} else { $Location }

if ($checkLocation) {
    Write-Host ""
    Write-Host "Checking quota for '$ModelName' ($DeploymentSkuName) in '$checkLocation'..."
    $quotaUsages = $null
    $quotaRaw = az rest --method get `
        --url "https://management.azure.com/subscriptions/$($selectedSubscription.id)/providers/Microsoft.CognitiveServices/locations/$checkLocation/usages?api-version=2024-10-01" `
        --output json 2>$null | ConvertFrom-Json
    if ($quotaRaw -and $quotaRaw.value) {
        $quotaUsages = $quotaRaw.value
    }

    $quotaAvailable  = $true
    $quotaChecked    = $false
    if ($quotaUsages) {
        # Match quota entries — Azure names them like "OpenAI.Standard.gpt-4o" or similar
        $matchedQuota = @($quotaUsages | Where-Object {
            $_.name.value -match [regex]::Escape($ModelName) -or
            $_.name.localizedValue -match [regex]::Escape($ModelName)
        })
        if ($matchedQuota.Count -gt 0) {
            $quotaChecked = $true
            foreach ($q in $matchedQuota) {
                $remaining = $q.limit - $q.currentValue
                Write-Host "  Quota: $($q.name.localizedValue)"
                Write-Host "    Current usage : $($q.currentValue) / $($q.limit) ($($q.unit))"
                Write-Host "    Remaining     : $remaining"
                if ($remaining -lt $DeploymentCapacity) {
                    $quotaAvailable = $false
                    Write-Host ""
                    Write-Host "  WARNING: Insufficient quota! Need $DeploymentCapacity but only $remaining available." -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "  No specific quota entry found for '$ModelName'. Azure will validate during deployment."
        }
    } else {
        Write-Host "  Could not retrieve quota info. Proceeding with deployment (Azure will validate)."
    }

    if (-not $quotaAvailable) {
        Write-Host ""
        Write-Host "You can request a quota increase at:" -ForegroundColor Yellow
        Write-Host "  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Steps:" -ForegroundColor Yellow
        Write-Host "  1. Open the link above and sign in to Azure Portal"
        Write-Host "  2. Select provider 'Azure AI Services' (or 'Cognitive Services')"
        Write-Host "  3. Find '$ModelName' in region '$checkLocation'"
        Write-Host "  4. Click 'Request increase' and enter the capacity you need"
        Write-Host ""
        $continueAnyway = Read-Host "Continue with deployment anyway? (Y/N)"
        if ($continueAnyway -notmatch '^[Yy]$') {
            Write-Host "Exiting. Request quota and re-run the script."
            exit 0
        }
    } elseif ($quotaChecked) {
        Write-Host "  Quota OK." -ForegroundColor Green
    }
}

# ── Resource group (new account only) ────────────────────────────────────────
if (-not $useExistingAccount) {
    if ($ResourceGroupName -eq '') {
        $ResourceGroupName = Read-Host "Enter a resource group name for the NEW AI Services account"
        if ($ResourceGroupName -eq '') { Write-Error "Resource group name is required."; exit 1 }
    }
    $rgExists = az group exists --name $ResourceGroupName
    if ($rgExists -eq 'false') {
        Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..."
        az group create --name $ResourceGroupName --location $Location | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create resource group. Exiting."; exit 1 }
    } else {
        Write-Host "Using existing resource group '$ResourceGroupName'"
    }
    $aiServicesName = "$ResourceGroupName-aiservices"
    $aiServicesRG   = $ResourceGroupName
}

# ── Deploy model ──────────────────────────────────────────────────────────────
$deploySuccess = $false

if ($useExistingAccount) {
    # Add model deployment to existing AI Services account via CLI (no Bicep needed)
    Write-Host ""
    Write-Host "Adding model '$ModelName' to existing account '$aiServicesName'..."
    $deployArgs = @(
        '--name',            $aiServicesName,
        '--resource-group',  $aiServicesRG,
        '--deployment-name', $ModelName,
        '--model-name',      $ModelName,
        '--model-format',    $ModelFormat,
        '--sku-name',        $DeploymentSkuName,
        '--sku-capacity',    "$DeploymentCapacity"
    )
    if ($ModelVersion -ne '') { $deployArgs += '--model-version'; $deployArgs += $ModelVersion }

    $deployErrorText = az cognitiveservices account deployment create @deployArgs --output none 2>&1 | Out-String
    $deploySuccess = ($LASTEXITCODE -eq 0)
    if (-not $deploySuccess) { Write-Host $deployErrorText }

    $openAIEndpoint = "https://$aiServicesName.openai.azure.com/"
    $aiEndpoint     = "https://$aiServicesName.services.ai.azure.com/"
} else {
    # Create new AI Services account + deployment via Bicep
    Write-Host ""
    Write-Host "Deploying new Azure AI Services account + model via Bicep..."
    $deployParams = @(
        "aiServicesName=$aiServicesName",
        "location=$Location",
        "modelName=$ModelName",
        "modelFormat=$ModelFormat",
        "deploymentCapacity=$DeploymentCapacity",
        "modelSkuName=$DeploymentSkuName"
    )
    if ($ModelVersion -ne '') { $deployParams += "modelVersion=$ModelVersion" }

    $deployErrorText = az deployment group create `
        --resource-group $aiServicesRG `
        --template-file "$PSScriptRoot\deploy.bicep" `
        --parameters $deployParams `
        --output json 2>&1 | Out-String
    $deploySuccess = ($LASTEXITCODE -eq 0)
    if (-not $deploySuccess) { Write-Host $deployErrorText }
    if ($deploySuccess) {
        $deployOutput = $deployErrorText
        $result         = $deployOutput | ConvertFrom-Json
        $aiEndpoint     = $result.properties.outputs.aiServicesEndpoint.value
        $openAIEndpoint = $result.properties.outputs.openAICompatibleEndpoint.value
    }
}

if ($deploySuccess) {
    $apiKeyCmd = "az cognitiveservices account keys list --name $aiServicesName --resource-group $aiServicesRG --query key1 -o tsv"
    Write-Host ""
    Write-Host "Deployment complete."
    Write-Host "AI Services Account  : $aiServicesName  (RG: $aiServicesRG)"
    Write-Host "Foundry endpoint     : $aiEndpoint"
    Write-Host "OpenAI-compat endpt  : $openAIEndpoint"
    Write-Host "Model Deployed       : $ModelName"
    if ($ModelVersion -ne '') { Write-Host "Model Version        : $ModelVersion" }
    Write-Host ""
    Write-Host "Retrieve your API key:"
    Write-Host "  $apiKeyCmd"

    # ── Connect AI Services to Foundry Hub ────────────────────────────────────
    if ($selectedHub) {
        Write-Host ""
        Write-Host "Connecting AI Services resource to Foundry Hub '$($selectedHub.name)'..."

        $mlExt = az extension list --output json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq 'ml' }
        if (-not $mlExt) {
            Write-Host "  Installing Azure ML CLI extension (one-time setup)..."
            az extension add --name ml --yes 2>$null
        }

        $apiKey = az cognitiveservices account keys list `
            --name $aiServicesName `
            --resource-group $aiServicesRG `
            --query key1 -o tsv 2>$null

        if ($apiKey) {
            $connName = "$aiServicesName-conn"
            $connYaml = @"
`$schema: https://azuremlschemas.azureedge.net/latest/aiServicesConnection.schema.json
name: $connName
type: azure_ai_services
endpoint: $aiEndpoint
api_key: $apiKey
"@
            $tempYaml = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "foundry-conn-$([System.Guid]::NewGuid().ToString('N')).yaml")
            $connYaml | Out-File -FilePath $tempYaml -Encoding utf8

            az ml connection create `
                --workspace-name $selectedHub.name `
                --resource-group $selectedHubRG `
                --file $tempYaml `
                --output none 2>&1

            Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Connected! View under '$($selectedHub.name)' -> Connected Resources in Azure AI Foundry."
            } else {
                Write-Host "  Auto-connect failed. Add manually in Foundry portal:"
                Write-Host "    Hub: $($selectedHub.name)  |  Settings -> Connected resources -> + New connection"
                Write-Host "    Type: Azure AI Services  |  Resource: $aiServicesName"
            }
        } else {
            Write-Host "  Could not retrieve API key — skipping auto-connect."
            Write-Host "  Add manually: Hub -> Settings -> Connected resources."
        }
    }

    # ── Create new Foundry Hub + Project if requested ──────────────────────────
    if ($createNewHub) {
        Write-Host ""
        Write-Host "Creating Azure AI Foundry Hub '$newHubName'..."

        $mlExt = az extension list --output json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq 'ml' }
        if (-not $mlExt) {
            Write-Host "  Installing Azure ML CLI extension (one-time setup)..."
            az extension add --name ml --yes 2>$null
        }

        az ml workspace create --kind Hub --name $newHubName --resource-group $aiServicesRG --location $Location --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Hub '$newHubName' created."
            Write-Host "  Creating Foundry Project '$newProjectName'..."
            $hubResourceId = "/subscriptions/$($selectedSubscription.id)/resourceGroups/$aiServicesRG/providers/Microsoft.MachineLearningServices/workspaces/$newHubName"
            az ml workspace create --kind project --name $newProjectName --resource-group $aiServicesRG --hub-id $hubResourceId --output none
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Project '$newProjectName' created."

                # Connect AI Services to the new Hub
                $apiKey = az cognitiveservices account keys list `
                    --name $aiServicesName --resource-group $aiServicesRG --query key1 -o tsv 2>$null
                if ($apiKey) {
                    $connName = "$aiServicesName-conn"
                    $connYaml = @"
`$schema: https://azuremlschemas.azureedge.net/latest/aiServicesConnection.schema.json
name: $connName
type: azure_ai_services
endpoint: $aiEndpoint
api_key: $apiKey
"@
                    $tempYaml = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "foundry-conn-$([System.Guid]::NewGuid().ToString('N')).yaml")
                    $connYaml | Out-File -FilePath $tempYaml -Encoding utf8
                    az ml connection create --workspace-name $newHubName --resource-group $aiServicesRG --file $tempYaml --output none 2>&1
                    Remove-Item $tempYaml -Force -ErrorAction SilentlyContinue
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  AI Services '$aiServicesName' connected to Hub '$newHubName'."
                    } else {
                        Write-Host "  Auto-connect failed. Add manually: Hub -> Settings -> Connected resources."
                    }
                }
                $foundryUrl = "https://ai.azure.com/build/overview?wsid=/subscriptions/$($selectedSubscription.id)/resourceGroups/$aiServicesRG/providers/Microsoft.MachineLearningServices/workspaces/$newProjectName"
                Write-Host "  Open project in Foundry: $foundryUrl"
            } else {
                Write-Host "  Project creation failed. Create manually at https://ai.azure.com"
            }
        } else {
            Write-Host "  Hub creation failed. Create manually at https://ai.azure.com"
        }
    }

    Write-Host ""
    Write-Host "Use in VS Code / GitHub Copilot (OpenAI-compatible endpoint):"
    Write-Host "  Endpoint : $openAIEndpoint"
    Write-Host "  Model    : $ModelName"

    # ── API Key display ───────────────────────────────────────────────────────
    Write-Host ""
    $showKey = Read-Host "Show API key now? (Y/N)"
    if ($showKey -match '^[Yy]$') {
        $apiKeyValue = az cognitiveservices account keys list `
            --name $aiServicesName --resource-group $aiServicesRG --query key1 -o tsv 2>$null
        if ($apiKeyValue) {
            Write-Host ""
            Write-Host "  API Key  : $apiKeyValue"
            Write-Host ""
            Write-Host "  (Store this key securely — do not commit it to source control.)"
        } else {
            $apiKeyValue = '<run: ' + $apiKeyCmd + '>'
            Write-Host "  Could not retrieve key. Run manually:"
            Write-Host "    $apiKeyCmd"
        }
    } else {
        $apiKeyValue = '<run: ' + $apiKeyCmd + '>'
        Write-Host "  API Key  : run: $apiKeyCmd"
    }

    # ── chatLanguageModels.json snippet ──────────────────────────────────────
    # The chat completions URL for OpenAI-compatible endpoint
    $chatUrl = ($openAIEndpoint.TrimEnd('/')) + '/openai/v1/chat/completions'
    Write-Host ""
    Write-Host "=================================================="
    Write-Host " Add this entry to chatLanguageModels.json"
    Write-Host " (File -> Preferences -> Open User Settings (JSON)"
    Write-Host "  or: %APPDATA%\Code\User\chatLanguageModels.json)"
    Write-Host "=================================================="
    Write-Host @"
{
    "name": "$ModelName",
    "vendor": "azure",
    "apiKey": "$apiKeyValue",
    "models": [
        {
            "id": "$ModelName",
            "name": "$ModelName",
            "url": "$chatUrl",
            "toolCalling": true,
            "vision": true,
            "maxInputTokens": 128000,
            "maxOutputTokens": 16000
        }
    ]
}
"@
    Write-Host "=================================================="
    Write-Host "NOTE: Replace the apiKey value with a VS Code secret reference"
    Write-Host "  (\`${input:chat.lm.secret.XXXX}) for better security, or paste"
    Write-Host "  the key directly for quick testing."
} else {
    $isQuotaError = $deployErrorText -match 'quota|InsufficientQuota|OutOfCapacity|SkuNotAvailable|capacity.*exceeded|not enough capacity'
    if ($isQuotaError) {
        Write-Host ""
        Write-Error "Deployment failed due to insufficient quota or capacity."
        Write-Host ""
        Write-Host "Request a quota increase at:" -ForegroundColor Yellow
        Write-Host "  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Steps:" -ForegroundColor Yellow
        Write-Host "  1. Open the link above and sign in to Azure Portal"
        Write-Host "  2. Select provider 'Azure AI Services' (or 'Cognitive Services')"
        Write-Host "  3. Find '$ModelName' in region '$Location'"
        Write-Host "  4. Click 'Request increase' and enter the capacity you need"
        Write-Host "  5. Once approved, re-run this script"
        Write-Host ""
        Write-Host "Alternatively, try a lower capacity (current: $DeploymentCapacity):" -ForegroundColor Yellow
        Write-Host "  pwsh .\deploy.ps1 -DeploymentCapacity 1"
    } else {
        Write-Error "Deployment failed. Check the error messages above."
    }
    exit 1
}

# FoundryCoPilot — Azure AI Foundry Deployment Scripts

Interactive PowerShell scripts and Bicep templates to provision Azure AI Foundry resources,
deploy LLM models, and configure them for use in Visual Studio Code with GitHub Copilot.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Script Parameters](#script-parameters)
4. [Interactive Flow](#interactive-flow)
5. [Deployment Paths](#deployment-paths)
6. [Using the Model in VS Code](#using-the-model-in-vs-code)
7. [Using the Model in Visual Studio](#using-the-model-in-visual-studio)
8. [Disclaimer](#disclaimer)
9. [License](#license)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) >= 2.60 | Must be on your `PATH` |
| PowerShell 7+ (`pwsh`) | Windows, macOS, or Linux — check with `$PSVersionTable.PSVersion` |
| Azure subscription | Contributor or Owner role required |
| Azure AI / Cognitive Services quota | Request at https://aka.ms/oai/access if needed |
| `az ml` CLI extension | Auto-installed by the script if creating a Foundry Hub |

---

## Quick Start

Run from the `azure-deploy` folder:

```powershell
.\deploy.ps1
```

All values are discovered interactively - no parameters are required.

> **Execution Policy error?** If you see a message like *"cannot be loaded because running
> scripts is disabled on this system"*, your PowerShell execution policy is blocking the script.
> Run the following command to allow it for the current session only:
>
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```
>
> Then re-run `.\deploy.ps1`. This change applies only to the current PowerShell window and
> does not affect system-wide settings.

---

## Script Parameters

All parameters are optional. Omitting them triggers interactive prompts.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ResourceGroupName` | string | (prompted) | Resource group for a new AI Services account |
| `-Location` | string | (region picker) | Azure region, e.g. `eastus2` |
| `-ModelName` | string | (model picker) | Model to deploy, e.g. `gpt-5.4-mini` |
| `-ModelVersion` | string | (auto) | Specific model version; omit to use the Azure-managed default |
| `-ModelFormat` | string | (auto) | `OpenAI`, `AzureAI`, etc. - auto-detected from the model list |
| `-DeploymentCapacity` | int | `10` | Thousands of tokens per minute (TPM) |

**Example - fully scripted (CI/CD):**

```powershell
.\deploy.ps1 `
    -ResourceGroupName "ai-prod-rg" `
    -Location "eastus2" `
    -ModelName "gpt-5.4-mini" `
    -DeploymentCapacity 20
```

---

## Interactive Flow

1. **Azure login** - skipped if you are already authenticated (`az account show` succeeds).
2. **Subscription picker** - lists all accessible subscriptions; select by number.
3. **Foundry Hub discovery** - scans for existing Azure AI Foundry Hubs:
   - If Hubs exist: pick one to connect your AI Services resource to it, or skip.
   - If no Hubs exist: offered the choice to create a new Hub + Project automatically after deployment.
4. **AI Services account discovery** - lists existing `AIServices` and `OpenAI` accounts:
   - Pick an existing account to add a model to it, or enter `N` to create a new one via Bicep.
5. **Model listing**:
   - *Existing account* - queries `az cognitiveservices account list-models` and reads the
     correct deployment SKU from model metadata (`GlobalStandard`, `DataZoneStandard`, `Standard`).
   - *New account* - scans Azure regions via the REST API and assigns `GlobalStandard`
     as the deployment SKU (required for all modern models).
6. **Model picker** - displays a table with columns: `#`, Name, Format, SKU, Version.
7. **Deploy**:
   - *Existing account* -> `az cognitiveservices account deployment create` (no Bicep needed).
   - *New account* -> `az deployment group create` using `deploy.bicep`.
8. **Hub / Project creation** *(if requested in step 3)*:
   - Creates the Hub via `az ml workspace create --kind Hub`.
   - Creates a Project under the Hub via `az ml workspace create --kind project`.
   - Connects the AI Services resource to the Hub automatically.
   - Prints the direct Azure AI Foundry portal URL.
9. **API key** - asks whether to display the key immediately or print the retrieval command.
10. **`chatLanguageModels.json` snippet** - prints the ready-to-paste JSON block for VS Code.

---

## Deployment Paths

### Path A - Add model to an existing AI Services account

No Bicep is used. The script runs:

```powershell
az cognitiveservices account deployment create `
    --name <account> `
    --resource-group <rg> `
    --deployment-name <model> `
    --model-name <model> `
    --model-version <version> `
    --model-format OpenAI `
    --sku-name GlobalStandard `
    --sku-capacity 10
```

### Path B - Create a new AI Services account + model (Bicep)

`deploy.bicep` provisions:

- `Microsoft.CognitiveServices/accounts` (`kind: AIServices`, account SKU `S0`)
- `Microsoft.CognitiveServices/accounts/deployments` (deployment SKU defaults to `GlobalStandard`)

Key Bicep parameters:

| Parameter | Default | Description |
|---|---|---|
| `aiServicesName` | (required) | Account name; also used as the custom subdomain |
| `location` | RG location | Azure region |
| `modelName` | (required) | Model identifier |
| `modelVersion` | `''` | Empty = Azure-managed default version |
| `modelFormat` | `OpenAI` | Model format |
| `deploymentCapacity` | `10` | TPM in thousands |
| `modelSkuName` | `GlobalStandard` | Deployment SKU - `GlobalStandard` is correct for gpt-4o, gpt-5.x, o3 |

After a successful Bicep deployment the script outputs:

- **Foundry endpoint**: `https://<account>.services.ai.azure.com/`
- **OpenAI-compatible endpoint**: `https://<account>.openai.azure.com/`
- **Model deployed** name and version

---

## Using the Model in VS Code

### Step 1 - Get your endpoint and API key

The script prints both at the end of every run. Retrieve them at any time:

```powershell
# Endpoint
az cognitiveservices account show `
    --name <account-name> --resource-group <rg> `
    --query properties.endpoint -o tsv

# API key
az cognitiveservices account keys list `
    --name <account-name> --resource-group <rg> `
    --query key1 -o tsv
```

### Step 2 - Add the model to chatLanguageModels.json

The script prints a ready-to-paste JSON entry. Copy it into:

```
%APPDATA%\Code\User\chatLanguageModels.json
```

Open the file via **File > Preferences > Open User Settings (JSON)** and add the entry to the
top-level array (create the file with an empty array `[]` if it does not exist yet).

Example entry (values filled in by the script):

```json
{
    "name": "gpt-5.4-mini",
    "vendor": "azure",
    "apiKey": "<your-api-key>",
    "models": [
        {
            "id": "gpt-5.4-mini",
            "name": "gpt-5.4-mini",
            "url": "https://<account>.openai.azure.com/openai/v1/chat/completions",
            "toolCalling": true,
            "vision": true,
            "maxInputTokens": 128000,
            "maxOutputTokens": 16000
        }
    ]
}
```

> **Security tip:** Instead of pasting the key directly, use a VS Code secret reference:
> `"apiKey": "${input:chat.lm.secret.XXXX}"` - VS Code prompts once and stores the key
> securely in the system credential store.

### Step 3 - Select the model in Copilot Chat

1. Open **GitHub Copilot Chat** in VS Code.
2. Click the **Model picker** dropdown (bottom of the chat input bar).
3. Your deployed model appears under the configured vendor - select it.

---

## Using the Model in Visual Studio

### Bring Your Own Model (BYOM)

Visual Studio 2022 and 2026 support **Bring Your Own Model (BYOM)** in Copilot Chat. You can
add an API key from **OpenAI**, **Anthropic**, or **Google** to use models beyond the built-in
Copilot set — including new or experimental models. See
[Get started with AI models in Copilot Chat](https://learn.microsoft.com/en-us/visualstudio/ide/copilot-select-add-models?view=visualstudio)
for full steps.

**To add a BYOM key in Visual Studio:**

1. Open Copilot Chat and click the **Model picker** dropdown.
2. Select your provider (OpenAI, Anthropic, or Google).
3. Enter your API key and select a model.

> **Note:** BYOM is not available for Copilot Business or Enterprise users.
> The **Model picker** will not show a **Manage models** option and there is no way to add
> API keys within Visual Studio. This is a GitHub/Microsoft policy enforced at the subscription
> level — it cannot be worked around by changing VS settings or version.
> Support is limited to the Copilot Chat experience — it does not affect code completions.

**Azure OpenAI custom endpoints are not a supported BYOM provider.** There is no option in
Visual Studio to enter an Azure endpoint or Azure API key for a model you deployed yourself.
To use your Azure-deployed model interactively, use **VS Code** with the
`chatLanguageModels.json` approach described above, or open the model directly in the
[Azure AI Foundry Playground](https://ai.azure.com).

### Built-in Copilot models (no Azure key needed)

Both VS 2022 and VS 2026 include access to built-in models through GitHub Copilot's
infrastructure - no API key or Azure resource is needed. Available models include GPT-5,
GPT-5 mini, Claude Sonnet 4, Claude Opus 4, Gemini 2.5 Pro, and others. Select from the
**Model picker** dropdown in the Copilot Chat window.

Model availability depends on your Copilot subscription tier. For Copilot Business or Enterprise,
an administrator must enable preview models via the organisation's Copilot policy settings.

### Visual Studio 2022 (17.8+)

**Workload:** Install the **Azure development** workload via Visual Studio Installer.

**Azure MCP tools** - Azure resource management directly in Copilot Chat:

1. In VS Installer > **Modify**, ensure the **Azure development** workload is installed.
2. Open Copilot Chat and click the **Select tools** button (two-wrenches icon).
3. Enable the top-level **Azure MCP Server** node.

> Azure MCP tools are installed with the workload but disabled by default.

### Visual Studio 2026 (18.x)

**Workload:** Install the **Azure and AI development** workload - GitHub Copilot for Azure is
included and GA in this release.

**Enable Azure tools:**

1. Open **GitHub Copilot Chat** (**View > GitHub Copilot Chat**).
2. Sign in to your GitHub account and, when prompted, to your Azure account.
3. Click the **Select tools** button (two-wrenches icon).
4. Enable **Azure** and **Azure MCP Server** at the top level.

**Custom agents (18.4+):** Define specialised Copilot agents with `.agent.md` files:

- Repo-scoped: `.github/agents/<name>.agent.md`
- User-scoped: `%USERPROFILE%\.github\agents\<name>.agent.md`

---

## Disclaimer

- **Not an official Microsoft product.** This project is independently maintained and is not
  endorsed by, affiliated with, or supported by Microsoft Corporation or GitHub, Inc.

- **Azure costs.** Deploying resources to Azure incurs charges based on your usage and pricing
  tier. Always review
  [Azure AI Services pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/)
  before deploying. The authors accept no responsibility for unexpected charges.

- **API keys are sensitive credentials.** Never commit API keys to source control. Use VS Code
  secret references or Azure Key Vault for production use.

- **Model availability.** Model names, versions, supported SKUs, and regional availability
  change frequently. The script queries live Azure APIs at run time, but there may be short
  propagation delays between Azure portal changes and API responses.

- **Preview models.** Models labelled as preview are subject to Microsoft's preview terms and
  may be modified, retired, or restricted without notice.

- **No warranty.** The scripts are provided as-is. Test in a non-production subscription
  before deploying to any production environment.

---

## License

MIT License

Copyright (c) 2026 FoundryCoPilot Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
<#
  Sample script to setup Azure subscription for Arc for Kubernetes Connection
#>
Param(
    [String]$jsonFile,
    [switch]$spContributorRole,
    [switch]$spCredReset
)

#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeAzureSetup -Value "1.0.030325.1100" -Option Constant -ErrorAction SilentlyContinue
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name cliMinVersions -Value @{
    "azure-cli"      = "2.41.0"
    "azure-cli-core" = "2.41.0"
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    "australiaeast","brazilsouth","canadacentral","canadaeast","centralindia","centralus","centraluseuap",
    "eastasia","eastus","eastus2","eastus2euap","francecentral","germanywestcentral","israelcentral",
    "italynorth","japaneast","koreacentral","northcentralus","northeurope","norwayeast","southafricanorth",
    "southcentralus","southeastasia","southindia","swedencentral","switzerlandnorth","uaenorth","uksouth",
    "ukwest","westcentralus","westeurope","westus","westus2","westus3"
)
function Test-AzVersions {
    #Function to check if the installed az versions are greater or equal to minVersions
    $retval = $true
    $curVersion = (az version) | ConvertFrom-Json
    if (-not $curVersion) { return $false }
    foreach ($item in $cliMinVersions.Keys ) {
        Write-Host " Checking $item minVersion $($cliMinVersions.$item).." -NoNewline
        $fgcolor = 'Green'
        if ($curVersion.$item) {
            Write-Verbose " Comparing $($curVersion.$item) -lt $($cliMinVersions.$item)."
            if ([version]$($curVersion.$item) -lt [version]$($cliMinVersions.$item)) {
                $retval = $false
                $fgcolor = 'Red'
            }
            Write-Host "found $($curVersion.$item)" -ForegroundColor $fgcolor
        }
    }
    return $retval
}
function Install-AzCli {
    #Check if Az CLI is installed. If not install it.
    $AzCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if (!$AzCommand) {
        $CLIPath = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
        Write-Host "> Installing AzCLI..."
        Push-Location $env:TEMP
        $progressPreference = 'silentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi -UseBasicParsing
        $progressPreference = 'Continue'
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /passive'
        Remove-Item .\AzureCLI.msi
        Pop-Location
        [System.Environment]::SetEnvironmentVariable("Path", "$($CLIPath);$env:Path")
        az config set core.disable_confirm_prompt=yes
        az config set core.only_show_errors=yes
        #az config set auto-upgrade.enable=yes
    }
    Write-Host "> Azure CLI installed" -ForegroundColor Green

    if (-not (Test-AzVersions)) {
        Write-Host "> Required Az versions are not installed. Attempting az upgrade. This may take a while."
        az upgrade --all --yes
        if (-not (Test-AzVersions)) {
            Write-Host "Error: Required versions not found after az upgrade. Please try uninstalling and reinstalling" -ForegroundColor Red
        }
    }
}
# Formats JSON in a nicer format than the built-in ConvertTo-Json does.
#  https://github.com/PowerShell/PowerShell/issues/2736
function Format-Json([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
    $indent = 0;
    ($json -Split '\n' |
    ForEach-Object {
        if ($_ -match '[\}\]]') {
            # This line contains  ] or }, decrement the indentation level
            $indent--
        }
        $line = (' ' * $indent * 2) + $_.TrimStart().Replace(':  ', ': ')
        if ($_ -match '[\{\[]') {
            # This line contains [ or {, increment the indentation level
            $indent++
        }
        $line
    }) -Join "`n"
}
function AssignRole([String] $roleToAssign) {
    #NOTE: using global values here for rest of the parameters.
    $roleparams = @(
        "--assignee", "$($servicePrincipal.appId)",
        "--role", "$roleToAssign",
        "--scope", "$rguri"
    )
    Write-Host "Creating $roleToAssign role assignment"
    $res = (az role assignment create @roleparams ) | ConvertFrom-Json
    if (!$res) { Write-Host " Error in assigning $roleToAssign role " -ForegroundColor Red }
}
###
# Main
###
Write-Host "AksEdgeAzureSetup version  `t: $gAksEdgeAzureSetup"
if (-not $jsonFile) {
    $jsonFile = "$PSScriptRoot\AzureConfig.json"
}
if (-not(Test-Path -Path "$jsonFile" -PathType Leaf)) {
    Write-Host "Error: Incorrect input. Enter valid jsonFile path" -ForegroundColor Red
    exit -1
}
Write-Verbose "Loading $jsonFile.."
$jsonContent = Get-Content "$jsonFile" | ConvertFrom-Json

if ($jsonContent.Azure) {
    $aicfg = $jsonContent.Azure
} elseif ($jsonContent.SubscriptionId) {
    $aicfg = $jsonContent
} else {
    Write-Host "Error: Incorrect json content" -ForegroundColor Red
    exit -1
}
if ($arcLocations -inotcontains $($aicfg.Location)) {
    Write-Host "Error: Location $($aicfg.Location) is not supported for Azure Arc" -ForegroundColor Red
    Write-Host "Supported Locations : $arcLocations"
    exit -1
}
# Install Cli
Install-AzCli
Write-Host "$aicfg"
Write-Host "> az login to create/update service principal" -ForegroundColor Cyan
$loginparams = @("--scope", "https://graph.microsoft.com//.default" )
if ($($aicfg.TenantId)) {
    $loginparams += @("--tenant", $($aicfg.TenantId))
}
$session = (az login @loginparams) | ConvertFrom-Json
if (-not $session) {
    Write-Host "Error: Login failed. See error above and if required specify the tenantId in the input json file." -ForegroundColor Red
    exit -1
}

if ($($aicfg.SubscriptionId)) {
    #If SubscriptionId is specified, look for that in the session
    $reqSession = $session | Where-Object { ($_.id -eq $aicfg.SubscriptionId) -and ($_.state -eq 'Enabled') }
    if (!$reqSession) {
        Write-Host "Error: [$($aicfg.SubscriptionId)] not found or not enabled." -ForegroundColor Red
        Write-Host "Available subscription ids with state :" -ForegroundColor Cyan
        $subinfo = $session | Select-Object name, id, state
        Write-Host ($subinfo | Out-String)
        #Write-Host ($($session.id) -join "`n") -ForegroundColor Cyan
        az logout
        exit -1
    }
    (az account set --subscription $($aicfg.SubscriptionId)) | Out-Null
} elseif ($($aicfg.SubscriptionName)) {
    #If SubscriptionName is specified, look for that in the session
    $reqSession = $session | Where-Object { ($_.name -eq $aicfg.SubscriptionName) -and ($_.state -eq 'Enabled') }
    if (!$reqSession) {
        Write-Host "Error: [$($aicfg.SubscriptionName)] not found or not enabled." -ForegroundColor Red
        Write-Host "Available subscription names with state :" -ForegroundColor Cyan
        $subinfo = $session | Select-Object name, id, state
        Write-Host ($subinfo | Out-String)
        az logout
        exit -1
    }
    (az account set --subscription $($reqSession.id)) | Out-Null
} else {
    #nothing specified. So use the default subscription and continue
    if ($session.Count -gt 1) {
        Write-Host ">>> Multiple subscriptions found :"
        $subinfo = $session | Select-Object name, id , state
        Write-Host ($subinfo | Out-String)
        $sub = $session | Where-Object { $_.IsDefault -eq $true }
    } else { $sub = $session }
    Write-Host ">>> Default subscription is $($sub.name)[$($sub.id)]" -ForegroundColor Cyan
}

$session = (az account show | ConvertFrom-Json -ErrorAction SilentlyContinue)
$aicfg.SubscriptionId = $session.id
$aicfg.SubscriptionName = $session.name
$aicfg.TenantId = $session.tenantId

Write-Host "Logged in $($session.name) subscription as $($session.user.name) ($($session.user.type))" -ForegroundColor Cyan
Write-Host "TenantID       : $($aicfg.TenantId)" -ForegroundColor Cyan
Write-Host "SubscriptionId : $($aicfg.SubscriptionId)" -ForegroundColor Cyan
$hasRights = $false
$userinfo = (az ad signed-in-user show) | ConvertFrom-Json
Write-Host "User Principal Name : $($userinfo.userPrincipalName)"
Write-Host "Looking for Azure RBAC roles"
$adminroles = (az role assignment list --all --assignee $userinfo.userPrincipalName --include-inherited) | ConvertFrom-Json
if ($adminroles) {
    Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
    foreach ($role in $adminroles) {
        Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
        if (($($role.scope) -eq "/subscriptions/$($aicfg.SubscriptionId)") -and ($role.roleDefinitionName -match 'Owner')) {
            Write-Host "* You have sufficient privileges" -ForegroundColor Green
            $hasRights = $true
        }
    }
}

if (-not $hasRights) {
    # two stage call to work around issue reported here : https://github.com/Azure/azure-powershell/issues/15261 which occurs for CSP subscriptions
    # look for classic administrators only when there is no Azure RBAC roles defined
    Write-Host "Looking for classic administrator roles"
    $adminroles = (az role assignment list --include-classic-administrators) | ConvertFrom-Json
    $adminrole = $adminroles | Where-Object { $_.principalName -ieq $($session.user.name) }
    if ($adminrole) {
        Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
        foreach ($role in $adminrole) {
            Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
            if (($($role.scope) -eq "/subscriptions/$($aicfg.SubscriptionId)") -and (( $role.roleDefinitionName -match 'Administrator'))) {
                Write-Host "* You have sufficient privileges" -ForegroundColor Green
                $hasRights = $true
            }
        }
    }
}
if (-not $hasRights) {
    Write-Host "Error: You do not have sufficient privileges for this subscription $($aicfg.SubscriptionId). Please refer to 'https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-steps#privileged-administrator-roles' for more details." -ForegroundColor Red
    az logout
    exit -1
}
# Resource group
$rgname = $aicfg.ResourceGroupName
$rguri = "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$rgname"
Write-Host "Checking $rgname..."
$rgexists = az group exists --name $rgname
if ($rgexists -ieq 'true') {
    Write-Host "* $rgname exists" -ForegroundColor Green
} else {
    Write-Host "Creating $rgname resource group"
    $rg = (az group create --resource-group $rgname -l $aicfg.Location | ConvertFrom-Json -ErrorAction SilentlyContinue)
    if ($rg) {
        Write-Host "$($rg.name) resource group created" -ForegroundColor Green
    } else { 
        Write-Host "Error: Failed to create $rgname resource group" -ForegroundColor Red
        az logout
        exit -1
    }
}

# Check and enable namespaces
$namespaces = @("Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity",
    "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation")
foreach ($namespace in $namespaces) {
    Write-Host "Checking $namespace..."
    $provider = (az provider show -n $namespace | ConvertFrom-Json -ErrorAction SilentlyContinue)
    if ($provider.registrationState -ieq "Registered") {
        Write-Host "* $namespace provider registered" -ForegroundColor Green
    } else {
        Write-Host "Registering $namespace provider. This can take some time. Please wait..." -ForegroundColor Yellow
        $provider = (az provider register -n $namespace --wait | ConvertFrom-Json -ErrorAction SilentlyContinue)
        Write-Host "$namespace provider registered successfully." -ForegroundColor Green
    }
}
# Create Service Principal

$spName = $aicfg.ServicePrincipalName
$spApp = (az ad sp list --display-name $spName | ConvertFrom-Json -ErrorAction SilentlyContinue)
$servicePrincipal = $null
$enableContributor = $spContributorRole.IsPresent
$enableKcOnboarding = (!$spContributorRole.IsPresent)
$enableAcmOnboarding = (!$spContributorRole.IsPresent)
$savePassword = $false

if ($spApp -is [Array]) {$spApp = $spApp | Where-Object {$_.displayName -ieq $spName}; }
if ($spApp) {
    # service principal found. Check roles required
    $servicePrincipal = $spApp
    Write-Host "$spName is already present."
    $spRoles = (az role assignment list --all --assignee $($spApp.appId)) | ConvertFrom-Json
    if ($spRoles) {
        $spRolesRgScope = $spRoles | Where-Object {$_.scope -eq $rguri } # resource group scope
        if ($spRolesRgScope) {
            if ($spRolesRgScope.roleDefinitionName -contains 'Contributor') {
                Write-Host "* Contributor role enabled" -ForegroundColor Green
                $enableContributor = $false
                $enableKcOnboarding = $false
                $enableAcmOnboarding = $false
            }
            if ($spRolesRgScope.roleDefinitionName -contains 'Azure Connected Machine Onboarding') {
                Write-Host "* Azure Connected Machine Onboarding role enabled" -ForegroundColor Green
                $enableAcmOnboarding = $false
            }
            if ($spRolesRgScope.roleDefinitionName -contains 'Kubernetes Cluster - Azure Arc Onboarding') {
                Write-Host "* Kubernetes Cluster - Azure Arc Onboarding role enabled" -ForegroundColor Green
                $enableKcOnboarding = $false
            }
        }
    }
    #TODO : Check assigning multiple roles in one go.
    if ($enableContributor) {
        AssignRole -roleToAssign "Contributor"
    } elseif ($enableAcmOnboarding) {
        #Check and assign the connected machine onboarding role. the kuberenetes role is assigned later.
        AssignRole -roleToAssign "Azure Connected Machine Onboarding"
    }

    if ($spCredReset) {
        Write-Host "Resetting credentials.."
        $servicePrincipal = (az ad sp credential reset --id $spApp.appId | ConvertFrom-Json)
        if ($servicePrincipal) {
            Write-Host "ServicePrincipal credentials reset successfully"
            $savePassword = $true
        } else {
            Write-Host "ServicePrincipal reset failed"
            az logout
            exit -1
        }
    }
} else {
    Write-Host "$spName not found. Creating.."
    $spparams = @(
        "--name", "$spName",
        "--scopes", "$rguri"
    )
    if ($spContributorRole) {
        $spparams += @("--role", "Contributor")
    } else {
        $spparams += @("--role", "Azure Connected Machine Onboarding")
    }
    $servicePrincipal = (az ad sp create-for-RBAC @spparams | ConvertFrom-Json)
    if (!$servicePrincipal) {
        Write-Host "Error: ServicePrincipal creation failed" -ForegroundColor Red
        az logout
        exit -1
    }
    $savePassword = $true
}
if ($enableKcOnboarding) {
    #Assign the Kubernetes Cluster - Azure Arc Onboarding role to serviceprincipal too
    AssignRole -roleToAssign "Kubernetes Cluster - Azure Arc Onboarding"
}
if ($savePassword) {
    $aicfg | Add-Member -MemberType NoteProperty -Name 'Auth' -Value @{"ServicePrincipalId" = "$($servicePrincipal.appId)"; "Password" = "$($servicePrincipal.password)"} -Force
    Write-Host "WARNING: The Service Principal password is stored in clear at $jsonFile" -ForegroundColor Yellow
}
$customLocationRPOID = (az ad sp list --filter "displayname eq 'Custom Locations RP'" --query "[?appDisplayName=='Custom Locations RP'].id" -o tsv)
$jsonContent.Azure | Add-Member -MemberType NoteProperty -Name 'CustomLocationOID' -Value $customLocationRPOID -Force

#Adding Arc config as per AKSEdge schema
$arcdata = @{
    Location          = $aicfg.Location
    ResourceGroupName = $aicfg.ResourceGroupName
    SubscriptionId    = $aicfg.SubscriptionId
    TenantId          = $aicfg.TenantId
    ClientId          = $aicfg.Auth.ServicePrincipalId
    ClientSecret      = $aicfg.Auth.Password
    ClusterName       = ""
}
$ecFile = $jsonContent.AksEdgeConfigFile
if ($ecFile) {
    $parentpath = Split-Path -Path $jsonFile -Parent
    if ($ecFile.Contains("\")) {
        $ecFile = Resolve-Path -Path $ecFile
    } else {
        $ecFile = Join-Path -Path $parentpath -ChildPath $ecFile
    }
    Write-Host "Updating $ecFile with Arc information"
    if (Test-Path -Path $ecFile) {
        $edgeCfg = Get-Content $ecFile | ConvertFrom-Json
        $edgeCfg | Add-Member -MemberType NoteProperty -Name 'Arc' -Value $arcdata -Force
        $edgeCfg | ConvertTo-Json -Depth 6 | Format-Json | Set-Content -Path "$ecFile" -Force
    }
} else {
    $jsonContent | Add-Member -MemberType NoteProperty -Name 'Arc' -Value $arcdata -Force
}

$jsonContent | ConvertTo-Json -Depth 6 | Format-Json | Set-Content -Path "$jsonFile" -Force
az logout
exit 0
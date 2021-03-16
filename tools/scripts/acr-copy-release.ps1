<#
 .SYNOPSIS
    Creates release images with a particular release version in 
    production ACR from the tested development version. 

 .DESCRIPTION
    The script requires az to be installed and already logged on to a 
    subscription.  This means it should be run in a azcliv2 task in the
    azure pipeline or "az login" must have been performed already.

    Releases images with a given version number.

 .PARAMETER BuildRegistry
    The name of the source registry where development image is present.

 .PARAMETER BuildSubscription
    The subscription where the build registry is located

 .PARAMETER ReleaseRegistry
    The name of the destination registry where release images will 
    be created.

 .PARAMETER ReleaseSubscription
    The subscription of the release registry is different than build
    registry subscription

 .PARAMETER ReleaseVersion
    The build version for the development image that is being released.

 .PARAMETER IsLatest
    Release as latest image
#>

Param(
    [string] $BuildRegistry = "industrialiot",
    [string] $BuildSubscription = "IOT_GERMANY",
    [string] $ReleaseRegistry = "industrialiotprod",
    [string] $ReleaseSubscription = $null,
    [Parameter(Mandatory = $true)] [string] $ReleaseVersion,
    [switch] $IsLatest,
    [switch] $IsMajorUpdate
)

if (![string]::IsNullOrEmpty($script:BuildSubscription)) {
    Write-Debug "Setting subscription to $($script:BuildSubscription)"
    $argumentList = @("account", "set", 
        "--subscription", $script:BuildSubscription, "-ojson")
    & "az" $argumentList 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LastExitCode -ne 0) {
        throw "az $($argumentList) failed with $($LastExitCode)."
    }
}

# get build registry credentials
$argumentList = @("acr", "credential", "show", 
    "--name", $script:BuildRegistry, "-ojson")
$result = (& "az" $argumentList 2>&1 | ForEach-Object { "$_" })
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
$sourceCredentials = $result | ConvertFrom-Json
$sourceUser = $sourceCredentials.username
$sourcePassword = $sourceCredentials.passwords[0].value
Write-Host "Using Source Registry User name $($sourceUser) and password ****"

# Get build repositories 
$argumentList = @("acr", "repository", "list",
    "--name", $script:BuildRegistry, "-ojson")
$result = (& "az" $argumentList 2>&1 | ForEach-Object { "$_" })
if ($LastExitCode -ne 0) {
    throw "az $($argumentList) failed with $($LastExitCode)."
}
$BuildRepositories = $result | ConvertFrom-Json

# In each repo - check whether a release tag exists
$jobs = @()
foreach ($Repository in $BuildRepositories) {

    $BuildTag = "$($Repository):$($script:ReleaseVersion)"

    # see if build tag exists
    $argumentList = @("acr", "repository", "show", 
        "--name", $script:BuildRegistry,
        "-t", $BuildTag,
        "-ojson"
    )
    $result = (& "az" $argumentList 2>&1 | ForEach-Object { "$_" })
    if ($LastExitCode -ne 0) {
        Write-Host "Image $BuildTag not found..."
        continue
    }
    $Image = $result | ConvertFrom-Json
    if ([string]::IsNullOrEmpty($Image.digest)) {
        Write-Host "Image $BuildTag not found..."
        continue
    }

    $ReleaseTags = @()
    if ($script:IsLatest.IsPresent) {
        $ReleaseTags += "latest"
    }

    # Example: if release version is 2.7.1, then base image tags are "2", "2.7", "2.7.1"
    $versionParts = $script:ReleaseVersion.Split('.')
    if ($versionParts.Count -gt 0) {
        $versionTag = $versionParts[0]
        if ($script:IsMajorUpdate.IsPresent -or $script:IsLatest.IsPresent) {
            $ReleaseTags += $versionTag
        }
        for ($i = 1; $i -lt ($versionParts.Count); $i++) {
            $versionTag = ("$($versionTag).{0}" -f $versionParts[$i])
            $ReleaseTags += $versionTag
        }
    }

    # Create acr command line 
    # --force is needed to replace existing tags like "latest" with new images
    $FullImageName = "$($script:BuildRegistry).azurecr.io/$($BuildTag)" 
    $argumentList = @("acr", "import", "-ojson", "--force",
        "--name", $script:ReleaseRegistry,
        "--source", $FullImageName
        "--username", $sourceUser,
        "--password", $sourcePassword
    )
    # set release subscription
    if (![string]::IsNullOrEmpty($script:ReleaseSubscription)) {
        $argumentList += "--subscription"
        $argumentList += $script:ReleaseSubscription
    }
    # add the output / release image tags
    foreach ($ReleaseTag in $ReleaseTags) {
        $argumentList += "--image"
        $argumentList += "$($Repository):$($ReleaseTag)"
    }
    
    $ConsoleOutput = "Copying $FullImageName $($Image.digest) to release $script:ReleaseRegistry"
    Write-Host "Starting Job $ConsoleOutput..."
    $jobs += Start-Job -Name $FullImageName -ArgumentList @($argumentList, $ConsoleOutput) -ScriptBlock {
        $argumentList = $args[0]
        $ConsoleOutput = $args[1]
        Write-Host "$($ConsoleOutput)..."
        & az $argumentList 2>&1 | ForEach-Object { "$_" }
        if ($LastExitCode -ne 0) {
            Write-Warning "$($ConsoleOutput) failed with $($LastExitCode) - 2nd attempt..."
            & "az" $argumentList 2>&1 | ForEach-Object { "$_" }
            if ($LastExitCode -ne 0) {
                throw "Error: $($ConsoleOutput) - 2nd attempt failed with $($LastExitCode)."
            }
        }
        Write-Host "$($ConsoleOutput) completed."
    }
}

# Wait for copy jobs to finish for this repo.
if ($jobs.Count -ne 0) {
    Write-Host "Waiting for copy jobs to finish for $($script:ReleaseRegistry)."
    # Wait until all jobs are completed
    Receive-Job -Job $jobs -WriteEvents -Wait | Out-Host
    $jobs | Out-Host
    $jobs | Where-Object { $_.State -ne "Completed" } | ForEach-Object {
        throw "ERROR: Copying $($_.Name). resulted in $($_.State)."
    }
}
Write-Host "All copy jobs completed successfully for $($script:ReleaseRegistry)."  
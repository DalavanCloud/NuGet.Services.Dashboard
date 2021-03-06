[CmdletBinding(DefaultParameterSetName='RegularBuild')]
param (
    [ValidateSet("debug", "release")]
    [string]$Configuration = 'debug',
    [int]$BuildNumber,
    [switch]$SkipRestore,
    [switch]$CleanCache,
    [string]$SimpleVersion = '1.0.0',
    [string]$SemanticVersion = '1.0.0-zlocal',
    [string]$Branch,
    [string]$CommitSHA,
    [string]$BuildBranch = '1c479a7381ebbc0fe1fded765de70d513b8bd68e'
)

# For TeamCity - If any issue occurs, this script fail the build. - By default, TeamCity returns an exit code of 0 for all powershell scripts, even if they fail
trap {
    Write-Host "BUILD FAILED: $_" -ForegroundColor Red
    Write-Host "ERROR DETAILS:" -ForegroundColor Red
    Write-Host $_.Exception -ForegroundColor Red
    Write-Host ("`r`n" * 3)
    exit 1
}

if (-not (Test-Path "$PSScriptRoot/build")) {
    New-Item -Path "$PSScriptRoot/build" -ItemType "directory"
}
wget -UseBasicParsing -Uri "https://raw.githubusercontent.com/NuGet/ServerCommon/$BuildBranch/build/init.ps1" -OutFile "$PSScriptRoot/build/init.ps1"
. "$PSScriptRoot/build/init.ps1" -BuildBranch "$BuildBranch"

Write-Host ("`r`n" * 3)
Trace-Log ('=' * 60)

$startTime = [DateTime]::UtcNow
if (-not $BuildNumber) {
    $BuildNumber = Get-BuildNumber
}
Trace-Log "Build #$BuildNumber started at $startTime"

$BuildErrors = @()
    
Invoke-BuildStep 'Getting private build tools' { Install-PrivateBuildTools } `
    -ev +BuildErrors

Invoke-BuildStep 'Installing NuGet.exe' { Install-NuGet } `
    -ev +BuildErrors

Invoke-BuildStep 'Clearing package cache' { Clear-PackageCache } `
    -skip:(-not $CleanCache) `
    -ev +BuildErrors

Invoke-BuildStep 'Clearing artifacts' { Clear-Artifacts } `
    -ev +BuildErrors

Invoke-BuildStep 'Restoring solution packages' { `
    Install-SolutionPackages -path (Join-Path $PSScriptRoot ".nuget\packages.config") -output (Join-Path $PSScriptRoot "packages") -excludeversion } `
    -skip:$SkipRestore `
    -ev +BuildErrors

Invoke-BuildStep 'Set version metadata in AssemblyInfo.cs' {
        $Paths = `
            (Join-Path $PSScriptRoot "NuGet.Services.Dashboard.Common\Properties\AssemblyInfo.g.cs"), `
            (Join-Path $PSScriptRoot "NuGet.Services.Dashboard.Operations\Properties\AssemblyInfo.g.cs"), `
            (Join-Path $PSScriptRoot "NuGet.Services.Dashboard.Operations.Tools\Properties\AssemblyInfo.g.cs")

        Foreach ($Path in $Paths) {
            Set-VersionInfo -Path $Path -Version $SimpleVersion -Branch $Branch -Commit $CommitSHA
        }
    } `
    -ev +BuildErrors

Invoke-BuildStep 'Building solution' { 
        $SolutionPath = Join-Path $PSScriptRoot "NuGet.Services.Dashboard.sln"
        Build-Solution $Configuration $BuildNumber -MSBuildVersion "14" $SolutionPath -SkipRestore:$SkipRestore `
    } `
    -ev +BuildErrors

Invoke-BuildStep 'Creating artifacts' {
        New-Package (Join-Path $PSScriptRoot "NuGet.Services.Dashboard.Operations.Tools\NuGet.Services.Dashboard.Operations.Tools.csproj") -Configuration $Configuration -Symbols -BuildNumber $BuildNumber -Version $SemanticVersion -Branch $Branch
    } `
    -ev +BuildErrors

Trace-Log ('-' * 60)

## Calculating Build time
$endTime = [DateTime]::UtcNow
Trace-Log "Build #$BuildNumber ended at $endTime"
Trace-Log "Time elapsed $(Format-ElapsedTime ($endTime - $startTime))"

Trace-Log ('=' * 60)

if ($BuildErrors) {
    $ErrorLines = $BuildErrors | %{ ">>> $($_.Exception.Message)" }
    Error-Log "Builds completed with $($BuildErrors.Count) error(s):`r`n$($ErrorLines -join "`r`n")" -Fatal
}

Write-Host ("`r`n" * 3)

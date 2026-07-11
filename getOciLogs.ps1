<#
.SYNOPSIS
Fetches and cleans Kubernetes logs from OCI Logging Search using the OCI CLI and jq.

.DESCRIPTION
This script automates the retrieval of Kubernetes pod logs stored in Oracle Cloud Infrastructure (OCI) Logging.

Behind the scenes, it:
1. Validates the time range and dynamically formats it to OCI's UTC requirements.
2. Uses the OCI CLI to query the specific log group using partial subject matching.
3. Automatically installs 'jq' via winget if it is missing from the system.
4. Uses 'jq' to parse the nested JSON payload and strip away the Kubernetes Container Runtime (CRI-O) boilerplate timestamps.
5. Outputs a single, clean, chronologically sorted text file containing only the pure application logs.

.EXAMPLE
.\getOciLogs.ps1 -ResourceName "partner-service-problem-api" -Namespace "microservices" -StartTime "2026-07-06 20:00" -EndTime "2026-07-06 23:59"
Retrieves logs for the specified resource within a 4-hour window and saves them to the current directory.

.EXAMPLE
.\getOciLogs.ps1 -ResourceName "geographic-address-management-api" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00" -OutputPath "C:\Logs\" -Debug
Retrieves logs spanning 24 hours, saves the resulting log file to "C:\Logs\", and prints detailed diagnostic information to the terminal during execution.

.EXAMPLE
.\getOciLogs.ps1 -Help
Displays this detailed help manual.

.NOTES
Version:        1.0.0
Author:         Guilherme Leal
Last Updated:   2026-07-11

Prerequisites:
- OCI CLI must be installed and authenticated on the host machine.
- Winget (Windows Package Manager) must be available if 'jq' is not already installed.

.LINK
OCI Logging Query Language: https://docs.oracle.com/pt-br/iaas/Content/Logging/Reference/query_language_specification.htm
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, ParameterSetName="LogSearch", HelpMessage="The base name of the deployment/resource (e.g., resource-inventory-orchestrator)")]
    [string]$ResourceName,

    [Parameter(Mandatory=$false, ParameterSetName="LogSearch", HelpMessage="The Kubernetes namespace (optional, but recommended for accuracy)")]
    [string]$Namespace = "",

    [Parameter(Mandatory=$true, ParameterSetName="LogSearch", HelpMessage="Start time (e.g., '2026-07-06 10:00')")]
    [datetime]$StartTime,

    [Parameter(Mandatory=$true, ParameterSetName="LogSearch", HelpMessage="End time (e.g., '2026-07-07 10:00')")]
    [datetime]$EndTime,

    [Parameter(Mandatory=$false, ParameterSetName="LogSearch", HelpMessage="Folder to save the output logs. Defaults to current directory.")]
    [string]$OutputPath = ".\",

    [Parameter(Mandatory=$false, ParameterSetName="LogSearch", HelpMessage="The maximum number of logs to fetch per query. Defaults to 500,000.")]
    [int]$MaxLogsPerQuery = 500000,

    [Parameter(Mandatory=$false, ParameterSetName="LogSearch", HelpMessage="OCID of the search scope. Defaults to the default compartment search scope.")]
    [Parameter(Mandatory=$false, ParameterSetName="Config", HelpMessage="The new OCID to save as the default search scope.")]
    [string]$SearchScope = "",

    [Parameter(Mandatory=$true, ParameterSetName="Config", HelpMessage="Update the default search scope and exit without searching.")]
    [switch]$SetSearchScope,

    [Parameter(Mandatory=$false, HelpMessage="Show the help menu.")]
    [switch]$Help
)

$IsDebug = $PSBoundParameters.ContainsKey('Debug')

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    return
}

# Validate pre-requisites
$ScriptPath = $PSCommandPath
$ScriptContent = Get-Content -Path $ScriptPath -Raw

$RegexPattern = '(?i)(\[string\]\$SearchScope\s*=\s*)"([^"]*)"'
$Match = [regex]::Match($ScriptContent, $RegexPattern)

function Update-Scope {
    param (
        [Parameter(Mandatory=$true)]
        [string]$NewScope
    )

    if ([string]::IsNullOrWhiteSpace($NewScope)) {
        Write-Host "[!] Search Scope is required to run this script." -ForegroundColor Red
        return
    }

    Write-Host "Saving scope as the new default..." -ForegroundColor Cyan
    $NewContent = $ScriptContent -replace $RegexPattern, ('$1"' + $NewScope + '"')
    Set-Content -Path $ScriptPath -Value $NewContent
    Write-Host "[+] Script updated successfully! You won't be asked again.`n" -ForegroundColor Green
}

if ($SetSearchScope) {
    if ([string]::IsNullOrWhiteSpace($SearchScope)) {
        $SearchScope = Read-Host "Enter the new default search scope"
    }
    Update-Scope -NewScope $SearchScope
    return
}

if ($Match.Success) {
    $HardcodedScope = $Match.Groups[2].Value

    if ([string]::IsNullOrWhiteSpace($SearchScope)) {
        Write-Host "`n[?] No default Search Scope configured." -ForegroundColor Yellow
        Write-Host "Either pass the -SearchScope flag or set your default scope" -Foreground Yellow
        $SaveDefault = Read-Host "Would you like to set the default search scope now? (y/n)"

        if ($SaveDefault -eq 'Y' -or $SaveDefault -eq 'y') {
            $SearchScope = Read-Host "Enter the search scope: "
            Update-Scope -NewScope $SearchScope
        } else {
            return
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($HardcodedScope) -and $PSBoundParameters.ContainsKey('SearchScope')) {
        Write-Host "`n[?] You provided a Search Scope, but the script currently has no default saved." -ForegroundColor Yellow
        $SaveChoice = Read-Host "Do you want to save this scope as default? (y/n)"

        if ($SaveChoice -eq 'Y' -or $SaveChoice -eq 'y') {
            Update-Scope -NewScope $SearchScope
        }
    }
}

if (!(Get-Command oci -ErrorAction SilentlyContinue)) {
    Write-Error "OCI CLI is not installed or not in your PATH. Please install it and authenticate before running this script."
    return
}

if (!(Get-Command jq -ErrorAction SilentlyContinue)) {

    $InstallJq = Read-Host "jq is not installed or not in your PATH. Do you want to install it now? (y/n)"
    if ($InstallJq -eq 'Y' -or $InstallJq -eq 'y') {
        Write-Host "Installing jq..."
        winget install jqlang.jq --silent --accept-package-agreements --accept-source-agreements | Out-Null

        $MachinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
        $UserPath    = [Environment]::GetEnvironmentVariable('PATH', 'User')

        $env:PATH = "$MachinePath;$UserPath"

        if (!(Get-Command jq -ErrorAction SilentlyContinue)) {
            Write-Error "Failed to install or locate jq. Please install it manually."
            return
        }

        Write-Host "jq has been installed successfully." -ForegroundColor Green
    } else {
        Write-Host "Please install jq manually (e.g. with winget install jqlang.jq) and ensure it's in your PATH."
        return
    }
}

if ($StartTime -ge $EndTime) {
    Write-Host "[!] Invalid Time Range: EndTime must be greater than StartTime." -ForegroundColor Red
    return
}

if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$AbsoluteOutputPath = (Get-Item $OutputPath).FullName
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TempJsonPath = Join-Path $AbsoluteOutputPath "temp_oci_raw_$Timestamp.json"
$FinalLogPath = Join-Path $AbsoluteOutputPath "$ResourceName-$Timestamp.log"

$StartUtc = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$EndUtc   = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Target Resource : $ResourceName"
Write-Host "Time Range (UTC): $StartUtc to $EndUtc"
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "1/3: Pulling raw logs from OCI (Fetching up to $MaxLogsPerQuery logs)..."

$SearchPattern = if ([string]::IsNullOrWhiteSpace($Namespace)) { "*$ResourceName*" } else { "*${Namespace}_*${ResourceName}*" }

$SearchQuery = "search \`"$SearchScope\`" | where subject = '$SearchPattern' | sort by datetime asc"

if ($IsDebug) {
    Write-Host "OCI command: oci logging-search search-logs --search-query `"$SearchQuery`" --time-start $StartUtc --time-end $EndUtc --limit $MaxLogsPerQuery" -ForegroundColor Yellow
}

$OciRawOutput = & oci logging-search search-logs --search-query $SearchQuery --time-start $StartUtc --time-end $EndUtc --limit $MaxLogsPerQuery 2>&1
$OciString = $OciRawOutput -join "`n"

if (!$OciString.Trim().StartsWith("{")) {
    Write-Host "`n[!] OCI CLI failed to return valid JSON. CLI Error:" -ForegroundColor Red
    Write-Host $OciString -ForegroundColor Yellow
    return
}

$RawMatchCount = [regex]::Matches($OciString, '"logContent"').Count

if ($IsDebug) {
    Write-Host "     -> OCI found $RawMatchCount logs matching your query." -ForegroundColor Yellow
}

if ($RawMatchCount -eq 0) {
    Write-Host "`n[!] OCI returned empty results. The pod didn't log anything in this timeframe, or the ResourceName is wrong." -ForegroundColor Yellow
    return
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TempJsonPath, $OciString, $Utf8NoBom)

Write-Host "2/3: Parsing log messages with jq..."

$JqFilter = '(.data.results[]?.data?.logContent?.data?.message // empty) | sub(\"^[^ ]+ (stdout|stderr) [A-Z] \"; \"\")'

if ($IsDebug) {
    Write-Host "     -> JQ filter: $JqFilter" -ForegroundColor Yellow
}

& jq -r $JqFilter $TempJsonPath > $FinalLogPath

Write-Host "3/3: Cleaning up..."
Remove-Item $TempJsonPath -ErrorAction SilentlyContinue

if ((Get-Item $FinalLogPath).Length -eq 0) {
    Write-Host "Raw logs downloaded, but jq failed to parse them. Check the JSON structure." -ForegroundColor Red
} else {
    Write-Host "Done! Saved clean logs to: $FinalLogPath" -ForegroundColor Green

    $OpenFile = Read-Host "Open the log file? (y/n)"
    if ($OpenFile -eq 'Y' -or $OpenFile -eq 'y') {
        Start-Process $FinalLogPath
    }
}

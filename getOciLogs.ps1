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
Version:        1.0.2
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
    [Parameter(Mandatory = $true, ParameterSetName = "LogSearch", HelpMessage = "The base name of the deployment/resource (e.g., resource-inventory-orchestrator)")]
    [string]$ResourceName,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "The Kubernetes namespace (optional, but recommended for accuracy)")]
    [string]$Namespace = "",

    [Parameter(Mandatory = $true, ParameterSetName = "LogSearch", HelpMessage = "Start time (e.g., '2026-07-06 10:00')")]
    [datetime]$StartTime,

    [Parameter(Mandatory = $true, ParameterSetName = "LogSearch", HelpMessage = "End time (e.g., '2026-07-07 10:00')")]
    [datetime]$EndTime,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "Folder to save the output logs. Defaults to the default output path.")]
    [string]$OutputPath = "./",

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "OCID of the search scope. Defaults to the default compartment search scope.")]
    [Parameter(Mandatory = $false, ParameterSetName = "Config", HelpMessage = "The new OCID to save as the default search scope.")]
    [string]$SearchScope = "",

    [Parameter(Mandatory = $false, ParameterSetName = "Config", HelpMessage = "Update the default search scope and exit without searching.")]
    [switch]$SetSearchScope,

    [Parameter(Mandatory = $false, ParameterSetName = "Config", HelpMessage = "Update the default output path and exit without searching.")]
    [switch]$SetOutputPath,

    [Parameter(Mandatory = $false, HelpMessage = "Show the help menu.")]
    [switch]$Help
)

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    return
}

$IS_DEBUG = $PSBoundParameters.ContainsKey('Debug')
$SCRIPT_PATH = $PSCommandPath
$SCRIPT_CONTENT = Get-Content -Path $SCRIPT_PATH -Raw

if ($SetOutputPath) {
    $OutputPathRegexPattern = '(?i)(\[string\]\$OutputPath\s*=\s*)"([^"]*)"'

    Write-Host "Enter the new default output path (current: $OutputPath)"
    Write-Host "You can use relative paths (.\Logs), absolute paths (C:\Logs), or variables (%APPDATA%\Logs)."
    $NewOutPath = Read-Host "New output path [enter to keep current]"

    if ([string]::IsNullOrWhiteSpace($NewOutPath)) {
        return
    }

    if ($NewOutPath -notmatch '^([a-zA-Z]:[\\/]|\\\\|\$PSScriptRoot|%)') {
        $ResolvedNow = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $NewOutPath))

        $chosen = $false
        while (-not $chosen) {
            Write-Host "`nYou entered a relative path. Do you want this to be:" -ForegroundColor Yellow
            Write-Host " [1] Dynamic : Always save relative to the folder you run the script from in the future."
            Write-Host " [2] Fixed   : Hardcode it to exactly '$ResolvedNow' forever."
            $Choice = Read-Host "Choose [1 or 2]"

            switch ($Choice) {
                '1' { $chosen = $true }
                '2' { $NewOutPath = $ResolvedNow; $chosen = $true }
                default { Write-Host "[x] Invalid choice. Please enter 1 or 2." -ForegroundColor Red }
            }
        }
    }

    if (!(Test-Path -Path $OutputPath)) {
        $shouldCreate = Read-Host "Folder does not exist. Should we create it? (y/n)"

        $chosen = $false
        $errorMessage = "[x] Invalid folder - The folder '$OutputPath' does not exist."
        while (-not $chosen) {
            switch ($shouldCreate) {
                'Y' { $chosen = $true }
                'y' { $chosen = $true }
                'N' { Write-Host $errorMessage -ForegroundColor Red; return }
                'n' { Write-Host $errorMessage -ForegroundColor Red; return }
                default { Write-Host "[x] Invalid choice. Please enter y or n." -ForegroundColor Red; $shouldCreate = Read-Host "Should we create it? (y/n)" }
            }
        }

        New-Item -ItemType Directory -Path $NewOutPath -Force | Out-Null
    }

    Write-Host "`nSaving output path as the new default..." -ForegroundColor Cyan
    $NewContent = $SCRIPT_CONTENT -replace $OutputPathRegexPattern, ('$1"' + $NewOutPath + '"')
    Set-Content -Path $SCRIPT_PATH -Value $NewContent
    Write-Host "[+] Default output path updated successfully!`n" -ForegroundColor Green
    return
}

$SearchScopeRegexPattern = '(?i)(\[string\]\$SearchScope\s*=\s*)"([^"]*)"'

function Update-Scope {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NewScope
    )

    if ([string]::IsNullOrWhiteSpace($NewScope)) {
        Write-Host "[x] Search Scope is required to run this script." -ForegroundColor Red
        return
    }

    Write-Host "Saving scope as the new default..." -ForegroundColor Cyan
    $NewContent = $SCRIPT_CONTENT -replace $SearchScopeRegexPattern, ('$1"' + $NewScope + '"')
    Set-Content -Path $SCRIPT_PATH -Value $NewContent
    Write-Host "[+] Default search scope updated successfully!`n" -ForegroundColor Green
}

if ($SetSearchScope) {
    Write-Host "Enter the new default search scope (current: $SearchScope)"
    $NewSearchScope = Read-Host "New search scope [enter to keep current]"

    if ([string]::IsNullOrWhiteSpace($NewSearchScope)) {
        return
    }

    Update-Scope -NewScope $NewSearchScope
    return
}

if (!(Get-Command oci -ErrorAction SilentlyContinue)) {
    Write-Error "OCI CLI is not installed or not in your PATH. Please install it and authenticate before running this script."
    return
}

if (!(Get-Command jq -ErrorAction SilentlyContinue)) {
    $InstallJq = Read-Host "jq is not installed or not in your PATH. Do you want to install it now? (y/n)"

    $chosen = $false
    $errorMessage = "[x] Please install jq manually (e.g. with winget install jqlang.jq) and ensure it's in your PATH."
    while (-not $chosen) {
        switch ($InstallJq) {
            'Y' { $chosen = $true }
            'y' { $chosen = $true }
            'N' { Write-Host $errorMessage -ForegroundColor Red; return }
            'n' { Write-Host $errorMessage -ForegroundColor Red; return }
            default { Write-Host "[x] Invalid choice. Please enter y or n." -ForegroundColor Red; $InstallJq = Read-Host "Do you want to install jq now? (y/n)" }
        }
    }

    Write-Host "Installing jq..."
    winget install jqlang.jq --silent --accept-package-agreements --accept-source-agreements | Out-Null

    $MachinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')

    $env:PATH = "$MachinePath;$UserPath"

    if (!(Get-Command jq -ErrorAction SilentlyContinue)) {
        Write-Error "[x] Failed to install or locate jq. Please install it manually." -ForegroundColor Red
        return
    }

    Write-Host "[+] jq has been installed successfully." -ForegroundColor Green
}

$SearchScopeSetInThisSession = $false
if ([string]::IsNullOrWhiteSpace($SearchScope)) {
    Write-Host "`n[!] No default Search Scope configured." -ForegroundColor Yellow
    Write-Host "Either pass the -SearchScope flag or set your default scope" -Foreground Yellow
    $SaveDefault = Read-Host "Would you like to set the default search scope now? (y/n)"

    $chosen = $false
    $errorMessage = "[x] No Search Scope provided. Please provide a valid scope to continue."
    while (-not $chosen) {
        switch ($SaveDefault) {
            'Y' { $chosen = $true }
            'y' { $chosen = $true }
            'N' { Write-Host $errorMessage -ForegroundColor Red; return }
            'n' { Write-Host $errorMessage -ForegroundColor Red; return }
            default { Write-Host "[x] Invalid choice. Please enter y or n." -ForegroundColor Red; $SaveDefault = Read-Host "Would you like to set the default search scope now? (y/n)" }
        }
    }

    $SearchScope = Read-Host "Enter the search scope"
    Update-Scope -NewScope $SearchScope
    $SearchScopeSetInThisSession = $true
}

if ($StartTime -ge $EndTime) {
    Write-Host "[x] Invalid Time Range: EndTime must be greater than StartTime." -ForegroundColor Red
    return
}

if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$StartUtc = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$EndUtc = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Target Resource : $ResourceName"
Write-Host "Time Range (UTC): $StartUtc to $EndUtc"
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "1/3: Fetching logs from OCI..."

$AbsoluteOutputPath = (Get-Item $OutputPath).FullName
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$TempJsonPath = Join-Path $env:TEMP "oci_raw_$Timestamp.json"
$TempErrPath = Join-Path $env:TEMP "oci_err_$Timestamp.txt"

$FinalLogPath = Join-Path $AbsoluteOutputPath "$ResourceName-$Timestamp.log"

$JqFilter = '(.data.results[]?.data?.logContent?.data?.message // empty) | sub(\"^[^ ]+ (stdout|stderr) [A-Z] \"; \"\")'

$SearchPattern = if ([string]::IsNullOrWhiteSpace($Namespace)) { "*$ResourceName*" } else { "*${Namespace}_*${ResourceName}*" }
$SearchQuery = "search \`"$SearchScope\`" | where subject = '$SearchPattern' | sort by datetime asc"

$NextPage = $null
$PageCount = 1
$TotalLogs = 0
$ChunkLimit = 1000 # OCI limits the number of logs per call to 1k (╯‵□′)╯︵┻━┻
[System.Console]::CursorVisible = $false

try {
    do {
        $OciArgsString = "logging-search search-logs --search-query `"$SearchQuery`" --time-start $StartUtc --time-end $EndUtc --limit $ChunkLimit"

        if (![string]::IsNullOrWhiteSpace($NextPage)) {
            $OciArgsString += " --page $NextPage"
        }

        if ($IS_DEBUG) {
            Write-Host "`nOCI command: oci $OciArgsString" -ForegroundColor Yellow
        }

        $BaseText = "Page $($PageCount): Searching logs"
        $Dots = @(".", "..", "...")
        $Counter = 0

        Remove-Item $TempJsonPath -Force -ErrorAction SilentlyContinue
        Remove-Item $TempErrPath -Force -ErrorAction SilentlyContinue

        $OciProcess = Start-Process -FilePath "oci" -ArgumentList $OciArgsString -RedirectStandardOutput $TempJsonPath -RedirectStandardError $TempErrPath -NoNewWindow -PassThru

        while (!$OciProcess.HasExited) {
            Write-Host "`r$BaseText$($Dots[$Counter % 3])   " -NoNewline
            $Counter++
            Start-Sleep -Milliseconds 333
        }

        $OciString = Get-Content -Path $TempJsonPath -Raw -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($OciString) -or !$OciString.Trim().StartsWith("{")) {
            $OciError = Get-Content -Path $TempErrPath -Raw -ErrorAction SilentlyContinue
            Write-Host "`n[!] OCI CLI failed or returned invalid JSON on Page $PageCount. Error:" -ForegroundColor Red

            if (![string]::IsNullOrWhiteSpace($OciError)) {
                Write-Host $OciError -ForegroundColor Red
            }
            elseif (![string]::IsNullOrWhiteSpace($OciString)) {
                Write-Host $OciString -ForegroundColor Red
            }
            else {
                Write-Host "Unknown error. Check your OCI authentication." -ForegroundColor Red
            }
            return
        }

        $ChunkCount = [regex]::Matches($OciString, '"logContent"').Count
        $TotalLogs += $ChunkCount

        if ($ChunkCount -gt 0) {
            Write-Host "`rPage $($PageCount): Parsing $ChunkCount logs with jq...                                        " -NoNewline
            $CleanLogs = & jq -r $JqFilter $TempJsonPath

            if ($null -ne $CleanLogs) {
                $LogBlock = $CleanLogs -join "`n"
                [System.IO.File]::AppendAllText($FinalLogPath, $LogBlock + "`n")
            }
        }

        $NextPageMatch = [regex]::Match($OciString, '"opc-next-page"\s*:\s*"([^"]+)"')

        if ($NextPageMatch.Success) {
            if ($NextPage -eq $NextPageMatch.Groups[1].Value) {
                Write-Host "`n[!] OCI API returned the exact same token. Stopping to prevent infinite loop." -ForegroundColor Yellow
                break
            }

            $NextPage = $NextPageMatch.Groups[1].Value
            Write-Host "`rPage $($PageCount): Finished processing. Moving to next page...                                        " -NoNewline
            $PageCount++
        }
        else {
            $NextPage = $null
            Write-Host "`rPage $($PageCount): Finished! Reached the end of the logs.                                        "
        }
    } while ($NextPage)
}
finally {
    [System.Console]::CursorVisible = $true
}

Remove-Item $TempJsonPath -Force -ErrorAction SilentlyContinue

if ($TotalLogs -eq 0) {
    Write-Host "`n[!] OCI returned empty results. The pod didn't log anything in this timeframe, or the ResourceName is wrong." -ForegroundColor Yellow
}
else {
    Write-Host "`nDone! Processed $PageCount pages and saved $TotalLogs total logs to:" -ForegroundColor Green
    Write-Host $FinalLogPath -ForegroundColor Cyan

    $SearchScopeMatch = [regex]::Match($SCRIPT_CONTENT, $SearchScopeRegexPattern)
    $HardcodedScope = $SearchScopeMatch.Groups[2].Value

    if (!$SearchScopeSetInThisSession -and ![string]::IsNullOrWhiteSpace($SearchScope) -and [string]::IsNullOrWhiteSpace($HardcodedScope)) {
        Write-Host "`n[!] You provided a Search Scope, but the script currently has no default saved." -ForegroundColor Yellow
        $SaveChoice = Read-Host "Do you want to save this scope as default? (y/n)"

        $chosen = $false
        $shouldSave = $false
        while (-not $chosen) {
            switch ($SaveChoice) {
                'Y' { $chosen = $true; $shouldSave = $true }
                'y' { $chosen = $true; $shouldSave = $true }
                'N' { $chosen = $true }
                'n' { $chosen = $true }
                default { Write-Host "[x] Invalid choice. Please enter y or n." -ForegroundColor Red; $SaveChoice = Read-Host "Do you want to save this scope as default? (y/n)" }
            }
        }

        if ($shouldSave) {
            Update-Scope -NewScope $SearchScope
        }
    }

    Write-Host "`nPress [Enter] to open the log file, or any other key to exit..." -NoNewline -ForegroundColor Cyan
    $KeyPress = [System.Console]::ReadKey($true)

    if ($KeyPress.Key -eq 'Enter') {
        Write-Host "`nOpening log file..." -ForegroundColor Green
        Start-Process $FinalLogPath
    }
    else {
        Write-Host ""
    }
}

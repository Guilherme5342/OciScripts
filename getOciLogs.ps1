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
Version:        1.1.0
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

function Get-JqScalarValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,

        [Parameter(Mandatory = $true)]
        [string]$Filter
    )

    $Value = & jq -r $Filter $JsonPath 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    foreach ($Line in @($Value)) {
        if (![string]::IsNullOrWhiteSpace($Line) -and $Line -ne "null") {
            return [string]$Line
        }
    }

    return $null
}

function Get-JqLongValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsonPath,

        [Parameter(Mandatory = $true)]
        [string]$Filter
    )

    $Value = Get-JqScalarValue -JsonPath $JsonPath -Filter $Filter
    [long]$ParsedValue = 0

    if ([long]::TryParse([string]$Value, [ref]$ParsedValue)) {
        return $ParsedValue
    }

    return $null
}

function Get-LogTimestamp {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    
    $TimestampMatch = [regex]::Match($Line, '\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b')

    if (!$TimestampMatch.Success) {
        return $null
    }

    return ($TimestampMatch.Value -replace ' ', 'T')
}

function Format-LogProgress {
    param (
        [Parameter(Mandatory = $true)]
        [int]$CurrentPage,

        [Parameter(Mandatory = $true)]
        [int]$CompletedPages,

        [Parameter(Mandatory = $true)]
        [int]$TotalPages,

        [Parameter(Mandatory = $true)]
        [string]$LastLogTimestamp,

        [Parameter(Mandatory = $false)]
        [string]$Spinner = ""
    )

    $SafeTotalPages = [math]::Max(1, $TotalPages)
    $SafeCompletedPages = [math]::Min([math]::Max(0, $CompletedPages), $SafeTotalPages)
    $Percent = [int][math]::Floor(($SafeCompletedPages / $SafeTotalPages) * 100)
    $FilledBlocks = [int][math]::Floor($Percent / 5)
    $EmptyBlocks = 20 - $FilledBlocks
    $Bar = ("#" * $FilledBlocks) + ("-" * $EmptyBlocks)

    return ("Page {0}/{1} [{2}] {3}% {4} | Last Log: {5}" -f $CurrentPage, $SafeTotalPages, $Bar, $Percent, $Spinner, $LastLogTimestamp)
}

function Write-ProgressLine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("`r{0}{1}" -f $Message, (" " * 40)) -NoNewline
}

function Test-CancelKeyPressed {
    try {
        if (![System.Console]::KeyAvailable) {
            return $false
        }

        $KeyPress = [System.Console]::ReadKey($true)
        return (($KeyPress.Key -eq [System.ConsoleKey]::Escape) -or ($KeyPress.Key -eq [System.ConsoleKey]::Q))
    }
    catch {
        return $false
    }
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

Write-Host "1/3: Counting matching logs in OCI..."

$AbsoluteOutputPath = (Get-Item $OutputPath).FullName
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$TempJsonPath = Join-Path $env:TEMP "oci_raw_$Timestamp.json"
$TempErrPath = Join-Path $env:TEMP "oci_err_$Timestamp.txt"
$TempCountJsonPath = Join-Path $env:TEMP "oci_count_$Timestamp.json"
$TempCountErrPath = Join-Path $env:TEMP "oci_count_err_$Timestamp.txt"

$FinalLogPath = Join-Path $AbsoluteOutputPath "$ResourceName-$Timestamp.log"

$JqFilter = '(.data.results[]?.data?.logContent?.data?.message // empty) | sub(\"^[^ ]+ (stdout|stderr) [A-Z] \"; \"\")'

$SearchPattern = if ([string]::IsNullOrWhiteSpace($Namespace)) { "*$ResourceName*" } else { "*${Namespace}_*${ResourceName}*" }
$SearchQuery = "search \`"$SearchScope\`" | where subject = '$SearchPattern' | sort by datetime asc"
$CountSearchQuery = $SearchQuery -replace '\|\s*sort\s+by\s+datetime\s+asc\s*$', '| summarize count() as TotalLogs'

$NextPage = $null
$PageCount = 1
$ProcessedPages = 0
$TotalLogsSaved = 0
$ChunkLimit = 1000 # OCI limits the number of logs per call to 1k (╯‵□′)╯︵┻━┻
$LastLogTimestamp = "N/A"
$CapturedStartTimestamp = $null
$CapturedEndTimestamp = $null
$UserCancelled = $false
$SpinnerFrames = @('-', '\', '|', '/')

$CountOciArgsString = "logging-search search-logs --search-query `"$CountSearchQuery`" --time-start $StartUtc --time-end $EndUtc --limit 1"

if ($IS_DEBUG) {
    Write-Host "`nOCI count command: oci $CountOciArgsString" -ForegroundColor Yellow
}

Remove-Item $TempCountJsonPath -Force -ErrorAction SilentlyContinue
Remove-Item $TempCountErrPath -Force -ErrorAction SilentlyContinue

$CountProcess = Start-Process -FilePath "oci" -ArgumentList $CountOciArgsString -RedirectStandardOutput $TempCountJsonPath -RedirectStandardError $TempCountErrPath -NoNewWindow -Wait -PassThru
$CountString = Get-Content -Path $TempCountJsonPath -Raw -ErrorAction SilentlyContinue
$CountJsonType = Get-JqScalarValue -JsonPath $TempCountJsonPath -Filter 'type'

if ($CountProcess.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($CountString) -or [string]::IsNullOrWhiteSpace($CountJsonType)) {
    $CountError = Get-Content -Path $TempCountErrPath -Raw -ErrorAction SilentlyContinue
    Write-Host "`n[!] OCI CLI failed or returned invalid JSON while counting logs. Error:" -ForegroundColor Red

    if (![string]::IsNullOrWhiteSpace($CountError)) {
        Write-Host $CountError -ForegroundColor Red
    }
    elseif (![string]::IsNullOrWhiteSpace($CountString)) {
        Write-Host $CountString -ForegroundColor Red
    }
    else {
        Write-Host "Unknown error. Check your OCI authentication." -ForegroundColor Red
    }

    Remove-Item $TempCountJsonPath -Force -ErrorAction SilentlyContinue
    Remove-Item $TempCountErrPath -Force -ErrorAction SilentlyContinue
    return
}

$ExpectedTotalLogs = Get-JqLongValue -JsonPath $TempCountJsonPath -Filter '(.data.results[0].data.TotalLogs // .data.results[0].data.totalLogs // .data.results[0].data.Count // .data.results[0].data.count // empty)'

if ($null -eq $ExpectedTotalLogs) {
    Write-Host "`n[!] Could not parse TotalLogs from the OCI count response." -ForegroundColor Red
    Remove-Item $TempCountJsonPath -Force -ErrorAction SilentlyContinue
    Remove-Item $TempCountErrPath -Force -ErrorAction SilentlyContinue
    return
}

Remove-Item $TempCountJsonPath -Force -ErrorAction SilentlyContinue
Remove-Item $TempCountErrPath -Force -ErrorAction SilentlyContinue

if ($ExpectedTotalLogs -eq 0) {
    Write-Host "`n[!] OCI returned empty results. The pod didn't log anything in this timeframe, or the ResourceName is wrong." -ForegroundColor Yellow
    return
}

$TotalPages = [int][math]::Ceiling($ExpectedTotalLogs / $ChunkLimit)
Write-Host "[+] Found $ExpectedTotalLogs matching logs across $TotalPages page(s)." -ForegroundColor Green
Write-Host "2/3: Fetching logs from OCI... Press Esc or Q to cancel safely."

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

        $Counter = 0

        Remove-Item $TempJsonPath -Force -ErrorAction SilentlyContinue
        Remove-Item $TempErrPath -Force -ErrorAction SilentlyContinue

        $OciProcess = Start-Process -FilePath "oci" -ArgumentList $OciArgsString -RedirectStandardOutput $TempJsonPath -RedirectStandardError $TempErrPath -NoNewWindow -PassThru

while (!$OciProcess.HasExited) {
            if (Test-CancelKeyPressed) {
                $UserCancelled = $true
                Stop-Process -Id $OciProcess.Id -Force -ErrorAction SilentlyContinue
                $null = $OciProcess.WaitForExit(5000)
                Write-Host "`n[!] Download aborted by user. Saving captured data..." -ForegroundColor Yellow
                break
            }

            $Spinner = $SpinnerFrames[$Counter % $SpinnerFrames.Count]
            $ProgressMessage = Format-LogProgress -CurrentPage $PageCount -CompletedPages $ProcessedPages -TotalPages $TotalPages -LastLogTimestamp $LastLogTimestamp -Spinner $Spinner
            Write-ProgressLine -Message $ProgressMessage
            $Counter++
            Start-Sleep -Milliseconds 200
        }

        if ($UserCancelled) {
            break
        }

        # Wait for file locks and exit codes to settle
        $OciProcess.WaitForExit()
        
        $OciString = Get-Content -Path $TempJsonPath -Raw -ErrorAction SilentlyContinue
        
        # Safely check the exit code (ignore it if it is $null)
        $IsExitCodeError = ($null -ne $OciProcess.ExitCode -and $OciProcess.ExitCode -ne 0)

        # If it's an error, or the string is empty, or it doesn't start with a JSON bracket '{', then it failed!
        if ($IsExitCodeError -or [string]::IsNullOrWhiteSpace($OciString) -or !$OciString.Trim().StartsWith("{")) {
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

        $ChunkCount = Get-JqLongValue -JsonPath $TempJsonPath -Filter '(.data.results // []) | length'

        if ($null -eq $ChunkCount) {
            Write-Host "`n[!] Could not parse the page result count with jq on Page $PageCount." -ForegroundColor Red
            return
        }

        if ($ChunkCount -gt 0) {
            $ProgressMessage = Format-LogProgress -CurrentPage $PageCount -CompletedPages $ProcessedPages -TotalPages $TotalPages -LastLogTimestamp $LastLogTimestamp -Spinner "jq"
            Write-ProgressLine -Message $ProgressMessage
            $CleanLogs = & jq -r $JqFilter $TempJsonPath

            if ($null -ne $CleanLogs) {
                $CleanLogLines = @($CleanLogs)
                $LogBlock = $CleanLogLines -join "`n"
                [System.IO.File]::AppendAllText($FinalLogPath, $LogBlock + "`n")
                $TotalLogsSaved += $CleanLogLines.Count

                $NonEmptyLogLines = @($CleanLogLines | Where-Object { ![string]::IsNullOrWhiteSpace($_) })

                if ($NonEmptyLogLines.Count -gt 0) {
                    if ([string]::IsNullOrWhiteSpace($CapturedStartTimestamp)) {
                        $FirstLogTimestamp = Get-LogTimestamp -Line $NonEmptyLogLines[0]

                        if (![string]::IsNullOrWhiteSpace($FirstLogTimestamp)) {
                            $CapturedStartTimestamp = $FirstLogTimestamp
                        }
                    }

                    $LastParsedLogTimestamp = Get-LogTimestamp -Line $NonEmptyLogLines[$NonEmptyLogLines.Count - 1]

                    if (![string]::IsNullOrWhiteSpace($LastParsedLogTimestamp)) {
                        $CapturedEndTimestamp = $LastParsedLogTimestamp
                        $LastLogTimestamp = $LastParsedLogTimestamp
                    }
                }
            }
        }

        $ProcessedPages = $PageCount
        $ProgressMessage = Format-LogProgress -CurrentPage $PageCount -CompletedPages $ProcessedPages -TotalPages $TotalPages -LastLogTimestamp $LastLogTimestamp -Spinner "ok"
        Write-ProgressLine -Message $ProgressMessage

        $NextPageMatch = [regex]::Match($OciString, '"opc-next-page"\s*:\s*"([^"]+)"')
        $NewNextPage = if ($NextPageMatch.Success) { $NextPageMatch.Groups[1].Value } else { $null }

        if (![string]::IsNullOrWhiteSpace($NewNextPage)) {
            if ($NextPage -eq $NewNextPage) {
                Write-Host "`n[!] OCI API returned the exact same token. Stopping to prevent infinite loop." -ForegroundColor Yellow
                break
            }

            $NextPage = $NewNextPage
            $PageCount++
        }
        else {
            $NextPage = $null
            Write-Host ""
        }
    } while ($NextPage)
}
finally {
    [System.Console]::CursorVisible = $true
}

Remove-Item $TempJsonPath -Force -ErrorAction SilentlyContinue
Remove-Item $TempErrPath -Force -ErrorAction SilentlyContinue
Remove-Item $TempCountJsonPath -Force -ErrorAction SilentlyContinue
Remove-Item $TempCountErrPath -Force -ErrorAction SilentlyContinue

$CapturedStartDisplay = if (![string]::IsNullOrWhiteSpace($CapturedStartTimestamp)) { $CapturedStartTimestamp } else { $StartUtc }
$CapturedEndDisplay = if (![string]::IsNullOrWhiteSpace($CapturedEndTimestamp)) { $CapturedEndTimestamp } elseif ($UserCancelled) { "Not available - no saved log timestamp found" } else { $EndUtc }

if ($UserCancelled) {
    Write-Host "`nDone! Processed $ProcessedPages/$TotalPages pages." -ForegroundColor Yellow
}
else {
    Write-Host "`nDone! Processed $ProcessedPages/$TotalPages pages." -ForegroundColor Green
}

Write-Host "Total Logs Saved: $TotalLogsSaved"
Write-Host ""
Write-Host "Timespan Captured:"
Write-Host "Start: $CapturedStartDisplay"
Write-Host "End:   $CapturedEndDisplay"

$LogFileExists = (Test-Path -LiteralPath $FinalLogPath)

if ($LogFileExists) {
    Write-Host ""
    Write-Host "Saved to: $FinalLogPath" -ForegroundColor Cyan
}
elseif ($UserCancelled) {
    Write-Host ""
    Write-Host "[!] No completed page was saved before cancellation." -ForegroundColor Yellow
}

$SearchScopeMatch = [regex]::Match($SCRIPT_CONTENT, $SearchScopeRegexPattern)
$HardcodedScope = $SearchScopeMatch.Groups[2].Value

if (!$UserCancelled -and !$SearchScopeSetInThisSession -and ![string]::IsNullOrWhiteSpace($SearchScope) -and [string]::IsNullOrWhiteSpace($HardcodedScope)) {
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

if ($LogFileExists) {
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

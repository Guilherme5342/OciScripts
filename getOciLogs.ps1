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
Version:        2.0.0
Author:         Guilherme Leal
Last Updated:   2026-07-12

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
    [string]$Namespace,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "Filter query, following the OCI Logging Query Language specification. See: https://docs.oracle.com/en-us/iaas/Content/Logging/Reference/query_language_specification.htm")]
    [string]$Query,

    [Parameter(Mandatory = $true, ParameterSetName = "LogSearch", HelpMessage = "Start time (e.g., '2026-07-06 10:00')")]
    [datetime]$StartTime,

    [Parameter(Mandatory = $true, ParameterSetName = "LogSearch", HelpMessage = "End time (e.g., '2026-07-07 10:00')")]
    [datetime]$EndTime,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "Folder to save the output logs. Defaults to the path in the config file.")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "OCID of the search scope. Defaults to the search scope in the config file.")]
    [string]$SearchScope,

    [Parameter(Mandatory = $false, ParameterSetName = "LogSearch", HelpMessage = "Path to the config file to be used for this session.")]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false, ParameterSetName = "Config", HelpMessage = "Update the default search scope and exit without searching.")]
    [switch]$SetSearchScope,

    [Parameter(Mandatory = $false, ParameterSetName = "Config", HelpMessage = "Update the default output path and exit without searching.")]
    [switch]$SetOutputPath,

    [Parameter(Mandatory = $false, HelpMessage = "Show the help menu.")]
    [switch]$Help
)

class Logger {
    error([string]$msg)     { Write-Host "[x] $msg" -ForegroundColor DarkRed }
    warn([string]$msg)      { Write-Host "[!] $msg" -ForegroundColor DarkYellow }
    info([string]$msg)      { Write-Host "[?] $msg" -ForegroundColor DarkBlue }
    important([string]$msg) { Write-Host "[*] $msg" -ForegroundColor DarkCyan }
    success([string]$msg)   { Write-Host "[+] $msg" -ForegroundColor DarkGreen }
    write([string]$msg)     { Write-Host "$msg" -ForegroundColor White }
    debug([string]$msg) {
        if ($script:IS_DEBUG) { Write-Host "[#] $msg" -ForegroundColor Gray }
    }
    cmd([string]$cmd, [string]$argsList) {
        if (!$script:IS_DEBUG) { return }

        Write-Host "[#] $cmd $argsList" -ForegroundColor Gray
    }
}

function Confirm-Choice {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$Title = "Confirm",
        [string]$YesText = "Yes",
        [string]$NoText = "No",
        [int]$DefaultChoice = 0
    )
    $Choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
        [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", $YesText)
        [System.Management.Automation.Host.ChoiceDescription]::new("&No", $NoText)
    )
    $DefaultChoice = $DefaultChoice
    $Decision = $Host.UI.PromptForChoice($Title, $Prompt, $Choices, $DefaultChoice)
    if ($Decision -eq 0) {
        return $true
    } else {
        return $false
    }
}

function Select-Option {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Options,

        [string]$Prompt = "Please select an option:",
        [string]$Title = "Selection",
        [int]$DefaultChoice = 0
    )

    $Choices = [System.Management.Automation.Host.ChoiceDescription[]]@()

    for ($i = 0; $i -lt $Options.Count; $i++) {
        $Shortcut = ($i + 1).ToString()
        $Label = "&$Shortcut. $($Options[$i])"
        $Choices += [System.Management.Automation.Host.ChoiceDescription]::new($Label, "Select $($Options[$i])")
    }

    $Decision = $Host.UI.PromptForChoice($Title, $Prompt, $Choices, $DefaultChoice)

    return $Decision
}

function Read {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$Default = "",
        [string]$Placeholder = "Press Enter to use the default"
    )
    $log.write("$Prompt (Default: ""$Default"")")
    Write-Host "> " -NoNewLine -ForegroundColor DarkCyan
    $userInput = $Host.UI.ReadLine()

    if ([string]::IsNullOrWhiteSpace($userInput)) {
        return $Default
    }
    return $userInput
}

function Read-Path {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$Default = ".\",
        [string]$Placeholder = "Press Enter to use the default"
    )

    $NewPath = Read -Prompt "$Prompt `nYou can use relative paths [.\Logs], absolute paths [C:\Logs], or variables [%APPDATA%\Logs]." -Default $Default -Placeholder $Placeholder

    if ($Default -eq $NewPath) {
        return $Default
    }

    if ($NewPath -notmatch '^([a-zA-Z]:[\\/]|\\\\|\$PSScriptRoot|%)') {
        $ResolvedNow = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $NewPath))

        $chosen = Select-Option -Prompt "`nYou entered a relative path. Do you want this to be:" -Options @(
            "Dynamic: Relative to the folder you run the script from in the future."
            "Fixed: Hardcode it to exactly '$ResolvedNow' forever."
        )

        if ($chosen -eq 1) {
            $NewPath = $ResolvedNow
        }
    }

    if (!(Test-Path -Path $NewPath)) {
        $shouldCreate = Confirm-Choice -Prompt "Folder does not exist. Should we create it?"

        if (!$shouldCreate) {
            $log.error("Folder does not exist.")
            return
        }

        New-Item -ItemType Directory -Path $NewPath -Force | Out-Null
    }

    return $NewPath
}

$BASE_TEMP_PATH = "$env:TEMP\OciLogs"
$TempJsonPath = Join-Path $BASE_TEMP_PATH "oci_result.json"
$TempErrPath = Join-Path $BASE_TEMP_PATH "oci_command_output.log"

function Clear-Workspace {
    if (Test-Path -Path $BASE_TEMP_PATH) {
        Remove-Item -Path $BASE_TEMP_PATH -Recurse -Force | Out-Null
    }
}

function CancelKeyPressed {
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

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    return
}

$IS_DEBUG = $PSBoundParameters.ContainsKey('Debug')
$log = [Logger]::new()
Clear-Workspace

$log.debug("Debug mode enabled.")
$log.debug("Loading config file...")

$CONFIG_PATH = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path -Path $PSScriptRoot -ChildPath "config.json" } else { $ConfigPath }

if (Test-Path -Path $CONFIG_PATH) {
    $CONFIG = Get-Content -Path $CONFIG_PATH | ConvertFrom-Json
} else {
    $DefaultConfig = [PSCustomObject]@{
        SearchScope = ""
        OutputPath  = "./"
    }
    $DefaultConfig | ConvertTo-Json | Set-Content -Path $CONFIG_PATH
}

$log.debug("Config loaded:  $CONFIG")

function Set-SearchScope {
    param (
        [string]$Scope = ""
    )
    $NewScope = Read -Prompt "Enter the new default search scope" -Default $Scope
    $log.important("Saving search scope as the new default...")
    $CONFIG.SearchScope = $NewScope
    Set-Content -Path $CONFIG_PATH -Value ($CONFIG | ConvertTo-Json)
    $log.success("Search scope updated successfully!")
}

if ([string]::IsNullOrWhiteSpace($CONFIG.SearchScope)) {
    $log.error("SearchScope is not set in the config file.")

    if (!(Confirm-Choice -Prompt "Would you like to set it now?")) {
        $log.warn("The search scope is needed to run the script. You can set it in the config file of with the flag -SetSearchScope")
        return
    }

    Set-SearchScope
}

if ($SetSearchScope) {
    Set-SearchScope -Scope $CONFIG.SearchScope
    return
}

if ($SetOutputPath) {
    $NewOutPath = Read-Path -Prompt "Enter the new default output path" -Default "./"
    $log.important("Saving folder as the new output default...")
    $CONFIG.OutputPath = $NewOutPath
    Set-Content -Path $CONFIG_PATH -Value ($CONFIG | ConvertTo-Json)
    $log.success("Output path updated successfully!")
    return
}

if (!(Test-Path $CONFIG.OutputPath)) {
    New-Item -ItemType Directory -Path $CONFIG.OutputPath -Force | Out-Null
}

if (!(Test-Path $BASE_TEMP_PATH)) {
    New-Item -ItemType Directory -Path $BASE_TEMP_PATH -Force | Out-Null
}

if (!(Get-Command oci -ErrorAction SilentlyContinue)) {
    $log.error("OCI CLI is not installed or not in your PATH. Please install it and authenticate before running this script.")
    return
}

if (!(Get-Command jq -ErrorAction SilentlyContinue)) {
    if (!(Confirm-Choice "jq is not installed or not in your PATH. Do you want to install it now?")) {
        $log.error("Please install jq manually (e.g. with winget install jqlang.jq) and ensure it's in your PATH.")
        return
    }

    $log.info("Installing jq...")
    winget install jqlang.jq --silent --accept-package-agreements --accept-source-agreements | Out-Null

    $MachinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')

    $log.debug("Updating PATH...")

    $env:PATH = "$MachinePath;$UserPath"

    if (!(Get-Command jq -ErrorAction SilentlyContinue)) {
        $log.error("Failed to install or locate jq. Please install it manually.")
        return
    }

    $log.success("jq has been installed successfully.")
}

if ($StartTime -ge $EndTime) {
    $log.error("Invalid Time Range: EndTime must be greater than StartTime.")
    return
}

$StartUtc = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$EndUtc = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$log.important("======================================================")
$log.important("Target Resource : $ResourceName")
$log.important("Time Range (UTC): $StartUtc to $EndUtc")
$log.important("======================================================")
$log.write("1/3: Counting matching logs in OCI...")

$SearchPattern = if ([string]::IsNullOrWhiteSpace($Namespace)) { "*$ResourceName*" } else { "*${Namespace}_*${ResourceName}*" }
$ScopeToUse = if ([string]::IsNullOrWhiteSpace($SearchScope)) { $CONFIG.SearchScope } else { $SearchScope }
$SearchQuery = "search `"$ScopeToUse`" | where subject = '$SearchPattern'"

if (![string]::IsNullOrWhiteSpace($Query)) {
    $SearchQuery = "$SearchQuery | where $Query"
}

$searchParamsJson = @{
    "limit"             = 1
    "searchQuery"       = "$SearchQuery | summarize count() as TotalLogs"
    "timeEnd"           = $EndUtc
    "timeStart"         = $StartUtc
} | ConvertTo-Json

$TempSearchJson = Join-Path -Path $BASE_TEMP_PATH -ChildPath "oci_search_params.json"
[System.IO.File]::WriteAllLines($TempSearchJson, $searchParamsJson)

$log.debug("searchParams: $searchParamsJson")

$ArgsString = @(
    "logging-search",
    "search-logs",
    "--from-json", "file://$TempSearchJson"
)

$log.cmd("oci", $ArgsString)

$CountProcess = Start-Process -FilePath "oci" -ArgumentList $ArgsString -RedirectStandardOutput $TempJsonPath -RedirectStandardError $TempErrPath -NoNewWindow -Wait -PassThru

function Validate-Oci-Return {
    param (
        [Parameter(Mandatory=$true)]
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) {
        return
    }

    $ErrorResponse = Get-Content -Path $TempErrPath -Raw -ErrorAction SilentlyContinue
    $log.error("OCI CLI failed or returned invalid JSON while counting logs. Error:")

    if (![string]::IsNullOrWhiteSpace($ErrorResponse)) {
        $log.error($ErrorResponse)
    } else {
        $log.error("Unknown error. Check your OCI authentication.")
    }

    exit 1
}

Validate-Oci-Return -ExitCode $CountProcess.ExitCode

$CountObject = Get-Content -Path $TempJsonPath -Raw | ConvertFrom-Json
$ExpectedTotalLogs = $CountObject.data.results[0].data.TotalLogs

$log.debug("ExpectedTotalLogs: $ExpectedTotalLogs")

if ($null -eq $ExpectedTotalLogs) {
    $log.error("Could not parse total of logs from OCI.")
    exit 1
}

if ($ExpectedTotalLogs -eq 0) {
    $log.warn("OCI returned empty results. The pod didn't log anything in this timeframe, or the ResourceName is wrong.")
    exit 0
}

$Timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$FileWindow = "$($StartTime.ToString('yyyyMMdd_HHmm'))_to_$($EndTime.ToString('yyyyMMdd_HHmm'))"
$FinalLogPath = Join-Path (Get-Item $CONFIG.OutputPath).FullName "$ResourceName-$FileWindow-$Timestamp.log"
$ChunkLimit = 1000 # OCI limits the number of logs per call to 1k (╯‵□′)╯︵┻━┻
$NextPage = $null
$PageCount = 1
$ProcessedPages = 0
$TotalPages = [int][math]::Ceiling($ExpectedTotalLogs / $ChunkLimit)
$TotalLogsSaved = 0
$LastLogTimestamp = "N/A"
$CapturedStartTimestamp = $null
$CapturedEndTimestamp = $null
$UserCancelled = $false
$SpinnerFrames = @('-', '\', '|', '/')
$JqFilter = '.\"opc-next-page\" // \"\", ((.data.results[]?.data?.logContent?.data?.message // empty) | sub(\"^[^ ]+ (stdout|stderr) [A-Z] \"; \"\"))'

$log.debug("ChunkLimit: $ChunkLimit")

$pages = if ($TotalPages -gt 1) { "pages" } else { "page" }
$log.info("Found $ExpectedTotalLogs matching logs in $TotalPages $pages.")

$log.info("Fetching logs from OCI... Press Esc or Q to cancel safely.")

[System.Console]::CursorVisible = $false
try {
    do {
        $searchParamsJson = @{
            "limit"             = $ChunkLimit
            "searchQuery"       = "$SearchQuery | sort by datetime asc"
            "timeEnd"           = $EndUtc
            "timeStart"         = $StartUtc
        }

        if (![string]::IsNullOrWhiteSpace($NextPage)) {
            $searchParamsJson["page"] = $NextPage
        }

        if ($null -eq $NextPage -or $IS_DEBUG) {
            $log.write(" ")
        }
        $log.debug("Search params: $($searchParamsJson | ConvertTo-Json)")
        [System.IO.File]::WriteAllLines($TempSearchJson, ($searchParamsJson | ConvertTo-Json))

        $ArgsString = @(
            "logging-search",
            "search-logs",
            "--from-json", "file://$TempSearchJson"
        )

        $log.cmd("oci", $ArgsString)

        $Counter = 0
        $OciProcess = Start-Process -FilePath "oci" -ArgumentList $ArgsString -RedirectStandardOutput $TempJsonPath -RedirectStandardError $TempErrPath -NoNewWindow -PassThru

        while (!$OciProcess.HasExited) {
            if (CancelKeyPressed) {
                $UserCancelled = $true
                Stop-Process -Id $OciProcess.Id -Force -ErrorAction SilentlyContinue
                $null = $OciProcess.WaitForExit(5000)
                $log.write("")
                $log.warn("Export aborted by user. Saving captured data...")
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

        $OciProcess.WaitForExit()
        Validate-Oci-Return -ExitCode $OciProcess.Exit

        $ProgressMessage = Format-LogProgress -CurrentPage $PageCount -CompletedPages $ProcessedPages -TotalPages $TotalPages -LastLogTimestamp $LastLogTimestamp -Spinner "jq"
        Write-ProgressLine -Message $ProgressMessage

        $CleanLogs = & jq -r $JqFilter $TempJsonPath

        $NewNextPage = $CleanLogs[0]
        $CleanLogLines = @($CleanLogs[1..($CleanLogs.Count - 1)])

        if ($CleanLogLines -eq $null) {
            $log.error("Could not parse the page result count with jq on Page $PageCount.")
            exit 1
        }

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

        $ProcessedPages = $PageCount
        $ProgressMessage = Format-LogProgress -CurrentPage $PageCount -CompletedPages $ProcessedPages -TotalPages $TotalPages -LastLogTimestamp $LastLogTimestamp -Spinner "ok"
        Write-ProgressLine -Message $ProgressMessage

        if (![string]::IsNullOrWhiteSpace($NewNextPage)) {
            if ($NextPage -eq $NewNextPage) {
                $log.warn("OCI API returned the exact same token. Stopping to prevent infinite loop.")
                break
            }

            $NextPage = $NewNextPage
            $PageCount++
        } else {
            $NextPage = $null
        }
    } while ($NextPage)
} finally {
    [System.Console]::CursorVisible = $true
}

Clear-Workspace

$CapturedStartDisplay = if (![string]::IsNullOrWhiteSpace($CapturedStartTimestamp)) { $CapturedStartTimestamp } else { $StartUtc }
$CapturedEndDisplay = if (![string]::IsNullOrWhiteSpace($CapturedEndTimestamp)) { $CapturedEndTimestamp } elseif ($UserCancelled) { "Not available - no saved log timestamp found" } else { $EndUtc }

$log.write("")
if ($UserCancelled -and $ProcessedPages -lt $TotalPages) {
    $log.info("User cancelled before all pages were processed.")
    $log.info("Processed $ProcessedPages/$TotalPages pages.")
} else {
    $log.success("Processed $ProcessedPages/$TotalPages pages.")
}

$log.write("Total Logs Saved: $TotalLogsSaved")
$log.write("`nTimespan Captured:")
$log.write("Start: $CapturedStartDisplay")
$log.write("End:   $CapturedEndDisplay")

$LogFileExists = (Test-Path -LiteralPath $FinalLogPath)

if ($LogFileExists) {
    $log.success("Saved to: $FinalLogPath")
} elseif ($UserCancelled) {
    $log.warn("No completed page was saved before cancellation.")
}

if (!$UserCancelled -and !$CONFIG.SearchScope -and ![string]::IsNullOrWhiteSpace($SearchScope)) {
    $log.warn("You provided a Search Scope, but the script currently has no default saved.")

    if (Confirm-Choice -Prompt "Do you want to save this scope as default?") {
        Set-SearchScope $SearchScope
    }
}

if ($LogFileExists) {
    $log.important("Press [Enter] to open the log file, or any other key to exit...")
    $KeyPress = [System.Console]::ReadKey($true)

    if ($KeyPress.Key -eq 'Enter') {
        $log.success("Opening log file...")
        Start-Process $FinalLogPath
    } else {
        $log.write("Exiting without opening the log file.")
    }
}

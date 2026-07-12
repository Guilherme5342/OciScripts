# OCI Kubernetes Log Fetcher (`getOciLogs.ps1`)

A robust PowerShell utility to extract, clean, and consolidate Kubernetes pod logs directly from Oracle Cloud Infrastructure (OCI) Logging Search.

The standard OCI Web Console limits you to viewing 500 log lines at a time. This script bypasses that limitation (fetching all the logs using OCI's CLI pagination), automatically formats them, and strips out the noisy Kubernetes runtime boilerplate, leaving you with pure, readable application logs.

## ✨ Features

- **Bypasses Console Limits:** Pulls massive log dumps locally for easy searching in VS Code or Notepad++.
- **Automatic Noise Filtering:** Uses `jq` to strip away K8s CRI-O timestamps and `stdout F` flags.
- **Smart Multi-Pod Consolidation:** Merges logs from all pods in a deployment into a single, chronologically sorted file.
- **Fuzzy Matching:** Supports exact namespaces and partial resource names automatically.
- **Self-Editing Configuration:** Remembers your OCI Log Group OCID by seamlessly updating its own source code so you never have to mess with configuration files.
- **Self-Healing Dependencies:** Automatically detects if `jq` is missing, silently installs it via `winget`, dynamically reloads your system `PATH`, and continues execution without missing a beat.

## 📋 Prerequisites

1. **Windows PowerShell** (Standard on Windows).
2. **OCI CLI**: Must be installed and authenticated on your machine.
    - Run `oci setup config` if you haven't authenticated before.
3. **Winget**: (Built into modern Windows) required _only_ if `jq` is not already installed.

## ⚙️ Initial Setup (Run Once)

Before fetching logs, the script needs to know which OCI Log Group to search (the "Search Scope"). You only have to do this once per machine — the script can save the setting internally.

To interactively set the default Search Scope (recommended):

```powershell
.\getOciLogs.ps1 -SetSearchScope
```

To run a single query with an explicit scope without changing the saved default, pass `-SearchScope` directly. If no default is saved, the script will offer to persist it after the query:

```powershell
.\getOciLogs.ps1 -SearchScope "ocid1.compartment.oc1..." -ResourceName "my-api" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00"
```

To update the default output folder interactively (supports relative paths, absolute paths, and `%ENV%` variables; will create the folder if missing):

```powershell
.\getOciLogs.ps1 -SetOutputPath
```

## 🚀 Usage

Once configured, run the script directly from your terminal.

### Basic Usage

Fetch logs for a specific microservice over a defined time window:

```powershell
.\getOciLogs.ps1 -ResourceName "geographic-address-management-api" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00"
```

### Advanced Usage

Filter by a specific Kubernetes namespace and save the output to a custom directory:

```powershell
.\getOciLogs.ps1 -ResourceName "problem-api" -Namespace "microservices" -StartTime "2026-07-06 20:00" -EndTime "2026-07-06 23:59" -OutputPath "C:\Logs\"
```

### Troubleshooting / Debugging

If you aren't getting the logs you expect, append the built-in `-Debug` flag. The script will print the exact OCI query it generates and the exact number of raw logs found before parsing:

```powershell
.\getOciLogs.ps1 -ResourceName "inventory-orchestrator" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00" -Debug
```

## ⚙️ Parameters

| Parameter         | Type       | Required | Description                                                                                                                                                                                                                                                 |
| ----------------- | ---------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-ResourceName`   | `String`   | **Yes*** | The base name (or partial name) of the deployment/pod.                                                                                                                                                                                                      |
| `-StartTime`      | `DateTime` | **Yes*** | The start of the search window (Local Time, e.g., `2026-07-09 10:00`).                                                                                                                                                                                      |
| `-EndTime`        | `DateTime` | **Yes*** | The end of the search window (Local Time).                                                                                                                                                                                                                  |
| `-Namespace`      | `String`   | No       | The Kubernetes namespace. Highly recommended for accuracy.                                                                                                                                                                                                  |
| `-OutputPath`     | `String`   | No       | Folder to save the output file for this run. Defaults to `.`\` (current directory).                                                                                                                                                                         |
| `-SearchScope`    | `String`   | No       | The OCI OCID log group string. (Prompts dynamically if not set).                                                                                                                                                                                            |
| `-SetSearchScope` | `Switch`   | No       | Opens an interactive prompt to set the default `SearchScope` saved in the script. Exits after saving (does not perform a search).                                                                                                                           |
| `-SetOutputPath`  | `Switch`   | No       | Opens an interactive prompt to set the default `OutputPath` saved in the script. Accepts relative, absolute, or `%ENV%` paths; can create the folder if it doesn't exist. Exits after saving (does not perform a search). Default is the current directory. |
| `-Help`           | `Switch`   | No       | Displays the built-in help manual.                                                                                                                                                                                                                          |

** Mandatory for searching logs, but not required if using `-SetSearchScope`.*

## 🧠 How it Works Under the Hood

1. **Self-Editing Config:** If no default Search Scope is detected, the script reads its own `$PSCommandPath` and uses regex to permanently bake your chosen OCID into the parameter block for future runs.
2. **Time Conversion:** The script accepts your local time and automatically converts it to the strictly required OCI ISO-8601 UTC format.
3. **Wildcard Routing:** If you provide `-Namespace orchestration` and `-ResourceName API`, it generates the precise OCI search query: `*orchestration_*API*`.
4. **Extraction & Parsing:** It pulls the raw JSON response from OCI, isolates the `results[]` array, and passes it to `jq`.
5. **Regex Cleaning:** `jq` applies the regex `^[^ ]+ (stdout|stderr) [A-Z]` to delete the container runtime string, dumping pure application stack traces into your final `.log` file.

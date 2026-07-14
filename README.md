# OCI Kubernetes Log Fetcher (`getOciLogs.ps1`)

A robust PowerShell utility to extract, clean, and consolidate Kubernetes pod logs directly from Oracle Cloud Infrastructure (OCI) Logging Search.

The standard OCI Web Console limits you to viewing 500 log lines at a time. This script automates the retrieval of Kubernetes pod logs stored in OCI Logging, bypassing console limitations by fetching logs in chunks. It automatically formats them and strips out the noisy Kubernetes Container Runtime (CRI-O) boilerplate timestamps, leaving you with pure, readable application logs.

## ✨ Features

- **Bypasses Console Limits:** Pulls massive log dumps locally by managing OCI CLI pagination with a limit of 1,000 logs per call.
- **Automatic Noise Filtering:** Uses `jq` to strip away K8s CRI-O timestamps and `stdout`/`stderr` flags from the nested JSON payload.
- **Smart Multi-Pod Consolidation:** Outputs a single, chronologically sorted text file containing pure application logs from matching resources.
- **Fuzzy Matching:** Uses the OCI CLI to query the specific log group using partial subject matching for namespaces and resource names.
- **JSON Configuration Management:** Stores your default Search Scope (OCID) and Output Path in a `config.json` file, eliminating the need to edit the script's source code or provide parameters repeatedly.
- **Self-Healing Dependencies:** Automatically installs `jq` via `winget` (`jqlang.jq`) if it is missing from the system, dynamically reloads the system `PATH`, and seamlessly continues execution.
- **Graceful Cancellation:** Pressing `Esc` or `Q` during the fetching process will safely abort the operation while retaining and saving all log data captured up to that point.
- **Live Progress Tracking:** Displays an updating progress bar in the console, showing the current page count, percentage complete, and the timestamp of the last fetched log.

## 📋 Prerequisites

- **Windows PowerShell:** Standard on Windows systems.
- **OCI CLI:** Must be installed and authenticated on the host machine.
- **Winget:** Windows Package Manager must be available if `jq` is not already installed on the system.

## ⚙️ Initial Setup (Run Once)

Before fetching logs, the script needs to know which OCI Log Group to search (the "Search Scope"). You only have to do this once per machine, as the script saves the setting in a local JSON configuration file.

To interactively set the default Search Scope (recommended):

```powershell
.\getOciLogs.ps1 -SetSearchScope
```

To run a single query with an explicit scope without changing the saved default, pass `-SearchScope` directly. If no default is saved, the script will prompt you to save it after the query completes:

```powershell
.\getOciLogs.ps1 -SearchScope "ocid1.compartment.oc1..." -ResourceName "my-api" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00"
```

To update the default output folder interactively (supports relative paths, absolute paths, or `%ENV%` variables; prompts to create the folder if missing):

```powershell
.\getOciLogs.ps1 -SetOutputPath
```

## 🚀 Usage

Once configured, run the script directly from your terminal.

### Basic Usage

Fetch logs for a specific microservice over a defined time window:

```powershell
.\getOciLogs.ps1 -ResourceName "example-service-api" -Namespace "microservices" -StartTime "2026-07-06 20:00" -EndTime "2026-07-06 23:59"
```

### Advanced Usage

Retrieve logs spanning 24 hours, save the resulting log file to a custom directory (`C:\Logs\`), and print detailed diagnostic information to the terminal during execution:

```powershell
.\getOciLogs.ps1 -ResourceName "example-service-api" -StartTime "2026-07-09 10:00" -EndTime "2026-07-10 10:00" -OutputPath "C:\Logs\" -Debug
```

## ⚙️ Parameters

| Parameter         | Type       | Required | Description                                                                         |
| ----------------- | ---------- | -------- | ----------------------------------------------------------------------------------- |
| `-ResourceName`   | `String`   | **Yes*** | The base name of the deployment/resource (e.g., `resource-inventory-orchestrator`). |
| `-StartTime`      | `DateTime` | **Yes*** | Start time (e.g., `'2026-07-06 10:00'`).                                            |
| `-EndTime`        | `DateTime` | **Yes*** | End time (e.g., `'2026-07-07 10:00'`).                                              |
| `-Namespace`      | `String`   | No       | The Kubernetes namespace (optional, but recommended for accuracy).                  |
| `-Query`          | `String`   | No       | Filter query, following the OCI Logging Query Language specification.               |
| `-OutputPath`     | `String`   | No       | Folder to save the output logs. Defaults to the path in the config file.            |
| `-SearchScope`    | `String`   | No       | OCID of the search scope. Defaults to the search scope in the config file.          |
| `-ConfigPath`     | `String`   | No       | Path to the config file to be used for this session.                                |
| `-SetSearchScope` | `Switch`   | No       | Update the default search scope and exit without searching.                         |
| `-SetOutputPath`  | `Switch`   | No       | Update the default output path and exit without searching.                          |
| `-Help`           | `Switch`   | No       | Show the detailed help menu.                                                        |

** Mandatory for searching logs, but not required if using configuration switches like `-SetSearchScope` or `-SetOutputPath*`.

## 🧠 How it Works Under the Hood

1. **JSON Configuration:** If no configuration path is specified, the script searches for or creates a `config.json` file in its root directory to permanently store your `SearchScope` and `OutputPath` settings.
2. **Time Conversion:** Validates the time range and dynamically formats your local time to OCI's strict ISO-8601 UTC requirements (`yyyy-MM-ddTHH:mm:ssZ`).
3. **Wildcard Routing & Query Injection:** If both a namespace and resource name are provided, it builds a precise partial match query (`*${Namespace}_*${ResourceName}*`). If an optional `-Query` string is supplied, it pipes the search into that OCI conditional.
4. **Extraction & Parsing:** It pulls the raw JSON response from OCI, isolates the nested `results` array, and manages pagination tokens (`opc-next-page`) to loop through results until completion.
5. **Regex Cleaning:** `jq` applies the regex filter `^[^ ]+ (stdout|stderr) [A-Z]` to delete the container runtime string, dumping pure application stack traces into your final `.log` file.

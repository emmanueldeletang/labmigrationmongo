# MongoDB Task Manager on Azure

A local Flask task-management application backed by MongoDB Community Edition on an Azure Ubuntu VM. One PowerShell installer provisions Azure, one Python script loads sample data, and one Python application serves the UI and REST API.

## Project files

| File or directory | Purpose |
| --- | --- |
| `deploy.ps1` | Signs in to Azure and provisions the VM, network, disk, and MongoDB service |
| `parameters.json` | Single source for deployment, MongoDB, Flask, and seed settings |
| `parameters-editor.html` | Standalone local editor for loading, changing, and saving `parameters.json` |
| `seed_mongo.py` | Replaces and loads the application data and indexes |
| `app.py` | Runs the Flask web application and REST API |
| `cloud-init.yaml` | MongoDB VM bootstrap template consumed by `deploy.ps1` |
| `templates/`, `static/` | Application pages and styles |


## Architecture and security

- MongoDB runs on Ubuntu 22.04 and uses the attached data disk at `/data/db` when available.
- MongoDB authorization is enabled and the configured user is created in the `admin` authentication database.
- MongoDB listens on all VM interfaces so the local Python processes can connect directly.
- The network security group allows SSH and MongoDB only from `SshSourceAddressPrefix`.
- Trusted Launch, Secure Boot, vTPM, a managed identity, a Standard public IP, and a Standard SSD are enabled by default through `parameters.json`.
- VM auto-shutdown defaults to 19:00 UTC and is configurable.

This is a lab architecture. `parameters.json` contains plaintext credentials and must remain private. For production, use Key Vault, SSH keys, private networking, monitoring, and a highly available managed data service.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)
- An Azure account with permission to create the configured resources
- Python 3.10 or later for local use

## Configure parameters

All editable values are in `parameters.json`. This includes Azure placement and VM options, credentials, network ranges, MongoDB settings, Flask host and port, task statuses, and seed data sizes.

Open [parameters-editor.html](parameters-editor.html) locally in Microsoft Edge or Chrome:

1. Select **Open JSON** and choose `parameters.json`.
2. Change the required values. Arrays and objects must remain valid JSON.
3. Select **Save** to overwrite the opened file, or **Save as** to create another copy.

The browser requires you to select the file explicitly before it grants read/write access. `Ctrl+S` saves the loaded document. In browsers without the File System Access API, Save downloads an updated JSON file instead.

Before deployment, replace `VmAdminPassword`, `MongoPassword`, and `FlaskSecretKey`. The VM password must contain at least 12 characters with uppercase, lowercase, numeric, and special characters. `ResourceToken` must contain one to five lowercase letters.

## Deploy to Azure

From the project directory:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
./deploy.ps1
```

To use a different JSON file:

```powershell
./deploy.ps1 -ParametersFile ".\parameters.json"
```

The installer uses device-code authentication for `TenantId`, lists enabled subscriptions, and asks you to select one. If `SshSourceAddressPrefix` is empty, it detects your public IP and stores its `/32` CIDR back in the JSON file.

Every deployment deletes and recreates the generated resource group. This permanently deletes its VM, disks, network, public IP, and MongoDB data. If the requested VM SKU is unavailable, the installer checks `FallbackLocations` and uses instance suffix `2` in generated resource names.

After deployment, the installer updates `MongoUri`, `PublicIpAddress`, `DeploymentLocation`, `ResourceGroupName`, and `VmName` without removing the other settings. Provisioning logs are available on the VM:

```powershell
ssh <VmAdminUsername>@<PublicIpAddress>
sudo cloud-init status --long
sudo journalctl -u cloud-final -u mongod --no-pager
```

## Run from VS Code

### Use the development container

With Docker and the VS Code Dev Containers extension installed, open the
repository in VS Code and select **Dev Containers: Reopen in Container**.
The container provides Python, PowerShell, Azure CLI, the project dependencies,
and the recommended Python, Azure, PowerShell, and MongoDB extensions. pip uses
Microsoft's package feed proxy so dependency installation also works on managed
networks that block public package download hosts. Port 5000 is forwarded
automatically when Flask starts.

Inside the container, deploy and run the project with:

```powershell
./deploy.ps1
python ./seed_mongo.py
python ./app.py
```

The deployment still requires interactive Azure device-code authentication,
and `parameters.json` must contain the required configuration.

### Use a local Python environment

Create and activate a virtual environment:

```powershell
python -m venv .venv
./.venv/Scripts/Activate.ps1
python -m pip install -r requirements.txt
```

Use two terminals after `deploy.ps1` completes.

### Terminal 1: seed the database

The seed operation replaces data in the three application collections, then creates the required indexes:

```powershell
python ./seed_mongo.py
```

The default configuration creates 20 users, 500 projects, and 100 tasks per project, for a total of 50,000 tasks.

With the default seed settings, expected output is:

```text
Seeded 20 users, 500 projects, and 50000 tasks.
```

This operation deletes the existing `users`, `projects`, and `tasks` documents before loading new data. It reads the connection, database, statuses, and record counts from `parameters.json`.

### Terminal 2: start Flask

```powershell
python ./app.py
```

Open `http://127.0.0.1:<FlaskPort>` using the port configured in `parameters.json`. `FlaskHost` defaults to `0.0.0.0`, which makes the server listen on every local interface. Stop Flask with `Ctrl+C`.

## REST API

PowerShell examples for a local app:

```powershell
$baseUrl = "http://127.0.0.1:5000"

# Health and read endpoints
Invoke-RestMethod "$baseUrl/health"
$users = Invoke-RestMethod "$baseUrl/api/users"
$projects = Invoke-RestMethod "$baseUrl/api/projects"
$tasks = Invoke-RestMethod "$baseUrl/api/projects/$($projects[0]._id)/tasks"
Invoke-RestMethod "$baseUrl/api/tasks/$($tasks[0]._id)"

# Create a task
$newTask = @{
    title = "Prepare release notes"
    description = "Summarize delivered work"
    project_id = $projects[0]._id
    assigned_user_id = $users[0]._id
    duration_days = 2
    status = "todo"
    dependencies = @($tasks[0]._id)
    can_run_parallel = $false
} | ConvertTo-Json
$created = Invoke-RestMethod "$baseUrl/api/tasks" -Method Post -ContentType "application/json" -Body $newTask

# Update status or assignment
$update = @{ status = "in_progress"; assigned_user_id = $users[1]._id } | ConvertTo-Json
Invoke-RestMethod "$baseUrl/api/tasks/$($created._id)" -Method Patch -ContentType "application/json" -Body $update
```

Endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/users` | List users |
| `GET` | `/api/projects` | List projects |
| `GET` | `/api/projects/<project_id>/tasks` | List tasks for a project |
| `GET` | `/api/tasks/<task_id>` | Read one task |
| `POST` | `/api/tasks` | Create a task |
| `PATCH` | `/api/tasks/<task_id>` | Update supported task fields |


## Cleanup

Use the resource group printed by `deploy.ps1`:

```powershell
az group delete --name <resource-group-name> --yes --no-wait
```

This permanently removes the VM, disk, public IP, network interface, NSG, and virtual network in that group.
**MONGODB LAB**

**Installation, Data Loading, Application Launch, and Azure DocumentDB Migration**

Step-by-step operating guide for the mongolabmigration workspace

**Scope**

Deploy MongoDB Community Edition to an Azure VM, load the sample dataset, run the local Flask application, and migrate project\_tasks\_db to Azure DocumentDB with the Visual Studio Code migration extension.

**Document version**

1.0 | 1 September 2026

*Microsoft Learn migration article reviewed: 17 August 2026*

# **Contents**

*In Microsoft Word, right-click the contents and select Update Field if page numbers are not populated.*

# **1. Purpose and outcome**

At the end of this guide, the source MongoDB database is running on an Azure Ubuntu VM, the sample dataset contains users, projects, and tasks, the Flask application is available locally, and a validated copy of the database is available in Azure DocumentDB.

|  |
| --- |
| **Lab safety**  The deployment script deletes and recreates its generated Azure resource group. The seed script deletes the users, projects, and tasks collections before reloading them. Never run either operation against an environment that contains data you need to preserve. |

# **2. Solution overview**

| **Component** | **Role** | **Runs where** |
| --- | --- | --- |
| deploy.ps1 | Provisions the source VM, networking, disk, and MongoDB | Local PowerShell and Azure |
| parameters.json | Stores all deployment, connection, Flask, and seed settings | Project folder |
| parameters-editor.html | Loads, edits, validates, and saves the JSON settings | Local Edge or Chrome |
| seed\_mongo.py | Creates sample users, projects, tasks, and indexes | Local Python |
| app.py | Serves the task-management UI and REST API | Local Python |
| Azure DocumentDB Migration Extension | Creates and monitors an Azure DMS migration job | Visual Studio Code |

## **2.1 Data flow**

Local browser -> Flask app -> source MongoDB VM. During migration, Azure Database Migration Service reads source MongoDB and writes Azure DocumentDB. After validation, the application connection can be switched to the target DocumentDB connection string.

# **3. Prerequisites**

## **3.1 Local workstation**

* Windows PowerShell 5.1 or PowerShell 7.
* Azure CLI installed and available as az.
* Python 3.10 or later.
* Visual Studio Code and Microsoft Edge or Google Chrome.
* An Azure account that can create virtual machines, networking, managed disks, Azure DocumentDB, and Azure Database Migration Service resources.

## **3.2 Migration permissions**

| **Role** | **Scope** | **Why it is needed** |
| --- | --- | --- |
| Reader | Subscription | Lists subscriptions and resource groups for each job |
| Azure Database Migration Service Contributor | Resource group | Creates or uses DMS |
| Contributor | Subscription | Registers Microsoft.DataMigration once |
| Contributor | Azure DocumentDB | Triggers the migration job |
| User Access Administrator | Virtual network; private mode only | Assigns Network Contributor to the DMS principal |

Migration jobs currently require native Azure DocumentDB authentication. Microsoft Entra ID authentication is not supported for the migration job connection.

# **4. Configure the lab**

## **4.1 Open the parameter editor**

1. Open parameters-editor.html from the project folder in Microsoft Edge or Chrome.
2. Select Open JSON and choose parameters.json.
3. Change the required fields, then select Save. The browser asks for explicit file permission before it can overwrite the file.
4. Keep parameters.json private because it contains plaintext credentials and connection strings.

## **4.2 Required settings**

| **Parameter** | **Action before deployment** |
| --- | --- |
| TenantId | Set the Microsoft Entra tenant used for Azure sign-in |
| ResourceToken | Use one to five lowercase letters; this is included in resource names |
| Location / FallbackLocations | Choose the preferred and fallback Azure regions |
| VmAdminUsername | Set the Linux administrator username |
| VmAdminPassword | Replace the sample value with a strong password |
| MongoUsername / MongoPassword | Set native MongoDB credentials; replace the sample password |
| FlaskSecretKey | Replace the placeholder with a long random value |
| SshSourceAddressPrefix | Leave empty to detect your public IP, or enter an IPv4 /32 CIDR |
| SeedUserCount / SeedProjectCount / SeedTasksPerProject | Adjust only if a different data volume is required |

|  |
| --- |
| **Do not expose credentials**  Do not paste real passwords or full connection strings into tickets, screenshots, email, source control, or this guide. Use the parameter names when documenting operations. |

# **5. Install MongoDB on Azure**

## **5.1 Open PowerShell in the project**

cd C:\Users\<user>\Downloads\mongolabmigration

Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned

.\deploy.ps1

## **5.2 Complete interactive Azure sign-in**

1. Open the device-login URL displayed by Azure CLI in an InPrivate or Incognito window.
2. Enter the device code and authenticate in the tenant configured by TenantId.
3. Return to the terminal and select an enabled Azure subscription from the numbered list.
4. Read the deletion warning carefully. The generated resource group is removed and recreated.

## **5.3 What the installer creates**

* A resource group, virtual network, subnet, network security group, static public IP, network interface, Ubuntu VM, and managed data disk.
* Inbound SSH and MongoDB rules restricted to SshSourceAddressPrefix.
* MongoDB Community Edition 8.0, enabled as a systemd service.
* MongoDB data on /data/db when the managed disk is available.
* Native MongoDB authorization and the configured application user.
* Trusted Launch, Secure Boot, vTPM, managed identity, and automatic shutdown.

## **5.4 Confirm installation**

Wait for Deployment complete. The script updates MongoUri, PublicIpAddress, DeploymentLocation, ResourceGroupName, and VmName in parameters.json.

ssh <VmAdminUsername>@<PublicIpAddress>

sudo cloud-init status --long

sudo systemctl status mongod --no-pager

sudo journalctl -u cloud-final -u mongod --no-pager

exit

From the local workstation, test the source port:

Test-NetConnection -ComputerName <PublicIpAddress> -Port <MongoPort>

Expected result: TcpTestSucceeded is True.

# **6. Prepare Python and load data**

## **6.1 Create the virtual environment**

python -m venv .venv

.\.venv\Scripts\Activate.ps1

python -m pip install --upgrade pip

python -m pip install -r requirements.txt

## **6.2 Load the sample database**

python .\seed\_mongo.py

The default configuration creates 20 users, 500 projects, and 100 tasks per project, for a total of 50,000 tasks.

With the default values, the expected output is:

Seeded 20 users, 500 projects, and 50000 tasks.

The script creates project\_tasks\_db, replaces the users, projects, and tasks data, and creates indexes for project\_id, assigned\_user\_id, status, and dependencies.

|  |
| --- |
| **Destructive seed operation**  seed\_mongo.py calls delete\_many on all three application collections. Run it only on the source lab database before migration. Do not run it after changing MongoUri to the Azure DocumentDB target unless you intentionally want to replace target data. |

## **6.3 Optional automated test**

python -m pip install -r requirements-dev.txt

python -m pytest -q

The tests use mongomock and do not modify the Azure MongoDB database.

# **7. Launch and verify the application**

## **7.1 Start Flask**

python .\app.py

1. Open http://127.0.0.1:5000, or use the FlaskPort value if it was changed.
2. Confirm that the dashboard reports the expected user, project, and task counts.
3. Open Users, Projects, a project task list, and a task detail page.
4. Test health from another PowerShell terminal.

Invoke-RestMethod http://127.0.0.1:5000/health

Expected response: status is ok. Stop Flask with Ctrl+C when required.

# **8. Plan the Azure DocumentDB migration**

## **8.1 Recommended mode for this lab**

Use Offline migration with Public connectivity for the initial lab migration. The dataset is reproducible, the source VM has a public endpoint, and the application can be stopped while the snapshot is copied. Offline mode is simpler and completes automatically.

| **Choice** | **Use when** | **Important behavior** |
| --- | --- | --- |
| Offline | A static snapshot and short outage are acceptable | Automatically completes after collection snapshots are copied |
| Online | Writes must continue during the initial copy | Requires MongoDB ChangeStream and a manual cutover |
| Public | Both endpoints can be allowlisted over public IPs | Add DMS static IPs to source and target firewalls |
| Private | Public exposure is prohibited | Requires VNet selection, nonoverlapping DMS CIDR, peering, routing, DNS, and extra RBAC |

## **8.2 Create and prepare the target**

1. Create an Azure DocumentDB cluster in the chosen subscription, resource group, and region.
2. Gather its native username, password, hostname, port, and connection string.
3. Confirm the target user can createCollection, dropCollection, createIndex, insert, and listCollections.
4. Register Microsoft.DataMigration once in the subscription.

az provider register --namespace Microsoft.DataMigration

az provider show --namespace Microsoft.DataMigration --query registrationState -o tsv

Wait until the registration state is Registered.

## **8.3 Prepare the source account**

Microsoft recommends a source migration user with readAnyDatabase and clusterMonitor on admin. The lab application user has clusterMonitor plus readWrite on project\_tasks\_db, but it does not have readAnyDatabase. Ask a MongoDB administrator to create a temporary native migration user or grant the required roles before starting the wizard.

use admin

db.createUser({

user: "<migration-user>",

pwd: "<strong-temporary-password>",

roles: [

{ role: "readAnyDatabase", db: "admin" },

{ role: "clusterMonitor", db: "admin" }

]

})

Run this in mongosh while authenticated as a user with user-administration privileges. Remove the temporary user after migration.

## **8.4 Run a premigration assessment**

Complete the assessment offered by the migration tooling before creating the job. Resolve incompatible commands, data types, index definitions, and other warnings. Record accepted exceptions in the migration change record.

# **9. Install and open the VS Code extensions**

1. In Visual Studio Code, open Extensions with Ctrl+Shift+X.
2. Install Azure DocumentDB Migration Extension from https://aka.ms/azure-documentdb-migration-extension.
3. Allow installation of the prerequisite DocumentDB for Visual Studio Code extension.
4. Reload Visual Studio Code if prompted, then sign in to Azure using the intended tenant and subscription.

Official procedure: [Migrate MongoDB using Azure DocumentDB Migration Extension](https://learn.microsoft.com/en-us/azure/documentdb/how-to-migrate-vs-code-extension)

# **10. Connect the extension to source MongoDB**

1. Open the DocumentDB view in the Visual Studio Code activity bar.
2. Under Document DB Connections, select Add New Connection.
3. Choose Connection String.
4. Paste a source connection string that uses the temporary migration user and authSource=admin. Base the host and port on PublicIpAddress and MongoPort in parameters.json.

mongodb://<migration-user>:<encoded-password>@<PublicIpAddress>:<MongoPort>/?authSource=admin

1. Expand the new connection and confirm that project\_tasks\_db and its three collections are visible.

|  |
| --- |
| **Local connectivity requirement**  The wizard needs local connectivity to source and target while it enumerates databases and submits the job. After submission, Azure DMS performs the transfer and VS Code can be closed. |

# **11. Create the migration job**

Right-click the expanded source connection, select Data Migration, select Migration to Azure DocumentDB, and then select Migrate to Azure DocumentDB. Complete all seven wizard steps.

## **11.1 Step 1 - Create job**

* Enter a descriptive job name, for example mongolab-project-tasks-offline-20260901.
* Select Offline for this lab. Select Online only after enabling and validating ChangeStream.
* Select Public for the current VM architecture. Select Private only when both network paths are prepared.

## **11.2 Step 2 - Select target**

* Select the target subscription, resource group, and Azure DocumentDB account.
* Enter the native Azure DocumentDB connection string.
* Add the IP shown by the wizard to the Azure DocumentDB firewall.

## **11.3 Step 3 - Select DMS**

* Choose an existing Azure Database Migration Service in the intended region or select Create DMS.
* One DMS per region can serve multiple public migration jobs.

## **11.4 Step 4 - Configure public connectivity**

The wizard displays one or more DMS static IP addresses. Allow each address on both endpoints. For the source VM, add temporary NSG rules without rerunning deploy.ps1, because rerunning the installer deletes the source resource group.

$resourceGroup = "<ResourceGroupName>"

$nsgName = "ng<ResourceToken>1" # confirm the actual NSG name in Azure

$dmsIp = "<DMS\_STATIC\_IP>"

az network nsg rule create --resource-group $resourceGroup --nsg-name $nsgName `

--name AllowMongoFromDms1 --priority 121 --direction Inbound --access Allow `

--protocol Tcp --source-address-prefixes "$dmsIp/32" --destination-port-ranges 27017

Use a unique name and priority for each additional DMS IP. Add the same DMS IPs to the Azure DocumentDB firewall through the wizard or portal.

## **11.5 Step 5 - Select collections**

* Select project\_tasks\_db.users, project\_tasks\_db.projects, and project\_tasks\_db.tasks.
* Select every required collection now; collections cannot be added after the job is created.

## **11.6 Step 6 - Configure collections**

* For an empty lab target, choose overwrite only if the wizard reports that a target collection already exists and replacement is intended.
* Choose unsharded unless capacity testing demonstrates that sharding is required.
* Choose Copy indexes from source so the four task indexes are migrated. Unique indexes are built before the initial load and nonunique indexes afterward.

## **11.7 Step 7 - Confirm and start**

* Review source, target, mode, connectivity, DMS, collections, overwrite behavior, sharding, and indexing.
* Select Start Migration. The extension opens View Existing Jobs.

# **12. Monitor, validate, and cut over**

## **12.1 Monitor the job**

* Use View Existing Jobs and select the correct DMS. Status refreshes automatically.
* Select the job row to inspect collection-level status and failures.
* Offline jobs complete automatically. Jobs can be paused and resumed at a logical point.

## **12.2 Validate the target**

1. Connect to Azure DocumentDB with the DocumentDB extension or mongosh.
2. Confirm project\_tasks\_db contains users, projects, and tasks.
3. Compare source and target document counts. Defaults are 20 users, 500 projects, and 50,000 tasks.
4. Confirm the expected indexes exist on tasks: project\_id, assigned\_user\_id, status, and dependencies.
5. Sample task documents and verify ObjectId references, dependencies arrays, statuses, and timestamps.

use project\_tasks\_db

db.users.countDocuments({})

db.projects.countDocuments({})

db.tasks.countDocuments({})

db.tasks.getIndexes()

db.tasks.findOne({})

## **12.3 Online migration cutover**

Skip this subsection for offline mode. For an online job: wait for initial load to finish, stop all writes to the source, monitor Time Since Last Change, wait for Replication Changes Played to stabilize, compare source and target counts, then select Cutover. Cutting over before synchronization can lose data.

## **12.4 Point the application to Azure DocumentDB**

1. Back up parameters.json.
2. Use parameters-editor.html to replace MongoUri with the Azure DocumentDB native connection string. Preserve its required TLS and authentication options.
3. Keep MongoDatabase as project\_tasks\_db unless the target uses a deliberately different database name.
4. Do not run seed\_mongo.py against the target.
5. Start python app.py, call /health, and repeat the UI checks from Section 7.
6. Keep the source unchanged until business and technical validation is complete.

# **13. Rollback and cleanup**

## **13.1 Rollback**

* Stop application writes to the target.
* Restore the backed-up source MongoUri in parameters.json.
* Start app.py and verify /health plus document counts.
* Investigate and reconcile any writes accepted by the target after cutover before retrying.

## **13.2 Remove temporary migration access**

az network nsg rule delete --resource-group <ResourceGroupName> --nsg-name <NsgName> --name AllowMongoFromDms1

use admin

db.dropUser("<migration-user>")

* Remove every temporary DMS IP from the source NSG and target firewall.
* Delete an unused DMS only after confirming it is not shared by other migration jobs.
* Retain the source for the agreed rollback window, then remove it with the approved cleanup process.

# **14. Troubleshooting**

| **Symptom** | **Likely cause** | **Action** |
| --- | --- | --- |
| Source connection times out | NSG or source address is not allowed | Test port 27017; add the local or DMS /32 rule |
| Target connection times out | DocumentDB firewall or DNS | Allow the displayed IP and test target port 10260 |
| Authentication failed | Wrong auth database, credentials, or mechanism | Use native credentials and verify authSource=admin |
| Database or collections not listed | Source role is insufficient | Grant readAnyDatabase and clusterMonitor to the migration user |
| Indexes fail | Unsupported or incompatible index definition | Review assessment and collection-level job details |
| Private peering fails | CIDR overlap, lock, RBAC, or wrong VNet | Use a nonoverlapping /24; validate routes, roles, and locks |
| Application fails after switch | Target URI, TLS options, firewall, or compatibility | Restore source URI, inspect error, then correct target settings |

Extension logs on Windows are stored in C:\Users\<username>\.dmamongo\logs\. Include relevant errors, job ID, timestamps, connectivity test results, and collection status when escalating.

# **15. Known migration limitations**

* Existing MongoDB views are not migrated by the extension; recreate them manually on the target.
* Internal databases admin, local, and system config are skipped.
* Collections beginning with system. are skipped.
* Database and collection names cannot be changed during migration.
* Private mode supports one active job per virtual network; use different virtual networks for concurrent private jobs.
* For environments that prohibit Microsoft-hosted DMS networking, use the documented self-hosted Kubernetes migration option.

# **16. Operational checklist**

| **Phase** | **Completion evidence** |
| --- | --- |
| Configuration | Secrets replaced; source CIDR, region, SKU, ports, and seed volume reviewed |
| Deployment | deploy.ps1 completed; cloud-init and mongod healthy |
| Data load | Seed output and source collection counts recorded |
| Application | Dashboard, pages, API, and /health validated |
| Assessment | Warnings resolved or formally accepted |
| Connectivity | Local, DMS, source, and target firewall paths validated |
| Migration | All three collections completed with no unresolved failures |
| Validation | Counts, indexes, samples, and application behavior match |
| Cutover | Target URI applied; source retained for rollback window |
| Cleanup | Temporary user and firewall rules removed |

# **17. References**

[Microsoft Learn: Migrate MongoDB using Azure DocumentDB Migration Extension](https://learn.microsoft.com/en-us/azure/documentdb/how-to-migrate-vs-code-extension)

[Azure DocumentDB Migration Extension installation](https://aka.ms/azure-documentdb-migration-extension)

Project operational source: README.md, deploy.ps1, parameters.json, seed\_mongo.py, and app.py in the mongolabmigration workspace.
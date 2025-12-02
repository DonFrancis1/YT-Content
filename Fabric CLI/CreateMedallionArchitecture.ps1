<#
.SYNOPSIS
    Creates a Medallion Architecture in Microsoft Fabric using Fabric CLI
    
.DESCRIPTION
    This script creates a single workspace with three lakehouses representing
    the medallion architecture layers: Bronze (raw), Silver (cleansed), and Gold (curated)
    Includes interactive capacity selection during deployment.
    IDEMPOTENT: Safe to run multiple times - checks for existing items and skips creation.
    
.PARAMETER WorkspaceName
    Name of the workspace to create (default: "Medallion_Architecture")
    
.PARAMETER CapacityName
    Name of the Fabric capacity to assign the workspace to (optional)
    If not specified, script will offer interactive selection
    
.PARAMETER Force
    Force recreation of existing items (use with caution)
    
.EXAMPLE
    .\Create-MedallionArchitecture.ps1
    
.EXAMPLE
    .\Create-MedallionArchitecture.ps1 -WorkspaceName "MyDataPlatform"
    
.EXAMPLE
    .\Create-MedallionArchitecture.ps1 -WorkspaceName "MyDataPlatform" -CapacityName "Production-Capacity"
    
.EXAMPLE
    .\Create-MedallionArchitecture.ps1 -WorkspaceName "MyDataPlatform" -Force
    
.NOTES
    Author: Francis Folaranmi
    Requires: Fabric CLI (fab) installed and authenticated
    Prerequisites: 
    - Python 3.10+ installed
    - Fabric CLI installed: pip install ms-fabric-cli
    - Authenticated to Fabric: fab auth login
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "Medallion_Architecture",
    
    [Parameter(Mandatory = $false)]
    [string]$CapacityName = "",
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Set error action preference
$ErrorActionPreference = "Stop"

#region Helper Functions

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if Fabric CLI is installed
function Test-FabricCLI {
    try {
        $fabVersion = fab --version 2>&1
        Write-ColorOutput "✓ Fabric CLI is installed: $fabVersion" -Color Green
        return $true
    }
    catch {
        Write-ColorOutput "✗ Fabric CLI is not installed or not in PATH" -Color Red
        Write-ColorOutput "Install it using: pip install ms-fabric-cli" -Color Yellow
        return $false
    }
}

# Function to check authentication status
function Test-FabricAuth {
    try {
        # Try to list workspaces to verify authentication
        $result = fab ls 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput "✓ Successfully authenticated to Microsoft Fabric" -Color Green
            return $true
        }
        else {
            Write-ColorOutput "✗ Not authenticated to Microsoft Fabric" -Color Red
            Write-ColorOutput "Authenticate using: fab auth login" -Color Yellow
            return $false
        }
    }
    catch {
        Write-ColorOutput "✗ Authentication check failed: $_" -Color Red
        return $false
    }
}

# Helper function to convert fixed-width table to objects
function Convert-FixedWidthTableToObjects {
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string[]]$InputLines
    )
    
    begin {
        $allLines = @()
    }
    
    process {
        $allLines += $InputLines
    }
    
    end {
        if ($allLines.Count -lt 2) { return @() }
        
        $headers = $allLines[0] -split '\s{2,}'
        $result = @()
        
        for ($i = 1; $i -lt $allLines.Count; $i++) {
            if ([string]::IsNullOrWhiteSpace($allLines[$i])) { continue }
            
            $values = $allLines[$i] -split '\s{2,}'
            $obj = @{}
            for ($j = 0; $j -lt [Math]::Min($headers.Count, $values.Count); $j++) {
                $obj[$headers[$j].Trim()] = $values[$j].Trim()
            }
            $result += [PSCustomObject]$obj
        }
        
        return $result
    }
}

# Function to get available capacities
function Get-AvailableCapacities {
    Write-ColorOutput "Retrieving available Fabric capacities..." -Color Cyan
    
    try {
        # Use fab ls .capacities to list capacities (more reliable)
        $result = fab ls .capacities -l 2>&1
        
        if ($LASTEXITCODE -eq 0 -and $result) {
            # Convert the table output to objects
            $capacities = $result | Convert-FixedWidthTableToObjects
            
            # Filter out reserved capacities
            $filtered = $capacities | Where-Object { $_.name -notlike "*Reserved*" }
            
            if ($filtered -and $filtered.Count -gt 0) {
                Write-ColorOutput "✓ Found $($filtered.Count) available capacity(ies)" -Color Green
                return $filtered
            }
            else {
                Write-ColorOutput "⚠ No non-reserved capacities found" -Color Yellow
                
                # Check if user has trial capacity by checking existing workspaces
                Write-ColorOutput "Checking for trial/shared capacity..." -Color Cyan
                $workspaces = fab ls 2>&1 | Out-String
                
                if ($workspaces -ne "") {
                    Write-ColorOutput "✓ Trial/shared capacity should be available for first workspace" -Color Green
                }
                
                return @()
            }
        }
        else {
            Write-ColorOutput "⚠ Could not retrieve dedicated capacities" -Color Yellow
            Write-ColorOutput "✓ Will proceed with trial/shared capacity" -Color Green
            return @()
        }
    }
    catch {
        Write-ColorOutput "⚠ Error retrieving capacities: $_" -Color Yellow
        Write-ColorOutput "✓ Will proceed with trial/shared capacity" -Color Green
        return @()
    }
}

# Function to select capacity interactively
function Select-Capacity {
    param([array]$Capacities)
    
    if ($Capacities.Count -eq 0) {
        Write-ColorOutput "`n✗ No capacities available to select." -Color Red
        return ""
    }
    
    # Auto-select if only one capacity
    if ($Capacities.Count -eq 1) {
        $selectedName = $Capacities[0].name + ".capacity"
        Write-ColorOutput "`n✓ Auto-selected capacity: $($Capacities[0].name)" -Color Green
        return $selectedName
    }
    
    Write-Host "`n================================================" -ForegroundColor Cyan
    Write-Host "  Available Fabric Capacities" -ForegroundColor Cyan
    Write-Host "================================================`n" -ForegroundColor Cyan
    
    for ($i = 0; $i -lt $Capacities.Count; $i++) {
        $cap = $Capacities[$i]
        Write-Host "[$i] $($cap.name)" -ForegroundColor White
        
        # Display additional properties if available
        if ($cap.PSObject.Properties['sku']) {
            Write-Host "    SKU: $($cap.sku)" -ForegroundColor Gray
        }
        if ($cap.PSObject.Properties['state']) {
            $stateColor = if ($cap.state -eq "Active") { "Green" } else { "Yellow" }
            Write-Host "    State: $($cap.state)" -ForegroundColor $stateColor
        }
        Write-Host ""
    }
    
    do {
        $selection = Read-Host "Select capacity (0-$(($Capacities.Count - 1)))"
        $valid = $selection -match '^\d+$' -and [int]$selection -ge 0 -and [int]$selection -lt $Capacities.Count
        
        if (-not $valid) {
            Write-Host "Invalid selection. Please enter a number between 0 and $(($Capacities.Count - 1))" -ForegroundColor Red
        }
    } while (-not $valid)
    
    $index = [int]$selection
    $selectedCapacity = $Capacities[$index]
    $selectedName = $selectedCapacity.name + ".capacity"
    Write-ColorOutput "`n✓ Selected capacity: $($selectedCapacity.name)" -Color Green
    return $selectedName
}

# Function to check if workspace exists
function Test-WorkspaceExists {
    param([string]$Name)
    
    Write-ColorOutput "Checking if workspace '$Name' exists..." -Color Cyan
    
    try {
        $workspaces = fab ls 2>&1 | Out-String
        
        if ($workspaces -match "$Name\.Workspace") {
            Write-ColorOutput "✓ Workspace '$Name' already exists" -Color Yellow
            return $true
        }
        else {
            Write-ColorOutput "✓ Workspace '$Name' does not exist (ready to create)" -Color Green
            return $false
        }
    }
    catch {
        Write-ColorOutput "✗ Error checking workspace: $_" -Color Red
        return $false
    }
}

# Function to check if lakehouse exists in workspace
function Test-LakehouseExists {
    param(
        [string]$WorkspaceName,
        [string]$LakehouseName
    )
    
    try {
        $items = fab ls "$WorkspaceName.Workspace" 2>&1 | Out-String
        
        if ($items -match "$LakehouseName\.Lakehouse") {
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        Write-ColorOutput "  ⚠ Warning: Error checking lakehouse existence: $_" -Color Yellow
        return $false
    }
}

# Function to check if folder exists in lakehouse
function Test-LakehouseFolderExists {
    param(
        [string]$WorkspaceName,
        [string]$LakehouseName,
        [string]$FolderPath
    )
    
    try {
        $folders = fab ls "$WorkspaceName.Workspace/$LakehouseName.Lakehouse/Files" 2>&1 | Out-String
        
        if ($folders -match "$FolderPath") {
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        return $false
    }
}

# Function to create a workspace
function New-FabricWorkspace {
    param(
        [string]$Name,
        [string]$Capacity
    )
    
    if ($Capacity -eq "") {
        Write-ColorOutput "✗ Error: Capacity is required to create workspace" -Color Red
        return $false
    }
    
    Write-ColorOutput "`nCreating workspace: $Name" -Color Cyan
    Write-ColorOutput "Using capacity: $Capacity" -Color Cyan
    
    try {
        # Create with capacity
        fab create "$Name.Workspace" -P capacityname=$Capacity
        
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput "✓ Successfully created workspace: $Name" -Color Green
            return $true
        }
        else {
            Write-ColorOutput "✗ Failed to create workspace: $Name" -Color Red
            return $false
        }
    }
    catch {
        Write-ColorOutput "✗ Error creating workspace: $_" -Color Red
        return $false
    }
}

# Function to create a lakehouse
function New-FabricLakehouse {
    param(
        [string]$WorkspaceName,
        [string]$LakehouseName,
        [bool]$CheckExists = $true
    )
    
    # Check if lakehouse already exists
    if ($CheckExists) {
        if (Test-LakehouseExists -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName) {
            if ($Force) {
                Write-ColorOutput "  ⚠ Lakehouse '$LakehouseName' exists - Force flag detected but recreation not implemented" -Color Yellow
                Write-ColorOutput "  ℹ Skipping creation and using existing lakehouse" -Color Cyan
                return $true
            }
            else {
                Write-ColorOutput "  ✓ Lakehouse '$LakehouseName' already exists - skipping creation" -Color Green
                return $true
            }
        }
    }
    
    Write-ColorOutput "  Creating lakehouse: $LakehouseName" -Color Cyan
    
    try {
        # Create lakehouse in the workspace using fab create
        fab create "$WorkspaceName.Workspace/$LakehouseName.Lakehouse"
        
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput "  ✓ Successfully created lakehouse: $LakehouseName" -Color Green
            return $true
        }
        else {
            Write-ColorOutput "  ✗ Failed to create lakehouse: $LakehouseName" -Color Red
            return $false
        }
    }
    catch {
        Write-ColorOutput "  ✗ Error creating lakehouse: $_" -Color Red
        return $false
    }
}

# Function to create folder structure in lakehouse
function New-LakehouseFolder {
    param(
        [string]$WorkspaceName,
        [string]$LakehouseName,
        [string]$FolderPath,
        [bool]$CheckExists = $true
    )
    
    # Check if folder already exists
    if ($CheckExists) {
        if (Test-LakehouseFolderExists -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName -FolderPath $FolderPath) {
            Write-ColorOutput "    ✓ Folder '$FolderPath' already exists - skipping" -Color DarkGray
            return $true
        }
    }
    
    Write-ColorOutput "    Creating folder: $FolderPath" -Color Gray
    
    try {
        fab create "$WorkspaceName.Workspace/$LakehouseName.Lakehouse/Files/$FolderPath" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput "    ✓ Created folder: $FolderPath" -Color DarkGreen
            return $true
        }
        else {
            Write-ColorOutput "    ⚠ Warning: Could not create folder: $FolderPath" -Color Yellow
            return $false
        }
    }
    catch {
        Write-ColorOutput "    ⚠ Warning: Error creating folder: $_" -Color Yellow
        return $false
    }
}

#endregion

#region Main Script Execution

# Display banner
Write-ColorOutput "`n================================================" -Color Cyan
Write-ColorOutput "  Medallion Architecture Deployment Script" -Color Cyan
Write-ColorOutput "  Microsoft Fabric - Using Fabric CLI" -Color Cyan
Write-ColorOutput "================================================`n" -Color Cyan

# Step 1: Validate prerequisites
Write-ColorOutput "Step 1: Validating prerequisites..." -Color Magenta

if (-not (Test-FabricCLI)) {
    exit 1
}

if (-not (Test-FabricAuth)) {
    Write-ColorOutput "`nPlease authenticate first using: fab auth login" -Color Yellow
    exit 1
}

# Step 2: Handle capacity selection
Write-ColorOutput "`nStep 2: Capacity configuration..." -Color Magenta

$availableCapacities = Get-AvailableCapacities

if ($availableCapacities.Count -eq 0) {
    Write-ColorOutput "`n✗ No capacities found. Cannot create workspace without a capacity." -Color Red
    Write-ColorOutput "Please ensure you have access to at least one Fabric capacity." -Color Yellow
    Write-ColorOutput "`nTo check capacities manually, run: fab ls .capacities -l" -Color Gray
    exit 1
}

if ($CapacityName -eq "") {
    # No capacity specified, MUST select one interactively
    Write-ColorOutput "`nInteractive capacity selection:" -Color Cyan
    $CapacityName = Select-Capacity -Capacities $availableCapacities
    
    if ($CapacityName -eq "") {
        Write-ColorOutput "`n✗ Capacity selection is required. Cannot proceed without capacity." -Color Red
        exit 1
    }
}
else {
    # Capacity specified, validate it exists
    Write-ColorOutput "`nValidating specified capacity: $CapacityName" -Color Cyan
    
    # Check if the capacity name already has .capacity suffix
    $searchName = if ($CapacityName -like "*.capacity") { 
        $CapacityName.Replace(".capacity", "")
    } else { 
        $CapacityName 
    }
    
    $found = $availableCapacities | Where-Object { $_.name -eq $searchName }
    
    if (-not $found) {
        Write-ColorOutput "`n✗ Specified capacity '$CapacityName' not found." -Color Red
        Write-ColorOutput "Please select from available capacities:" -Color Yellow
        $CapacityName = Select-Capacity -Capacities $availableCapacities
        
        if ($CapacityName -eq "") {
            Write-ColorOutput "`n✗ Capacity selection is required. Cannot proceed without capacity." -Color Red
            exit 1
        }
    }
    else {
        # Ensure it has .capacity suffix
        if (-not ($CapacityName -like "*.capacity")) {
            $CapacityName = $CapacityName + ".capacity"
        }
        Write-ColorOutput "✓ Capacity '$CapacityName' found and validated" -Color Green
    }
}

Write-ColorOutput "`n✓ Capacity configuration complete - continuing deployment..." -Color Green

# Step 3: Check if workspace exists
Write-ColorOutput "`nStep 3: Checking workspace..." -Color Magenta

$workspaceExists = Test-WorkspaceExists -Name $WorkspaceName

if ($workspaceExists) {
    Write-ColorOutput "✓ Workspace exists - will verify/create lakehouses within it" -Color Green
}
else {
    # Step 4: Create workspace
    Write-ColorOutput "`nStep 4: Creating workspace..." -Color Magenta
    
    if (-not (New-FabricWorkspace -Name $WorkspaceName -Capacity $CapacityName)) {
        Write-ColorOutput "`nDeployment failed at workspace creation" -Color Red
        exit 1
    }
    
    # Brief pause to allow workspace to be fully provisioned
    Start-Sleep -Seconds 2
}

# Step 5: Create lakehouses
Write-ColorOutput "`nStep 5: Creating medallion architecture lakehouses..." -Color Magenta

$lakehouses = @(
    @{Name = "LH_Bronze"; Description = "Raw/Landing zone for ingested data"},
    @{Name = "LH_Silver"; Description = "Cleansed and conformed data"},
    @{Name = "LH_Gold"; Description = "Business-level aggregated and curated data"}
)

$createdLakehouses = @()
$existingLakehouses = @()
$failedLakehouses = @()

foreach ($lakehouse in $lakehouses) {
    Write-ColorOutput "`n  Processing: $($lakehouse.Name)" -Color White
    Write-ColorOutput "  Purpose: $($lakehouse.Description)" -Color Gray
    
    $lakehouseCreated = New-FabricLakehouse -WorkspaceName $WorkspaceName -LakehouseName $lakehouse.Name -CheckExists $true
    
    if ($lakehouseCreated) {
        # Track whether this was newly created or already existed
        if (Test-LakehouseExists -WorkspaceName $WorkspaceName -LakehouseName $lakehouse.Name) {
            $existingLakehouses += $lakehouse.Name
        }
        else {
            $createdLakehouses += $lakehouse.Name
        }
        
        # Create folder structure for each lakehouse
        Write-ColorOutput "  Setting up folder structure..." -Color Gray
        
        # Create standard folders based on lakehouse type
        switch ($lakehouse.Name) {
            "LH_Bronze" {
                $folders = @("raw", "landing", "archive")
            }
            "LH_Silver" {
                $folders = @("cleansed", "conformed", "validated")
            }
            "LH_Gold" {
                $folders = @("curated", "aggregated", "published")
            }
        }
        
        foreach ($folder in $folders) {
            New-LakehouseFolder -WorkspaceName $WorkspaceName `
                                -LakehouseName $lakehouse.Name `
                                -FolderPath $folder `
                                -CheckExists $true | Out-Null
        }
    }
    else {
        Write-ColorOutput "  ✗ Failed: $($lakehouse.Name)" -Color Red
        $failedLakehouses += $lakehouse.Name
    }
}

# Step 6: Summary
Write-ColorOutput "`n================================================" -Color Cyan
Write-ColorOutput "  Deployment Summary" -Color Cyan
Write-ColorOutput "================================================`n" -Color Cyan

Write-ColorOutput "Workspace: $WorkspaceName" -Color White
if ($CapacityName -ne "") {
    Write-ColorOutput "Capacity: $CapacityName" -Color White
}
else {
    Write-ColorOutput "Capacity: Shared/Trial (No dedicated capacity)" -Color Yellow
}

if ($createdLakehouses.Count -gt 0) {
    Write-ColorOutput "`nNewly Created Lakehouses:" -Color White
    foreach ($lh in $createdLakehouses) {
        Write-ColorOutput "  ✓ $lh" -Color Green
    }
}

if ($existingLakehouses.Count -gt 0) {
    Write-ColorOutput "`nExisting Lakehouses (Verified):" -Color White
    foreach ($lh in $existingLakehouses) {
        Write-ColorOutput "  ✓ $lh (already existed)" -Color Cyan
    }
}

if ($failedLakehouses.Count -gt 0) {
    Write-ColorOutput "`nFailed Lakehouses:" -Color White
    foreach ($lh in $failedLakehouses) {
        Write-ColorOutput "  ✗ $lh" -Color Red
    }
}

$totalSuccess = $createdLakehouses.Count + $existingLakehouses.Count
Write-ColorOutput "`n================================================" -Color Cyan
Write-ColorOutput "Total Lakehouses: $totalSuccess of $($lakehouses.Count)" -Color White

if ($failedLakehouses.Count -eq 0) {
    Write-ColorOutput "✓ Deployment completed successfully!" -Color Green
}
else {
    Write-ColorOutput "⚠ Deployment completed with some failures" -Color Yellow
}

Write-ColorOutput "================================================`n" -Color Cyan

#endregion
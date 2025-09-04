$totalSpaceCleared = 0
$totalFilesDeleted = 0
$currentDate = Get-Date
$formattedDate = $currentDate.ToString("dd/MM/yyyy HH:mm")


$LogFile = "C:\Temp\RM01-DiskClear.log"
if (-not (Test-Path $LogFile)) {
    New-Item -Path $LogFile -ItemType File
}

function Write-Log {
    param ([string]$Text)
    try {
        # Pulling the current date for each addition to the log is unnecessary compute
        Add-Content -Path $LogFile -Value "[$formattedDate] - $Text" -ErrorAction Stop
    } catch {
        Write-Warning "An error occurred writing to log file: $_"
    }
}

# Combines all PS data files into one variable
# psd1 files will only live in the path specified below
$IndividualDeletionRules = Get-ChildItem -Path "C:\Scripts\RM01\Rules\RM01-Cus*.psd1" | Import-PowerShellDataFile -ErrorAction Stop
$DeletionRules = @{}
try {
    $IndividualDeletionRules | ForEach-Object {
        $DeletionRules += $_
    }
} catch {
    Write-Error "An error occurred while consolidating rules: $_"
    throw
}

# Each rule gets passed through the pipeline instead of assigned to a single variable
# This allows deletions to occur in a stream as opposed to in big chunks
# For large groups of files, potential thousands of objects will not be stored in memory
$DeletionRules.GetEnumerator() | ForEach-Object -Process {
    $rule = $_
    $wildcardPath = $rule.Key
    
    # Allows for multiple wildcards within file paths
    $resolvedPaths = try { Resolve-Path -Path $wildcardPath -ErrorAction SilentlyContinue } catch {}
    
    if ($null -eq $resolvedPaths) {
        Write-Warning "Path pattern '$wildcardPath' could not be resolved. Skipping."
        return
    }

    # Using custom objects with only necessary properties instead of PathInfo objects
    foreach ($pathInfo in $resolvedPaths) {
        [PSCustomObject]@{
            Path = $pathInfo.Path
            FileNames = $rule.Value.FileNames
            RetentionDays = $rule.Value.RetentionDays
            Depth = $rule.Value.Depth
        }
    }
} | ForEach-Object -Process {
    $ruleSubPath = $_

    if (-not (Test-Path -Path $ruleSubPath.Path -PathType Container)) {
        Write-Warning "Resolved path is not a valid container, skipping: $($ruleSubPath.Path)"
        return 
    }

    $params = @{
        Path = $ruleSubPath.Path
        File = $true        
        ErrorAction = "SilentlyContinue"
    }


    if (0 -ne $ruleSubPath.Depth) {
        $params['Depth'] = $ruleSubPath.Depth
        $params['Recurse'] = $true 
    }

    # Checks all files and filters based on filename/extension or last modified
    $retentionThreshold = $currentDate.AddDays(-$ruleSubPath.RetentionDays)
    Get-ChildItem @params | Where-Object { 
        $filtered = $_
        $dateTest = $filtered.LastWriteTime -lt $retentionThreshold 
        
        $nameMatch = $false
        if ($dateTest) {
            $nameMatch = ($ruleSubPath.FileNames | Where-Object { $filtered.Name -like $_ } -ErrorAction SilentlyContinue).Count -gt 0
        }
        
        return $nameMatch -and $dateTest
    }

} | ForEach-Object -Process {
    $file = $_
    try {
        Write-Log "Deleting file: $($file.FullName) - Last modified $($file.LastWriteTime)"
        Remove-Item -Path $file.FullName -Force -WhatIf -ErrorAction Stop
        
        $totalSpaceCleared += $file.Length
        $totalFilesDeleted++
    } catch {
        Write-Error "Failed to delete file: $($file.FullName). Error: $_"
    }
}

$spaceClearedInGB = [math]::Round($totalSpaceCleared / 1GB, 2)
Write-Log "Total files processed for deletion: $totalFilesDeleted"
Write-Log "Total space cleared: $spaceClearedInGB GB"

try {
    # ClearedDiskSpace field defaults to 0 if not set before
    $currentCleared = [float](Ninja-Property-Get -Name cleareddiskspace)
    $newValue = [math]::Round($currentCleared + $spaceClearedInGB, 2)
    Ninja-Property-Set -Name cleareddiskspace -Value $newValue
}
catch {
   Write-Error "Error updating cleareddiskspace custom field. Error: $_"
}
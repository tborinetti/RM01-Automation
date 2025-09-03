$totalSpaceCleared = 0
$totalFilesDeleted = 0
$currentDate = Get-Date
$LogFile = "C:\Temp\RM01-DiskClear.log"
if (-not (Test-Path $LogFile)) {
    New-Item -Path $LogFile -ItemType File
}

$formattedDate = $currentDate.ToString("dd/MM/yyyy HH:mm")
function Write-Log {
    param ([string]$Text)
    try {
        # Add-Content -Path $LogFile -Value "[$(Get-Date -Format "dd/MM/yyyy HH:mm")] - $Text" -ErrorAction Stop
        Add-Content -Path $LogFile -Value "[$formattedDate] - $Text" -ErrorAction Stop
    } catch {
        Write-Warning "An error occurred writing to log file: $_"
    }
}


$IndividualDeletionRules = Get-ChildItem -Path "C:\Scripts\RM01\Rules\RM01*.psd1" | Import-PowerShellDataFile -ErrorAction Stop
$DeletionRules = @{}
try {
    $IndividualDeletionRules | ForEach-Object {
        $DeletionRules += $_
    }
} catch {
    Write-Error "An error occurred while consolidating rules: $_"
    throw
}



$DeletionRules.GetEnumerator() | ForEach-Object -Process {
    $rule = $_
    $wildcardPath = $rule.Key
    
    $resolvedPaths = try { Resolve-Path -Path $wildcardPath -ErrorAction SilentlyContinue } catch {}
    
    if ($null -eq $resolvedPaths) {
        Write-Warning "Path pattern '$wildcardPath' could not be resolved. Skipping."
        return
    }

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
        #Remove-Item -Path $file.FullName -Force -WhatIf -ErrorAction Stop
        
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
    $currentCleared = [float](Ninja-Property-Get -Name cleareddiskspace)
    $newValue = [math]::Round($currentCleared + $spaceClearedInGB, 2)
    Ninja-Property-Set -Name cleareddiskspace -Value $newValue
}
catch {
   Write-Error "Error updating cleareddiskspace custom field. Error: $_"
}
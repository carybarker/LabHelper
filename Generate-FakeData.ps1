<#
.SYNOPSIS
    Generates fake data files and folders to a specified total size, optionally filling with Project Gutenberg text.

.DESCRIPTION
    This script creates a specified directory structure and fills files with random
    or zero-byte content (default) or with text fetched from Project Gutenberg URLs.
    You can specify a total size (TargetSizeGB) for distribution, or provide individual
    sizes for each file in the FileList.

.PARAMETER DestinationPath
    The root directory where the fake data will be created.
    Defaults to '.\FakeData'.

.PARAMETER TargetSizeGB
    The total size of data to generate in Gigabytes. This is used for files
    in FileList that do not have an individual size specified.
    Defaults to 10 GB.

.PARAMETER FileList
    An array of relative file paths or PowerShell custom objects.
    - If a string (e.g., 'ProjectA\Document.txt'): The file's size will be
      determined by distributing the remaining TargetSizeGB evenly among
      files without specified sizes.
    - If a PSCustomObject (e.g., @{ Path = 'Images\photo.jpg'; SizeMB = 500 }):
      The file will be created with the specified 'SizeMB'.
    The script will create these files and their parent directories.
    If no files are specified or valid, a single large dummy file will be created.

.PARAMETER UseGutenbergData
    If set to $true, the script will fetch text from Project Gutenberg URLs
    and use it to fill the generated files. Otherwise, files will be filled
    with zero bytes (more efficient for very large files where content doesn't matter).

.PARAMETER GutenbergBookURLs
    An array of URLs pointing to plain text (.txt) files on Project Gutenberg.
    If UseGutenbergData is $true and this parameter is not provided, default
    URLs will be used.

.EXAMPLE
    # Example 1: Distribute 5GB evenly among three files, using Gutenberg data
    .\Generate-FakeData.ps1 -DestinationPath 'C:\Temp\MyFakeData' -TargetSizeGB 5 `
        -FileList @('Reports\Q1_Sales.xlsx', 'Data\users.csv', 'Logs\app.log') -UseGutenbergData

.EXAMPLE
    # Example 2: Specify individual file sizes (total will be 1GB + 2.5GB = 3.5GB).
    # The TargetSizeGB parameter is effectively ignored for these files, as they have explicit sizes.
    .\Generate-FakeData.ps1 -DestinationPath 'D:\TestEnv' `
        -FileList @(
            @{ Path = 'Docs\document.txt'; SizeMB = 1000 }, # 1 GB
            @{ Path = 'Media\video.mp4'; SizeMB = 2500 }   # 2.5 GB
        ) -UseGutenbergData

.EXAMPLE
    # Example 3: Mixed list - some with specified sizes, some distributed from remaining TargetSizeGB.
    # 'BigFile\archive.zip' will be 3GB.
    # The remaining 7GB (10GB - 3GB) will be distributed evenly between 'OtherData\logs.txt'
    # and 'MoreFiles\config.json' (3.5GB each).
    .\Generate-FakeData.ps1 -DestinationPath 'E:\HybridData' -TargetSizeGB 10 `
        -FileList @(
            @{ Path = 'BigFile\archive.zip'; SizeMB = 3000 }, # 3 GB explicitly
            'OtherData\logs.txt',                             # Remaining 7 GB distributed
            'MoreFiles\config.json'                           # ... between these two
        ) -UseGutenbergData

.NOTES
    - The script attempts to adhere to specified individual file sizes first.
    - For files without specified sizes, the remaining `TargetSizeGB` is distributed.
    - If all files in `FileList` have `SizeMB` specified, the `TargetSizeGB` parameter
      will not influence the generated file sizes; the sum of `SizeMB`s will be the total.
    - Generating large files with actual text content (UseGutenbergData $true)
      can be significantly slower than generating zero-byte files.
    - Ensure you have enough free space before running.
    - File content will be repeated if the target file size is larger than the
      downloaded Gutenberg text.
#>
function Generate-FakeData {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$false)]
        [string]$DestinationPath = '.\FakeData',

        [Parameter(Mandatory=$false)]
        [int]$TargetSizeGB = 10,

        [Parameter(Mandatory=$false)]
        [object[]]$FileList, # Changed to object[] to support PSCustomObject with size

        [Parameter(Mandatory=$false)]
        [switch]$UseGutenbergData,

        [Parameter(Mandatory=$false)]
        [string[]]$GutenbergBookURLs
    )

    $ErrorActionPreference = 'Stop' # Ensure script stops on errors

    try {
        $targetSizeBytes = [long]$TargetSizeGB * 1GB
        Write-Host "Overall Target total size (budget for distribution): $($TargetSizeGB) GB ($([Math]::Round($targetSizeBytes / 1MB, 2)) MB)"

        # Resolve the full path for the destination
        $fullDestinationPath = (Convert-Path $DestinationPath).TrimEnd('\/')

        # Ensure the destination directory exists
        if (-not (Test-Path $fullDestinationPath)) {
            Write-Host "Creating destination directory: '$fullDestinationPath'..."
            New-Item -ItemType Directory -Path $fullDestinationPath | Out-Null
        } else {
            Write-Host "Destination directory already exists: '$fullDestinationPath'."
        }

        # --- Process FileList to separate specified sizes from unspecified ---
        $filesWithSpecifiedSizes = @()
        $filesWithoutSpecifiedSizes = @()
        $specifiedSizesTotalBytes = 0

        # Handle case where no FileList is provided initially
        if (-not $FileList -or $FileList.Count -eq 0) {
            Write-Host "No specific files provided in FileList. Creating a single large dummy file for distribution."
            $FileList = @("dummy_data_0.bin")
        }

        foreach ($item in $FileList) {
            # Check if it's a simple string path
            if ($item -is [string]) {
                $filesWithoutSpecifiedSizes += $item
            }
            # Check if it's a Hashtable (and convert it) or already a PSCustomObject
            elseif ($item -is [System.Collections.Hashtable] -or ($item -is [System.Management.Automation.PSObject] -and $item.PSObject.Properties['Path'] -and $item.PSObject.Properties['SizeMB'])) {
                $processedItem = $item # Start with the item
                if ($item -is [System.Collections.Hashtable]) {
                    # Explicitly convert Hashtable to PSCustomObject
                    try {
                        $processedItem = [PSCustomObject]$item
                    } catch {
                        Write-Warning "Failed to convert Hashtable '$item' to PSCustomObject. It will be ignored: $($_.Exception.Message)"
                        continue
                    }
                }

                # Now check if the processed item (either original PSCustomObject or converted one) has the required properties
                if ($processedItem.PSObject.Properties['Path'] -and $processedItem.PSObject.Properties['SizeMB']) {
                    $path = $processedItem.Path
                    $sizeMB = $processedItem.SizeMB
                    if ($sizeMB -le 0) {
                        Write-Warning "File '$path' has an invalid SizeMB ($sizeMB). It will be treated as having no specified size."
                        $filesWithoutSpecifiedSizes += $path
                        continue
                    }
                    $fileSizeByte = [long]$sizeMB * 1MB
                    $filesWithSpecifiedSizes += [PSCustomObject]@{Path = $path; SizeBytes = $fileSizeByte}
                    $specifiedSizesTotalBytes += $fileSizeByte
                } else {
                    Write-Warning "Invalid item in FileList format: '$item'. Hashtable/PSCustomObject is missing 'Path' or 'SizeMB' properties. It will be ignored."
                }
            } else {
                Write-Warning "Invalid item in FileList format: '$item'. Expected string or Hashtable/PSCustomObject with 'Path' and 'SizeMB'. It will be ignored."
            }
        }

        $effectiveTotalFiles = $filesWithSpecifiedSizes.Count + $filesWithoutSpecifiedSizes.Count
        if ($effectiveTotalFiles -eq 0) {
            Write-Warning "No valid files found in FileList after processing. Exiting."
            return
        }

        # Calculate remaining target size for files without specified sizes
        $remainingTargetSizeBytes = $targetSizeBytes - $specifiedSizesTotalBytes
        $bytesPerUnspecifiedFile = 0

        if ($filesWithoutSpecifiedSizes.Count -gt 0) {
            if ($remainingTargetSizeBytes -le 0) {
                Write-Warning "Total explicitly specified file sizes ($([Math]::Round($specifiedSizesTotalBytes / 1GB, 2)) GB) already meet or exceed the overall TargetSizeGB ($TargetSizeGB GB)."
                Write-Warning "Files without specified sizes will be created with a minimal size (1 byte) to ensure existence."
                $bytesPerUnspecifiedFile = 1 # Create minimal file if no size left in the overall budget
            } else {
                $bytesPerUnspecifiedFile = [long]($remainingTargetSizeBytes / $filesWithoutSpecifiedSizes.Count)
                Write-Host "Remaining budget from TargetSizeGB for files without explicit sizes: $([Math]::Round($remainingTargetSizeBytes / 1MB, 2)) MB"
                Write-Host "Approximate size per file without explicit size: $([Math]::Round($bytesPerUnspecifiedFile / 1MB, 2)) MB"
            }
        }

        # --- Prepare the final list of files with their calculated/specified sizes ---
        $allFilesToCreate = @()
        foreach ($file in $filesWithSpecifiedSizes) {
            $allFilesToCreate += $file # These already have Path and SizeBytes
        }
        foreach ($path in $filesWithoutSpecifiedSizes) {
            $allFilesToCreate += [PSCustomObject]@{Path = $path; SizeBytes = $bytesPerUnspecifiedFile}
        }

        Write-Host "Total files to process: $($allFilesToCreate.Count)"
        Write-Host "--- Detailed File Size Plan ---"
        $expectedTotalGeneratedSize = 0
        foreach ($fileInfo in $allFilesToCreate) {
            Write-Host "  - File: '$($fileInfo.Path)' -> Will be $([Math]::Round($fileInfo.SizeBytes / 1MB, 2)) MB"
            $expectedTotalGeneratedSize += $fileInfo.SizeBytes
        }
        Write-Host "Expected total size from all files combined: $([Math]::Round($expectedTotalGeneratedSize / 1GB, 2)) GB"
        Write-Host "-----------------------------"

        $gutenbergContentBytes = $null

        if ($UseGutenbergData) {
            Write-Host "Fetching Project Gutenberg data..."
            $urlsToFetch = @()

            if ($GutenbergBookURLs) {
                $urlsToFetch = $GutenbergBookURLs
            } else {
                # Default Gutenberg books if none are specified
                $urlsToFetch = @(
                    'https://www.gutenberg.org/ebooks/31100.txt.utf-8', # Jane Austin collected works
                    'https://www.gutenberg.org/cache/epub/928/pg928.txt',  # Alice's Adventures in Wonderland
                    'https://www.gutenberg.org/ebooks/42324.txt.utf-8'   # Frankenstein
                )
                Write-Host "Using default Project Gutenberg book URLs."
            }

            $allText = New-Object System.Text.StringBuilder
            foreach ($url in $urlsToFetch) {
                Write-Host "Downloading: $url"
                try {
                    $webRequestResult = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction SilentlyContinue
                    if ($webRequestResult.StatusCode -eq 200) {
                        $allText.Append($webRequestResult.Content)
                    } else {
                        Write-Warning "Failed to download $url. Status Code: $($webRequestResult.StatusCode)"
                    }
                } catch {
                    Write-Warning "Could not download $url : $($_.Exception.Message)"
                }
            }
            if ($allText.Length -gt 0) {
                # Convert accumulated text to byte array (UTF8 by default for GetBytes)
                $gutenbergContentBytes = [System.Text.Encoding]::UTF8.GetBytes($allText.ToString())
                Write-Host "Downloaded $($gutenbergContentBytes.Length) bytes of Gutenberg content."
            } else {
                Write-Warning "No Gutenberg content downloaded. Files will be created with zero bytes."
                $UseGutenbergData = $false # Fallback to zero-byte filling
            }
        }

        # --- Create files ---
        for ($i = 0; $i -lt $allFilesToCreate.Count; $i++) {
            $fileInfo = $allFilesToCreate[$i]
            $relativePath = $fileInfo.Path
            $fileTargetSizeBytes = $fileInfo.SizeBytes # Use the calculated/specified size for this file

            $filePath = Join-Path -Path $fullDestinationPath -ChildPath $relativePath

            Write-Host "Processing file: '$filePath' (File $($i + 1) of $($allFilesToCreate.Count))"
            Write-Host "  Target size for this file: $([Math]::Round($fileTargetSizeBytes / 1MB, 2)) MB"

            # Create parent directories for the current file if they don't exist
            $parentDir = Split-Path -Path $filePath -Parent
            if (-not (Test-Path $parentDir)) {
                Write-Host "  Creating directory: '$parentDir'..."
                New-Item -ItemType Directory -Path $parentDir | Out-Null
            }

            if ($PSCmdlet.ShouldProcess($filePath, "Create dummy file of size $([Math]::Round($fileTargetSizeBytes / 1MB, 2)) MB")) {
                try {
                    $fileStream = New-Object System.IO.FileStream($filePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

                    if ($UseGutenbergData -and $gutenbergContentBytes -ne $null -and $gutenbergContentBytes.Length -gt 0) {
                        $currentBytesWritten = 0
                        $contentLength = $gutenbergContentBytes.Length
                        Write-Host "  Filling file with Gutenberg content..."

                        while ($currentBytesWritten -lt $fileTargetSizeBytes) {
                            $bytesToWrite = [System.Math]::Min($contentLength, $fileTargetSizeBytes - $currentBytesWritten)
                            $fileStream.Write($gutenbergContentBytes, 0, $bytesToWrite)
                            $currentBytesWritten += $bytesToWrite

                            # If we wrote less than the remaining needed, it means we consumed all available content
                            # and need to loop back to the beginning of the Gutenberg data.
                            # This condition means we wrote all the content, but still need more bytes.
                            # The loop will continue and start writing from the beginning of the Gutenberg content.
                        }
                        Write-Host "  Finished writing Gutenberg content to '$filePath'."
                    } else {
                        Write-Host "  Filling file with zero bytes (efficient for large files)..."
                        $fileStream.SetLength($fileTargetSizeBytes) # Efficiently creates a file of specified size with zeros
                    }

                    $fileStream.Close()
                    $fileStream.Dispose() # Release resources

                    Write-Host "  Created file '$filePath' with size $([System.IO.FileInfo]$filePath).Length bytes."
                } catch {
                    Write-Warning "  Could not create file '$filePath': $($_.Exception.Message)"
                }
            }
        }

        Write-Host "`nFake data generation complete!"
        Write-Host "Total files processed: $($allFilesToCreate.Count)"

        # Calculate actual total size created (optional, for verification)
        $actualTotalSize = (Get-ChildItem -Path $fullDestinationPath -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-Host "Actual total size generated across all files: $([Math]::Round($actualTotalSize / 1GB, 2)) GB"

    } catch {
        Write-Error "An error occurred: $($_.Exception.Message)"
        Write-Error "Script stopped."
    }
}

# Example usage:

# 1. Generate 10GB of fake data with default files, filled with zero bytes (original behavior)
# Generate-FakeData -DestinationPath 'C:\Temp\MyLabDataZero'

# 2. Generate 10GB of fake data using a custom file list, filled with default Gutenberg books
#    - TargetSizeGB (10GB) will be distributed among the three files.
# Generate-FakeData -DestinationPath 'C:\Temp\MyLabDataGutenberg' `
#    -FileList @(
#        'LabReports\Exp_A_Results.txt',
#        'Documents\ThesisDraft.docx',
#        'Archives\Project_Beta_Backup.zip'
#    ) -UseGutenbergData

# 3. Generate data with specific individual file sizes.
#    - The total size will be the sum of specified sizes (1GB + 2.5GB = 3.5GB).
#    - TargetSizeGB parameter is effectively ignored for these files.
# Generate-FakeData -DestinationPath 'D:\GutenbergTest' -UseGutenbergData `
#    -GutenbergBookURLs @(
#        'https://www.gutenberg.org/files/2701/2701-0.txt', # Moby Dick
#        'https://www.gutenberg.org/files/345/345-0.txt'   # Dracula
#    ) `
#    -FileList @(
#        @{ Path = 'Books\MobyDick.txt'; SizeMB = 1024 },     # 1 GB
#        @{ Path = 'Movies\Dracula_Script.txt'; SizeMB = 2560 } # 2.5 GB
#    )

# 4. Mixed example: One file with specified size, others distributed from TargetSizeGB.
#    - 'BigData\log.zip' will be 3GB.
#    - Remaining 7GB (10GB - 3GB) will be distributed evenly between 'Raw\data.csv' and 'Processed\results.txt' (3.5GB each).
# Generate-FakeData -DestinationPath 'C:\MixedData' -TargetSizeGB 10 -UseGutenbergData `
#    -FileList @(
#        @{ Path = 'BigData\log.zip'; SizeMB = 3000 },
#        'Raw\data.csv',
#        'Processed\results.txt'
#    )

# To run the function after saving the script (e.g., as Generate-FakeData.ps1),
# you first need to dot-source it in your PowerShell session:
# . .\Generate-FakeData.ps1
# Then you can call the function with your desired parameters.
# Example: Generate-FakeData -DestinationPath 'C:\MyLabData' -TargetSizeGB 5 -FileList @(@{Path='File1.txt'; SizeMB=1000}, 'File2.txt') -UseGutenbergData

<#
.SYNOPSIS
    Quick String Look (qsl) - An interactive CLI wrapper for Select-String.
.DESCRIPTION
    Allows specifying a file once, and then performing multiple fast string
    searches interactively with color-coded highlighting, context lines, and options.
.PARAMETER Path
    The path to the file you want to search.
.PARAMETER Pattern
    An optional search pattern. If provided, qsl runs in single-shot mode (non-interactive) and exits.
.PARAMETER CaseSensitive
    Enables case-sensitive matching.
.PARAMETER Context
    Number of context lines to display before and after each match (default is 0).
.PARAMETER Mode
    Search mode: 'Literal' or 'Regex' (default is 'Literal').
#>
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [Parameter(Position = 1)]
    [string]$Pattern,

    [switch]$CaseSensitive,

    [int]$Context = 0,

    [ValidateSet("Literal", "Regex")]
    [string]$Mode = "Literal",

    [string]$FileEncoding = "Default"
)

# Define ANSI codes for styling
$esc = [char]27
$Reset = "$esc[0m"
$Bold = "$esc[1m"
$Dim = "$esc[2m"
$Underline = "$esc[4m"

# Foreground Colors
$Red = "$esc[31m"
$Green = "$esc[32m"
$Yellow = "$esc[33m"
$Blue = "$esc[34m"
$Magenta = "$esc[35m"
$Cyan = "$esc[36m"
$White = "$esc[37m"
$Gray = "$esc[90m"

# Premium Highlight styling: Black text on bright orange-yellow background
$Highlight = "$esc[48;5;220;38;5;16m"
$FileHighlight = "$esc[1;38;5;82m"   # Bold lime green
$InfoHighlight = "$esc[1;38;5;45m"   # Bold cyan

# Ensure terminal renders UTF-8 output correctly
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Helper: read all lines from a file with the specified encoding
function Read-FileLines {
    param([string]$FilePath, [string]$EncodingName)
    $enc = switch ($EncodingName.ToLower()) {
        "utf8"    { [System.Text.Encoding]::UTF8 }
        "default" { [System.Text.Encoding]::Default }
        "big5"    { [System.Text.Encoding]::GetEncoding(950) }
        "gbk"     { [System.Text.Encoding]::GetEncoding(936) }
        default   {
            try   { [System.Text.Encoding]::GetEncoding($EncodingName) }
            catch { [System.Text.Encoding]::Default }
        }
    }
    return [System.IO.File]::ReadAllLines($FilePath, $enc)
}

# Function to print a range of lines from the file
function Show-Lines {
    param(
        [string]$FilePath,
        [int]$StartLine,
        [int]$EndLine,
        [string]$Keyword = ""
    )

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Host "${Red}Error: Target file '$FilePath' does not exist.${Reset}"
        return
    }

    if ($StartLine -lt 1) {
        Write-Host "${Red}Error: Start line must be at least 1.${Reset}"
        return
    }

    if ($EndLine -lt $StartLine) {
        Write-Host "${Red}Error: End line must be >= start line.${Reset}"
        return
    }

    $maxRange = 100
    $range = $EndLine - $StartLine + 1
    if ($range -gt $maxRange) {
        Write-Host "${Red}Error: Line range cannot exceed $maxRange lines. Requested: $range lines (${StartLine}-${EndLine}).${Reset}"
        return
    }

    $allLines = Read-FileLines -FilePath $FilePath -EncodingName $FileEncoding
    $totalLines = $allLines.Count

    if ($StartLine -gt $totalLines) {
        Write-Host "${Yellow}Start line $StartLine exceeds file length ($totalLines lines).${Reset}"
        return
    }

    $actualEnd = [Math]::Min($EndLine, $totalLines)
    $keywordPattern = if ($Keyword) { [Regex]::Escape($Keyword) } else { $null }

    Write-Host "${Gray}--- Lines $StartLine to $actualEnd (of $totalLines total)$(if ($Keyword) { " | Keyword: '$Keyword'" })---${Reset}"
    for ($i = $StartLine; $i -le $actualEnd; $i++) {
        $lineText = $allLines[$i - 1]

        if ($keywordPattern) {
            $highlighted = ""
            $lastIdx = 0
            foreach ($m in ([regex]::Matches($lineText, $keywordPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))) {
                $highlighted += $lineText.Substring($lastIdx, $m.Index - $lastIdx)
                $highlighted += "${Highlight}" + $lineText.Substring($m.Index, $m.Length) + "${Reset}"
                $lastIdx = $m.Index + $m.Length
            }
            $highlighted += $lineText.Substring($lastIdx)
            Write-Host "  ${Gray}$($i.ToString().PadLeft(5)) |${Reset} $highlighted"
        } else {
            Write-Host "  ${Gray}$($i.ToString().PadLeft(5)) |${Reset} $lineText"
        }
    }
    Write-Host "${Gray}----------------------------------${Reset}"
}

# Function to show help menu
function Show-Help {
    Write-Host ""
    Write-Host "  ${Bold}${Underline}Commands Reference:${Reset}"
    Write-Host "  ${Cyan}:q${Reset} or ${Cyan}:exit${Reset}      Exit the tool"
    Write-Host "  ${Cyan}:f${Reset} or ${Cyan}:file <path>${Reset} Change the target file"
    Write-Host "  ${Cyan}:l${Reset} or ${Cyan}:literal${Reset}     Switch to Literal search mode (default)"
    Write-Host "  ${Cyan}:r${Reset} or ${Cyan}:regex${Reset}       Switch to Regular Expression search mode"
    Write-Host "  ${Cyan}:c${Reset} or ${Cyan}:case${Reset}        Toggle Case Sensitivity"
    Write-Host "  ${Cyan}:ctx <n>${Reset}            Set context lines (e.g., :ctx 2)"
    Write-Host "  ${Cyan}:p <start>,<end> [keyword]${Reset}   Print lines in range, max 100 lines; optional keyword is highlighted (e.g., :p 1,20 or :p 1,20 error)"
    Write-Host "  ${Cyan}:enc <encoding>${Reset}             Set file encoding (e.g., :enc UTF8 / :enc Big5 / :enc Default)"
    Write-Host "  ${Cyan}:h${Reset} or ${Cyan}:help${Reset}       Show this help reference"
    Write-Host ""
}

# Function to perform Select-String search and format output
function Invoke-Search {
    param(
        [string]$FilePath,
        [string]$SearchPattern,
        [string]$SearchMode,
        [bool]$IsCaseSensitive,
        [int]$NumContext
    )

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Host "${Red}Error: Target file '$FilePath' does not exist.${Reset}"
        return
    }

    # Prepare search pattern based on mode
    $finalPattern = $SearchPattern
    if ($SearchMode -eq "Literal") {
        # Escape pattern so Select-String treats it literally, while still populating .Matches
        $finalPattern = [Regex]::Escape($SearchPattern)
    }

    # Build parameter table for Select-String
    $params = @{
        Pattern   = $finalPattern
        AllMatches = $true
    }
    if ($IsCaseSensitive) {
        $params.CaseSensitive = $true
    }
    if ($NumContext -gt 0) {
        $params.Context = $NumContext
    }

    try {
        $fileLines = Read-FileLines -FilePath $FilePath -EncodingName $FileEncoding
        $results = $fileLines | Select-String @params
        if (-not $results) {
            Write-Host "${Yellow}No matches found for '$SearchPattern'${Reset}"
            return
        }

        $resultsArray = @($results)
        $totalMatches = $resultsArray.Count

        # Guard against flooding the terminal
        $maxDisplay = 100
        if ($totalMatches -gt $maxDisplay) {
            Write-Host "${Yellow}Found $totalMatches matches. Showing first $maxDisplay. (Press Enter to continue, or Ctrl+C to abort)${Reset}"
            $null = Read-Host
            $resultsArray = $resultsArray | Select-Object -First $maxDisplay
        }

        # Print header
        Write-Host "${Gray}--- Found $totalMatches match(es) ---${Reset}"

        $matchIndex = 0
        foreach ($match in $resultsArray) {
            $matchIndex++
            $lineNum = $match.LineNumber
            $lineText = $match.Line

            # Pre-Context
            if ($match.Context -and $match.Context.PreContext) {
                $preLineNum = $lineNum - $match.Context.PreContext.Count
                foreach ($preLine in $match.Context.PreContext) {
                    Write-Host "  ${Gray}$($preLineNum.ToString().PadLeft(5)) | $preLine${Reset}"
                    $preLineNum++
                }
            }

            # Main Line Highlight
            $highlightedLine = ""
            $lastIdx = 0
            # Matches are sorted by Index to process left-to-right
            $sortedMatches = $match.Matches | Sort-Object Index
            
            foreach ($m in $sortedMatches) {
                if ($m.Index -ge $lastIdx) {
                    # Add text before match
                    $highlightedLine += $lineText.Substring($lastIdx, $m.Index - $lastIdx)
                    # Add highlighted match
                    $highlightedLine += "${Highlight}" + $lineText.Substring($m.Index, $m.Length) + "${Reset}"
                    # Update index to end of match
                    $lastIdx = $m.Index + $m.Length
                }
            }
            # Add remaining text on line
            if ($lastIdx -lt $lineText.Length) {
                $highlightedLine += $lineText.Substring($lastIdx)
            }

            # Print main line
            Write-Host "> ${Cyan}$($lineNum.ToString().PadLeft(5)) |${Reset} $highlightedLine"

            # Post-Context
            if ($match.Context -and $match.Context.PostContext) {
                $postLineNum = $lineNum + 1
                foreach ($postLine in $match.Context.PostContext) {
                    Write-Host "  ${Gray}$($postLineNum.ToString().PadLeft(5)) | $postLine${Reset}"
                    $postLineNum++
                }
            }

            # Print spacer between matches if context is used
            if ($NumContext -gt 0 -and $matchIndex -lt $resultsArray.Count) {
                Write-Host "${Gray}  .....${Reset}"
            }
        }
        Write-Host "${Gray}----------------------------------${Reset}"
    } catch {
        Write-Host "${Red}Search failed: $_${Reset}"
    }
}

# --- Initialization Phase ---

# Check if Path was supplied; if not, scans current folder and asks user
if (-not $Path) {
    Write-Host "${Yellow}Scanning current directory for text files...${Reset}"
    $files = Get-ChildItem -File | Where-Object { $_.Extension -in '.log', '.txt', '.csv', '.json', '.xml', '.md', '.ini', '.yaml' }
    if ($files.Count -gt 0) {
        Write-Host "Available files in this folder:"
        for ($i = 0; $i -lt $files.Count; $i++) {
            $sizeKB = [Math]::Round($files[$i].Length / 1KB, 1)
            Write-Host "  [$i] $($files[$i].Name) ($sizeKB KB)"
        }
        $selection = Read-Host "Select a file index [0-$($files.Count-1)] or type a file path"
        if ($selection -match '^\d+$' -and [int]$selection -lt $files.Count) {
            $Path = $files[[int]$selection].FullName
        } elseif ($selection.Trim() -ne "") {
            $Path = $selection
        }
    } else {
        $Path = Read-Host "Enter the path of the file to search"
    }
}

# Resolve target path to an absolute path
if ($Path) {
    $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
    if ($resolved) {
        $Path = $resolved.Path
    }
}

# Keep prompting if path is still invalid
while (-not $Path -or -not (Test-Path $Path -PathType Leaf)) {
    Write-Host "${Red}Error: Specified file path does not exist or is a folder.${Reset}"
    $Path = Read-Host "Enter a valid file path (or type ':q' to exit)"
    if ($Path -eq ":q" -or $Path -eq ":exit") {
        return
    }
    if ($Path) {
        $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
        if ($resolved) {
            $Path = $resolved.Path
        }
    }
}

# --- Execution Phase ---

# If Pattern was provided as an argument, run a single search and exit
if ($Pattern) {
    $IsCase = [bool]$CaseSensitive
    Invoke-Search -FilePath $Path -SearchPattern $Pattern -SearchMode $Mode -IsCaseSensitive $IsCase -NumContext $Context
    return
}

# Function to display the status header (called at startup and after settings changes)
function Show-Header {
    Clear-Host
    Write-Host "============================================================${Reset}"
    Write-Host "🔍  ${Bold}Quick String Look (qsl)${Reset}"
    Write-Host "------------------------------------------------------------"
    Write-Host "  Target File : ${FileHighlight}$Path${Reset}"
    Write-Host "  Search Mode : ${InfoHighlight}$Mode${Reset}"
    Write-Host "  Sensitivity : ${InfoHighlight}$(if ($CaseSensitive) { "Case-Sensitive" } else { "Case-Insensitive" })${Reset}"
    Write-Host "  Context     : ${InfoHighlight}$Context line(s)${Reset}"
    Write-Host "  Encoding    : ${InfoHighlight}$FileEncoding${Reset}"
    Write-Host "------------------------------------------------------------"
    Write-Host "  Commands: ${Cyan}:q${Reset} (exit), ${Cyan}:f <path>${Reset} (change file), ${Cyan}:help${Reset} (more options)"
    Write-Host "============================================================`n"
}

# Welcome Header for Interactive Mode
Show-Header

# Start prompt loop
while ($true) {
    # Prepare dynamic mode descriptions for prompt
    $shortMode = if ($Mode -eq "Literal") { "Literal" } else { "Regex" }
    $shortCase = if ($CaseSensitive) { "Case" } else { "NoCase" }
    $fileNameOnly = Split-Path $Path -Leaf

    # Prompt user
    # Format: [filename.log] (Literal|NoCase|Ctx:0) >
    $promptStr = "[${Green}$fileNameOnly${Reset}] (${Gray}$shortMode|$shortCase|Ctx:$Context${Reset}) ${Magenta}🔍${Reset} "
    Write-Host -NoNewline $promptStr
    $query = Read-Host

    if ($null -eq $query -or $query.Trim() -eq "") {
        continue
    }

    $query = $query.Trim()

    # Handle commands
    if ($query.StartsWith(":")) {
        $parts = $query -split '\s+', 2
        $cmd = $parts[0].ToLower()
        $arg = if ($parts.Count -gt 1) { $parts[1] } else { $null }

        switch ($cmd) {
            { $_ -in ":q", ":exit" } {
                Write-Host "Goodbye!" -ForegroundColor Yellow
                return
            }
            { $_ -in ":f", ":file" } {
                if (-not $arg) {
                    Write-Host "${Red}Error: Please specify a file path. Example: :file mylog.log${Reset}"
                } else {
                    $resolvedArg = Resolve-Path $arg -ErrorAction SilentlyContinue
                    if ($resolvedArg -and (Test-Path $resolvedArg.Path -PathType Leaf)) {
                        $Path = $resolvedArg.Path
                        Show-Header
                    } else {
                        Write-Host "${Red}Error: File '$arg' not found or invalid.${Reset}"
                    }
                }
            }
            { $_ -in ":l", ":literal" } {
                $Mode = "Literal"
                Show-Header
            }
            { $_ -in ":r", ":regex" } {
                $Mode = "Regex"
                Show-Header
            }
            { $_ -in ":c", ":case" } {
                $CaseSensitive = -not $CaseSensitive
                Show-Header
            }
            { $_ -in ":ctx", ":context" } {
                if ($arg -match '^\d+$') {
                    $Context = [int]$arg
                    Show-Header
                } else {
                    Write-Host "${Red}Error: Context must be a non-negative integer. Example: :ctx 2${Reset}"
                }
            }
            { $_ -in ":enc", ":encoding" } {
                if ($arg) {
                    $FileEncoding = $arg.Trim()
                    Show-Header
                } else {
                    Write-Host "${Red}Error: Please specify an encoding. Example: :enc UTF8 / :enc Big5 / :enc Default${Reset}"
                }
            }
            { $_ -in ":p", ":print" } {
                if ($arg -match '^(\d+),(\d+)(?:\s+(.+))?$') {
                    $kw = if ($Matches[3]) { $Matches[3].Trim() } else { "" }
                    Show-Lines -FilePath $Path -StartLine ([int]$Matches[1]) -EndLine ([int]$Matches[2]) -Keyword $kw
                } else {
                    Write-Host "${Red}Error: Please specify a line range. Example: :p 1,20 or :p 1,20 keyword${Reset}"
                }
            }
            { $_ -in ":h", ":help" } {
                Show-Help
            }
            Default {
                Write-Host "${Red}Unknown command: $cmd. Type :help for commands.${Reset}"
            }
        }
        Write-Host "" # blank line after command feedback
        continue
    }

    # Execute search
    Invoke-Search -FilePath $Path -SearchPattern $query -SearchMode $Mode -IsCaseSensitive $CaseSensitive -NumContext $Context
    Write-Host "" # spacing
}

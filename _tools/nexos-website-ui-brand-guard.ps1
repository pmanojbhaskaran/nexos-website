param(
  [Parameter(Mandatory=$false)]
  [ValidateSet('worktree','staged','ci')]
  [string]$Mode = 'worktree'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolRoot
$BaselinePath = Join-Path $ToolRoot 'nexos-website-ui-brand-baseline.json'

if (-not [System.IO.File]::Exists($BaselinePath)) {
  throw ('STOP|NEXOS_WEBSITE_UI_BRAND_GUARD|BASELINE_MISSING|' + $BaselinePath)
}

function Run-Git {
  param(
    [Parameter(Mandatory=$true)][string[]]$Args,
    [Parameter(Mandatory=$true)][string]$Label
  )

  $Output = @(& git -C $RepoRoot @Args 2>&1)
  $ExitCode = $LASTEXITCODE

  if ($ExitCode -ne 0) {
    throw ('STOP|NEXOS_WEBSITE_UI_BRAND_GUARD|' + $Label + '|EXIT=' + [string]$ExitCode + '|OUTPUT=' + (($Output | ForEach-Object { [string]$_ }) -join ' | '))
  }

  $Lines = [System.Collections.Generic.List[string]]::new()
  foreach ($Line in $Output) {
    if ($null -ne $Line) {
      $Lines.Add([string]$Line)
    }
  }

  return @($Lines.ToArray())
}

function Get-ValidCssHexes {
  param([Parameter(Mandatory=$true)][string]$Content)

  $Matches = @([regex]::Matches($Content, '(?<!&)#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b'))
  $Values = [System.Collections.Generic.List[string]]::new()

  foreach ($Match in $Matches) {
    $Values.Add($Match.Value.ToUpperInvariant())
  }

  return @($Values.ToArray() | Sort-Object -Unique)
}

function Is-UiFile {
  param([Parameter(Mandatory=$true)][string]$Rel)

  $Lower = $Rel.ToLowerInvariant()
  return ($Lower.EndsWith('.html') -or $Lower.EndsWith('.css') -or $Lower.EndsWith('.js'))
}

$Baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
$ExpectedUiFiles = @($Baseline.trackedUiFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)

$TrackedFiles = @(Run-Git -Args @('ls-files') -Label 'LS_FILES')
$CurrentUiFiles = [System.Collections.Generic.List[string]]::new()

foreach ($File in $TrackedFiles) {
  $Rel = ([string]$File).Replace('\','/').Trim()
  if ([string]::IsNullOrWhiteSpace($Rel)) {
    continue
  }

  if (Is-UiFile -Rel $Rel) {
    $CurrentUiFiles.Add($Rel)
  }
}

$CurrentUiFilesSorted = @($CurrentUiFiles.ToArray() | Sort-Object -Unique)

Write-Output ('PROOF|NEXOS_WEBSITE_UI_BRAND_GUARD|MODE|' + $Mode)
Write-Output ('PROOF|NEXOS_WEBSITE_UI_BRAND_GUARD|FILES_COUNT|' + [string]$CurrentUiFilesSorted.Count)

if (($CurrentUiFilesSorted -join '|') -ne ($ExpectedUiFiles -join '|')) {
  throw ('STOP|NEXOS_WEBSITE_UI_BRAND_GUARD|TRACKED_UI_FILES_CHANGED|EXPECTED=' + ($ExpectedUiFiles -join '|') + '|ACTUAL=' + ($CurrentUiFilesSorted -join '|'))
}

$Violations = [System.Collections.Generic.List[string]]::new()
$OffBrandClassPatterns = @(
  'bg-slate-',
  'text-slate-',
  'border-slate-',
  'bg-blue-',
  'text-blue-',
  'border-blue-',
  'bg-amber-',
  'text-amber-',
  'border-amber-',
  'bg-black',
  'text-white'
)

foreach ($Rel in $CurrentUiFilesSorted) {
  $FullPath = Join-Path $RepoRoot ($Rel.Replace('/','\'))

  if (-not [System.IO.File]::Exists($FullPath)) {
    $Violations.Add('FILE_MISSING|' + $Rel)
    continue
  }

  $Content = [System.IO.File]::ReadAllText($FullPath)
  $Lines = [System.IO.File]::ReadAllLines($FullPath)

  if ($Content.IndexOf('TENEX', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    $Violations.Add('LEGACY_TENEX_TEXT|' + $Rel)
  }

  foreach ($Pattern in $OffBrandClassPatterns) {
    if ($Content.IndexOf($Pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $Violations.Add('OFF_BRAND_CLASS_PATTERN|' + $Rel + '|' + $Pattern)
    }
  }

  if ($Content.IndexOf('--teal:#01696F', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    $Violations.Add('MISSING_PRIMARY_TOKEN|' + $Rel + '|--teal:#01696F')
  }

  if ($Content.IndexOf('--teal-dark:#0C4E54', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    $Violations.Add('MISSING_DEEP_TEAL_TOKEN|' + $Rel + '|--teal-dark:#0C4E54')
  }

  $CurrentHexes = @(Get-ValidCssHexes -Content $Content)

  $ExpectedHexes = @()
  $Property = $Baseline.allowedHexByFile.PSObject.Properties[$Rel]
  if ($null -ne $Property) {
    $ExpectedHexes = @($Property.Value | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
  }

  foreach ($Hex in $CurrentHexes) {
    if ($ExpectedHexes -notcontains $Hex) {
      $Violations.Add('NEW_RAW_HEX_NOT_IN_BASELINE|' + $Rel + '|' + $Hex)
    }
  }

  foreach ($Hex in $ExpectedHexes) {
    if ($CurrentHexes -notcontains $Hex) {
      $Violations.Add('BASELINE_RAW_HEX_REMOVED_WITHOUT_BASELINE_UPDATE|' + $Rel + '|' + $Hex)
    }
  }

  Write-Output ('PROOF|NEXOS_WEBSITE_UI_BRAND_GUARD|FILE|' + $Rel + '|HEX_COUNT|' + [string]$CurrentHexes.Count)
}

if ($Violations.Count -gt 0) {
  foreach ($Violation in $Violations) {
    Write-Output ('STOP|NEXOS_WEBSITE_UI_BRAND_GUARD|VIOLATION|' + $Violation)
  }

  throw ('STOP|NEXOS_WEBSITE_UI_BRAND_GUARD|FAILED|COUNT=' + [string]$Violations.Count)
}

Write-Output 'PROOF|NEXOS_WEBSITE_UI_BRAND_GUARD|PASS'
exit 0
$ErrorActionPreference = "Stop"

$talkPath = Join-Path $PSScriptRoot "..\TALK.md"
$text = Get-Content -LiteralPath $talkPath -Raw -Encoding UTF8
$referencesPath = Join-Path $PSScriptRoot "..\REFERENCES.md"
$referencesText = Get-Content -LiteralPath $referencesPath -Raw -Encoding UTF8

$slideMatches = [regex]::Matches($text, '(?m)^## Slide ([0-9]+)')
$slides = @($slideMatches | ForEach-Object { [int]$_.Groups[1].Value })
$expected = @(1..72)

if ($slides.Count -ne 72) {
    throw "Expected 72 slides, found $($slides.Count)."
}

for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($slides[$i] -ne $expected[$i]) {
        throw "Slide numbering mismatch at position $($i + 1): found $($slides[$i])."
    }
}

$used = @([regex]::Matches($text, '\[(A|B|C)[0-9]+\]') |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique)

$defined = @([regex]::Matches($text, '(?m)^- \[((A|B|C)[0-9]+)\]') |
    ForEach-Object { '[' + $_.Groups[1].Value + ']' } |
    Sort-Object -Unique)

$missingDefinitions = @($used | Where-Object { $_ -notin $defined })
$unusedDefinitions = @($defined | Where-Object { $_ -notin $used })

if ($missingDefinitions.Count -gt 0) {
    throw "References used but not defined: $($missingDefinitions -join ', ')"
}

if ($unusedDefinitions.Count -gt 0) {
    throw "References defined but not used: $($unusedDefinitions -join ', ')"
}

$standaloneDefinitions = @([regex]::Matches($referencesText, '(?m)^- \[((A|B|C)[0-9]+)\]') |
    ForEach-Object { '[' + $_.Groups[1].Value + ']' } |
    Sort-Object -Unique)

$missingFromStandalone = @($defined | Where-Object { $_ -notin $standaloneDefinitions })
$extraInStandalone = @($standaloneDefinitions | Where-Object { $_ -notin $defined })

if ($missingFromStandalone.Count -gt 0) {
    throw "References missing from REFERENCES.md: $($missingFromStandalone -join ', ')"
}

if ($extraInStandalone.Count -gt 0) {
    throw "References present only in REFERENCES.md: $($extraInStandalone -join ', ')"
}

$placeholderPattern = '(?i)\b(TODO|TBD)\b|arxiv\.org/search|^# Summary'
$placeholders = [regex]::Matches($text, $placeholderPattern, 'Multiline')
if ($placeholders.Count -gt 0) {
    throw "Found $($placeholders.Count) unresolved placeholder(s)."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$markdownFiles = Get-ChildItem -LiteralPath $repoRoot -Filter "*.md" -File
foreach ($markdownFile in $markdownFiles) {
    $markdown = Get-Content -LiteralPath $markdownFile.FullName -Raw -Encoding UTF8
    $localLinks = [regex]::Matches($markdown, '\[[^\]]+\]\((?!https?://|mailto:|#)([^)]+)\)')
    foreach ($link in $localLinks) {
        $target = $link.Groups[1].Value.Split('#')[0]
        $resolvedTarget = Join-Path $markdownFile.DirectoryName $target
        if (-not (Test-Path -LiteralPath $resolvedTarget)) {
            throw "Broken local link in $($markdownFile.Name): $target"
        }
    }
}

Write-Host "Validation passed: 72 slides, $($used.Count) closed references, synchronized reference index, no placeholders."

$ErrorActionPreference = "Stop"

$talkPath = Join-Path $PSScriptRoot "..\TALK.md"
$text = Get-Content -LiteralPath $talkPath -Raw -Encoding UTF8
$referencesPath = Join-Path $PSScriptRoot "..\REFERENCES.md"
$referencesText = Get-Content -LiteralPath $referencesPath -Raw -Encoding UTF8

$slideMatches = [regex]::Matches($text, '(?m)^## Slide ([0-9]+)')
$slides = @($slideMatches | ForEach-Object { [int]$_.Groups[1].Value })
$expected = @(1..88)

if ($slides.Count -ne 88) {
    throw "Expected 88 slides, found $($slides.Count)."
}

for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($slides[$i] -ne $expected[$i]) {
        throw "Slide numbering mismatch at position $($i + 1): found $($slides[$i])."
    }
}

$expectedTitle = '# AI Communication Stack: From One Tensor to the Whole System'
$normalizedTalkText = $text.TrimStart([char]0xFEFF)
if (-not $normalizedTalkText.StartsWith($expectedTitle)) {
    throw "Unexpected talk title. Expected: $expectedTitle"
}

$readmePath = Join-Path $PSScriptRoot "..\README.md"
$readmeText = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
if (-not $readmeText.TrimStart([char]0xFEFF).StartsWith($expectedTitle)) {
    throw "README title is not synchronized with TALK.md."
}

$mainSlideBodies = [regex]::Matches(
    $text,
    '(?ms)^## Slide ([0-9]+)[^\r\n]*\r?\n(.*?)(?=^## Slide [0-9]+|\z)'
)
if ($mainSlideBodies.Count -ne 88) {
    throw "Expected 88 complete main-slide bodies, found $($mainSlideBodies.Count)."
}

$speakerNoteMarker = ([char]0x8BB2).ToString() +
    ([char]0x5E08).ToString() +
    ([char]0x8BF4).ToString() +
    ([char]0x660E).ToString() +
    ([char]0xFF1A).ToString()
$missingSpeakerNotes = @($mainSlideBodies |
    Where-Object { -not $_.Groups[2].Value.Contains($speakerNoteMarker) } |
    ForEach-Object { $_.Groups[1].Value })
if ($missingSpeakerNotes.Count -gt 0) {
    throw "Main slides missing speaker notes: $($missingSpeakerNotes -join ', ')"
}

$narrativeAnchors = @(
    'Physical Architecture & Topology',
    'Semantics, Transport and Reliability',
    'Communication Software & Execution',
    'Locality, Overlap, Distributed Kernel and KV'
)
foreach ($anchor in $narrativeAnchors) {
    if (-not $text.Contains($anchor)) {
        throw "Missing zero-background narrative anchor: $anchor"
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
$allMarkdownText = ($markdownFiles | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
}) -join "`n"

$stalePredecessorPatterns = @(
    '64[^\r\n]{0,20}PPTX',
    '2E3BE00DCDC00F8A80A792E34C83877560E6673AA605B55F52563E28AD97211C'
)
foreach ($stalePattern in $stalePredecessorPatterns) {
    if ([regex]::IsMatch($allMarkdownText, $stalePattern, 'IgnoreCase')) {
        throw "Found stale predecessor-deck wording: $stalePattern"
    }
}

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

Write-Host "Validation passed: 88 slides, $($used.Count) closed references, synchronized reference index, no placeholders."

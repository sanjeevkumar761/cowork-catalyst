<#
.SYNOPSIS
Cowork Catalyst - turn existing skills into share-ready Copilot Cowork plugins.

.DESCRIPTION
Cowork Catalyst scaffolds, validates, packages, and shares a plugin from an
existing skill. It can also read a skill's Markdown without building a plugin.

Without arguments, prompts for a skill group, skill, and recipient email.
Creates a new plugin named after the skill, registers and copies the skill,
validates source, provisions a shared deployment, packages, validates the ZIP,
and shares it with the recipient. Requires an installed WIQD CLI supporting
source/package validation modes (tested with 0.24.0) and Microsoft 365 sign-in:
wiqd auth login --interactive

Asks for confirmation before creating files or making tenant changes. Existing
plugin directories require -Update. Failures stop subsequent steps;
partially created files/resources are retained for diagnosis, not rolled back.
Does not install WIQD, accept EULAs, sign in, or publish to the tenant catalog.

Use -ReadOnly to return the complete UTF-8 Markdown as a single string,
including front matter, without WIQD or tenant access. Defaults to the
paralegal group in this mode for compatibility with the original reader.

Reference: https://learn.microsoft.com/en-us/copilot/cowork/cowork-plugin-development
Current WIQD uses source/package modes instead of the article's older deep mode.
Source validation is an offline project/declarative-agent check, not full skill
validation. Final package validation uploads the ZIP to Microsoft's validation
service and may require sign-in; sharing runs only after it passes.

.PARAMETER SkillName
The skill folder name, for example legal-research.

.PARAMETER SkillsPath
Optional directory containing skill folders; bypasses group selection.
Cannot be combined with SkillGroup. Relative paths use the working directory.

.PARAMETER SkillGroup
Group folder under SampleSkillsPath, for example paralegal.

.PARAMETER SampleSkillsPath
Root containing <group>\skills\<skill>\SKILL.md. Defaults to sample-skills
relative to the script, regardless of the current working directory.

.PARAMETER ShareEmail
One recipient email address. Prompts when omitted.

.PARAMETER OutputPath
Parent directory for the new or existing <skill-name> plugin. Defaults to plugins beside
the scripts directory.

.PARAMETER Environment
Deployment environment. Defaults to dev (shared), not local (personal).
The generated lifecycle and environment must explicitly configure shared scope.

.PARAMETER ReadOnly
Return Markdown only. SkillName is required; no prompts or tenant changes.

.PARAMETER Update
Update an existing, provisioned shared plugin in OutputPath. Reuses its IDs,
replaces the selected skill folder, and increments the target package patch version.
Local changes to that skill folder are replaced. Other skills are left untouched.

.PARAMETER SourceSkillVersion
Optional caller-supplied source version label, recorded separately from the
plugin package version. It is not inferred from Markdown and does not fetch a version.

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1 -SkillGroup paralegal -SkillName legal-research -ShareEmail 'you@contoso.com'

.EXAMPLE
$content = .\scripts\New-CoworkPluginFromSkill.ps1 -ReadOnly -SkillName legal-research

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1 -SkillGroup paralegal -SkillName legal-research -ShareEmail 'you@contoso.com' -WhatIf

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1 -Update -SkillGroup paralegal -SkillName legal-research -SourceSkillVersion '2026.11' -ShareEmail 'you@contoso.com'
#>
[CmdletBinding(DefaultParameterSetName = 'Plugin', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([string], [pscustomobject])]
param (
    [Parameter(ParameterSetName = 'Plugin', Position = 0)]
    [Parameter(ParameterSetName = 'ReadOnly', Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^(?!\.{1,2}$)[^\\/:*?"<>|]+$')]
    [string]$SkillName,

    [Parameter(ParameterSetName = 'Plugin')]
    [Parameter(ParameterSetName = 'ReadOnly')]
    [ValidateNotNullOrEmpty()]
    [string]$SkillsPath,

    [Parameter(ParameterSetName = 'Plugin')]
    [Parameter(ParameterSetName = 'ReadOnly')]
    [ValidatePattern('^(?!\.{1,2}$)[^\\/:*?"<>|]+$')]
    [string]$SkillGroup,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SampleSkillsPath = (Join-Path $PSScriptRoot '..\sample-skills'),

    [Parameter(ParameterSetName = 'Plugin')]
    [ValidateNotNullOrEmpty()]
    [string]$ShareEmail,

    [Parameter(ParameterSetName = 'Plugin')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\plugins'),

    [Parameter(ParameterSetName = 'Plugin')]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')]
    [string]$Environment = 'dev',

    [Parameter(ParameterSetName = 'Plugin')]
    [switch]$Update,

    [Parameter(ParameterSetName = 'Plugin')]
    [ValidateNotNullOrEmpty()]
    [string]$SourceSkillVersion,

    [Parameter(ParameterSetName = 'ReadOnly', Mandatory = $true)]
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'

function Select-Directory {
    param ([string]$Prompt, [System.IO.DirectoryInfo[]]$Directories)

    if ($Directories.Count -eq 0) {
        throw "No selectable directories found: $Prompt"
    }
    for ($index = 0; $index -lt $Directories.Count; $index++) {
        Write-Host ('{0}. {1}' -f ($index + 1), $Directories[$index].Name)
    }
    while ($true) {
        $answer = Read-Host "$Prompt (number or exact name)"
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Directories.Count) {
            return $Directories[$number - 1].Name
        }
        $match = @($Directories | Where-Object { $_.Name -eq $answer })
        if ($match.Count -eq 1) {
            return $match[0].Name
        }
        Write-Warning 'Choose a listed number or exact directory name.'
    }
}

function Test-RecipientEmail {
    param ([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email) -or $Email -match '[\s,;]') {
        return $false
    }
    try {
        $address = [System.Net.Mail.MailAddress]::new($Email)
        return $address.Address -ceq $Email -and $Email -match '^[^@]+@[^@]+\.[^@]+$'
    }
    catch [System.FormatException] {
        return $false
    }
}

function Invoke-Wiqd {
    param ([string[]]$Arguments)

    $global:LASTEXITCODE = 0
    & $wiqdCommand @Arguments --skill wiqd --workflow plugin | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if ($LASTEXITCODE -eq 3) {
            throw 'WIQD requires human EULA consent. Review its displayed terms and complete consent yourself, then retry. No terms were accepted by this script.'
        }
        throw "WIQD '$($Arguments -join ' ')' failed with exit code $LASTEXITCODE. Subsequent steps were not run."
    }
}

function Get-DeploymentValue {
    param ([string]$Path, [string]$Name)

    $entries = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match "^\s*$Name\s*=" })
    if ($entries.Count -ne 1) {
        throw "Expected exactly one $Name setting in '$Path'. Correct the deployment configuration before continuing."
    }
    $value = ($entries[0] -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '\$\{') {
        throw "$Name is empty or unresolved in '$Path'. Deployment is not ready."
    }
    return $value
}

function Assert-NoLinks {
    param ([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Linked paths are not supported: '$($item.FullName)'."
        }
        $item = $item.Parent
    }
    foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
        if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Linked paths are not supported: '$($child.FullName)'."
        }
        if ($child.PSIsContainer) { Assert-NoLinks $child.FullName }
    }
}

function Get-SkillSnapshot {
    param ([string]$Path)

    Assert-NoLinks $Path
    $root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    } | Sort-Object path -CaseSensitive)
    $text = ($files | ForEach-Object { "$($_.path)`0$($_.sha256)" }) -join "`n"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') }
    finally { $hasher.Dispose() }
    [pscustomobject]@{ sha256 = $hash; files = $files }
}

function Get-SourceGit {
    param ([string]$Path)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ status = 'git_unavailable'; root = $null; commit = $null; dirty = $null }
    }
    # Inspect ancestors rather than treating an arbitrary git failure as "not a repository".
    $directory = Get-Item -LiteralPath $Path
    while ($null -ne $directory -and -not (Test-Path -LiteralPath (Join-Path $directory.FullName '.git'))) {
        $directory = $directory.Parent
    }
    if ($null -eq $directory) {
        return [pscustomobject]@{ status = 'not_a_repository'; root = $null; commit = $null; dirty = $null }
    }
    $commit = & git -C $Path rev-parse --verify --quiet 'HEAD^{commit}'
    $gitStatus = 'available'
    if ($LASTEXITCODE -ne 0) {
        $branch = & git -C $Path symbolic-ref --quiet HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve source Git HEAD.' }
        & git -C $Path show-ref --verify --quiet $branch
        if ($LASTEXITCODE -ne 1) { throw 'Source Git HEAD is not a valid commit or an unborn branch.' }
        $commit = $null
        $gitStatus = 'unborn_repository'
    }
    $changes = @(& git -C $Path status --porcelain --untracked-files=all --ignored=matching -- .)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read source Git worktree status.' }
    [pscustomobject]@{ status = $gitStatus; root = $directory.FullName; commit = $commit; dirty = ($changes.Count -gt 0) }
}

function Get-PackageVersion {
    param ([string]$Value)

    if ($Value -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Invalid package version '$Value'; expected major.minor.patch."
    }
    $version = [version]$Value
    if ($version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) {
        throw 'Package version components must not exceed 65535.'
    }
    return $version
}

function Write-Provenance {
    $temporaryPath = "$provenancePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $provenance | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $provenancePath) {
            [IO.File]::Replace($temporaryPath, $provenancePath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temporaryPath, $provenancePath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
    }
}

if ($SkillsPath -and $SkillGroup) {
    throw 'Specify SkillsPath or SkillGroup, not both.'
}
if (-not $ReadOnly) {
    Write-Host 'Cowork Catalyst'
    Write-Host 'Turn existing skills into share-ready Copilot Cowork plugins.'
    Write-Host ''
}
if (-not $SkillsPath) {
    if (-not $SkillGroup) {
        if ($ReadOnly) {
            $SkillGroup = 'paralegal'
        }
        else {
            $groups = @(Get-ChildItem -LiteralPath $SampleSkillsPath -Directory |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'skills') -PathType Container } |
                Sort-Object Name)
            $SkillGroup = Select-Directory -Prompt 'Choose a skill group' -Directories $groups
        }
    }
    $SkillsPath = Join-Path (Join-Path $SampleSkillsPath $SkillGroup) 'skills'
}
if (-not $SkillName) {
    $skills = @(Get-ChildItem -LiteralPath $SkillsPath -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
        Sort-Object Name)
    $SkillName = Select-Directory -Prompt 'Choose a skill' -Directories $skills
}

$skillDirectory = Join-Path -Path $SkillsPath -ChildPath $SkillName -ErrorAction Stop
$skillFile = Join-Path -Path $skillDirectory -ChildPath 'SKILL.md' -ErrorAction Stop

if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf -ErrorAction Stop)) {
    throw "SKILL.md was not found for skill '$SkillName' at '$skillFile'. Check SkillName and SkillsPath."
}

if ($ReadOnly) {
    Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
    return
}

if ($SkillName.Length -gt 64 -or $SkillName -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
    throw 'Plugin skill names must be lowercase letters/digits separated by single hyphens, at most 64 characters. Rename the source skill folder and its front matter consistently.'
}
if ($ShareEmail) {
    if (-not (Test-RecipientEmail $ShareEmail)) {
        throw 'ShareEmail must be one plain email address, for example you@contoso.com.'
    }
}
else {
    do {
        $ShareEmail = Read-Host 'Which email address should receive access to the plugin?'
        $validEmail = Test-RecipientEmail $ShareEmail
        if (-not $validEmail) {
            Write-Warning 'Enter one plain email address, for example you@contoso.com.'
        }
    } until ($validEmail)
}

$outputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$pluginDirectory = Join-Path $outputDirectory $SkillName
$packageFile = Join-Path $pluginDirectory "appPackage\build\appPackage.$Environment.zip"
if (-not $Update -and (Test-Path -LiteralPath $pluginDirectory)) {
    throw "Destination '$pluginDirectory' already exists. Choose another OutputPath; no files were overwritten."
}
$targetSkillDirectory = Join-Path $pluginDirectory "appPackage\skills\$SkillName"
$targetSkillFile = Join-Path $targetSkillDirectory 'SKILL.md'
$manifestFile = Join-Path $pluginDirectory 'appPackage\manifest.json'
$environmentFile = Join-Path $pluginDirectory "env\.env.$Environment"
$provenancePath = Join-Path $pluginDirectory 'cowork-catalyst.provenance.json'
$previousHistory = @()
$versionWrites = @()
$originalIds = $null
$sourceSnapshot = Get-SkillSnapshot $skillDirectory
$sourceGit = Get-SourceGit $skillDirectory
$sourceRoot = (Get-Item -LiteralPath $skillDirectory).FullName.TrimEnd('\', '/')
if ($pluginDirectory.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $sourceRoot.StartsWith($pluginDirectory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $sourceRoot -eq $pluginDirectory) {
    throw 'Source skill and plugin output must be separate, non-overlapping directories.'
}
if ($Update) {
    if (-not (Test-Path -LiteralPath $pluginDirectory -PathType Container)) {
        throw "Cannot update: plugin '$pluginDirectory' does not exist."
    }
    Assert-NoLinks $pluginDirectory
    foreach ($required in @('wiqd.plugin.json', 'appPackage\manifest.json', "appPackage\skills\$SkillName\SKILL.md")) {
        if (-not (Test-Path -LiteralPath (Join-Path $pluginDirectory $required) -PathType Leaf)) {
            throw "Cannot update: missing '$required'."
        }
    }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    if (@($manifest.agentSkills | Where-Object { $_.folder -ceq "skills/$SkillName" }).Count -ne 1) {
        throw 'Cannot update: selected skill must be registered exactly once.'
    }
    $lifecycle = Get-Content -LiteralPath (Join-Path $pluginDirectory 'm365agents.yml') -Raw
    if ($lifecycle -notmatch '(?m)^environmentFolderPath:\s*[''"]?\./env[''"]?\s*$' -or
        $lifecycle -notmatch '(?m)^\s+scope:\s*\$\{\{AGENT_SCOPE\}\}\s*$') {
        throw 'Cannot update: unsupported lifecycle configuration.'
    }
    if ((Get-DeploymentValue $environmentFile 'AGENT_SCOPE') -cne 'shared') {
        throw 'Cannot update: target environment is not shared.'
    }
    $originalIds = @{
        TEAMS_APP_ID = Get-DeploymentValue $environmentFile 'TEAMS_APP_ID'
        M365_TITLE_ID = Get-DeploymentValue $environmentFile 'M365_TITLE_ID'
    }
    if (Test-Path -LiteralPath $provenancePath) {
        $previous = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
        if ($previous.schemaVersion -ne 1 -or $previous.skillName -cne $SkillName) {
            throw 'Cannot update: incompatible provenance or mismatched skill identity.'
        }
        $previousHistory = @($previous.attempts)
    }
    if ($manifest.version -ceq '${{TEAMS_APP_VERSION}}') {
        $currentVersion = Get-PackageVersion (Get-DeploymentValue $environmentFile 'TEAMS_APP_VERSION')
    }
    else {
        $currentVersion = Get-PackageVersion $manifest.version
    }
    if ($currentVersion.Build -eq 65535) { throw 'Patch version is exhausted; set the next major/minor version explicitly before updating.' }
    $packageVersion = '{0}.{1}.{2}' -f $currentVersion.Major, $currentVersion.Minor, ($currentVersion.Build + 1)
    foreach ($envFile in Get-ChildItem -LiteralPath (Join-Path $pluginDirectory 'env') -File -Force |
        Where-Object { $_.Name -match '^\.env\.[a-zA-Z0-9_-]+$' }) {
        $text = Get-Content -LiteralPath $envFile.FullName -Raw
        $entries = @([regex]::Matches($text, '(?m)^\s*TEAMS_APP_VERSION\s*=.*$'))
        if ($entries.Count -gt 1) { throw "Duplicate TEAMS_APP_VERSION in '$($envFile.FullName)'." }
        if ($entries.Count -eq 1) {
            $null = Get-PackageVersion (Get-DeploymentValue $envFile.FullName 'TEAMS_APP_VERSION')
            if ($manifest.version -cne '${{TEAMS_APP_VERSION}}' -and
                (Get-DeploymentValue $envFile.FullName 'TEAMS_APP_VERSION') -cne $manifest.version) {
                throw 'Literal manifest and environment versions conflict; reconcile before updating.'
            }
        }
        $value = if ($envFile.FullName -eq $environmentFile) { $packageVersion } else {
            if ($entries.Count -eq 1) { Get-DeploymentValue $envFile.FullName 'TEAMS_APP_VERSION' } else { "$currentVersion" }
        }
        $text = if ($entries.Count -eq 1) {
            [regex]::Replace($text, '(?m)^\s*TEAMS_APP_VERSION\s*=.*$', "TEAMS_APP_VERSION=$value")
        } else { $text.TrimEnd() + "`nTEAMS_APP_VERSION=$value`n" }
        $versionWrites += [pscustomobject]@{ path = $envFile.FullName; text = $text }
    }
    Write-Host "Update package version: $currentVersion -> $packageVersion (source version label: $SourceSkillVersion)"
}

Write-Host "Plugin: $SkillName | Source: $skillDirectory | Destination: $pluginDirectory"
Write-Host "Environment: $Environment (must be shared) | Recipient: $ShareEmail"
Write-Host 'This workflow provisions resources and grants access in your signed-in Microsoft 365 tenant.'
$action = if ($Update) { 'Update selected skill (replace local contents), bump package patch version' } else { 'Create' }
if (-not $PSCmdlet.ShouldProcess($pluginDirectory, "$action, validate, provision ($Environment), package, and share plugin with $ShareEmail")) {
    return
}

$wiqdCommand = Get-Command wiqd -ErrorAction SilentlyContinue
if (-not $wiqdCommand) {
    throw 'WIQD is not on PATH. Install the CLI using https://microsoft.github.io/wiqd/getting-started/installation/ and sign in with: wiqd auth login --interactive. This script does not install software.'
}
Invoke-Wiqd -Arguments @('--version')

if (-not $Update) {
    Write-Host 'Step 2: Scaffold the plugin and add the selected skill.'
    Invoke-Wiqd -Arguments @('plugin', 'create', '--name', $SkillName, '--output', $outputDirectory)
    if (-not (Test-Path -LiteralPath (Join-Path $pluginDirectory 'wiqd.plugin.json') -PathType Leaf)) {
        throw "WIQD did not create the expected project at '$pluginDirectory'."
    }
    Invoke-Wiqd -Arguments @('plugin', 'add', 'skill', '--name', $SkillName, '--folder', $pluginDirectory)
    if (-not (Test-Path -LiteralPath $targetSkillFile -PathType Leaf)) {
        throw "WIQD did not scaffold the expected skill at '$targetSkillFile'."
    }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    if (@($manifest.agentSkills | Where-Object { $_.folder -ceq "skills/$SkillName" }).Count -ne 1) {
        throw 'The selected skill was not registered exactly once in agentSkills.'
    }
    $packageVersion = "$(Get-PackageVersion $manifest.version)"
}
$attempt = [ordered]@{
    id = [guid]::NewGuid().ToString()
    startedAtUtc = [datetime]::UtcNow.ToString('o')
    completedAtUtc = $null
    operation = if ($Update) { 'update' } else { 'create' }
    environment = $Environment
    packageVersion = $packageVersion
    source = [ordered]@{
        path = (Get-Item -LiteralPath $skillDirectory).FullName
        version = $SourceSkillVersion
        git = $sourceGit
        skillMdSha256 = (Get-FileHash -LiteralPath $skillFile).Hash
        contentSha256 = $sourceSnapshot.sha256
        files = $sourceSnapshot.files
    }
    status = 'in_progress'
    stage = 'copy'
}
$provenance = [ordered]@{ schemaVersion = 1; skillName = $SkillName; attempts = @($previousHistory) + @($attempt) }
Write-Provenance
try {
    if ($Update) {
        foreach ($write in $versionWrites) { Set-Content -LiteralPath $write.path -Value $write.text -Encoding UTF8 -NoNewline }
        $manifest.version = '${{TEAMS_APP_VERSION}}'
        $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestFile -Encoding UTF8
        # Replace only the explicitly selected skill's contents, never the project or other skills.
        foreach ($child in Get-ChildItem -LiteralPath $targetSkillDirectory -Force) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force
        }
    }
    # Keep companion resources so relative references in SKILL.md continue to work.
    Get-ChildItem -LiteralPath $skillDirectory -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $targetSkillDirectory -Recurse -Force
    }
    if ((Get-FileHash -LiteralPath $skillFile).Hash -cne (Get-FileHash -LiteralPath $targetSkillFile).Hash) {
        throw 'Copied SKILL.md does not match the source.'
    }
    if ((Get-SkillSnapshot $targetSkillDirectory).sha256 -cne $sourceSnapshot.sha256 -or
        (Get-SkillSnapshot $skillDirectory).sha256 -cne $sourceSnapshot.sha256) {
        throw 'Source or copied skill content changed during the run. Deployment stopped.'
    }

    $lifecycleFile = Join-Path $pluginDirectory 'm365agents.yml'
    $lifecycle = Get-Content -LiteralPath $lifecycleFile -Raw
    # Only the standard generated lifecycle is supported; never rewrite deployment scope.
    if ($lifecycle -notmatch '(?m)^environmentFolderPath:\s*[''"]?\./env[''"]?\s*$' -or
        $lifecycle -notmatch '(?m)^\s+scope:\s*\$\{\{AGENT_SCOPE\}\}\s*$') {
        throw "Unsupported lifecycle in '$lifecycleFile'. Expected ./env and provisioning scope from AGENT_SCOPE; no tenant changes were made."
    }
    $environmentFile = Join-Path $pluginDirectory "env\.env.$Environment"
    if ((Get-DeploymentValue -Path $environmentFile -Name 'AGENT_SCOPE') -cne 'shared') {
        throw "Environment '$Environment' is not shared. Use the scaffold's dev environment, not personal local; no tenant changes were made."
    }

    Write-Host 'Step 3: Validate source before provisioning.'
    $attempt.stage = 'source_validation'
    Write-Provenance
    Invoke-Wiqd -Arguments @('plugin', 'validate', '--mode', 'source', '--path', $pluginDirectory, '--env', $Environment)

    Write-Host 'Step 4: Provision, package, validate the final ZIP, and share.'
    $attempt.stage = 'provision'
    Write-Provenance
    Invoke-Wiqd -Arguments @('plugin', 'provision', '--path', $pluginDirectory, '--env', $Environment)
    $null = Get-DeploymentValue -Path $environmentFile -Name 'TEAMS_APP_ID'
    $null = Get-DeploymentValue -Path $environmentFile -Name 'M365_TITLE_ID'
    if ($Update) {
        foreach ($name in $originalIds.Keys) {
            if ((Get-DeploymentValue $environmentFile $name) -cne $originalIds[$name]) {
                throw "Deployment identity $name changed unexpectedly. Packaging and sharing stopped."
            }
        }
    }
    $attempt.stage = 'package'
    Write-Provenance
    Invoke-Wiqd -Arguments @('plugin', 'package', '--path', $pluginDirectory, '--env', $Environment, '--output', $packageFile)
    if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) {
        throw "WIQD did not produce the expected package at '$packageFile'. Sharing was not attempted."
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packageFile)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq "skills/$SkillName/SKILL.md" })
        if ($entries.Count -ne 1) {
            throw 'The final ZIP must contain exactly one SKILL.md for the selected skill. Sharing was not attempted.'
        }
        $stream = $entries[0].Open()
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $packagedHash = [System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
            if ($packagedHash -cne $attempt.source.skillMdSha256) {
                throw 'Packaged SKILL.md does not match the source. Sharing was not attempted.'
            }
        }
        finally {
            $hasher.Dispose()
            $stream.Dispose()
        }
        $prefix = "skills/$SkillName/"
        $packagedFiles = @($archive.Entries | Where-Object {
            $_.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -and -not $_.FullName.EndsWith('/')
        })
        if ($packagedFiles.Count -ne $sourceSnapshot.files.Count) {
            throw 'Packaged skill file inventory differs from the recorded source.'
        }
        foreach ($file in $sourceSnapshot.files) {
            $matches = @($packagedFiles | Where-Object { $_.FullName -ceq ($prefix + $file.path) })
            if ($matches.Count -ne 1) { throw "Missing or duplicate packaged skill resource: '$($file.path)'." }
            $stream = $matches[0].Open()
            $hasher = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
                if ($hash -cne $file.sha256) { throw "Packaged resource differs from recorded source: '$($file.path)'." }
            }
            finally { $hasher.Dispose(); $stream.Dispose() }
        }
        $manifestEntries = @($archive.Entries | Where-Object { $_.FullName -ceq 'manifest.json' })
        if ($manifestEntries.Count -ne 1) { throw 'Final ZIP must contain one manifest.json.' }
        $manifestReader = [IO.StreamReader]::new($manifestEntries[0].Open())
        try { $packagedManifest = $manifestReader.ReadToEnd() | ConvertFrom-Json }
        finally { $manifestReader.Dispose() }
        if ($packagedManifest.version -cne $packageVersion) {
            throw 'Packaged manifest version does not match the recorded package version.'
        }
    }
    finally {
        $archive.Dispose()
    }
    $attempt.stage = 'package_validation'
    Write-Provenance
    Invoke-Wiqd -Arguments @('plugin', 'validate', '--mode', 'package', '--path', $pluginDirectory, '--env', $Environment, '--package-file', $packageFile)
    $attempt.stage = 'share'
    Write-Provenance
    Invoke-Wiqd -Arguments @('plugin', 'share', '--path', $pluginDirectory, '--env', $Environment, '--scope', 'users', '--email', $ShareEmail)
    $attempt.status = 'succeeded'
    $attempt.stage = 'complete'
    $attempt.completedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-Provenance
}
catch {
    $attempt.status = 'failed'
    $attempt.completedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-Provenance
    throw
}

[pscustomobject]@{
    PluginName = $SkillName
    PluginPath = $pluginDirectory
    SkillPath = $targetSkillFile
    PackagePath = $packageFile
    Environment = $Environment
    SharedWith = $ShareEmail
    PackageVersion = $packageVersion
    SourceSkillVersion = $SourceSkillVersion
    ProvenancePath = $provenancePath
}

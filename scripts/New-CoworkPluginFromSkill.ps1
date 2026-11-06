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
plugin directories are never overwritten. Failures stop subsequent steps;
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
Parent directory for the new <skill-name> plugin. Defaults to plugins beside
the scripts directory.

.PARAMETER Environment
Deployment environment. Defaults to dev (shared), not local (personal).
The generated lifecycle and environment must explicitly configure shared scope.

.PARAMETER ReadOnly
Return Markdown only. SkillName is required; no prompts or tenant changes.

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1 -SkillGroup paralegal -SkillName legal-research -ShareEmail 'you@contoso.com'

.EXAMPLE
$content = .\scripts\New-CoworkPluginFromSkill.ps1 -ReadOnly -SkillName legal-research

.EXAMPLE
.\scripts\New-CoworkPluginFromSkill.ps1 -SkillGroup paralegal -SkillName legal-research -ShareEmail 'you@contoso.com' -WhatIf
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
if (Test-Path -LiteralPath $pluginDirectory) {
    throw "Destination '$pluginDirectory' already exists. Choose another OutputPath; no files were overwritten."
}

Write-Host "Plugin: $SkillName | Source: $skillDirectory | Destination: $pluginDirectory"
Write-Host "Environment: $Environment (must be shared) | Recipient: $ShareEmail"
Write-Host 'This workflow provisions resources and grants access in your signed-in Microsoft 365 tenant.'
if (-not $PSCmdlet.ShouldProcess($pluginDirectory, "Create, validate, provision ($Environment), package, and share plugin with $ShareEmail")) {
    return
}

$wiqdCommand = Get-Command wiqd -ErrorAction SilentlyContinue
if (-not $wiqdCommand) {
    throw 'WIQD is not on PATH. Install the CLI using https://microsoft.github.io/wiqd/getting-started/installation/ and sign in with: wiqd auth login --interactive. This script does not install software.'
}
Invoke-Wiqd -Arguments @('--version')

Write-Host 'Step 2: Scaffold the plugin and add the selected skill.'
Invoke-Wiqd -Arguments @('plugin', 'create', '--name', $SkillName, '--output', $outputDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $pluginDirectory 'wiqd.plugin.json') -PathType Leaf)) {
    throw "WIQD did not create the expected project at '$pluginDirectory'."
}
Invoke-Wiqd -Arguments @('plugin', 'add', 'skill', '--name', $SkillName, '--folder', $pluginDirectory)
$targetSkillDirectory = Join-Path $pluginDirectory "appPackage\skills\$SkillName"
$targetSkillFile = Join-Path $targetSkillDirectory 'SKILL.md'
if (-not (Test-Path -LiteralPath $targetSkillFile -PathType Leaf)) {
    throw "WIQD did not scaffold the expected skill at '$targetSkillFile'."
}
$manifest = Get-Content -LiteralPath (Join-Path $pluginDirectory 'appPackage\manifest.json') -Raw | ConvertFrom-Json
if (@($manifest.agentSkills | Where-Object { $_.folder -ceq "skills/$SkillName" }).Count -ne 1) {
    throw 'The selected skill was not registered exactly once in agentSkills.'
}
# Keep companion resources so relative references in SKILL.md continue to work.
Get-ChildItem -LiteralPath $skillDirectory -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $targetSkillDirectory -Recurse -Force
}
if ((Get-FileHash -LiteralPath $skillFile).Hash -cne (Get-FileHash -LiteralPath $targetSkillFile).Hash) {
    throw 'Copied SKILL.md does not match the source.'
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
Invoke-Wiqd -Arguments @('plugin', 'validate', '--mode', 'source', '--path', $pluginDirectory, '--env', $Environment)

Write-Host 'Step 4: Provision, package, validate the final ZIP, and share.'
Invoke-Wiqd -Arguments @('plugin', 'provision', '--path', $pluginDirectory, '--env', $Environment)
$null = Get-DeploymentValue -Path $environmentFile -Name 'TEAMS_APP_ID'
$null = Get-DeploymentValue -Path $environmentFile -Name 'M365_TITLE_ID'
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
        if ($packagedHash -cne (Get-FileHash -LiteralPath $skillFile).Hash) {
            throw 'Packaged SKILL.md does not match the source. Sharing was not attempted.'
        }
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}
finally {
    $archive.Dispose()
}
Invoke-Wiqd -Arguments @('plugin', 'validate', '--mode', 'package', '--path', $pluginDirectory, '--env', $Environment, '--package-file', $packageFile)
Invoke-Wiqd -Arguments @('plugin', 'share', '--path', $pluginDirectory, '--env', $Environment, '--scope', 'users', '--email', $ShareEmail)

[pscustomobject]@{
    PluginName = $SkillName
    PluginPath = $pluginDirectory
    SkillPath = $targetSkillFile
    PackagePath = $packageFile
    Environment = $Environment
    SharedWith = $ShareEmail
}

# Offline regression tests. WIQD and console prompts are mocked; no tenant calls.
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '..\New-CoworkPluginFromSkill.ps1'
$sourceRoot = Join-Path $PSScriptRoot '..\..\sample-skills'
$sourceSkills = Join-Path $sourceRoot 'paralegal\skills'
$sourceFile = Join-Path $sourceSkills 'legal-research\SKILL.md'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('read-skill-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $testRoot -ItemType Directory
$global:ReadSkillTestState = $null

function Assert-True {
    param ([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Reset-TestState {
    param ([string]$Failure = '', [string[]]$Inputs = @(), [switch]$Personal, [switch]$MissingIds, [switch]$CorruptZip)
    $global:ReadSkillTestState = @{
        Calls = [System.Collections.Generic.List[string]]::new()
        Inputs = [System.Collections.Generic.Queue[string]]::new()
        Prompts = [System.Collections.Generic.List[string]]::new()
        Failure = $Failure
        Personal = $Personal.IsPresent
        MissingIds = $MissingIds.IsPresent
        CorruptZip = $CorruptZip.IsPresent
    }
    foreach ($inputValue in $Inputs) { $global:ReadSkillTestState.Inputs.Enqueue($inputValue) }
}

function Read-Host {
    param ([string]$Prompt)
    $global:ReadSkillTestState.Prompts.Add($Prompt)
    if ($global:ReadSkillTestState.Inputs.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $global:ReadSkillTestState.Inputs.Dequeue()
}

function wiqd {
    $arguments = @($args)
    function Get-Option {
        param ([string]$Name)
        $index = [array]::IndexOf($arguments, $Name)
        if ($index -lt 0) { throw "Missing WIQD argument: $Name" }
        return $arguments[$index + 1]
    }
    Assert-True ((Get-Option '--skill') -eq 'wiqd') 'Missing skill attribution.'
    Assert-True ((Get-Option '--workflow') -eq 'plugin') 'Missing workflow attribution.'
    $operation = if ($arguments[0] -eq '--version') { 'version' } else { $arguments[1] }
    if ($operation -eq 'validate') { $operation += '-' + (Get-Option '--mode') }
    $global:ReadSkillTestState.Calls.Add($operation)
    $global:LASTEXITCODE = 0
    if ($global:ReadSkillTestState.Failure -eq $operation) {
        $global:LASTEXITCODE = 17
        return
    }
    if ($global:ReadSkillTestState.Failure -eq 'eula' -and $operation -eq 'create') {
        $global:LASTEXITCODE = 3
        return
    }
    switch ($operation) {
        'version' { '0.24.0' }
        'create' {
            $project = Join-Path (Get-Option '--output') (Get-Option '--name')
            $null = New-Item -Path (Join-Path $project 'appPackage'), (Join-Path $project 'env') -ItemType Directory -Force
            '{}' | Set-Content -LiteralPath (Join-Path $project 'wiqd.plugin.json')
            @'
environmentFolderPath: ./env
provision:
  - uses: copilotAgent/publish
    with:
      scope: ${{AGENT_SCOPE}}
'@ | Set-Content -LiteralPath (Join-Path $project 'm365agents.yml')
            $scope = if ($global:ReadSkillTestState.Personal) { 'personal' } else { 'shared' }
            "AGENT_SCOPE=$scope`nTEAMS_APP_ID=" | Set-Content -LiteralPath (Join-Path $project 'env\.env.dev')
        }
        'add' {
            Assert-True ($arguments[2] -eq 'skill') 'Expected add skill.'
            $project = Get-Option '--folder'
            $name = Get-Option '--name'
            $folder = Join-Path $project "appPackage\skills\$name"
            $null = New-Item -Path $folder -ItemType Directory
            'scaffold placeholder' | Set-Content -LiteralPath (Join-Path $folder 'SKILL.md')
            @{ version = '1.0.0'; agentSkills = @(@{ folder = "skills/$name" }) } | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath (Join-Path $project 'appPackage\manifest.json')
        }
        'provision' {
            $project = Get-Option '--path'
            Assert-True ((Get-Option '--env') -eq 'dev') 'Provision must use shared dev.'
            if (-not $global:ReadSkillTestState.MissingIds) {
                $version = @(Get-Content -LiteralPath (Join-Path $project 'env\.env.dev') |
                    Where-Object { $_ -match '^TEAMS_APP_VERSION=' })
                @("AGENT_SCOPE=shared", "TEAMS_APP_ID=test-app-id", "M365_TITLE_ID=test-title-id") + $version |
                    Set-Content -LiteralPath (Join-Path $project 'env\.env.dev')
                if ($global:ReadSkillTestState.Failure -eq 'changed-identity') {
                    (Get-Content -LiteralPath (Join-Path $project 'env\.env.dev') -Raw).Replace('TEAMS_APP_ID=test-app-id', 'TEAMS_APP_ID=unexpected-id') |
                        Set-Content -LiteralPath (Join-Path $project 'env\.env.dev')
                }
            }
        }
        'package' {
            $project = Get-Option '--path'
            $zip = Get-Option '--output'
            $null = New-Item -Path (Split-Path $zip -Parent) -ItemType Directory -Force
            if ($global:ReadSkillTestState.CorruptZip) {
                'changed skill' | Set-Content -LiteralPath (Join-Path $project 'appPackage\skills\legal-research\SKILL.md')
            }
            # Build outside appPackage to avoid including the output ZIP itself.
            $temporaryZip = Join-Path $project 'test-package.zip'
            $manifest = Get-Content -LiteralPath (Join-Path $project 'appPackage\manifest.json') -Raw | ConvertFrom-Json
            if ($manifest.version -ceq '${{TEAMS_APP_VERSION}}') {
                $version = Get-Content -LiteralPath (Join-Path $project 'env\.env.dev') |
                    Where-Object { $_ -match '^TEAMS_APP_VERSION=' }
                $manifest.version = ($version -split '=', 2)[1]
            }
            if ($global:ReadSkillTestState.Failure -eq 'wrong-package-version') {
                $manifest.version = '9.9.9'
            }
            $builtManifest = Join-Path $project 'manifest.json'
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $builtManifest
            Compress-Archive -Path (Join-Path $project 'appPackage\skills'), $builtManifest -DestinationPath $temporaryZip
            Remove-Item -LiteralPath $builtManifest
            Move-Item -LiteralPath $temporaryZip -Destination $zip -Force
        }
        'validate-source' {
            Assert-True ((Get-Option '--env') -eq 'dev') 'Source validation must use dev.'
        }
        'validate-package' {
            Assert-True (Test-Path -LiteralPath (Get-Option '--package-file') -PathType Leaf) 'Must validate the exact built ZIP.'
        }
        'share' {
            Assert-True ((Get-Option '--env') -eq 'dev') 'Sharing must use shared dev.'
            Assert-True ((Get-Option '--scope') -eq 'users') 'Must not share tenant-wide.'
            Assert-True ((Get-Option '--email') -eq 'recipient@example.com') 'Wrong share recipient.'
        }
        default { throw "Unexpected WIQD operation: $operation" }
    }
}

function Invoke-TestPlugin {
    param ([string]$Output)
    & $reader -SkillGroup paralegal -SkillName legal-research -ShareEmail 'recipient@example.com' -OutputPath $Output -Confirm:$false
}

function Assert-Fails {
    param ([scriptblock]$Action, [string]$ExpectedMessage)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert-True ($null -ne $failure) "Expected failure matching: $ExpectedMessage"
    Assert-True ($failure.Exception.Message -like "*$ExpectedMessage*") "Unexpected failure: $failure"
}

try {
    Reset-TestState
    $expected = Get-Content -LiteralPath $sourceFile -Raw -Encoding UTF8
    Push-Location $testRoot
    try {
        $content = & $reader -ReadOnly legal-research
        Assert-True ($content -is [string] -and $content -ceq $expected) 'Read-only content must match, independently of working directory.'
        $content = & $reader -ReadOnly legal-research -SkillsPath $sourceSkills
        Assert-True ($content -ceq $expected) 'Explicit SkillsPath failed.'
    }
    finally { Pop-Location }
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Read-only must not invoke WIQD.'
    Assert-Fails { & $reader -ReadOnly nonexistent-skill } 'was not found'
    Assert-Fails { & $reader -ReadOnly '..' } 'does not match'

    Reset-TestState
    $previewOutput = Join-Path $testRoot 'preview'
    $null = & $reader -SkillGroup paralegal -SkillName legal-research -ShareEmail 'recipient@example.com' -OutputPath $previewOutput -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $previewOutput)) 'WhatIf must not create files.'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'WhatIf must not invoke WIQD.'

    Reset-TestState -Inputs @('invalid-group', '1', 'legal-research', 'invalid-email', 'recipient@example.com')
    $result = & $reader -OutputPath (Join-Path $testRoot 'interactive') -Confirm:$false
    Assert-True ($global:ReadSkillTestState.Prompts.Count -eq 5) 'Expected group, skill and email prompts with invalid-input retries.'
    Assert-True ($result.PluginName -eq 'legal-research' -and $result.SharedWith -eq 'recipient@example.com') 'Wrong workflow result.'
    Assert-True (($global:ReadSkillTestState.Calls -join ',') -eq 'version,create,add,validate-source,provision,package,validate-package,share') 'Incorrect lifecycle ordering.'
    Assert-True ((Get-FileHash -LiteralPath $result.SkillPath).Hash -eq (Get-FileHash -LiteralPath $sourceFile).Hash) 'Copied source changed.'
    Assert-True (Test-Path -LiteralPath $result.PackagePath -PathType Leaf) 'Package must persist.'

    $initialFiles = @(Get-ChildItem -LiteralPath $result.PluginPath -File -Recurse -Force |
        Sort-Object FullName | ForEach-Object {
            '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName).Hash
        })
    foreach ($run in 2..3) {
        Reset-TestState
        Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'interactive') } 'already exists'
        Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) "Run $run must stop before any WIQD command."
        $currentFiles = @(Get-ChildItem -LiteralPath $result.PluginPath -File -Recurse -Force |
            Sort-Object FullName | ForEach-Object {
                '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName).Hash
            })
        Assert-True (($currentFiles -join "`n") -ceq ($initialFiles -join "`n")) "Run $run changed the existing plugin files."
        Write-Host "PASS: run $run blocked with 'already exists'; zero WIQD calls; existing files unchanged."
    }

    Reset-TestState
    $customSkills = Join-Path $testRoot 'custom-skills'
    $null = New-Item -Path $customSkills -ItemType Directory
    Copy-Item -LiteralPath (Join-Path $sourceSkills 'legal-research') -Destination $customSkills -Recurse
    $references = Join-Path $customSkills 'legal-research\references'
    $null = New-Item -Path $references -ItemType Directory
    'Companion content' | Set-Content -LiteralPath (Join-Path $references 'example.txt') -Encoding UTF8
    $customResult = & $reader -SkillsPath $customSkills -SkillName legal-research -ShareEmail 'recipient@example.com' -OutputPath (Join-Path $testRoot 'custom') -Confirm:$false
    Assert-True ($global:ReadSkillTestState.Prompts.Count -eq 0) 'Explicit inputs must not prompt.'
    $companion = Join-Path $customResult.PluginPath 'appPackage\skills\legal-research\references\example.txt'
    Assert-True ((Get-Content -LiteralPath $companion) -eq 'Companion content') 'Companion resources must be copied.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($customResult.PackagePath)
    try {
        Assert-True ($null -ne $archive.GetEntry('skills/legal-research/references/example.txt')) 'Companion resources must be packaged.'
    }
    finally { $archive.Dispose() }

    $provenance = Get-Content -LiteralPath $customResult.ProvenancePath -Raw | ConvertFrom-Json
    Assert-True ($provenance.attempts.Count -eq 1 -and $provenance.attempts[0].status -eq 'succeeded') 'Create provenance must record success.'
    Assert-True ($provenance.attempts[0].source.git.status -eq 'not_a_repository') 'Non-Git source must be explicit.'
    Assert-True ($customResult.PackageVersion -eq '1.0.0') 'Initial package version must come from the scaffold.'
    $originalSourceHash = $provenance.attempts[0].source.contentSha256
    $staleFile = Join-Path (Split-Path $customResult.SkillPath -Parent) 'stale.txt'
    'remove me' | Set-Content -LiteralPath $staleFile
    $otherSkill = Join-Path $customResult.PluginPath 'appPackage\skills\other-skill'
    $null = New-Item -Path $otherSkill -ItemType Directory
    'keep me' | Set-Content -LiteralPath (Join-Path $otherSkill 'SKILL.md')
    $localEnv = Join-Path $customResult.PluginPath 'env\.env.local'
    'AGENT_SCOPE=personal' | Set-Content -LiteralPath $localEnv
    $userEnv = Join-Path $customResult.PluginPath 'env\.env.dev.user'
    'LOCAL_TEST_SETTING=preserve-me' | Set-Content -LiteralPath $userEnv
    $userEnvHash = (Get-FileHash -LiteralPath $userEnv).Hash
    'Updated companion content' | Set-Content -LiteralPath (Join-Path $references 'example.txt') -Encoding UTF8
    $updateArguments = @{
        Update = $true
        SkillsPath = $customSkills
        SkillName = 'legal-research'
        ShareEmail = 'recipient@example.com'
        OutputPath = Join-Path $testRoot 'custom'
        SourceSkillVersion = '2026.11'
        Confirm = $false
    }
    Reset-TestState
    $beforePreview = Get-Content -LiteralPath $customResult.ProvenancePath -Raw
    $null = & $reader @updateArguments -WhatIf
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Update WhatIf must not invoke WIQD.'
    Assert-True ((Get-Content -LiteralPath $customResult.ProvenancePath -Raw) -ceq $beforePreview) 'Update WhatIf changed provenance.'
    Assert-True (Test-Path -LiteralPath $staleFile) 'Update WhatIf removed a file.'
    $updated = & $reader @updateArguments
    Assert-True ($updated.PackageVersion -eq '1.0.1' -and $updated.SourceSkillVersion -eq '2026.11') 'Source label and package version must be independent.'
    Assert-True (($global:ReadSkillTestState.Calls -join ',') -eq 'version,validate-source,provision,package,validate-package,share') 'Update must reuse existing project without create/add.'
    Assert-True (-not (Test-Path -LiteralPath $staleFile)) 'Stale selected-skill resources must be removed.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $otherSkill 'SKILL.md')) -eq 'keep me') 'Other skills must not change.'
    Assert-True ((Get-Content -LiteralPath $localEnv -Raw) -match 'TEAMS_APP_VERSION=1.0.0') 'Other environment versions must not bump.'
    Assert-True ((Get-FileHash -LiteralPath $userEnv).Hash -eq $userEnvHash) 'User environment settings must not change.'
    $provenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
    Assert-True ($provenance.attempts.Count -eq 2) 'Update must preserve earlier provenance.'
    Assert-True ($provenance.attempts[1].source.contentSha256 -ne $originalSourceHash) 'Companion changes must affect the content hash.'
    Assert-True ($provenance.attempts[1].status -eq 'succeeded') 'Successful update provenance missing.'
    $manifest = Get-Content -LiteralPath (Join-Path $updated.PluginPath 'appPackage\manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.version -ceq '${{TEAMS_APP_VERSION}}') 'Version must use the environment variable.'
    Reset-TestState
    $updatedAgain = & $reader @updateArguments
    Assert-True ($updatedAgain.PackageVersion -eq '1.0.2') 'Subsequent update must increment the patch.'
    Reset-TestState -Failure 'validate-source'
    Assert-Fails { & $reader @updateArguments } 'exit code 17'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('provision')) 'Failed update validation must block provisioning.'
    $failedProvenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
    Assert-True ($failedProvenance.attempts[-1].status -eq 'failed' -and $failedProvenance.attempts[-1].stage -eq 'source_validation') 'Failed attempts must not appear deployed.'
    Assert-True ($failedProvenance.attempts[-2].status -eq 'succeeded') 'Prior successful history must survive failure.'
    $targetManifestPath = Join-Path $updated.PluginPath 'appPackage\manifest.json'
    $manifestBefore = Get-Content -LiteralPath $targetManifestPath -Raw
    $badManifest = $manifestBefore | ConvertFrom-Json
    $badManifest.version = 'invalid'
    $badManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $targetManifestPath
    Reset-TestState
    Assert-Fails { & $reader @updateArguments } 'Invalid package version'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Invalid version must fail before WIQD.'
    Set-Content -LiteralPath $targetManifestPath -Value $manifestBefore -NoNewline
    $targetEnvPath = Join-Path $updated.PluginPath 'env\.env.dev'
    $envBefore = Get-Content -LiteralPath $targetEnvPath -Raw
    Set-Content -LiteralPath $targetEnvPath -Value ($envBefore.Replace('AGENT_SCOPE=shared', 'AGENT_SCOPE=personal')) -NoNewline
    Assert-Fails { & $reader @updateArguments } 'not shared'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Personal update must fail before WIQD.'
    Set-Content -LiteralPath $targetEnvPath -Value ($envBefore.Replace('TEAMS_APP_ID=test-app-id', 'TEAMS_APP_ID=')) -NoNewline
    Assert-Fails { & $reader @updateArguments } 'empty or unresolved'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Unprovisioned update must fail before WIQD.'
    Set-Content -LiteralPath $targetEnvPath -Value $envBefore -NoNewline
    'TEAMS_APP_VERSION=1.0.0' | Add-Content -LiteralPath $targetEnvPath
    Assert-Fails { & $reader @updateArguments } 'exactly one TEAMS_APP_VERSION'
    Set-Content -LiteralPath $targetEnvPath -Value $envBefore -NoNewline
    Reset-TestState
    Assert-Fails { & $reader -Update -SkillGroup paralegal -SkillName legal-research -ShareEmail 'recipient@example.com' -OutputPath (Join-Path $testRoot 'missing-update') -Confirm:$false } 'does not exist'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Missing update project must fail before WIQD.'

    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $customSkills init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Test Git initialization failed.' }
        Reset-TestState
        $null = & $reader @updateArguments
        $unbornProvenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
        Assert-True ($unbornProvenance.attempts[-1].source.git.status -eq 'unborn_repository' -and
            $null -eq $unbornProvenance.attempts[-1].source.git.commit) 'Unborn Git source must record an unavailable commit without inventing a revision.'
        & git -C $customSkills add -- .
        & git -C $customSkills -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit --quiet -m 'Test source revision'
        if ($LASTEXITCODE -ne 0) { throw 'Test Git commit failed.' }
        $head = & git -C $customSkills rev-parse HEAD
        Reset-TestState
        $null = & $reader @updateArguments
        $gitProvenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
        Assert-True ($gitProvenance.attempts[-1].source.git.commit -eq $head -and -not $gitProvenance.attempts[-1].source.git.dirty) 'Clean Git revision must be captured.'
        '.ignored-source-file' | Set-Content -LiteralPath (Join-Path $customSkills '.gitignore')
        & git -C $customSkills add -- .gitignore
        & git -C $customSkills -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false commit --quiet -m 'Ignore local source fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Test Git ignore commit failed.' }
        'Ignored but copied content' | Set-Content -LiteralPath (Join-Path $customSkills 'legal-research\.ignored-source-file')
        Reset-TestState
        $head = & git -C $customSkills rev-parse HEAD
        $null = & $reader @updateArguments
        $gitProvenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
        Assert-True ($gitProvenance.attempts[-1].source.git.dirty) 'Ignored source content included in the copy must count as dirty.'
        Remove-Item -LiteralPath (Join-Path $customSkills 'legal-research\.ignored-source-file')
        'Dirty content' | Set-Content -LiteralPath (Join-Path $references 'example.txt')
        Reset-TestState
        $null = & $reader @updateArguments
        $gitProvenance = Get-Content -LiteralPath $updated.ProvenancePath -Raw | ConvertFrom-Json
        Assert-True ($gitProvenance.attempts[-1].source.git.commit -eq $head -and $gitProvenance.attempts[-1].source.git.dirty) 'Dirty source must not be presented as the exact committed revision.'
    }
    Reset-TestState -Failure 'wrong-package-version'
    Assert-Fails { & $reader @updateArguments } 'Packaged manifest version'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('share')) 'Wrong packaged version must block sharing.'
    Reset-TestState -Failure 'changed-identity'
    Assert-Fails { & $reader @updateArguments } 'changed unexpectedly'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('package')) 'Changed deployment IDs must block packaging and sharing.'
    Reset-TestState
    Remove-Item -LiteralPath $result.ProvenancePath
    $legacy = & $reader -Update -SkillGroup paralegal -SkillName legal-research -ShareEmail 'recipient@example.com' -OutputPath (Join-Path $testRoot 'interactive') -Confirm:$false
    Assert-True ($legacy.PackageVersion -eq '1.0.1') 'Legacy plugin update must migrate the literal version.'
    $legacyProvenance = Get-Content -LiteralPath $legacy.ProvenancePath -Raw | ConvertFrom-Json
    Assert-True ($legacyProvenance.attempts.Count -eq 1 -and $legacyProvenance.attempts[0].operation -eq 'update') 'Legacy update must not fabricate earlier history.'
    Write-Host 'PASS: provenance history, Git revision/dirty state, independent source/package versions, update previews, patch increments, stale resource removal and failure records.'

    foreach ($operation in @('version', 'create', 'add', 'validate-source', 'provision', 'package', 'validate-package', 'share')) {
        Reset-TestState -Failure $operation
        $output = Join-Path $testRoot "failure-$operation"
        Assert-Fails { Invoke-TestPlugin $output } 'exit code 17'
        Assert-True ($global:ReadSkillTestState.Calls[$global:ReadSkillTestState.Calls.Count - 1] -eq $operation) "Did not stop after $operation failure."
    }
    Reset-TestState -Failure 'eula'
    Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'eula') } 'human EULA consent'
    Assert-True (($global:ReadSkillTestState.Calls -join ',') -eq 'version,create') 'EULA gate must stop without accepting terms.'
    Reset-TestState -Personal
    Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'personal') } 'not shared'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('provision')) 'Personal deployment must not provision.'
    Reset-TestState -MissingIds
    Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'missing-ids') } 'empty or unresolved'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('package')) 'Missing provisioning evidence must block packaging.'
    Reset-TestState -CorruptZip
    Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'corrupt-zip') } 'does not match the source'
    Assert-True (-not $global:ReadSkillTestState.Calls.Contains('share')) 'Changed ZIP skill must block sharing.'

    Reset-TestState
    Assert-Fails { Invoke-TestPlugin (Join-Path $testRoot 'interactive') } 'already exists'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Existing project must not invoke WIQD.'
    Assert-Fails { & $reader -SkillGroup paralegal -SkillsPath $sourceSkills -SkillName legal-research } 'not both'
    Assert-Fails { & $reader -SkillGroup paralegal -SkillName legal-research -ShareEmail 'a@example.com,b@example.com' } 'one plain email'
    Assert-True ($global:ReadSkillTestState.Calls.Count -eq 0) 'Invalid inputs must not invoke WIQD.'

    Write-Host 'PASS: reader, prompts/retries, explicit paths, WhatIf, exact copy/ZIP, lifecycle order, all CLI failure gates, scope/ID checks, repeated-run protection, collision and input validation.'
}
finally {
    # Only this test's uniquely created directory is removed.
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Remove-Variable -Name ReadSkillTestState -Scope Global
}

# Cowork Catalyst

**Your skill. Your audience. Plugin delivery, automated.**

Stop stitching together commands to turn a useful skill into something your
team can use. **Cowork Catalyst automates the journey from an existing skill to
a validated, packaged, and shared Copilot Cowork plugin** through one guided
PowerShell entry point.

Choose a skill, enter a recipient's email, and approve the run. Cowork Catalyst
handles the delivery steps so you can focus on the expertise you want to share,
not the mechanics of plugin creation.

- **Less repetitive work:** automate scaffolding, skill copying, validation,
  provisioning, packaging, and sharing instead of running each step yourself.
- **Faster handoffs:** turn existing expertise into a plugin colleagues can
  access without assembling the delivery workflow from scratch.
- **More consistent delivery:** use the same validation gates and content
  integrity checks on every run, reducing opportunities for manual mistakes.
- **Reuse what you already have:** bring existing skills and companion resources
  into Copilot Cowork without rewriting them for this workflow.

```text
YOU CHOOSE                         COWORK CATALYST AUTOMATES
-----------                        ------------------------
Skill + recipient + approval  -->  Build -> Validate -> Provision
                                             -> Package -> Validate -> Share
```

**One guided launch. Automated delivery. Built-in checks before sharing.**

Powered by the [WIQD CLI](https://microsoft.github.io/wiqd/) and based on Microsoft's
[Build plugins for Copilot Cowork](https://learn.microsoft.com/en-us/copilot/cowork/cowork-plugin-development)
guide.

## What you get

- **Guided selection:** pick a skill group and skill by number or name.
- **One skill, one plugin:** the new plugin uses the selected skill's folder name.
- **Companion resources included:** copies the entire skill folder, not just its Markdown.
- **Validation gates:** checks source before provisioning and the final ZIP before sharing.
- **Content integrity:** verifies the copied and packaged `SKILL.md` matches the source.
- **Targeted sharing:** grants access to one recipient, not the entire tenant.
- **Safe previews:** use `-WhatIf` before making changes.
- **Read-only mode:** read a skill without WIQD, sign-in, or deployment.
- **Explicit updates:** replace a selected skill in its existing deployment with a
  separately managed plugin package version.
- **Source provenance:** retain source paths, Git revisions when available, file
  hashes, and an attempt history in the local plugin project.

> **Before you run:** the full workflow creates resources in your signed-in
> Microsoft 365 tenant. Final package validation uploads the ZIP to Microsoft's
> validation service. Review the skill folder first: **all its contents, including
> hidden files, are copied**. Do not include credentials, secrets, or material you
> are not authorized to share.

## Prerequisites

For building and sharing:

1. **PowerShell.** PowerShell 7+ is recommended, especially for WIQD installation.
   The current implementation has been tested on **Windows**. PowerShell 7 and
   WIQD also support macOS and Linux, so Cowork Catalyst can be extended to those
   platforms by adapting its Windows-style paths and validating the workflow.
   Cross-platform compatibility has not yet been verified.
2. **WIQD installed and available on `PATH`.** Follow the
   [installation guide](https://microsoft.github.io/wiqd/getting-started/installation/).
   Cowork Catalyst was tested with WIQD **0.24.0** and requires the `source` and
   `package` validation modes.
3. **A Microsoft 365 account and tenant** with the required development/sharing
   permissions and access to Copilot Cowork. Your organization's policies apply.
4. **An existing skill** containing `SKILL.md`.

Check WIQD and sign in to the tenant you intend to use:

```powershell
wiqd --version
wiqd auth login --interactive
```

The script does not install software, sign you in, or accept EULAs for you.
Read-only mode only requires PowerShell and the source skill.

## Quick start

Open a PowerShell terminal in this project's root directory.

### 1. Preview the workflow

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1 -WhatIf
```

Select your skill group, skill, and recipient email. The script displays the
planned destination and action without invoking WIQD or changing files or tenant
resources. The selected destination must not already exist, even for a preview.

### 2. Create and share

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1
```

The guided prompts look like this:

```text
Cowork Catalyst
Turn existing skills into share-ready Copilot Cowork plugins.

1. paralegal
Choose a skill group (number or exact name): 1

1. legal-research
Choose a skill (number or exact name): 1

Which email address should receive access to the plugin?: colleague@contoso.com
```

Review the destination, environment, and email, then approve the PowerShell
confirmation prompt. You can cancel with **Ctrl+C**.

### 3. Find the result

For `legal-research` with the default settings:

| Output | Location |
|---|---|
| Plugin project | `plugins\legal-research` |
| Copied skill | `plugins\legal-research\appPackage\skills\legal-research\SKILL.md` |
| Deployable package | `plugins\legal-research\appPackage\build\appPackage.dev.zip` |
| Local provenance/history | `plugins\legal-research\cowork-catalyst.provenance.json` |

On success, the script returns an object with `PluginName`, `PluginPath`,
`SkillPath`, `PackagePath`, `Environment`, `SharedWith`, `PackageVersion`,
`SourceSkillVersion`, and `ProvenancePath`.

The recipient can look under **Copilot Cowork > Sources & Skills > Plugins >
Shared with me**, subject to their account access and tenant policies.

## Usage examples

### Supply the selections upfront

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1 `
    -SkillGroup paralegal `
    -SkillName legal-research `
    -ShareEmail 'colleague@contoso.com'
```

This skips selection prompts, but still asks for confirmation before changes.

### Choose another output directory

`-OutputPath` is the **parent** directory; the script adds the skill name beneath it.

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1 `
    -SkillGroup paralegal `
    -SkillName legal-research `
    -ShareEmail 'colleague@contoso.com' `
    -OutputPath 'C:\CoworkPlugins\trial-01'
```

This creates `C:\CoworkPlugins\trial-01\legal-research`.

### Use skills from another location

Point `-SkillsPath` at the directory containing individual skill folders:

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1 `
    -SkillsPath 'C:\MySkills\paralegal\skills' `
    -SkillName legal-research `
    -ShareEmail 'colleague@contoso.com'
```

Group selection is bypassed. Omit `-SkillName` to select a skill interactively.
Do not combine `-SkillsPath` with `-SkillGroup`.

### Read a skill without deploying

```powershell
$content = .\scripts\New-CoworkPluginFromSkill.ps1 `
    -ReadOnly `
    -SkillName legal-research

$content
```

Returns the entire UTF-8 Markdown, including front matter, as one string with no
branding banner. This mode defaults to the `paralegal` group, requires a skill
name, and does not prompt or invoke WIQD. You can also supply `-SkillGroup`,
`-SampleSkillsPath`, or `-SkillsPath`.

### Capture the deployment result

```powershell
$result = .\scripts\New-CoworkPluginFromSkill.ps1 `
    -SkillGroup paralegal `
    -SkillName legal-research `
    -ShareEmail 'colleague@contoso.com'

$result | Format-List
```

## Add your own skills

Use this layout under [sample-skills](./sample-skills/), or point
`-SampleSkillsPath` at another root with the same structure:

```text
sample-skills\
  <group>\
    skills\
      <skill-name>\
        SKILL.md
        references\     (optional)
        assets\         (optional)
```

Only groups containing a `skills` directory appear in the group menu. Only skill
folders containing `SKILL.md` appear in the skill menu.

For plugin creation, skill folder names must:

- Use lowercase letters and digits, optionally separated by single hyphens.
- Be at most 64 characters.
- Match the skill's front-matter name.

Example:

```markdown
---
name: legal-research
description: Legal research and case analysis guidance.
---

Your skill instructions go here.
```

Keep companion-file references relative to the skill folder. Cowork Catalyst
copies files unchanged; it does not rewrite front matter or repair invalid skills.

## Update an existing plugin

Normal create runs still refuse an existing destination. Use **`-Update`** to
intentionally update the plugin previously created for the selected skill:

```powershell
.\scripts\New-CoworkPluginFromSkill.ps1 `
    -Update `
    -SkillGroup paralegal `
    -SkillName legal-research `
    -SourceSkillVersion '2026.11' `
    -ShareEmail 'colleague@contoso.com' `
    -WhatIf
```

Remove `-WhatIf` when ready, then approve the confirmation. If the original
deployment used a custom `-OutputPath` or `-Environment`, supply those same values.
The source is still your **current local skill folder**; the script does not
download, select, or check out a historical source version.

An update:

1. Requires an existing plugin, the exact skill registration, a supported shared
   lifecycle, and populated deployment IDs. It does not create missing deployments.
2. Plans a patch-version increment, such as `1.0.0` to `1.0.1`.
3. After approval, **replaces the selected skill folder's contents**, including
   removing resources no longer in the source. Save any local edits first.
   Other skill folders are left untouched. Linked paths and overlapping
   source/output directories are rejected.
4. Validates source, re-provisions using the existing environment, verifies
   deployment IDs did not change, packages, validates the exact ZIP, and shares
   with the supplied recipient. It does not create a new project or remove
   existing recipients' access.

### Source versions and plugin versions are different

| Value | Meaning |
|---|---|
| `-SourceSkillVersion` | Optional label you supply for the source, e.g. `2026.11`. Not automatically extracted from Markdown, verified against upstream, or used to fetch files. |
| Source Git commit | Source repository's HEAD when available, with a separate dirty flag scoped to the skill folder. A dirty source is **not** claimed to be an exact copy of that commit. |
| Source content hash | SHA-256 over a sorted inventory of relative file paths and their SHA-256 hashes, covering `SKILL.md` and companion files, including hidden files. Empty directories are not hashed. |
| Plugin package version | M365 app manifest version. Create uses the scaffold's version; every approved update increments its patch component independently of the source label. |

On the first update, a literal manifest version is migrated to
`${{TEAMS_APP_VERSION}}`. Missing version settings are initialized in standard
environment files under `env`; only the selected environment's version is
incremented. Conflicting or malformed versions stop the run. There is no
automatic major/minor rollover at the maximum patch value.

Even if the source is unchanged, explicitly running `-Update` creates a new
patch-version attempt. This is not an automatic upstream synchronization service.

### Provenance and failure history

The project-root `cowork-catalyst.provenance.json` records:

- The resolved local source path and optional source-version label.
- Git root, commit, and dirty state, or an explicit unavailable/not-a-repository
  status. A new Git repository without commits is recorded as `unborn_repository`
  with no commit; malformed/inaccessible repository metadata stops the run.
- The `SKILL.md` hash, whole-skill content hash, and per-file hash inventory.
- Each attempt's operation, environment, package version, timestamps, stage, and
  `in_progress`, `succeeded`, or `failed` status.

The selected skill's file inventory, hashes, and plugin version are checked in
the final ZIP. The provenance file stays **outside the package**: it can contain
machine-specific paths and is not uploaded as plugin content. Keep the local
project/environment files to retain deployment identity and history. Provenance
is a local audit record, not a signed attestation or live tenant-state query.

Previously created plugins without provenance can be updated after the normal
registration/scope/ID checks; their history begins with that update. Earlier
source versions and deployment events cannot be reconstructed.

**No automatic rollback or resume:** a failed update retains local skill/version
changes and records its failing stage. Provisioning may already have changed the
tenant before packaging, validation, or sharing failed. A successful record means
the full command sequence completed, not that an end-user runtime test passed.
An interrupted process may leave an `in_progress` record. Inspect the project
and tenant state before retrying; another explicit update increments the version
again. Read-only and `-WhatIf` runs do not write provenance.

## Parameters

| Parameter | Purpose | Default |
|---|---|---|
| `-SkillName` | Skill folder name; required in read-only mode | Prompt in plugin mode |
| `-SkillGroup` | Group under the sample-skills root | Prompt; `paralegal` in read-only mode |
| `-SampleSkillsPath` | Root containing `<group>\skills` folders | Project's `sample-skills` |
| `-SkillsPath` | Direct directory containing skill folders; bypasses groups | Not set |
| `-ShareEmail` | One plain recipient email address | Prompt |
| `-OutputPath` | Parent directory for the new or existing plugin | Project's `plugins` |
| `-Environment` | Deployment environment; must be configured as shared | `dev` |
| `-ReadOnly` | Return Markdown without deployment | Off |
| `-Update` | Update an existing provisioned shared plugin; replace selected skill and bump package patch version | Off |
| `-SourceSkillVersion` | Optional source label for provenance, independent of package version | Not set |
| `-WhatIf` | Preview without WIQD or filesystem/tenant changes | Off |
| `-Confirm` | Control the confirmation prompt | Confirmation requested |

Default source/output paths are relative to the script's location. Explicit
relative paths are resolved from your current working directory.

For built-in help:

```powershell
Get-Help .\scripts\New-CoworkPluginFromSkill.ps1 -Full
```

## Validation and deployment boundaries

Cowork Catalyst follows this order:

1. Scaffold a new plugin with WIQD.
2. Register the skill and copy its contents.
3. Confirm the generated lifecycle uses shared deployment configuration.
4. Run offline `source` validation.
5. Provision the selected environment.
6. Require populated `TEAMS_APP_ID` and `M365_TITLE_ID` provisioning evidence.
7. Package and verify the selected skill's exact contents in the ZIP.
8. Run `package` validation against that exact ZIP.
9. Share with the specified email using `--scope users`.

**Source validation is not full skill validation.** For a skills-only plugin,
WIQD may report no declarative-agent source to check. The final package validation
provides additional package/platform checks; neither check proves the skill's
real-world behavior.

The current CLI uses `--mode source` and `--mode package`; older documentation
may describe `--mode deep`.

The standard `dev` environment is shared; `local` is personal testing and cannot
be used by this workflow for sharing. Environment names alone are not sufficient:
the script checks the generated lifecycle and `AGENT_SCOPE=shared`. It does not
silently rewrite deployment scope or create custom environment configurations.

Direct sharing is **not** submission to the organization catalog or public
Marketplace. Review generated manifest metadata, developer details, URLs, and
icons before wider distribution.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Prompt asks for `Type` under `New-CertificateNotificationTask` | A different Windows cmdlet was invoked, possibly by tab completion. Press **Ctrl+C**, then run `.\scripts\New-CoworkPluginFromSkill.ps1` exactly. |
| WIQD is not found | Install WIQD using the official guide, reopen the terminal if needed, and check `wiqd --version`. |
| Authentication or permission failure | Run `wiqd auth login --interactive`, verify the tenant/account, and check organizational permissions with your administrator. |
| EULA consent is required | Review WIQD's displayed terms and complete its human consent flow yourself. The script never accepts terms automatically. |
| Destination already exists | Use `-Update` to deliberately update that provisioned shared plugin. Use a new `-OutputPath` only when you intend a separate deployment. Nothing is resumed automatically. |
| Update has missing deployment IDs, invalid versions, or conflicting provenance | Inspect the existing project's environment, manifest, and history. Update is blocked rather than creating a replacement deployment or guessing a version. |
| No groups or skills appear | Check the directory layout and the presence of `skills` folders and `SKILL.md` files. |
| Environment is not shared or lifecycle is unsupported | Use the standard generated `dev` environment. Do not relabel an already-provisioned personal deployment as shared. |
| Source or package validation fails | Read the WIQD diagnostics and correct the source skill/configuration. Later steps will not run. |
| Skill copy or ZIP integrity check fails | Inspect the retained source/output files. Sharing is blocked if the packaged skill differs from its source. |
| PowerShell blocks script execution | Follow your organization's script-signing/execution-policy process. Do not bypass managed security policies. |

**Failures do not roll back files or cloud resources.** If provisioning succeeded
but a later step failed, the deployment can still exist even though sharing did
not complete. Inspect the retained project and WIQD output before retrying or
cleaning up. Deleting a local folder does not remove provisioned tenant resources.

Do not create repeated deployments in new output directories without first
checking whether earlier attempts left resources behind.

## Run the offline regression tests

```powershell
.\scripts\Tests\New-CoworkPluginFromSkill.Tests.ps1
```

Tests mock WIQD and console prompts; they do not provision resources, upload
packages, or share anything. They cover selection/retries, read-only output,
custom paths, previews, companion files, package integrity, lifecycle ordering,
failure gates, EULA handling, deployment-scope checks, repeated-run protection,
source provenance, Git clean/dirty state, and explicit versioned updates.

## Project entry points

- [Plugin workflow script](./scripts/New-CoworkPluginFromSkill.ps1)
- [Offline regression tests](./scripts/Tests/New-CoworkPluginFromSkill.Tests.ps1)
- [Example legal-research skill](./sample-skills/paralegal/skills/legal-research/SKILL.md)

---

Cowork Catalyst is a helper workflow for Copilot Cowork plugin development.
It does not replace tenant policy, platform validation, or human review of the
skills you distribute.

# actions

GitHub Actions shared by GrzybDev's repositories.

## codesign

Code-signs Windows files with a certificate that never leaves its machine, such as one on a smart card. A release
uploads each file to a signing store as `unsigned/<repository>/<app>/v<version>/<SHA-256>/<name>`, the machine that
holds the certificate signs it and uploads the copy under `signed/`, and the release checks that the copy is its file
with a valid signature added before it takes it. Each release clears its files from the store when it is done.

Sign files that are already built:

```yaml
- uses: GrzybDev/actions/codesign@v1
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    AWS_DEFAULT_REGION: ${{ secrets.AWS_DEFAULT_REGION }}
    AWS_ENDPOINT_URL: ${{ secrets.AWS_ENDPOINT_URL }}
  with:
    files: build/App.exe
    version: 1.2.3
    subject: ${{ vars.SIGNING_SUBJECT }}
```

Without `files`, the action only gives the signing command as its `command` output, for a tool that signs as it
packages, such as `vpk pack --signTemplate "<command> {{file...}}"`; the step that runs it needs the same `AWS_*`
environment. [`codesign/action.yml`](codesign/action.yml) describes every input. The action needs a Windows runner,
and a job that signs must end within 150 minutes, after which the signing machine removes a file instead of signing
it. The store's key needs only to list, read, write and delete files in its bucket.

### Setting up a repository

A repository that signs needs the secrets and variables that the example reads. Fill in a copy of
[`codesign/.env.example`](codesign/.env.example) named `codesign/.env`, which git ignores, and run this with the
GitHub CLI signed in:

```powershell
codesign\setup-repository.ps1 -Repository <owner>/<name>
```

It sets the `AWS_*` keys as Actions secrets and `SIGNING_SUBJECT` and `SIGNING_STORE` as Actions variables; without
`SIGNING_STORE`, the reusable workflows below sign through `s3://codesign`. A key that the file leaves out or empty
keeps what the repository has. `-WhatIf` lists what it would set, and `-EnvFile` reads another file.

### The signing machine

Keep this running there, from a clone of this repository, while a release signs; it signs each round of files in one
`signtool` call, so a card asks for its PIN once per round:

```powershell
codesign\sign-pending.ps1 -Watch
```

Before the card asks for its PIN, the script lists the files of the round; enter the PIN only when they are the files
of the release that is running. The store is `-Store`, else `SIGNING_STORE`, else `s3://codesign`. It needs Windows
PowerShell 5.1 or PowerShell 7, the AWS CLI with the store's credentials and endpoint (in the environment or an AWS
CLI profile), the card inserted with its certificate registered by proCertum CardManager, and `signtool` from Visual
Studio or the Windows SDK. When the environment names no AWS CLI profile, it takes the one that an `AWS_PROFILE` line
in `codesign/.env` names, for its own calls only; repositories never get that key. `Get-Help
codesign\sign-pending.ps1 -Detailed` lists the other parameters.

## bump-version

Raises the version with [bump-my-version](https://callowayproject.github.io/bump-my-version/) (`patch`, `minor`
or `major`), or sets the exact version that a published release names, and commits it together with a refreshed
`uv.lock`, when the project has one, as the github-actions bot. A raised version is tagged
`v<version>`; a release keeps its own tag, and the commit of its version goes to the default branch, which refuses it
if it moved past the release. `rebuild` keeps the version and builds the commit that is checked out. The job needs
`contents: write`.

```yaml
- uses: actions/checkout@v7
- id: bump
  uses: GrzybDev/actions/bump-version@v1
  with:
    bump: ${{ inputs.version_type }}
    version: ${{ github.event_name == 'release' && github.ref_name || '' }}
```

Its outputs are the `version` to build and the `ref` (a commit) to build from.

## Python app builds

A reusable workflow builds a Python app whose package is `src/<lowercase repository name>` on Linux, macOS and
Windows, with Nuitka or, given `builder: pyinstaller`, with PyInstaller, from the dependencies that its `uv.lock`
pins. Without a `version` it keeps debug builds as artifacts; with one it builds onefile executables, signs the Windows one with `codesign` and attaches them to the
release `v<version>`.

```yaml
jobs:
  build:
    needs: version
    permissions:
      contents: write
    uses: GrzybDev/actions/.github/workflows/python-app.yml@v1
    secrets: inherit
    with:
      version: ${{ needs.version.outputs.version }}
      ref: ${{ needs.version.outputs.ref }}
      include-package: rich._unicode_data
```

## Python checks

A reusable workflow lints a Python app with Ruff (and mypy, given `mypy: true`), runs its tests and calls its command
line entry points, `<lowercase repository name> --help` and `python -m <lowercase repository name> --help`, on the
dependencies that its `uv.lock` pins. The tests run on Ubuntu unless `runners` lists other runners; `apt-packages` are
installed on the Linux ones. Run builds after it, so that nothing is built from code that fails them:

```yaml
jobs:
  checks:
    uses: GrzybDev/actions/.github/workflows/python-checks.yml@v1
    with:
      test-command: pytest
      apt-packages: ffmpeg
      runners: '["ubuntu-latest", "windows-latest"]'

  build:
    needs: checks
    uses: GrzybDev/actions/.github/workflows/python-app.yml@v1
```

## C++ DLL builds

Two reusable workflows build a Visual Studio solution, `<repository name>.slnx` unless `solution` names another, for
the solution platform `platform`, `x64` when empty. Its projects take their libraries from a vcpkg manifest and write
to `<platform>\<configuration>`, or for `x86`, whose projects are Win32, to `<configuration>`, with a GoogleTest
executable `<repository name>.Tests.exe` there. A 32-bit library passes `platform: x86` to both workflows.

`cpp-checks.yml` builds the Debug configuration, runs the tests, analyzes the code with CodeQL (leaving out what vcpkg
built) and keeps the build, without the files named after the repository such as the tests, as the `DebugBuild`
artifact; it reuses what vcpkg built in earlier runs. The calling workflow grants `security-events: write` for the
analysis. `cpp-dll.yml` builds the Release configuration from scratch, runs the tests, signs the `library` with
`codesign` and attaches it to the release `v<version>`:

```yaml
jobs:
  checks:
    permissions:
      contents: read
      security-events: write
    uses: GrzybDev/actions/.github/workflows/cpp-checks.yml@v1

  version:
    # bump-version, as above

  build:
    needs: version
    permissions:
      contents: write
    uses: GrzybDev/actions/.github/workflows/cpp-dll.yml@v1
    secrets: inherit
    with:
      version: ${{ needs.version.outputs.version }}
      ref: ${{ needs.version.outputs.ref }}
      library: MFReadWrite.dll
```

## Development

The codesign scripts have Pester 5 tests, which CI runs as well:

```powershell
Invoke-Pester codesign/tests
```

The signing tests sign with a short-lived self-signed certificate that they add to the current user's store and remove
with its key when they end, through a folder store and through an S3 store that a script serves on 127.0.0.1, which
needs the AWS CLI.

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

Each executable of a release comes with `<name>_THIRD-PARTY-NOTICES.md`, written from what was installed for that
system: the Python runtime and every package with its version, licence and a link to its source code, then their licence
texts and the project's `LICENSE.md`. A package without a licence text stops the build before the signing.

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
installed on the Linux ones. Given `pnpm-build: true`, `pnpm build` runs before the tests, on Node 24 from the packages
that `pnpm-lock.yaml` pins, for tests that need what it builds. Run builds after it, so that nothing is built from code
that fails them:

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
analysis, and also `actions: read` in a private repository, whose results stay in the run as the `CodeQL` artifact
because a personal account has no code scanning for it. `cpp-dll.yml` builds the Release configuration from scratch,
runs the tests, signs the `library` with `codesign` and attaches it, with the repository's `THIRD-PARTY-NOTICES.md` if
there is one, to the release `v<version>`:

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

## .NET checks

A reusable workflow restores a .NET solution, `<repository name>.slnx` unless `solution` names another, in locked
mode, so every project needs its `packages.lock.json` (`RestorePackagesWithLockFile`), builds it in Release and runs
its xunit.v3 tests on Microsoft.Testing.Platform, with the SDK and test runner that its `global.json` selects. Warnings
fail the build where the projects make them errors; `submodules: true` checks out the submodules for a build that
needs them. It builds and tests on Ubuntu and Windows unless `runners` lists other runners, and keeps the xunit TRX
reports of a runner whose tests fail as the `test-results-<runner>` artifact.

Given `allowed-licenses`, a JSON file in the repository such as `["MIT", "Apache-2.0"]`, the first runner checks with
[nuget-license](https://github.com/sensslen/nuget-license) that every NuGet package the solution restores, transitive
ones included, has a license that the file lists. A package whose license nuget-license cannot tell from its license
expression, file or address fails the check, unless `license-overrides` names a JSON file in the repository that gives
the license of that package version as an SPDX expression:

```json
[
  { "Id": "Some.Package", "Version": "1.2.3", "License": "MPL-1.1 OR GPL-2.0-or-later" }
]
```

```yaml
jobs:
  checks:
    uses: GrzybDev/actions/.github/workflows/dotnet-checks.yml@v1
    with:
      allowed-licenses: allowed-licenses.json
      license-overrides: license-overrides.json
```

## .NET app releases

A reusable workflow releases a .NET desktop app for 64-bit Windows and Linux with [Velopack](https://velopack.io), with
the vpk that matches the Velopack package of the app. It publishes the `project` self-contained and ReadyToRun, in
locked mode like the .NET checks, which needs `win-x64` and `linux-x64` in the project's `RuntimeIdentifiers`. The
`properties` are MSBuild properties, one `Name=Value` per line. Each line of `workers`, `<folder>=<project>`, publishes
a worker process the same way into that folder of the app, and the files of `artifact`, which an earlier job of the
run uploaded, join the app's files.

For Windows, vpk packs an installer, a portable zip and the update packages, and `codesign` signs every PE file
that is not signed yet, satellite assemblies and native libraries included: all of the app's files in one round and the
installer in a second, so a release asks for the PIN twice. For Linux, vpk packs an AppImage and the update packages,
and a `.deb` installs the app into `/opt/<lowercase name>` with the command `<lowercase name>`, and a desktop entry and
the `linux-icons` named after the app's `id`.

The `id` identifies the app to its updates and names its install folder, `%LOCALAPPDATA%\<id>` on Windows, which an
uninstall removes whole, so the app keeps its own data in a folder of another name. It also names the installers, as
vpk makes them and its upload expects them: `<id>-win-Setup.exe`, `<id>-win-Portable.zip` and `<id>.AppImage`. The
`.deb` is `<lowercase name>_amd64.deb`, where `<name>` is `name`, the repository's name unless given, which also titles
the app. The installers keep their names from one release to the next and are attached to the release `v<version>`.

Given `upload: true`, the builds first download the latest release from the release store, so that vpk adds delta
packages, and the workflow then uploads the `.deb` and the `win` and `linux` update feeds with their packages through
the S3 API. The store comes from the Actions secrets `RELEASE_STORE_ENDPOINT_URL`, `RELEASE_STORE_REGION`,
`RELEASE_STORE_BUCKET`, `RELEASE_STORE_ACCESS_KEY_ID` and `RELEASE_STORE_SECRET_ACCESS_KEY`, whose key needs to list,
read and write files in the bucket. The app reads the feeds over HTTPS from the bucket's public address, which it can
take as a build property from an Actions variable:

```yaml
jobs:
  checks:
    uses: GrzybDev/actions/.github/workflows/dotnet-checks.yml@v1

  version:
    # bump-version, as above

  release:
    needs: [checks, version]
    permissions:
      contents: write
    uses: GrzybDev/actions/.github/workflows/dotnet-app.yml@v1
    secrets: inherit
    with:
      version: ${{ needs.version.outputs.version }}
      ref: ${{ needs.version.outputs.ref }}
      project: src/App/App.csproj
      id: dev.example.app
      icon: assets/app.ico
      linux-icons: assets/linux
      categories: Office;
      deb-depends: libc6 (>= 2.33), libicu74 | libicu72, libfontconfig1
      properties: UpdateFeedUrl=${{ vars.UPDATE_FEED_URL }}
      upload: true
```

## .NET server releases

A reusable workflow releases a .NET server for Linux as a container image and as archives. It publishes the `project`
in locked mode like the .NET checks, which needs `linux-x64` and every runtime of `runtimes` in the project's
`RuntimeIdentifiers`, and the files of `artifact`, which an earlier job of the run uploaded, join the server's files in
the image and in each archive.

The .NET SDK builds the image for `linux-x64` without a Dockerfile (`PublishContainer`), so the project sets its base
image, port, user and environment with the SDK's container properties. The image goes to `registry`, `ghcr.io` unless
given, as the repository `image`, such as `owner/server` in lower case, signed in with `GITHUB_TOKEN`, and is tagged
with the version and, unless it is a pre-release, with `X.Y`, `X` and `latest`. A new package on GitHub's registry
starts private.

Each runtime of `runtimes`, separated by spaces and `linux-x64` unless given, gets an archive
`<name>-<version>-<runtime>.tar.gz`, where `<name>` is the last part of `image`. It holds one folder of the same name,
owned by root: the server published self-contained and ReadyToRun as a single file, and the rest of the project's
publish output, such as a systemd unit that the project adds to it. The single file unpacks its native libraries when it
starts, into `DOTNET_BUNDLE_EXTRACT_BASE_DIR` or the home folder of the user that runs it. The archives are attached to
the release `v<version>`, and given `upload: true`, also uploaded under `server/<version>/` to the release store that
the `RELEASE_STORE_*` secrets name, as for the app releases. The calling job grants `packages: write` for the image and
`contents: write` for the release:

```yaml
jobs:
  server:
    needs: [checks, version]
    permissions:
      contents: write
      packages: write
    uses: GrzybDev/actions/.github/workflows/dotnet-server.yml@v1
    secrets: inherit
    with:
      version: ${{ needs.version.outputs.version }}
      ref: ${{ needs.version.outputs.ref }}
      project: src/Server/Server.csproj
      image: example/server
      upload: true
```

## Development

The codesign scripts have Pester 5 tests, which CI runs as well:

```powershell
Invoke-Pester codesign/tests
```

The signing tests sign with a short-lived self-signed certificate that they add to the current user's store and remove
with its key when they end, through a folder store and through an S3 store that a script serves on 127.0.0.1, which
needs the AWS CLI.

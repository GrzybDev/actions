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
Studio or the Windows SDK. `Get-Help codesign\sign-pending.ps1 -Detailed` lists the other parameters.

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

## Development

The signing scripts have Pester 5 tests, which CI runs as well:

```powershell
Invoke-Pester codesign/tests
```

They sign through a folder store with a short-lived self-signed certificate that they add to the current user's store
and remove with its key when they end.

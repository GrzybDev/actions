#requires -Version 5.1

<#
.SYNOPSIS
Sets the secrets and variables that a repository's releases need to sign with the codesign action.

.DESCRIPTION
Reads KEY=value lines from a .env file, which .env.example lists, and sets them on the repository with the GitHub CLI:
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION and AWS_ENDPOINT_URL as Actions secrets, SIGNING_SUBJECT
and SIGNING_STORE as Actions variables. A key that the file leaves out or empty keeps what the repository has; without
SIGNING_STORE, workflows sign through s3://codesign. Blank lines and lines starting with # are skipped, and a value may
be quoted. The values reach gh through its standard input and are never printed.

.EXAMPLE
codesign\setup-repository.ps1 -Repository GrzybDev/MetalGearRedirector -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # The repository to set up, as owner/name.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repository,

    # The file to read the values from, .env next to this script by default.
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$secrets = 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_DEFAULT_REGION', 'AWS_ENDPOINT_URL'
$variables = 'SIGNING_SUBJECT', 'SIGNING_STORE'

if (-not (Test-Path -LiteralPath $EnvFile)) { throw "$EnvFile does not exist: fill in a copy of .env.example there." }
# The whole file is checked before anything is set, so that a mistyped key leaves no repository half set up. No message
# repeats a line, which may hold a secret.
$values = @{}
$number = 0
foreach ($line in Get-Content -LiteralPath $EnvFile -Encoding UTF8) {
    $number++
    if ($line -match '^\s*(#|$)') { continue }
    if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        throw "Line $number of $EnvFile is not KEY=value."
    }
    $key, $value = $Matches[1], ($Matches[2] -replace '^(["''])(.*)\1$', '$2')
    if (($secrets + $variables) -notcontains $key) {
        throw "Line $number of $EnvFile sets $key, which this script does not set."
    }
    $values[$key] = $value
}

# Windows PowerShell pipes text to programs in ASCII, which turns the accented letters of a subject into question marks;
# here it takes only an unwrapped encoding, not the one New-Object returns.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# It also starts a program's input in the console's encoding, which on a UTF-8 console puts a byte order mark before the
# value; the same code page without the mark leaves the console as it is.
$consoleEncoding = [Console]::InputEncoding
$consoleAddsMark = $consoleEncoding.GetPreamble().Length -gt 0
if ($consoleAddsMark) { [Console]::InputEncoding = $OutputEncoding }
$skipped = @()
try {
    foreach ($key in $secrets + $variables) {
        if (-not $values[$key]) {
            $skipped += $key
            continue
        }
        $kind = if ($secrets -contains $key) { 'secret' } else { 'variable' }
        if (-not $PSCmdlet.ShouldProcess($Repository, "Set the $kind $key")) { continue }
        # Not on the command line, which other processes on this machine can read.
        $values[$key] | gh $kind set $key --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "gh could not set the $kind $key on $Repository." }
    }
}
finally {
    if ($consoleAddsMark) { [Console]::InputEncoding = $consoleEncoding }
}
if ($skipped) { Write-Host "$EnvFile gives no value for $($skipped -join ', '), so $Repository keeps what it has." }

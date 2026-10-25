BeforeAll {
    $scripts = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $scripts 'Signing.psm1') -Force
    $shell = (Get-Process -Id $PID).Path
    # An aborted run leaves its certificate behind.
    foreach ($leftover in Get-ChildItem Cert:\CurrentUser\My, Cert:\CurrentUser\CA |
        Where-Object { $_.Subject -eq 'CN=Build Script Tests' -and $_.Issuer -eq $_.Subject }) {
        if ($leftover.HasPrivateKey) { Remove-Item $leftover.PSPath -DeleteKey } else { Remove-Item $leftover.PSPath }
    }
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Build Script Tests' `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddMinutes(15)
    $store = Join-Path $TestDrive 'store'
    $release = @{
        SIGNING_STORE = $store; SIGNING_REPOSITORY = 'sample-repository'; SIGNING_APP = 'sample-app'; SIGNING_VERSION = '1.2.3'
        SIGNING_TIMEOUT_MINUTES = '1'; SIGNING_SUBJECT = $null
    }

    function New-UnsignedFile([string]$Name) {
        $path = Join-Path $TestDrive $Name
        Add-Type -TypeDefinition "public static class Sample$([guid]::NewGuid().ToString('N')) { }" -OutputAssembly $path
        return $path
    }

    function Get-Signer([string]$Path) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.SignerCertificate) { return $signature.SignerCertificate.Thumbprint }
    }

    function Start-Script([string]$Script, [string[]]$Arguments) {
        $log = Join-Path $TestDrive "$([guid]::NewGuid()).log"
        $process = Start-Process $shell -ArgumentList (@('-NoProfile', '-File', "`"$scripts\$Script`"") + $Arguments) `
            -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        # Without the handle taken while the process runs, its exit code is lost.
        $null = $process.Handle
        return [pscustomobject]@{ Process = $process; Log = $log }
    }

    # With a .env that does not exist, so that the codesign\.env of the machine never applies to a test.
    function Start-SignPending([string[]]$Arguments) {
        Start-Script 'sign-pending.ps1' (@('-EnvFile', "`"$(Join-Path $TestDrive 'absent.env')`"") + $Arguments)
    }

    # PowerShell hands $null to .NET as an empty string, which .NET Framework removes but PowerShell 7's .NET keeps.
    function Set-EnvironmentVariable([string]$Name, [string]$Value) {
        if ($Value) { Set-Item "Env:$Name" $Value } else { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
    }

    function Invoke-WithEnvironment([hashtable]$Variables, [scriptblock]$Script) {
        $previous = @{}
        foreach ($name in $Variables.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            Set-EnvironmentVariable $name $Variables[$name]
        }
        try {
            & $Script
        }
        finally {
            foreach ($name in $previous.Keys) { Set-EnvironmentVariable $name $previous[$name] }
        }
    }

    function Start-SignRemote([string[]]$Files, [hashtable]$Settings = @{}) {
        $environment = $release.Clone()
        foreach ($name in $Settings.Keys) { $environment[$name] = $Settings[$name] }
        Invoke-WithEnvironment $environment {
            Start-Script 'sign-remote.ps1' (@('-AllowUntrustedRoot') + @($Files | ForEach-Object { "`"$_`"" }))
        }
    }

    function Wait-Line($Started, [string]$Pattern) {
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        while (-not ($line = Select-String -LiteralPath $Started.Log -Pattern $Pattern | Select-Object -First 1)) {
            if ($Started.Process.HasExited -or [DateTime]::UtcNow -gt $deadline) {
                throw "No line matched $Pattern in: $(Get-Content $Started.Log, "$($Started.Log).err" -Raw)"
            }
            Start-Sleep -Milliseconds 200
        }
        return $line.Matches[0]
    }

    # Returns once sign-pending.ps1 watches: finding signtool can take most of a minute on a runner, which would count
    # against the release's timeout.
    function Start-Signer([string]$Store) {
        $signer = Start-SignPending @('-Watch', '-Store', "`"$Store`"", '-CertificateThumbprint',
            $certificate.Thumbprint, '-TimestampUrl', '""', '-IntervalSeconds', '1', '-SettleSeconds', '1', '-AllowUntrustedRoot')
        try {
            Wait-Line $signer '^Watching ' | Out-Null
        }
        catch {
            Stop-Script $signer
            throw
        }
        return $signer
    }

    function Stop-Script($Started) {
        Stop-Process -Id $Started.Process.Id
        $Started.Process.WaitForExit()
        # A call to the AWS CLI that it was running holds its log open until it ends.
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Started.Process.Id)" | ForEach-Object {
            Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            Wait-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        }
    }

    function Wait-Script($Started) {
        $Started.Process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $Started.Process.ExitCode
            Output = (Get-Content $Started.Log, "$($Started.Log).err" -Raw) -join "`n"
        }
    }

    function Add-StoreEntry([string]$Store, [string]$Key, [string]$File, [switch]$Abandoned) {
        $path = Join-Path $Store $Key
        New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
        if ($File) { Copy-Item $File $path } else { Set-Content $path 'content' }
        if ($Abandoned) { (Get-Item $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-3) }
    }

    function Get-StoreContent([string]$Store) {
        @('unsigned/', 'signed/' | ForEach-Object { Get-StoreFiles $Store $_ } | ForEach-Object Key | Sort-Object)
    }

    # Answers the upload of a file as the signing machine would, with any content.
    function Publish-Counterpart([string]$File, [string]$Content = $File, [switch]$Unsigned) {
        $hash = (Get-FileHash $File).Hash.ToLowerInvariant()
        $key = "sample-repository/sample-app/v1.2.3/$hash/$(Split-Path -Leaf $File)"
        $deadline = [DateTime]::UtcNow.AddMinutes(1)
        while (-not (Test-Path (Join-Path $store "unsigned/$key"))) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "$File was never uploaded." }
            Start-Sleep -Milliseconds 100
        }
        $signed = Join-Path $store "signed/$key"
        New-Item -ItemType Directory -Force (Split-Path -Parent $signed) | Out-Null
        Copy-Item $Content $signed
        if (-not $Unsigned) {
            Set-AuthenticodeSignature -FilePath $signed -Certificate $certificate -HashAlgorithm SHA256 | Out-Null
        }
    }
}

AfterAll {
    Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -DeleteKey
    # New-SelfSignedCertificate also puts a copy, without the key, among the intermediate authorities.
    Remove-Item "Cert:\CurrentUser\CA\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
}

Describe 'Signing through a store' {
    It "signs a round's files with one signtool call, and the same content again for a later run" {
        $first = New-UnsignedFile 'first.dll'
        $second = New-UnsignedFile "second caf$([char]0xE9).dll"
        $again = Join-Path $TestDrive 'again\first.dll'
        New-Item -ItemType Directory (Split-Path -Parent $again) | Out-Null
        Copy-Item $first $again
        $signer = Start-Signer $store
        try {
            $result = Wait-Script (Start-SignRemote $first, $second)
            $againResult = Wait-Script (Start-SignRemote $again)
        }
        finally {
            Stop-Script $signer
        }

        $result.ExitCode | Should -Be 0
        Get-Signer $first | Should -Be $certificate.Thumbprint
        Get-Signer $second | Should -Be $certificate.Thumbprint
        $againResult.ExitCode | Should -Be 0
        Get-Signer $again | Should -Be $certificate.Thumbprint
        @(Get-Content $signer.Log | Where-Object { $_ -like 'Signing * file(s)*' }) |
            Should -Be 'Signing 2 file(s) with one signtool call:', 'Signing 1 file(s) with one signtool call:'
        Get-StoreContent $store | Should -BeNullOrEmpty
    }

    It 'signs through an S3 store whose proxy drops the Content-Length of requests without a body' {
        $file = New-UnsignedFile 'stored.dll'
        $buckets = Join-Path $TestDrive 'buckets'
        $config = Join-Path $TestDrive 'aws-config'
        # The AWS CLI's s3 commands sign with the CRT client on the runners; this makes them do so wherever this runs.
        Set-Content $config "[default]`ns3 =`n  preferred_transfer_client = crt"
        $aws = @{
            AWS_CONFIG_FILE = $config; AWS_SHARED_CREDENTIALS_FILE = $config; AWS_PROFILE = $null
            AWS_ACCESS_KEY_ID = 'sample-key'; AWS_SECRET_ACCESS_KEY = 'sample-secret'; AWS_SESSION_TOKEN = $null
            AWS_DEFAULT_REGION = 'us-east-1'; AWS_ENDPOINT_URL_S3 = $null
        }
        $server = Start-Script 'tests\FakeS3Store.ps1' @('-Root', "`"$buckets`"")
        try {
            $aws.AWS_ENDPOINT_URL = "http://127.0.0.1:$((Wait-Line $server '^Listening on (\d+)').Groups[1].Value)"
            $result = Invoke-WithEnvironment $aws {
                $signer = Start-Signer 's3://codesign/releases'
                try {
                    Wait-Script (Start-SignRemote $file @{ SIGNING_STORE = 's3://codesign/releases' })
                }
                finally {
                    Stop-Script $signer
                }
            }
        }
        finally {
            Stop-Script $server
        }

        $result.Output | Should -Match 'Signed stored\.dll\.'
        $result.ExitCode | Should -Be 0
        Get-Signer $file | Should -Be $certificate.Thumbprint
        @(Get-ChildItem $buckets -Recurse -File) | Should -BeNullOrEmpty
    }

    It 'never picks a certificate the system does not trust' {
        $result = Wait-Script (Start-SignPending @('-Store', "`"$(Join-Path $TestDrive 'empty')`"",
            '-TimestampUrl', '""'))

        $result.Output | Should -Match 'Signing as |No trusted code-signing certificate'
        $result.Output | Should -Not -Match $certificate.Thumbprint
    }

    It 'signs nothing whose content differs from its key' {
        $swapped = Join-Path $TestDrive 'swapped'
        $file = New-UnsignedFile 'swapped.dll'
        Add-StoreEntry $swapped "unsigned/sample-repository/sample-app/v1.2.3/$('0' * 64)/swapped.dll" $file
        Add-StoreEntry $swapped 'unsigned/other-layout/swapped.dll' $file

        $result = Wait-Script (Start-SignPending @('-Store', "`"$swapped`"", '-CertificateThumbprint',
            $certificate.Thumbprint, '-TimestampUrl', '""', '-SettleSeconds', '0', '-AllowUntrustedRoot'))

        $result.ExitCode | Should -Be 0
        # The console wraps a warning wider than its window.
        $result.Output -replace '\r?\n', '' | Should -Match 'v1\.2\.3/0{64}/swapped\.dll does not hold the content its name gives'
        $result.Output | Should -Not -Match 'Signing \d+ file'
        Test-Path (Join-Path $swapped 'signed') | Should -BeFalse
    }

    It 'takes a signature only from the certificate that SIGNING_SUBJECT names' {
        $refused = New-UnsignedFile 'refused.dll'
        $accepted = New-UnsignedFile 'accepted.dll'

        $runs = (Start-SignRemote $refused @{ SIGNING_SUBJECT = 'CN=Someone Else' }),
            (Start-SignRemote $accepted @{ SIGNING_SUBJECT = 'CN=Build Script Tests' })
        Publish-Counterpart $refused
        Publish-Counterpart $accepted
        $refusal, $acceptance = $runs | ForEach-Object { Wait-Script $_ }

        $refusal.ExitCode | Should -Not -Be 0
        $refusal.Output | Should -Match 'refused\.dll\.signed is not signed by the expected certificate'
        Get-Signer $refused | Should -BeNullOrEmpty
        $acceptance.ExitCode | Should -Be 0
        Get-Signer $accepted | Should -Be $certificate.Thumbprint
    }

    It 'takes from the store only the uploaded file with a valid signature added' {
        $unsigned = New-UnsignedFile 'unsigned.dll'
        $substituted = New-UnsignedFile 'substituted.dll'

        $runs = (Start-SignRemote $unsigned), (Start-SignRemote $substituted)
        Publish-Counterpart $unsigned -Unsigned
        Publish-Counterpart $substituted -Content (New-UnsignedFile 'other.dll')
        $unsignedResult, $substitutedResult = $runs | ForEach-Object { Wait-Script $_ }

        $unsignedResult.ExitCode | Should -Not -Be 0
        $unsignedResult.Output | Should -Match 'unsigned\.dll\.signed carries no valid signature'
        Get-Signer $unsigned | Should -BeNullOrEmpty
        $substitutedResult.ExitCode | Should -Not -Be 0
        $substitutedResult.Output | Should -Match 'substituted\.dll\.signed is not substituted\.dll with a signature added'
        Get-Signer $substituted | Should -BeNullOrEmpty
        Get-StoreContent $store | Should -BeNullOrEmpty
    }

    It 'gives up when no signature comes in time' {
        $file = New-UnsignedFile 'late.dll'

        $result = Wait-Script (Start-SignRemote $file @{ SIGNING_TIMEOUT_MINUTES = '0.01' })

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Not signed within 0\.01 min: late\.dll'
        Get-Signer $file | Should -BeNullOrEmpty
        Get-StoreContent $store | Should -BeNullOrEmpty
    }
}

Describe 'Files that no release waits for' {
    BeforeAll {
        function Get-EntryKey([string]$Side, [string]$File, [string]$Version = '1.2.3') {
            $hash = (Get-FileHash $File).Hash.ToLowerInvariant()
            "$Side/sample-repository/sample-app/v$Version/$hash/$(Split-Path -Leaf $File)"
        }
    }

    It 'removes files that no release run can wait for any more instead of signing them, and signs the fresh ones' {
        $aged = Join-Path $TestDrive 'aged'
        $fresh = New-UnsignedFile 'fresh.dll'
        $abandoned = New-UnsignedFile 'abandoned.dll'
        $earlier = New-UnsignedFile 'earlier.dll'
        $kept = New-UnsignedFile 'kept.dll'
        Add-StoreEntry $aged (Get-EntryKey 'unsigned' $fresh) $fresh
        Add-StoreEntry $aged (Get-EntryKey 'unsigned' $abandoned) $abandoned -Abandoned
        Add-StoreEntry $aged (Get-EntryKey 'signed' $earlier '1.2.2') $earlier -Abandoned
        Add-StoreEntry $aged (Get-EntryKey 'unsigned' $kept) $kept -Abandoned
        Add-StoreEntry $aged 'unsigned/other-repository/v1.0.0/tool.exe' $earlier -Abandoned

        # Held open without delete sharing, it cannot be removed, as with a store key that may not delete.
        $lock = [System.IO.File]::Open((Join-Path $aged (Get-EntryKey 'unsigned' $kept)), 'Open', 'Read', 'Read')
        try {
            $result = Wait-Script (Start-SignPending @('-Store', "`"$aged`"", '-CertificateThumbprint',
                $certificate.Thumbprint, '-TimestampUrl', '""', '-SettleSeconds', '0', '-AllowUntrustedRoot'))
        }
        finally {
            $lock.Dispose()
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Removed unsigned/sample-repository/sample-app/v1\.2\.3/abandoned\.dll'
        $result.Output | Should -Match 'Removed signed/sample-repository/sample-app/v1\.2\.2/earlier\.dll'
        [regex]::Matches($result.Output, 'WARNING: unsigned/sample-repository/sample-app/v1\.2\.3/kept\.dll, ').Count |
            Should -Be 1
        $result.Output | Should -Match 'Signing 1 file\(s\)'
        Get-StoreContent $aged | Should -Be @((Get-EntryKey 'signed' $fresh), (Get-EntryKey 'unsigned' $fresh),
            (Get-EntryKey 'unsigned' $kept), 'unsigned/other-repository/v1.0.0/tool.exe' | Sort-Object)
        Get-Signer (Join-Path $aged (Get-EntryKey 'signed' $fresh)) | Should -Be $certificate.Thumbprint
    }
}

Describe 'The AWS CLI profile of the signing machine' {
    BeforeAll {
        # Stands in for the AWS CLI: records the profile of each call and answers that the store is empty.
        $bin = Join-Path $TestDrive 'aws-bin'
        $profiles = Join-Path $bin 'profiles.txt'
        New-Item -ItemType Directory $bin | Out-Null
        Set-Content (Join-Path $bin 'aws.cmd') -Encoding Ascii -Value '@echo off',
            '>>"%~dp0profiles.txt" echo(%AWS_PROFILE%', 'echo null'
        $envFile = Join-Path $TestDrive 'profile.env'
        [System.IO.File]::WriteAllLines($envFile, [string[]]@('AWS_ACCESS_KEY_ID=sample-key-id',
            'AWS_PROFILE=sample-file-profile'))
        $originalPath = $env:PATH
        $env:PATH = "$bin;$env:PATH"
        (Get-Command aws).Source | Should -Be (Join-Path $bin 'aws.cmd')
    }

    AfterAll {
        $env:PATH = $originalPath
    }

    It 'uses <expected> for its AWS CLI calls and leaves the environment as it was' -ForEach @(
        @{ Environment = $null; Expected = 'sample-file-profile' }
        @{ Environment = 'sample-environment-profile'; Expected = 'sample-environment-profile' }
    ) {
        Remove-Item $profiles -ErrorAction SilentlyContinue
        $arguments = @{
            Store = 's3://sample-bucket'; EnvFile = $envFile; CertificateThumbprint = $certificate.Thumbprint
            TimestampUrl = ''
        }
        Invoke-WithEnvironment @{ AWS_PROFILE = $Environment } {
            # In this process, as when run from a console, so that a profile left behind shows here.
            & "$scripts\sign-pending.ps1" @arguments 6>$null
            $env:AWS_PROFILE | Should -Be $Environment
        }

        Get-Content $profiles | Sort-Object -Unique | Should -Be $Expected
    }
}

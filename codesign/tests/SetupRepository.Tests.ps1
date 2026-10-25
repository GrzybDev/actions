BeforeAll {
    $setupScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup-repository.ps1'
    $envFile = Join-Path $TestDrive '.env'
    $repository = 'sample-owner/sample-repository'

    # Stands in for the GitHub CLI as a program, so that the values take the same pipe as to gh, and records what each
    # call gets.
    $bin = Join-Path $TestDrive 'bin'
    $arguments = Join-Path $bin 'arguments.txt'
    $received = Join-Path $bin 'input.txt'
    New-Item -ItemType Directory $bin | Out-Null
    Set-Content (Join-Path $bin 'gh.cmd') -Encoding Ascii -Value '@echo off', '>>"%~dp0arguments.txt" echo %*',
        '>>"%~dp0input.txt" findstr "^"', 'exit /b %GH_EXIT_CODE%'
    $path = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    (Get-Command gh).Source | Should -Be (Join-Path $bin 'gh.cmd')

    # Without a byte order mark, as editors save it.
    function Set-EnvFile([string[]]$Lines) {
        [System.IO.File]::WriteAllLines($envFile, $Lines)
    }
}

AfterAll {
    $env:PATH = $path
    Remove-Item Env:GH_EXIT_CODE -ErrorAction SilentlyContinue
}

Describe 'Setting up a repository' {
    BeforeEach {
        Remove-Item $arguments, $received -ErrorAction SilentlyContinue
        $env:GH_EXIT_CODE = '0'
    }

    It 'sets nothing with -WhatIf, then each repository key the file gives, with its value only on standard input' {
        $subject = "CN=Sample Signer, L=Sample Town$([char]0xE9), C=PL"
        Set-EnvFile '# Sample values', '', 'AWS_ACCESS_KEY_ID=sample-key-id',
            ' AWS_SECRET_ACCESS_KEY = "sample secret" ', 'AWS_DEFAULT_REGION=sample-region',
            "SIGNING_SUBJECT='$subject'", 'SIGNING_STORE=', 'AWS_PROFILE=sample-profile'

        & $setupScript -Repository $repository -EnvFile $envFile -WhatIf
        Test-Path $arguments | Should -BeFalse

        & $setupScript -Repository $repository -EnvFile $envFile
        Get-Content $arguments | Should -Be "secret set AWS_ACCESS_KEY_ID --repo $repository",
            "secret set AWS_SECRET_ACCESS_KEY --repo $repository", "secret set AWS_DEFAULT_REGION --repo $repository",
            "variable set SIGNING_SUBJECT --repo $repository"
        $values = "sample-key-id`r`nsample secret`r`nsample-region`r`n$subject`r`n"
        # As bytes: comparing strings ignores a byte order mark, which gh would keep in the value.
        [System.IO.File]::ReadAllBytes($received) | Should -Be ([System.Text.Encoding]::UTF8.GetBytes($values))
    }

    It 'refuses a file with <problem> before it sets anything, without repeating the line' -ForEach @(
        @{ Problem = 'a key that no script reads'; Line = 'AWS_SESSION_TOKEN=sample-token'
            Message = '* sets AWS_SESSION_TOKEN, which neither this script nor sign-pending.ps1 reads.' }
        @{ Problem = 'a line that is not KEY=value'; Line = 'sample-token'; Message = 'Line 2 of * is not KEY=value.' }
    ) {
        Set-EnvFile 'AWS_ACCESS_KEY_ID=sample-key-id', $Line

        { & $setupScript -Repository $repository -EnvFile $envFile } | Should -Throw -ExpectedMessage $Message
        Test-Path $arguments | Should -BeFalse
    }

    It 'stops at the first key that gh fails to set' {
        Set-EnvFile 'AWS_ACCESS_KEY_ID=sample-key-id', 'AWS_SECRET_ACCESS_KEY=sample-secret'
        $env:GH_EXIT_CODE = '1'

        { & $setupScript -Repository $repository -EnvFile $envFile } |
            Should -Throw -ExpectedMessage "gh could not set the secret AWS_ACCESS_KEY_ID on $repository."
        @(Get-Content $arguments).Count | Should -Be 1
    }
}

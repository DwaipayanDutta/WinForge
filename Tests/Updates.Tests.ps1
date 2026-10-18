BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Hash verification' {
    It 'detects a mismatch' {
        $f = Join-Path $TestDrive 'x.zip'
        'hello' | Set-Content $f
        $r = Test-WinForgeHash -File $f -ExpectedHash ('0' * 64)
        $r.Match | Should -BeFalse
    }
    It 'accepts a match' {
        $f = Join-Path $TestDrive 'y.zip'
        'hello' | Set-Content $f
        $h = (Get-FileHash $f -Algorithm SHA256).Hash
        (Test-WinForgeHash -File $f -ExpectedHash $h.ToLower()).Match | Should -BeTrue
    }
    It 'rejects an expected value that is not a SHA256 hash' {
        $f = Join-Path $TestDrive 'z.zip'; 'x' | Set-Content $f
        { Test-WinForgeHash -File $f -ExpectedHash '' } | Should -Throw '*not a SHA256*'
    }
}

Describe 'SHA256SUMS parsing' {
    BeforeAll { $h1 = 'A' * 64; $h2 = 'B' * 64 }
    It 'matches the file name exactly' {
        Get-WinForgeExpectedHash -SumsLines @("$h1  WinForge-1.0.zip.old", "$h2  WinForge-1.0.zip") -FileName 'WinForge-1.0.zip' | Should -Be $h2
    }
    It 'accepts the binary-mode asterisk' {
        Get-WinForgeExpectedHash -SumsLines @("$h1 *WinForge-1.0.zip") -FileName 'WinForge-1.0.zip' | Should -Be $h1
    }
    It 'throws when the file is not listed' {
        { Get-WinForgeExpectedHash -SumsLines @("$h1  Other.zip") -FileName 'WinForge-1.0.zip' } | Should -Throw '*does not list*'
    }
}

Describe 'Release asset URLs' {
    It 'accepts <Url>' -ForEach @(@{ Url = 'https://github.com/DwaipayanDutta/WinForge/releases/download/v1.0/WinForge-1.0.zip' }) {
        Test-WinForgeReleaseUrl $Url | Should -BeTrue
    }
    It 'rejects <Url>' -ForEach @(
        @{ Url = 'http://github.com/DwaipayanDutta/WinForge/releases/download/v1.0/WinForge-1.0.zip' }
        @{ Url = 'https://evil.example/DwaipayanDutta/WinForge/releases/download/v1.0/WinForge-1.0.zip' }
        @{ Url = 'https://github.com/someone/WinForge/releases/download/v1.0/WinForge-1.0.zip' }
        @{ Url = 'https://github.com/DwaipayanDutta/WinForge/raw/main/WinForge-1.0.zip' }
    ) {
        Test-WinForgeReleaseUrl $Url | Should -BeFalse
    }
}

Describe 'Update check' {
    It 'deletes the download and throws on a hash mismatch' {
        $ctx = New-WfTestContext
        Initialize-WinForgeLog -Context $ctx
        Mock Get-WinForgeLatestRelease { [pscustomobject]@{ Tag = 'v9.9.9'; Published = 'x'; Assets = @(
            [pscustomobject]@{ Name = 'WinForge-9.9.9.zip'; Url = 'https://github.com/DwaipayanDutta/WinForge/releases/download/v9.9.9/WinForge-9.9.9.zip' }
            [pscustomobject]@{ Name = 'SHA256SUMS.txt'; Url = 'https://github.com/DwaipayanDutta/WinForge/releases/download/v9.9.9/SHA256SUMS.txt' }) } }
        Mock Invoke-WebRequest { if ($OutFile -like '*.zip') { 'payload' | Set-Content $OutFile } else { "$('0' * 64)  WinForge-9.9.9.zip" | Set-Content $OutFile } }
        { Invoke-WinForgeUpdateCheck -Context $ctx -Download } | Should -Throw '*Hash mismatch*'
        Test-Path (Join-Path $ctx.StateRoot 'updates\WinForge-9.9.9.zip') | Should -BeFalse
    }
    It 'reports whether the release is newer without downloading' {
        $ctx = New-WfTestContext
        Mock Get-WinForgeLatestRelease { [pscustomobject]@{ Tag = 'v9.9.9'; Published = 'x'; Assets = @(
            [pscustomobject]@{ Name = 'WinForge-9.9.9.zip'; Url = 'https://github.com/DwaipayanDutta/WinForge/releases/download/v9.9.9/WinForge-9.9.9.zip' }
            [pscustomobject]@{ Name = 'SHA256SUMS.txt'; Url = 'https://github.com/DwaipayanDutta/WinForge/releases/download/v9.9.9/SHA256SUMS.txt' }) } }
        Mock Invoke-WebRequest {}
        $r = Invoke-WinForgeUpdateCheck -Context $ctx
        $r.UpdateAvailable | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0
    }
}

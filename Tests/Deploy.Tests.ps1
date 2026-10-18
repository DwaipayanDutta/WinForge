BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-WinForgeLog -Context ([pscustomobject]@{ LogDir = $TestDrive; StateWritable = $false })
    function New-WfAnswerFile { param([hashtable] $Extra = @{})
        $f = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.xml')
        New-WinForgeAutounattend -OutFile $f @Extra | Out-Null
        return $f
    }
}

Describe 'Autounattend' {
    It 'refuses to overwrite an existing file' {
        $f = Join-Path $TestDrive 'a.xml'
        'x' | Set-Content $f
        { New-WinForgeAutounattend -OutFile $f } | Should -Throw '*overwrite*'
    }
    It 'produces XML that parses, with the wcm namespace declared' {
        $doc = [xml](Get-Content (New-WfAnswerFile) -Raw)
        $doc.DocumentElement.GetAttribute('xmlns:wcm') | Should -Be 'http://schemas.microsoft.com/WMIConfig/2002/State'
    }
    It 'contains no disk configuration by default' {
        (Get-Content (New-WfAnswerFile) -Raw) | Should -Not -Match 'DiskConfiguration|CreatePartition'
    }
    It 'omits disk wipe when -NoDiskWipe is set' {
        (Get-Content (New-WfAnswerFile @{ NoDiskWipe = $true }) -Raw) | Should -Not -Match 'CreatePartition'
    }
    It 'refuses to generate an unattended disk wipe' {
        { New-WinForgeAutounattend -OutFile (Join-Path $TestDrive 'w.xml') -IncludeDiskWipe } | Should -Throw '*not implemented*'
        Test-Path (Join-Path $TestDrive 'w.xml') | Should -BeFalse
    }
    It 'forces a password change and removes cached answer files' {
        $x = Get-Content (New-WfAnswerFile) -Raw
        $x | Should -Match 'net user WinForge /logonpasswordchg:yes'
        $x | Should -Match 'Panther\\unattend\.xml'
    }
    It 'rejects values that would inject XML: <Name>' -ForEach @(
        @{ Name = 'ComputerName'; Value = 'PC</ComputerName><x>' }
        @{ Name = 'Locale'; Value = 'en-US"><x a="' }
        @{ Name = 'TimeZone'; Value = 'Nowhere Standard Time' }
        @{ Name = 'UserName'; Value = 'a b&c' }
        @{ Name = 'Profile'; Value = 'Aggressive -Expert' }
    ) {
        $p = @{ OutFile = (Join-Path $TestDrive 'inj.xml'); $Name = $Value }
        { New-WinForgeAutounattend @p } | Should -Throw
        Test-Path (Join-Path $TestDrive 'inj.xml') | Should -BeFalse
    }
}

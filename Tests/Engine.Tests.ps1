BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $two = New-WfTestTweak -Id 'test-two' -Targets @(
        @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'A'; Kind = 'DWord'; Value = 1 }
        @{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'B'; Kind = 'DWord'; Value = 1 })
    $one = New-WfTestTweak -Id 'test-one' -Targets @(@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'C'; Kind = 'DWord'; Value = 1 })
    $dng = New-WfTestTweak -Id 'test-danger' -Risk 'Danger' -Targets @(@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\WinForgeTest'; Name = 'D'; Kind = 'DWord'; Value = 1 })
    $catalogDir = New-WfTestCatalog -Tweaks @($two, $one, $dng) -Profiles @(@{ Id = 'P'; Name = 'P'; TweakIds = @('test-one','test-two') })

    # Adapters are mocked with an in-memory "registry" keyed by value name.
    function Initialize-WfFakeSystem {
        $global:WfFake = @{}
        $global:WfRestored = New-Object System.Collections.Generic.List[string]
        Mock Get-WinForgeSystemInfo { Get-WfTestSystem }
        Mock Get-TargetSnapshot { [pscustomobject]@{ Existed = $false; KeyExisted = $true; Kind = $null; Value = $null } }
        Mock Invoke-TargetApply { $global:WfFake[$Target.Name] = $true }
        Mock Test-SingleTarget { [bool]$global:WfFake[$Target.Name] }
        Mock Restore-TargetSnapshot { $global:WfFake.Remove($Target.Name); $global:WfRestored.Add($Target.Name) }
    }
}

AfterAll { Remove-Variable -Name WfFake, WfRestored, WfSawApplying -Scope Global -ErrorAction SilentlyContinue }

Describe 'Engine apply' {
    BeforeEach { Initialize-WfFakeSystem; $ctx = New-WfTestContext -CatalogRoot $catalogDir -Elevated }

    It 'does not call any adapter when -Preview is used' {
        $plan = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Preview
        $plan[0].Supported | Should -BeTrue
        Should -Invoke Invoke-TargetApply -Times 0
    }
    It 'refuses to apply without confirmation (-Force)' {
        { Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' } | Should -Throw '*requires confirmation*'
        Should -Invoke Invoke-TargetApply -Times 0
    }
    It 'refuses to apply without elevation' {
        $ctx.Elevated = $false
        { Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Force } | Should -Throw '*Administrator*'
    }
    It 'throws on an unknown tweak ID' {
        { Invoke-WinForgeOperation -Context $ctx -TweakId 'no-such-tweak' -Preview } | Should -Throw "*Unknown tweak ID*"
    }
    It 'applies, verifies and writes a completed run record' {
        $r = Invoke-WinForgeOperation -Context $ctx -Profile 'P' -Force
        @($r).Count | Should -Be 2
        @($r | Where-Object Status -ne 'AppliedVerified') | Should -BeNullOrEmpty
        $rec = Get-WinForgeHistory -Context $ctx
        $rec.State | Should -Be 'Completed'
        $rec.Applied | Should -Be 2
    }
    It 'persists the captured state before changing anything' {
        $global:WfSawApplying = $false
        Mock Invoke-TargetApply {
            $f = Get-ChildItem -LiteralPath $ctx.RunDir -Filter '*.json' | Select-Object -First 1
            $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $last = @($rec.Tweaks)[-1]
            $global:WfSawApplying = ($last.Status -eq 'Applying' -and $null -ne $last.Before)
            $global:WfFake[$Target.Name] = $true
        }
        Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Force | Out-Null
        $global:WfSawApplying | Should -BeTrue
    }
    It 'rolls back already-applied targets when a later target fails' {
        Mock Invoke-TargetApply { if ($Target.Name -eq 'B') { throw 'access denied' }; $global:WfFake[$Target.Name] = $true }
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-two' -Force
        $r[0].Status | Should -Be 'RolledBack'
        $global:WfRestored | Should -Be @('A')
        $global:WfFake.ContainsKey('A') | Should -BeFalse
    }
    It 'reports VerifyFailed (and keeps it undoable) when the write cannot be verified' {
        Mock Test-SingleTarget { $false }
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Force
        $r[0].Status | Should -Be 'VerifyFailed'
    }
    It 'marks an already-applied tweak as AlreadyApplied and does not re-apply' {
        Mock Test-TweakTargets { $true }
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Force
        $r[0].Status | Should -Be 'AlreadyApplied'
        Should -Invoke Invoke-TargetApply -Times 0
    }
    It 'refuses to run against a catalog that fails validation' {
        $bad = New-WfTestTweak -Id 'test-bad'; $bad.Script = 'calc.exe'
        $ctx.CatalogRoot = New-WfTestCatalog -Tweaks @($one, $bad)
        { Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one' -Preview } | Should -Throw '*failed validation*'
        Should -Invoke Get-TargetSnapshot -Times 0
    }
}

Describe 'Danger gate in the engine' {
    BeforeEach { Initialize-WfFakeSystem; $ctx = New-WfTestContext -CatalogRoot $catalogDir -Elevated }

    It 'blocks a Danger tweak without -Expert even with -Force' {
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-danger' -Force
        $r[0].Status | Should -Be 'Blocked'
        Should -Invoke Invoke-TargetApply -Times 0
    }
    It 'blocks a Danger tweak with -Expert but the wrong typed confirmation' {
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-danger' -Force -Expert -TypedConfirmation 'test-one'
        $r[0].Status | Should -Be 'Blocked'
    }
    It 'applies a Danger tweak with -Expert and the matching confirmation' {
        $r = Invoke-WinForgeOperation -Context $ctx -TweakId 'test-danger' -Force -Expert -TypedConfirmation 'test-danger'
        $r[0].Status | Should -Be 'AppliedVerified'
    }
}

Describe 'Undo' {
    BeforeEach {
        Initialize-WfFakeSystem
        $ctx = New-WfTestContext -CatalogRoot $catalogDir -Elevated
        Invoke-WinForgeOperation -Context $ctx -TweakId 'test-one','test-two' -Force | Out-Null
        $runId = (Get-WinForgeHistory -Context $ctx).RunId
        $global:WfRestored.Clear()
    }

    It 'restores targets newest-first and marks the run restored' {
        $r = Invoke-WinForgeUndo -Context $ctx -RunId $runId
        @($r | Where-Object Status -ne 'Restored') | Should -BeNullOrEmpty
        $global:WfRestored | Should -Be @('B','A','C')
        (Get-WinForgeHistory -Context $ctx).Restored | Should -Be 2
    }
    It 'does not restore the same run twice' {
        Invoke-WinForgeUndo -Context $ctx -RunId $runId | Out-Null
        $global:WfRestored.Clear()
        @(Invoke-WinForgeUndo -Context $ctx -RunId $runId) | Should -BeNullOrEmpty
        $global:WfRestored.Count | Should -Be 0
    }
    It 'undoes a single tweak' {
        Invoke-WinForgeUndo -Context $ctx -RunId $runId -TweakId 'test-one' | Out-Null
        $global:WfRestored | Should -Be @('C')
    }
    It 'refuses a run record whose targets were tampered with' {
        $path = Join-Path $ctx.RunDir "$runId.json"
        $rec = Get-Content $path -Raw | ConvertFrom-Json
        @($rec.Tweaks)[0].After[0].Path = 'Software\Microsoft\Windows\CurrentVersion\Run'
        $rec | ConvertTo-Json -Depth 12 | Set-Content $path
        $r = Invoke-WinForgeUndo -Context $ctx -RunId $runId -TweakId 'test-one'
        $r[0].Status | Should -Be 'Refused'
        $global:WfRestored.Count | Should -Be 0
    }
    It 'rejects a run ID that is not a run ID' {
        { Invoke-WinForgeUndo -Context $ctx -RunId '..\..\secrets' } | Should -Throw '*Invalid run ID*'
    }
    It 'requires elevation' {
        $ctx.Elevated = $false
        { Invoke-WinForgeUndo -Context $ctx -RunId $runId } | Should -Throw '*Administrator*'
    }
}

Describe 'History' {
    It 'counts a single matching entry under strict mode' {
        $ctx = New-WfTestContext
        $rec = [pscustomobject]@{ RunId = New-WinForgeRunId; StartedUtc = 'x'; Profile = $null; State = 'Completed'
            Tweaks = @([pscustomobject]@{ Id = 'a'; Status = 'AppliedVerified' }) }
        Save-RunRecord -Context $ctx -Record $rec | Out-Null
        Set-StrictMode -Version Latest
        (Get-WinForgeHistory -Context $ctx).Applied | Should -Be 1
    }
    It 'creates run IDs from UTC time' {
        $id = New-WinForgeRunId
        $id | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{6}$'
        [datetime]::ParseExact($id.Substring(0, 15), 'yyyyMMddTHHmmss', $null) |
            Should -BeGreaterThan ([DateTime]::UtcNow.AddMinutes(-2))
    }
}

Describe 'Multi-target verification' {
    It 'returns false when one of two targets is not in the desired state' {
        $t = [pscustomobject]@{
            Targets = @(
                [pscustomobject]@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\X'; Name = 'A'; Kind = 'DWord'; Value = 1 },
                [pscustomobject]@{ Type = 'Registry'; Hive = 'HKCU'; Path = 'Software\X'; Name = 'B'; Kind = 'DWord'; Value = 1 }
            )
        }
        Mock Test-RegistryTarget { param($Target) $Target.Name -eq 'A' }
        Test-TweakTargets -Tweak $t | Should -BeFalse
    }
}

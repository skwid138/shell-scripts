$script:PeeseaInferenceScript = Join-Path $PSScriptRoot '..\personal\peesea-inference.ps1'
. $script:PeeseaInferenceScript

Describe 'Peesea inference launcher' {
  BeforeEach {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestStatusReadCount = 0
    $global:PeeseaTestListenerReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    $global:PeeseaTestCurrentSid = $null
    $global:PeeseaTestCleanupActions = @()
    $global:PeeseaTestProcessRecords = @()
    $global:PeeseaTestStart = $null
    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Get-PeeseaCurrentUserSid { 'S-1-5-21-test-user' }
    Mock Get-PeeseaProcessRecords { @() }
    Mock Get-PeeseaProcessRecordById { $null }
    Mock Get-PeeseaProcessOwnerSid { $null }
    Mock Get-PeeseaProcessObject { throw 'Real process access is forbidden in unit tests.' }
    Mock Close-PeeseaBrowserProcess { throw 'Real process close is forbidden in unit tests.' }
    Mock Stop-PeeseaHelperProcess { throw 'Real process termination is forbidden in unit tests.' }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      @(
        [pscustomobject]@{
          type = 'llm'; modelKey = $coder.ModelKey
          path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
        [pscustomobject]@{
          type = 'llm'; modelKey = $qwen.ModelKey
          path = 'lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
      )
    }
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $true; Port = 1234 } }
    Mock Get-PeeseaServerListener {
      [pscustomobject]@{
        Exists = $true
        Port = 1234
        LocalAddress = '0.0.0.0'
        ProcessName = 'LM Studio.exe'
        ProcessPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
        ExpectedProcessPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      }
    }
    Mock Get-PeeseaLoadedModels {
      $profile = Get-PeeseaProfile -Model Coder
      @([pscustomobject]@{
          Type = 'llm'
          Identifier = $profile.Identifier
          ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath
          ContextLength = 81920
          Status = 'idle'
        })
    }
    Mock Invoke-PeeseaLms { [pscustomobject]@{ ExitCode = 0; Output = '' } }
  }

  It 'reuses a verified same-model server and model while still running cleanup' {
    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $result.ExitCode | Should Be 0
    Assert-MockCalled Get-PeeseaCurrentUserSid -Times 1 -Scope It
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'continues launching when a noncritical process cleanup inventory fails' {
    Mock Get-PeeseaProcessRecords { throw 'fixture inventory failure' }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $result.ExitCode | Should Be 0
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'reuses a compatible larger context without shrinking or reloading it' {
    Mock Get-PeeseaLoadedModels {
      $profile = Get-PeeseaProfile -Model Coder
      @([pscustomobject]@{
          Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath; ContextLength = 100000; Status = 'idle'; Queued = 0
        })
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $result.Message | Should Match 'context 100000'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'unloads and exactly reloads the known target when its context is below 81920' {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $profile = Get-PeeseaProfile -Model Coder
      if ($global:PeeseaTestLoadedReadCount -eq 2) { return @() }
      $context = if ($global:PeeseaTestLoadedReadCount -eq 1) { 40960 } else { 81920 }
      @([pscustomobject]@{
          Type = 'llm'
          Identifier = $profile.Identifier
          ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath
          ContextLength = $context
          Status = 'idle'
          Queued = 0
        })
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $callStrings = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' })
    $callText = $callStrings -join "`n"
    $callText | Should Match '(?m)^unload qwen3-coder-4090$'
    $callText | Should Match '(?m)^load .*--exact --context-length 81920 --gpu max --identifier qwen3-coder-4090$'
    $callText | Should Not Match '--all'
    $loadCalls = @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'load' })
    $loadCalls.Count | Should Be 1
    $loadCalls[0][1] | Should Be 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  }

  It 'reloads a known physical model that has the wrong API identifier' {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $profile = Get-PeeseaProfile -Model Coder
      if ($global:PeeseaTestLoadedReadCount -eq 2) { return @() }
      $identifier = if ($global:PeeseaTestLoadedReadCount -eq 1) { 'unexpected-id' } else { $profile.Identifier }
      @([pscustomobject]@{
          Type = 'llm'; Identifier = $identifier; ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath; ContextLength = 81920; Status = 'idle'; Queued = 0
        })
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $callText = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^unload unexpected-id$'
    $callText | Should Match '--identifier qwen3-coder-4090'
  }

  It 'refuses duplicate loaded model identities rather than unloading either one' {
    Mock Get-PeeseaLoadedModels {
      $profile = Get-PeeseaProfile -Model Coder
      @(
        [pscustomobject]@{ Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey; ModelPath = $profile.ModelPath; ContextLength = 81920 }
        [pscustomobject]@{ Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey; ModelPath = $profile.ModelPath; ContextLength = 81920 }
      )
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'ambiguous'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'uses the legacy Coder API identifier and the separate Qwen3.8 27B profile' {
    $coder = Get-PeeseaProfile
    $qwen = Get-PeeseaProfile -Model Qwen27B

    $coder.Name | Should Be 'Coder'
    $coder.ModelKey | Should Be 'qwen/qwen3-coder-30b'
    $coder.Identifier | Should Be 'qwen3-coder-4090'
    $coder.MinimumContext | Should Be 81920
    $qwen.ModelKey | Should Be 'qwen/qwen3.8-27b'
    $qwen.Identifier | Should Be 'qwen/qwen3.8-27b'
    $qwen.MinimumContext | Should Be 81920
    [IO.Path]::GetFileName($qwen.ModelPath) | Should Be 'Qwen3.8-27B-Q4_K_M.gguf'
  }

  It 'exposes PowerShell-native help without running launcher side effects' {
    $help = Get-Help $script:PeeseaInferenceScript

    $help.Synopsis | Should Match 'Launch the selected Peesea LM Studio inference profile'
    Assert-MockCalled Enter-PeeseaLaunchLock -Times 0 -Scope It
    Assert-MockCalled Get-PeeseaCurrentUserSid -Times 0 -Scope It
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'resolves a downloaded model only by its exact known physical path and key' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaTestJsonFixture = @([pscustomobject]@{
        type = 'llm'
        modelKey = $profile.ModelKey
        path = $profile.ModelPath
      })
    Mock Get-PeeseaLmsJson { $global:PeeseaTestJsonFixture }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be $profile.ModelPath
    $target.Profile.ModelKey | Should Be $profile.ModelKey
    Assert-MockCalled Get-PeeseaLmsJson -Times 1 -Scope It
  }

  It 'maps the pinned SDK relative model path while retaining its exact CLI selector' {
    $profile = Get-PeeseaProfile -Model Coder
    $relativePath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $global:PeeseaTestJsonFixture = @([pscustomobject]@{
        type = 'llm'
        modelKey = $profile.ModelKey
        path = $relativePath
        deviceIdentifier = $null
      })
    Mock Get-PeeseaLmsJson { $global:PeeseaTestJsonFixture }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be $relativePath
  }

  It 'refuses a relative SDK path that escapes the local models directory' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaTestJsonFixture = @([pscustomobject]@{
        type = 'llm'
        modelKey = $profile.ModelKey
        path = '../../outside/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
        deviceIdentifier = $null
      })
    Mock Get-PeeseaLmsJson { $global:PeeseaTestJsonFixture }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'outside the local models directory'
    }

    $threw | Should Be $true
  }

  It 'refuses duplicate downloaded records for the exact target file' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaTestJsonFixture = @(
      [pscustomobject]@{ type = 'llm'; modelKey = $profile.ModelKey; path = $profile.ModelPath }
      [pscustomobject]@{ type = 'llm'; modelKey = $profile.ModelKey; path = $profile.ModelPath }
    )
    Mock Get-PeeseaLmsJson { $global:PeeseaTestJsonFixture }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $true
    }

    $threw | Should Be $true
  }

  It 'switches to Qwen3.8 27B by exact identity and preserves the embedding model' {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      $embedding = [pscustomobject]@{
        Type = 'embedding'
        Identifier = 'text-embedding-nomic-embed-text-v1.5'
        ModelKey = 'nomic-embed-text-v1.5'
        ModelPath = 'C:\Users\skwid\.lmstudio\models\nomic-embed-text-v1.5'
        ContextLength = 0
        Status = 'idle'
        Queued = 0
      }
      if ($global:PeeseaTestLoadedReadCount -eq 1) {
        return @($embedding, [pscustomobject]@{
            Type = 'llm'; Identifier = $coder.Identifier; ModelKey = $coder.ModelKey
            ModelPath = $coder.ModelPath; ContextLength = 81920; Status = 'idle'; Queued = 0
          })
      }
      if ($global:PeeseaTestLoadedReadCount -eq 2) { return @($embedding) }
      return @($embedding, [pscustomobject]@{
          Type = 'llm'; Identifier = $qwen.Identifier; ModelKey = $qwen.ModelKey
          ModelPath = $qwen.ModelPath; ContextLength = 81920; Status = 'idle'; Queued = 0
        })
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $true
    $callText = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^unload qwen3-coder-4090$'
    $callText | Should Match 'load .*Qwen3\.8-27B-Q4_K_M\.gguf --exact --context-length 81920 --gpu max --identifier qwen/qwen3\.8-27b'
    $callText | Should Not Match 'unload text-embedding-nomic-embed-text-v1\.5'
  }

  It 'starts the expected server only when the server and port listener are absent' {
    $global:PeeseaTestStatusReadCount = 0
    $global:PeeseaTestListenerReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaServerStatus {
      $global:PeeseaTestStatusReadCount++
      if ($global:PeeseaTestStatusReadCount -eq 1) {
        [pscustomobject]@{ Running = $false; Port = 0 }
      } else {
        [pscustomobject]@{ Running = $true; Port = 1234 }
      }
    }
    Mock Get-PeeseaServerListener {
      $global:PeeseaTestListenerReadCount++
      if ($global:PeeseaTestListenerReadCount -eq 1) { return @() }
      [pscustomobject]@{
        Exists = $true
        Port = 1234
        LocalAddress = '0.0.0.0'
        ProcessName = 'LM Studio.exe'
        ProcessPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
        ExpectedProcessPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      }
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $callText = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^server start --bind 0\.0\.0\.0 --port 1234$'
    ($callText -split "`n" | Where-Object { $_ -match '^server start' }).Count | Should Be 1
  }

  It 'closes approved browsers gracefully and stops only approved helpers owned by this user' {
    $global:PeeseaTestCurrentSid = 'S-1-5-21-current-user'
    $global:PeeseaTestCleanupActions = @()
    $global:PeeseaTestStart = [datetime]::SpecifyKind([datetime]'2026-10-28T12:00:00', [DateTimeKind]::Utc)
    $creation = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($global:PeeseaTestStart)
    $global:PeeseaTestProcessRecords = @(
      [pscustomobject]@{ ProcessId = 101; Name = 'firefox.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 102; Name = 'OneDrive.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 0 }
      [pscustomobject]@{ ProcessId = 103; Name = 'OneDrive.exe'; CreationDate = $creation; OwnerSid = 'S-1-5-21-other-user'; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 104; Name = 'explorer.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 105; Name = 'unknown-gpu-app.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 106; Name = 'dwm.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 107; Name = 'sshd.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 0 }
      [pscustomobject]@{ ProcessId = 108; Name = 'tailscale.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 109; Name = 'LM Studio.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
      [pscustomobject]@{ ProcessId = 110; Name = 'llama-server.exe'; CreationDate = $creation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
    )
    Mock Get-PeeseaCurrentUserSid { $global:PeeseaTestCurrentSid }
    Mock Get-PeeseaProcessRecords { $global:PeeseaTestProcessRecords }
    Mock Get-PeeseaProcessRecordById {
      @($global:PeeseaTestProcessRecords | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1)
    }
    Mock Get-PeeseaProcessOwnerSid { $ProcessRecord.OwnerSid }
    Mock Get-PeeseaProcessObject {
      $record = $global:PeeseaTestProcessRecords | Where-Object { $_.ProcessId -eq $ProcessId } | Select-Object -First 1
      [pscustomobject]@{ Id = $ProcessId; ProcessName = [IO.Path]::GetFileNameWithoutExtension($record.Name); StartTime = $global:PeeseaTestStart }
    }
    Mock Close-PeeseaBrowserProcess {
      $global:PeeseaTestCleanupActions += "close:$($ProcessObject.Id)"
      $true
    }
    Mock Stop-PeeseaHelperProcess {
      $global:PeeseaTestCleanupActions += "stop:$($ProcessObject.Id)"
      $true
    }

    Invoke-PeeseaCleanup

    ($global:PeeseaTestCleanupActions -join ',') | Should Be 'close:101,stop:102'
    Assert-MockCalled Stop-PeeseaHelperProcess -Times 1 -Scope It
    Assert-MockCalled Close-PeeseaBrowserProcess -Times 1 -Scope It
  }

  It 'skips a process when its PID has been reused before the cleanup action' {
    $global:PeeseaTestCurrentSid = 'S-1-5-21-current-user'
    $global:PeeseaTestStart = [datetime]::SpecifyKind([datetime]'2026-10-28T12:00:00', [DateTimeKind]::Utc)
    $originalCreation = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($global:PeeseaTestStart)
    $replacementStart = $global:PeeseaTestStart.AddMinutes(1)
    $replacementCreation = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($replacementStart)
    $global:PeeseaTestProcessRecords = @(
      [pscustomobject]@{ ProcessId = 201; Name = 'firefox.exe'; CreationDate = $originalCreation; OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1 }
    )
    $global:PeeseaTestReusedRecord = [pscustomobject]@{
      ProcessId = 201; Name = 'firefox.exe'; CreationDate = $replacementCreation
      OwnerSid = $global:PeeseaTestCurrentSid; SessionId = 1
    }
    Mock Get-PeeseaCurrentUserSid { $global:PeeseaTestCurrentSid }
    Mock Get-PeeseaProcessRecords { $global:PeeseaTestProcessRecords }
    Mock Get-PeeseaProcessRecordById { $global:PeeseaTestReusedRecord }
    Mock Get-PeeseaProcessOwnerSid { $ProcessRecord.OwnerSid }
    Mock Close-PeeseaBrowserProcess { throw 'A replaced PID must never be closed.' }

    Invoke-PeeseaCleanup

    Assert-MockCalled Close-PeeseaBrowserProcess -Times 0 -Scope It
    Assert-MockCalled Get-PeeseaProcessObject -Times 0 -Scope It
  }

  It 'distinguishes process creation timestamps within the same displayed second' {
    $startEarly = [datetime]::Parse('2026-10-28T12:00:00.100Z').ToLocalTime()
    $startLate = [datetime]::Parse('2026-10-28T12:00:00.900Z').ToLocalTime()
    $original = [pscustomobject]@{
      ProcessId = 301; Name = 'firefox.exe'; CreationDate = $startEarly; OwnerSid = 'S-1-5-21-current-user'
    }
    $current = [pscustomobject]@{
      ProcessId = 301; Name = 'firefox.exe'; CreationDate = $startLate; OwnerSid = 'S-1-5-21-current-user'
    }
    $processObject = [pscustomobject]@{
      Id = 301; ProcessName = 'firefox'; StartTime = $startLate
    }

    (Test-PeeseaSameProcessRecord -Original $original -Current $current) | Should Be $false
    (Test-PeeseaProcessObjectIdentity -ProcessRecord $original -ProcessObject $processObject) | Should Be $false
  }

  It 'refuses a loaded model with the expected identifier but the wrong physical file' {
    Mock Get-PeeseaLoadedModels {
      @([pscustomobject]@{
          Type = 'llm'
          Identifier = 'qwen3-coder-4090'
          ModelKey = 'qwen/qwen3-coder-30b'
          ModelPath = 'C:\Users\skwid\.lmstudio\models\other\wrong.gguf'
          ContextLength = 81920
          Status = 'idle'
          Queued = 0
        })
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'unknown physical model path'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'refuses a foreign listener on the expected bind without starting or hijacking it' {
    Mock Get-PeeseaServerListener {
      [pscustomobject]@{
        Exists = $true
        Port = 1234
        LocalAddress = '0.0.0.0'
        ProcessName = 'unrelated.exe'
        ProcessPath = 'C:\unrelated.exe'
        ExpectedProcessPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'refusing to hijack'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'refuses the expected LM Studio process when it is bound only to loopback' {
    Mock Get-PeeseaServerListener {
      $expectedPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      [pscustomobject]@{
        Exists = $true; Port = 1234; LocalAddress = '127.0.0.1'
        ProcessName = 'LM Studio.exe'; ProcessPath = $expectedPath; ExpectedProcessPath = $expectedPath
      }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'refusing to hijack'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'refuses a running LM Studio server on a different port' {
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $true; Port = 4321 } }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'port 1234'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'does not clean up or invoke LM Studio when another launcher owns the lock' {
    Mock Enter-PeeseaLaunchLock { $null }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    Assert-MockCalled Get-PeeseaCurrentUserSid -Times 0 -Scope It
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 0 -Scope It
  }

  It 'returns failure and releases the lock when an LM Studio load command fails' {
    Mock Get-PeeseaLoadedModels { @() }
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 7; Output = 'fixture failure' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'exit code 7'
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'does not report Ready when a successful load lacks the required postcondition' {
    Mock Get-PeeseaLoadedModels { @() }
    Mock Invoke-PeeseaLms { [pscustomobject]@{ ExitCode = 0; Output = '' } }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'did not verify exactly one loaded'
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'does not continue loading when the exact known-model unload fails' {
    Mock Get-PeeseaLoadedModels {
      $profile = Get-PeeseaProfile -Model Coder
      @([pscustomobject]@{
          Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath; ContextLength = 40960; Status = 'idle'; Queued = 0
        })
    }
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 7; Output = 'unload fixture failure' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'unload.*exit code 7'
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'does not load a model when starting the absent server fails' {
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $false; Port = 0 } }
    Mock Get-PeeseaServerListener { @() }
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 8; Output = 'server start fixture failure' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'server start.*exit code 8'
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  AfterEach {
    Remove-Variable -Name PeeseaTestLoadedReadCount, PeeseaTestStatusReadCount, PeeseaTestListenerReadCount, PeeseaTestLmsCalls, PeeseaTestCurrentSid, PeeseaTestCleanupActions, PeeseaTestProcessRecords, PeeseaTestStart, PeeseaTestReusedRecord, PeeseaTestJsonFixture -Scope Global -ErrorAction SilentlyContinue
  }
}

Describe 'LM Studio CLI JSON boundary' {
  It 'accepts the pinned server status JSON shape' {
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = '{"running":true,"port":1234}' }
    }

    $status = Get-PeeseaServerStatus

    $status.Running | Should Be $true
    $status.Port | Should Be 1234
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
  }

  It 'parses ls JSON and resolves its relative SDK path through the real CLI mapper' {
    $profile = Get-PeeseaProfile -Model Coder
    $relativePath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $global:PeeseaCliFixture = ConvertTo-Json -InputObject @([pscustomobject]@{
        type = 'llm'; modelKey = $profile.ModelKey; path = $relativePath; deviceIdentifier = $null
      }) -Depth 8 -Compress
    Mock Test-PeeseaModelFile { $true }
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be $relativePath
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
  }

  It 'maps pinned relative loaded-model paths while preserving the original CLI path and embedding' {
    $coder = Get-PeeseaProfile -Model Coder
    $coderRelativePath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $embeddingIdentifier = 'text-embedding-nomic-embed-text-v1.5'
    $fixtureRecords = @(
      [pscustomobject]@{
        type = 'llm'; modelKey = $coder.ModelKey; identifier = $coder.Identifier
        format = 'gguf'; displayName = 'Qwen3 Coder'; publisher = 'lmstudio-community'
        path = $coderRelativePath; sizeBytes = 18632186176; indexedModelIdentifier = 'coder-fixture'
        deviceIdentifier = $null; contextLength = 81920; status = 'idle'; queued = 0
        parallel = 4; engineConfigFileEnabled = $false
      }
      [pscustomobject]@{
        type = 'embedding'; modelKey = 'nomic-embed-text-v1.5'; identifier = $embeddingIdentifier
        format = 'gguf'; displayName = 'Nomic Embed'; publisher = 'lmstudio-community'
        path = 'lmstudio-community/nomic-embed-text-v1.5/model.gguf'; sizeBytes = 1370000000
        indexedModelIdentifier = 'embedding-fixture'; deviceIdentifier = $null
        status = 'idle'; queued = 0; parallel = $null; engineConfigFileEnabled = $false
      }
    )
    $global:PeeseaCliFixture = ConvertTo-Json -InputObject $fixtureRecords -Depth 8 -Compress
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }

    $models = @(Get-PeeseaLoadedModels)

    $models.Count | Should Be 2
    $models[0].ModelPath | Should Be $coder.ModelPath
    $models[0].LmsPath | Should Be $coderRelativePath
    $models[0].Identifier | Should Be $coder.Identifier
    $models[0].ContextLength | Should Be 81920
    $models[1].Type | Should Be 'embedding'
    $models[1].Identifier | Should Be $embeddingIdentifier
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
  }

  It 'does not accept an LM Link model as the known local LLM' {
    $profile = Get-PeeseaProfile -Model Coder
    $record = [pscustomobject]@{
      type = 'llm'; modelKey = $profile.ModelKey; identifier = $profile.Identifier
      path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
      deviceIdentifier = 'remote-device'; contextLength = 81920
    }
    $global:PeeseaCliFixture = '[' + (ConvertTo-Json -InputObject $record -Compress) + ']'
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }

    $loaded = @(Get-PeeseaLoadedModels)

    $loaded.Count | Should Be 1
    $loaded[0].DeviceIdentifier | Should Be 'remote-device'
    (Get-PeeseaProfileForLoadedModel -LoadedModel $loaded[0]) | Should Be $null
  }

  It 'rejects a loaded LLM that reports zero context' {
    $profile = Get-PeeseaProfile -Model Coder
    $record = [pscustomobject]@{
      type = 'llm'; modelKey = $profile.ModelKey; identifier = $profile.Identifier
      path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
      deviceIdentifier = $null; contextLength = 0
    }
    $global:PeeseaCliFixture = '[' + (ConvertTo-Json -InputObject $record -Compress) + ']'
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }
    $threw = $false

    try {
      Get-PeeseaLoadedModels | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'valid context'
    }

    $threw | Should Be $true
  }

  It 'rejects a loaded LLM that reports negative context' {
    $profile = Get-PeeseaProfile -Model Coder
    $record = [pscustomobject]@{
      type = 'llm'; modelKey = $profile.ModelKey; identifier = $profile.Identifier
      path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
      deviceIdentifier = $null; contextLength = -1
    }
    $global:PeeseaCliFixture = '[' + (ConvertTo-Json -InputObject $record -Compress) + ']'
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }
    $threw = $false

    try {
      Get-PeeseaLoadedModels | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'valid context'
    }

    $threw | Should Be $true
  }

  It 'rejects missing and non-integer loaded LLM context values' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaContextFixtures = @(
      [pscustomobject]@{
        type = 'llm'; modelKey = $profile.ModelKey; identifier = $profile.Identifier
        path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
        deviceIdentifier = $null
      }
      [pscustomobject]@{
        type = 'llm'; modelKey = $profile.ModelKey; identifier = $profile.Identifier
        path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
        deviceIdentifier = $null; contextLength = 'not-an-integer'
      }
    )
    Mock Invoke-PeeseaLms {
      $fixture = $global:PeeseaContextFixtures[$global:PeeseaContextFixtureIndex]
      $global:PeeseaContextFixtureIndex++
      [pscustomobject]@{ ExitCode = 0; Output = '[' + (ConvertTo-Json -InputObject $fixture -Compress) + ']' }
    }

    foreach ($index in @(0, 1)) {
      $global:PeeseaContextFixtureIndex = $index
      $threw = $false
      try {
        Get-PeeseaLoadedModels | Out-Null
      } catch {
        $threw = $_.Exception.Message -match 'valid context'
      }
      $threw | Should Be $true
    }
  }

  It 'fails closed for CLI errors and invalid JSON' {
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 7; Output = 'fixture failure' }
    }
    $exitFailed = $false
    try {
      Get-PeeseaLmsJson -Arguments @('ps', '--json') | Out-Null
    } catch {
      $exitFailed = $_.Exception.Message -match 'exit code 7'
    }
    $exitFailed | Should Be $true

    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = 'not-json' }
    }
    $jsonFailed = $false
    try {
      Get-PeeseaLmsJson -Arguments @('ps', '--json') | Out-Null
    } catch {
      $jsonFailed = $_.Exception.Message -match 'invalid JSON'
    }
    $jsonFailed | Should Be $true
  }

  AfterEach {
    Remove-Variable -Name PeeseaCliFixture, PeeseaContextFixtures, PeeseaContextFixtureIndex -Scope Global -ErrorAction SilentlyContinue
  }
}

Describe 'Peesea native listener adapter' {
  It 'starts the server when Windows reports no matching listener instances' {
    $global:PeeseaListenerQueryCount = 0
    $global:PeeseaListenerStatusCount = 0
    $global:PeeseaListenerLmsCalls = @()
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaMissingListenerError = [System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('No matching listener instance'),
      'CmdletizationQuery_NotFound,Get-NetTCPConnection',
      [System.Management.Automation.ErrorCategory]::ObjectNotFound,
      'MSFT_NetTCPConnection'
    )
    $global:PeeseaMissingListenerError.FullyQualifiedErrorId | Should Be 'CmdletizationQuery_NotFound,Get-NetTCPConnection'
    $global:PeeseaMissingListenerError.CategoryInfo.Category | Should Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)

    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Get-PeeseaCurrentUserSid { 'S-1-5-21-listener-test' }
    Mock Get-PeeseaProcessRecords { @() }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      @(
        [pscustomobject]@{ type = 'llm'; modelKey = $coder.ModelKey; path = $coder.ModelPath }
        [pscustomobject]@{ type = 'llm'; modelKey = $qwen.ModelKey; path = $qwen.ModelPath }
      )
    }
    Mock Get-PeeseaServerStatus {
      $global:PeeseaListenerStatusCount++
      if ($global:PeeseaListenerStatusCount -eq 1) {
        [pscustomobject]@{ Running = $false; Port = 0 }
      } else {
        [pscustomobject]@{ Running = $true; Port = 1234 }
      }
    }
    Mock Get-NetTCPConnection {
      $global:PeeseaListenerQueryCount++
      if ($global:PeeseaListenerQueryCount -eq 1) { throw $global:PeeseaMissingListenerError }
      [pscustomobject]@{ LocalPort = 1234; LocalAddress = '0.0.0.0'; OwningProcess = 13088 }
    }
    Mock Get-CimInstance {
      [pscustomobject]@{
        Name = 'LM Studio.exe'
        ExecutablePath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      }
    }
    Mock Get-PeeseaLoadedModels {
      @([pscustomobject]@{
          Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey
          ModelPath = $profile.ModelPath; ContextLength = 81920; Status = 'idle'; Queued = 0
        })
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaListenerLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $callText = @($global:PeeseaListenerLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^server start --bind 0\.0\.0\.0 --port 1234$'
    $global:PeeseaListenerQueryCount | Should Be 3
  }

  It 'propagates listener permission errors without starting LM Studio or reporting Ready' {
    $profile = Get-PeeseaProfile -Model Coder
    $permissionError = [System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('Access denied to listener inventory'),
      'AccessDenied,Get-NetTCPConnection',
      [System.Management.Automation.ErrorCategory]::PermissionDenied,
      'MSFT_NetTCPConnection'
    )
    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Get-PeeseaCurrentUserSid { 'S-1-5-21-listener-test' }
    Mock Get-PeeseaProcessRecords { @() }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      @(
        [pscustomobject]@{
          type = 'llm'; modelKey = $coder.ModelKey
          path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
        [pscustomobject]@{
          type = 'llm'; modelKey = $qwen.ModelKey
          path = 'lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
      )
    }
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $false; Port = 0 } }
    Mock Get-NetTCPConnection { throw $permissionError }
    Mock Get-CimInstance { throw 'Unexpected listener process lookup.' }
    Mock Invoke-PeeseaLms { [pscustomobject]@{ ExitCode = 0; Output = '' } }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'Access denied'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Get-CimInstance -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'propagates listener process lookup errors instead of treating them as a foreign process' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaListenerLmsCalls = @()
    $global:PeeseaProcessLookupError = [System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('Access denied to listener process metadata'),
      'AccessDenied,Get-CimInstance',
      [System.Management.Automation.ErrorCategory]::PermissionDenied,
      'Win32_Process'
    )
    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Get-PeeseaCurrentUserSid { 'S-1-5-21-listener-test' }
    Mock Get-PeeseaProcessRecords { @() }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      @(
        [pscustomobject]@{
          type = 'llm'; modelKey = $coder.ModelKey
          path = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
        [pscustomobject]@{
          type = 'llm'; modelKey = $qwen.ModelKey
          path = 'lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
          deviceIdentifier = $null
        }
      )
    }
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $true; Port = 1234 } }
    Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort = 1234; LocalAddress = '0.0.0.0'; OwningProcess = 54321 } }
    Mock Get-CimInstance { throw $global:PeeseaProcessLookupError }
    Mock Invoke-PeeseaLms {
      $global:PeeseaListenerLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $false
    $result.Message | Should Match 'Access denied to listener process metadata'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  AfterEach {
    Remove-Variable -Name PeeseaListenerQueryCount, PeeseaListenerStatusCount, PeeseaListenerLmsCalls, PeeseaMissingListenerError, PeeseaProcessLookupError -Scope Global -ErrorAction SilentlyContinue
  }
}

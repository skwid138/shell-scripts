$script:PeeseaInferenceScript = Join-Path $PSScriptRoot '..\personal\peesea-inference.ps1'
. $script:PeeseaInferenceScript

function Get-PeeseaCatalogFixtureMetadata {
  param([Parameter(Mandatory)]$Profile)

  if ($Profile.Name -eq 'Coder') {
    return [pscustomobject]@{
      DisplayName = 'Qwen3 Coder 30B'
      Publisher = 'qwen'
      SizeBytes = 18632365388
      ParamsString = '30B-A3B'
      Architecture = 'qwen3moe'
      Vision = $false
    }
  }
  if ($Profile.Name -eq 'Qwen27B') {
    return [pscustomobject]@{
      DisplayName = 'Qwen3.8 27B'
      Publisher = 'qwen'
      SizeBytes = 17742040464
      ParamsString = '27B'
      Architecture = 'qwen35'
      Vision = $true
    }
  }
  return [pscustomobject]@{
    DisplayName = 'Swift 1.5 Qwen3.8 27B'
    Publisher = 'ukisai'
    SizeBytes = 18370006848
    ParamsString = '27B'
    Architecture = 'qwen35'
    Vision = $true
  }
}

function New-PeeseaCatalogBaseFixture {
  param(
    [Parameter(Mandatory)]$Profile,
    [string]$SelectedVariant,
    [string]$Path,
    [string]$QuantizationName,
    [object]$DeviceIdentifier,
    [string[]]$Variants
  )

  $metadata = Get-PeeseaCatalogFixtureMetadata -Profile $Profile
  if (-not $PSBoundParameters.ContainsKey('SelectedVariant')) { $SelectedVariant = $Profile.VariantKey }
  if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = $Profile.CatalogPath }
  if (-not $PSBoundParameters.ContainsKey('QuantizationName')) { $QuantizationName = $Profile.QuantizationName }
  if (-not $PSBoundParameters.ContainsKey('Variants')) { $Variants = @($Profile.VariantKey) }
  return [pscustomobject]@{
    type = 'llm'
    modelKey = $Profile.ModelKey
    format = 'gguf'
    displayName = $metadata.DisplayName
    publisher = $metadata.Publisher
    path = $Path
    sizeBytes = $metadata.SizeBytes
    indexedModelIdentifier = $Profile.ModelKey
    deviceIdentifier = $DeviceIdentifier
    paramsString = $metadata.ParamsString
    architecture = $metadata.Architecture
    quantization = [pscustomobject]@{ name = $QuantizationName; bits = 4 }
    variants = $Variants
    selectedVariant = $SelectedVariant
    vision = $metadata.Vision
    trainedForToolUse = $true
    maxContextLength = 262144
  }
}

function New-PeeseaStandaloneModelFixture {
  param(
    [Parameter(Mandatory)]$Profile,
    [Parameter(Mandatory)][string]$Path
  )

  $metadata = Get-PeeseaCatalogFixtureMetadata -Profile $Profile
  $fixture = [pscustomobject]@{
    type = 'llm'
    modelKey = $Profile.ModelKey
    format = 'gguf'
    displayName = $metadata.DisplayName
    publisher = $metadata.Publisher
    path = $Path
    deviceIdentifier = $null
  }
  if ($Profile.IdentityKind -eq 'StandalonePhysical') {
    $fixture | Add-Member -NotePropertyName indexedModelIdentifier -NotePropertyValue $Profile.IndexedModelIdentifier
    $fixture | Add-Member -NotePropertyName quantization -NotePropertyValue ([pscustomobject]@{ name = $Profile.QuantizationName; bits = 4 })
  }
  return $fixture
}

function New-PeeseaVariantDetailFixture {
  param(
    [Parameter(Mandatory)]$Profile,
    [string]$VariantKey,
    [string]$Path,
    [string]$IndexedModelIdentifier,
    [string]$QuantizationName,
    [object]$DeviceIdentifier
  )

  $metadata = Get-PeeseaCatalogFixtureMetadata -Profile $Profile
  if (-not $PSBoundParameters.ContainsKey('VariantKey')) { $VariantKey = $Profile.VariantKey }
  if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = $Profile.CatalogPath }
  if (-not $PSBoundParameters.ContainsKey('IndexedModelIdentifier')) { $IndexedModelIdentifier = $Profile.IndexedModelIdentifier }
  if (-not $PSBoundParameters.ContainsKey('QuantizationName')) { $QuantizationName = $Profile.QuantizationName }
  return [pscustomobject]@{
    type = 'llm'
    modelKey = $VariantKey
    format = 'gguf'
    displayName = $metadata.DisplayName
    publisher = $metadata.Publisher
    path = $Path
    sizeBytes = $metadata.SizeBytes
    indexedModelIdentifier = $IndexedModelIdentifier
    deviceIdentifier = $DeviceIdentifier
    paramsString = $metadata.ParamsString
    architecture = $metadata.Architecture
    quantization = [pscustomobject]@{ name = $QuantizationName; bits = 4 }
    vision = $metadata.Vision
    trainedForToolUse = $true
    maxContextLength = 262144
  }
}

function Get-PeeseaCatalogJsonFixture {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $coder = Get-PeeseaProfile -Model Coder
  $qwen = Get-PeeseaProfile -Model Qwen27B
  $swift = Get-PeeseaProfile -Model Swift27B
  if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq '--json') {
    return @(
      (New-PeeseaCatalogBaseFixture -Profile $coder)
      (New-PeeseaCatalogBaseFixture -Profile $qwen)
      (New-PeeseaStandaloneModelFixture -Profile $swift -Path $swift.IndexedModelIdentifier)
    )
  }
  if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[2] -eq '--json') {
    if ($Arguments[1] -eq $coder.ModelKey) { return @(New-PeeseaVariantDetailFixture -Profile $coder) }
    if ($Arguments[1] -eq $qwen.ModelKey) { return @(New-PeeseaVariantDetailFixture -Profile $qwen) }
  }
  throw 'Unexpected mocked LM Studio catalog query.'
}

function New-PeeseaLoadedLlmFixture {
  param(
    [Parameter(Mandatory)]$Profile,
    [long]$ContextLength = 81920,
    [string]$Identifier,
    [string]$CatalogPath,
    [string]$IndexedModelIdentifier,
    [string]$SelectedVariant,
    [string]$QuantizationName,
    [object]$DeviceIdentifier,
    [string[]]$VariantKeys
  )

  if (-not $PSBoundParameters.ContainsKey('Identifier')) { $Identifier = $Profile.Identifier }
  if (-not $PSBoundParameters.ContainsKey('CatalogPath')) { $CatalogPath = $Profile.CatalogPath }
  if (-not $PSBoundParameters.ContainsKey('IndexedModelIdentifier')) { $IndexedModelIdentifier = $Profile.ModelKey }
  if (-not $PSBoundParameters.ContainsKey('SelectedVariant')) { $SelectedVariant = $Profile.VariantKey }
  if (-not $PSBoundParameters.ContainsKey('QuantizationName')) { $QuantizationName = $Profile.QuantizationName }
  if (-not $PSBoundParameters.ContainsKey('VariantKeys')) { $VariantKeys = @($Profile.VariantKey) }
  return [pscustomobject]@{
    Type = 'llm'
    Identifier = $Identifier
    ModelKey = $Profile.ModelKey
    CatalogPath = $CatalogPath
    IndexedModelIdentifier = $IndexedModelIdentifier
    SelectedVariant = $SelectedVariant
    VariantKeys = $VariantKeys
    QuantizationName = $QuantizationName
    DeviceIdentifier = $DeviceIdentifier
    ContextLength = $ContextLength
    Status = 'idle'
    Queued = 0
  }
}

function New-PeeseaLoadedEmbeddingFixture {
  return [pscustomobject]@{
    Type = 'embedding'
    Identifier = 'text-embedding-nomic-embed-text-v1.5'
    ModelKey = 'text-embedding-nomic-embed-text-v1.5'
    CatalogPath = 'nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf'
    IndexedModelIdentifier = 'nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf'
    SelectedVariant = ''
    VariantKeys = @()
    QuantizationName = 'Q4_K_M'
    DeviceIdentifier = $null
    ContextLength = 0
    Status = 'idle'
    Queued = 0
  }
}

function New-PeeseaPsLlmJsonFixture {
  param(
    [Parameter(Mandatory)]$Profile,
    [object]$ContextLength = 81920,
    [object]$DeviceIdentifier = $null
  )

  $metadata = Get-PeeseaCatalogFixtureMetadata -Profile $Profile
  return [pscustomobject]@{
    type = 'llm'
    modelKey = $Profile.ModelKey
    format = 'gguf'
    displayName = $metadata.DisplayName
    publisher = $metadata.Publisher
    path = $Profile.CatalogPath
    sizeBytes = $metadata.SizeBytes
    indexedModelIdentifier = $Profile.ModelKey
    deviceIdentifier = $DeviceIdentifier
    paramsString = $metadata.ParamsString
    architecture = $metadata.Architecture
    quantization = [pscustomobject]@{ name = $Profile.QuantizationName; bits = 4 }
    variants = @($Profile.VariantKey)
    selectedVariant = $Profile.VariantKey
    identifier = $Profile.Identifier
    ttlMs = $null
    lastUsedTime = 1793234742153
    vision = $metadata.Vision
    trainedForToolUse = $true
    maxContextLength = 262144
    contextLength = $ContextLength
    status = 'idle'
    queued = 0
    parallel = 4
    engineConfigFileEnabled = $false
  }
}

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
    Mock Write-Host {}
    Mock Get-PeeseaProcessRecords { @() }
    Mock Get-PeeseaProcessRecordById { $null }
    Mock Get-PeeseaProcessOwnerSid { $null }
    Mock Get-PeeseaProcessObject { throw 'Real process access is forbidden in unit tests.' }
    Mock Close-PeeseaBrowserProcess { throw 'Real process close is forbidden in unit tests.' }
    Mock Stop-PeeseaHelperProcess { throw 'Real process termination is forbidden in unit tests.' }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaLmsJson {
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
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
      @(New-PeeseaLoadedLlmFixture -Profile $profile)
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

  It 'announces cleanup and profile validation before their blocking operations' {
    $global:PeeseaTestPhaseTimeline = @()
    Mock Write-Host {
      $global:PeeseaTestPhaseTimeline += 'phase:' + [string]::Join('', @($Object))
    }
    Mock Get-PeeseaCurrentUserSid {
      $global:PeeseaTestPhaseTimeline += 'cleanup'
      'S-1-5-21-test-user'
    }
    Mock Get-PeeseaLmsJson {
      $global:PeeseaTestPhaseTimeline += 'metadata:' + ($Arguments -join ' ')
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
    }
    Mock Get-PeeseaServerStatus {
      $global:PeeseaTestPhaseTimeline += 'server-status'
      [pscustomobject]@{ Running = $true; Port = 1234 }
    }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $global:PeeseaTestPhaseTimeline += "models:$($global:PeeseaTestLoadedReadCount)"
      $profile = Get-PeeseaProfile -Model Coder
      @(New-PeeseaLoadedLlmFixture -Profile $profile)
    }

    $result = Invoke-PeeseaInference -Model Coder
    $timeline = @($global:PeeseaTestPhaseTimeline)
    $cleanupPhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Starting approved process cleanup' })
    $cleanupIndex = [array]::IndexOf($timeline, 'cleanup')
    $validationPhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Validating Coder profile and downloaded model identity' })
    $metadataIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -eq 'metadata:ls --json' })
    $serverCheckPhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Checking LM Studio server status' })
    $serverStatusIndex = [array]::IndexOf($timeline, 'server-status')
    $serverReusePhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Reusing verified LM Studio server' })
    $modelCheckPhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Checking loaded model state' })
    $modelReadIndex = [array]::IndexOf($timeline, 'models:1')
    $modelReusePhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Reusing verified loaded Coder model' })
    $finalVerificationPhaseIndex = [array]::FindIndex($timeline, [Predicate[string]]{ param($entry) $entry -match 'Verifying final model and server state' })
    $finalModelReadIndex = [array]::IndexOf($timeline, 'models:2')

    $cleanupPhaseIndex | Should BeGreaterThan -1
    $cleanupPhaseIndex | Should BeLessThan $cleanupIndex
    $cleanupIndex | Should BeLessThan $validationPhaseIndex
    $validationPhaseIndex | Should BeLessThan $metadataIndex
    $metadataIndex | Should BeLessThan $serverCheckPhaseIndex
    $serverCheckPhaseIndex | Should BeLessThan $serverStatusIndex
    $serverStatusIndex | Should BeLessThan $serverReusePhaseIndex
    $serverReusePhaseIndex | Should BeLessThan $modelCheckPhaseIndex
    $modelCheckPhaseIndex | Should BeLessThan $modelReadIndex
    $modelReadIndex | Should BeLessThan $modelReusePhaseIndex
    $modelReusePhaseIndex | Should BeLessThan $finalVerificationPhaseIndex
    $finalVerificationPhaseIndex | Should BeLessThan $finalModelReadIndex
    (@($result.PSObject.Properties.Name) -join ',') | Should Be 'Ready,ExitCode,Message'
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
      @(New-PeeseaLoadedLlmFixture -Profile $profile -ContextLength 100000)
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
      @(New-PeeseaLoadedLlmFixture -Profile $profile -ContextLength $context)
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
    $callText | Should Match '(?m)^load qwen/qwen3-coder-30b --exact --context-length 81920 --gpu max --identifier qwen3-coder-4090$'
    $callText | Should Not Match '--all'
    $loadCalls = @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'load' })
    $loadCalls.Count | Should Be 1
    $loadCalls[0][1] | Should Be 'qwen/qwen3-coder-30b'
  }

  It 'reloads a known physical model that has the wrong API identifier' {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $profile = Get-PeeseaProfile -Model Coder
      if ($global:PeeseaTestLoadedReadCount -eq 2) { return @() }
      $identifier = if ($global:PeeseaTestLoadedReadCount -eq 1) { 'unexpected-id' } else { $profile.Identifier }
      @(New-PeeseaLoadedLlmFixture -Profile $profile -Identifier $identifier)
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
        (New-PeeseaLoadedLlmFixture -Profile $profile)
        (New-PeeseaLoadedLlmFixture -Profile $profile)
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
    $coder.CatalogPath | Should Be 'qwen/qwen3-coder-30b'
    $coder.Identifier | Should Be 'qwen3-coder-4090'
    $coder.VariantKey | Should Be 'qwen/qwen3-coder-30b@q4_k_m'
    $coder.QuantizationName | Should Be 'Q4_K_M'
    $coder.IndexedModelIdentifier | Should Match '^qwen/qwen3-coder-30b@lmstudio-community/'
    $coder.MinimumContext | Should Be 81920
    $qwen.ModelKey | Should Be 'qwen/qwen3.8-27b'
    $qwen.CatalogPath | Should Be 'qwen/qwen3.8-27b'
    $qwen.Identifier | Should Be 'qwen/qwen3.8-27b'
    $qwen.VariantKey | Should Be 'qwen/qwen3.8-27b@q4_k_m'
    $qwen.QuantizationName | Should Be 'Q4_K_M'
    $qwen.IndexedModelIdentifier | Should Match '^qwen/qwen3\.8-27b@lmstudio-community/'
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

  It 'resolves the known catalog base, selected variant, and physical binding' {
    $profile = Get-PeeseaProfile -Model Coder

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be $profile.CatalogPath
    $target.VariantKey | Should Be $profile.VariantKey
    $target.IndexedModelIdentifier | Should Be $profile.IndexedModelIdentifier
    $target.Profile.ModelKey | Should Be $profile.ModelKey
    Assert-MockCalled Get-PeeseaLmsJson -Times 3 -Scope It
  }

  It 'uses the logical catalog base rather than a physical file path as the exact CLI selector' {
    $profile = Get-PeeseaProfile -Model Coder

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be $profile.ModelKey
    ($target.LmsPath -eq $profile.ModelPath) | Should Be $false
  }

  It 'resolves relative and absolute standalone physical paths without inventing variant metadata' {
    $profile = Get-PeeseaProfile -Model Coder
    $relativePhysicalPath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path $relativePhysicalPath
    Mock Get-PeeseaLmsJson { @($global:PeeseaStandaloneFixture) }

    $relativeTarget = Resolve-PeeseaTarget -Profile $profile

    $relativeTarget.IdentityKind | Should Be 'StandalonePhysical'
    $relativeTarget.PhysicalPath | Should Be $profile.ModelPath
    $relativeTarget.LmsPath | Should Be $relativePhysicalPath
    $relativeTarget.VariantKey | Should Be $null
    $relativeTarget.QuantizationName | Should Be $null

    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path $profile.ModelPath
    $absoluteTarget = Resolve-PeeseaTarget -Profile $profile

    $absoluteTarget.IdentityKind | Should Be 'StandalonePhysical'
    $absoluteTarget.PhysicalPath | Should Be $profile.ModelPath
    $absoluteTarget.LmsPath | Should Be $profile.ModelPath
    $absoluteTarget.VariantKey | Should Be $null
    $absoluteTarget.QuantizationName | Should Be $null
  }

  It 'rejects standalone physical paths that escape or differ from the known file' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path '../../outside/wrong.gguf'
    Mock Get-PeeseaLmsJson { @($global:PeeseaStandaloneFixture) }
    $outsideThrew = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $outsideThrew = $_.Exception.Message -match 'outside the local models directory'
    }
    $outsideThrew | Should Be $true

    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path 'lmstudio-community/other/wrong.gguf'
    $wrongFileThrew = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongFileThrew = $_.Exception.Message -match 'does not identify its known local physical model'
    }
    $wrongFileThrew | Should Be $true
  }

  It 'rejects standalone records that report a different selected variant or quantization' {
    $profile = Get-PeeseaProfile -Model Coder
    $knownPath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path $knownPath
    $global:PeeseaStandaloneFixture | Add-Member -NotePropertyName selectedVariant -NotePropertyValue 'qwen/qwen3-coder-30b@q4_k_l'
    Mock Get-PeeseaLmsJson { @($global:PeeseaStandaloneFixture) }
    $wrongSelectionThrew = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongSelectionThrew = $_.Exception.Message -match 'different selected variant'
    }
    $wrongSelectionThrew | Should Be $true

    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path $knownPath
    $global:PeeseaStandaloneFixture | Add-Member -NotePropertyName quantization -NotePropertyValue ([pscustomobject]@{ name = 'Q4_K_L'; bits = 4 })
    $wrongQuantizationThrew = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongQuantizationThrew = $_.Exception.Message -match 'different quantization'
    }
    $wrongQuantizationThrew | Should Be $true
  }

  It 'resolves Qwen from its selected catalog variant and physical binding' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = [pscustomobject]@{
      type = 'llm'; modelKey = 'qwen/qwen3.8-27b'; format = 'gguf'
      displayName = 'Qwen3.8 27B'; publisher = 'qwen'; path = 'qwen/qwen3.8-27b'
      sizeBytes = 17742040464; indexedModelIdentifier = 'qwen/qwen3.8-27b'
      deviceIdentifier = $null; paramsString = '27B'; architecture = 'qwen35'
      quantization = [pscustomobject]@{ name = 'Q4_K_M'; bits = 4 }
      variants = @('qwen/qwen3.8-27b@q4_k_m'); selectedVariant = 'qwen/qwen3.8-27b@q4_k_m'
      vision = $true; trainedForToolUse = $true; maxContextLength = 262144
    }
    $global:PeeseaVariantDetailFixture = [pscustomobject]@{
      type = 'llm'; modelKey = 'qwen/qwen3.8-27b@q4_k_m'; format = 'gguf'
      displayName = 'Qwen3.8 27B'; publisher = 'qwen'; path = 'qwen/qwen3.8-27b'
      sizeBytes = 17742040464
      indexedModelIdentifier = 'qwen/qwen3.8-27b@lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
      deviceIdentifier = $null; paramsString = '27B'; architecture = 'qwen35'
      quantization = [pscustomobject]@{ name = 'Q4_K_M'; bits = 4 }
      vision = $true; trainedForToolUse = $true; maxContextLength = 262144
    }
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) { return @($global:PeeseaBaseCatalogFixture) }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        return @($global:PeeseaVariantDetailFixture)
      }
      throw 'Unexpected catalog fixture query.'
    }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be 'qwen/qwen3.8-27b'
    $target.VariantKey | Should Be 'qwen/qwen3.8-27b@q4_k_m'
    $target.IndexedModelIdentifier | Should Be 'qwen/qwen3.8-27b@lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
    Assert-MockCalled Get-PeeseaLmsJson -Times 3 -Scope It
  }

  It 'accepts additional unselected variants when the known Q4_K_M variant remains selected' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = New-PeeseaCatalogBaseFixture -Profile $profile -Variants @(
      'qwen/qwen3.8-27b@q4_k_m', 'qwen/qwen3.8-27b@q4_k_l'
    )
    $global:PeeseaVariantDetailFixture = New-PeeseaVariantDetailFixture -Profile $profile
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) { return @($global:PeeseaBaseCatalogFixture) }
      if ($Arguments.Count -eq 3) { return @($global:PeeseaVariantDetailFixture) }
      throw 'Unexpected catalog fixture query.'
    }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.VariantKey | Should Be $profile.VariantKey
    $target.QuantizationName | Should Be $profile.QuantizationName
  }

  It 'refuses a base record when the expected variant is not selected' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = New-PeeseaCatalogBaseFixture -Profile $profile -SelectedVariant 'qwen/qwen3.8-27b@q4_k_l'
    $global:PeeseaVariantDetailFixture = New-PeeseaVariantDetailFixture -Profile $profile
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) { return @($global:PeeseaBaseCatalogFixture) }
      if ($Arguments.Count -eq 3) { return @($global:PeeseaVariantDetailFixture) }
      throw 'Unexpected catalog fixture query.'
    }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'Selected LM Studio variant'
    }

    $threw | Should Be $true
    Assert-MockCalled Get-PeeseaLmsJson -Times 1 -Scope It
  }

  It 'refuses a base record missing the selected variant or with another base quantization' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixtures = @(
      (New-PeeseaCatalogBaseFixture -Profile $profile -Variants @('qwen/qwen3.8-27b@q4_k_l'))
      (New-PeeseaCatalogBaseFixture -Profile $profile -QuantizationName 'Q4_K_L')
    )
    Mock Get-PeeseaLmsJson { return @($global:PeeseaBaseCatalogFixtures[0]) }
    $missingVariantFailed = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $missingVariantFailed = $_.Exception.Message -match 'uniquely confirm'
    }
    $missingVariantFailed | Should Be $true

    Mock Get-PeeseaLmsJson { return @($global:PeeseaBaseCatalogFixtures[1]) }
    $wrongBaseQuantizationFailed = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongBaseQuantizationFailed = $_.Exception.Message -match 'uniquely confirm'
    }
    $wrongBaseQuantizationFailed | Should Be $true
  }

  It 'refuses a detail record with a different physical index or quantization' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = New-PeeseaCatalogBaseFixture -Profile $profile
    $global:PeeseaVariantDetailFixture = New-PeeseaVariantDetailFixture -Profile $profile -IndexedModelIdentifier 'qwen/qwen3.8-27b@lmstudio-community/other.gguf'
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) { return @($global:PeeseaBaseCatalogFixture) }
      if ($Arguments.Count -eq 3) { return @($global:PeeseaVariantDetailFixture) }
      throw 'Unexpected catalog fixture query.'
    }
    $wrongPhysicalIndexFailed = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongPhysicalIndexFailed = $_.Exception.Message -match 'does not bind to the known local physical file'
    }
    $wrongPhysicalIndexFailed | Should Be $true

    $global:PeeseaVariantDetailFixture = New-PeeseaVariantDetailFixture -Profile $profile -QuantizationName 'Q4_K_L'
    $wrongDetailQuantizationFailed = $false
    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $wrongDetailQuantizationFailed = $_.Exception.Message -match 'does not bind to the known local physical file'
    }
    $wrongDetailQuantizationFailed | Should Be $true
  }

  It 'refuses duplicate exact detail records instead of taking the first one' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = New-PeeseaCatalogBaseFixture -Profile $profile
    $detail = New-PeeseaVariantDetailFixture -Profile $profile
    $global:PeeseaVariantDetailFixtures = @($detail, $detail)
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) { return @($global:PeeseaBaseCatalogFixture) }
      if ($Arguments.Count -eq 3) { return $global:PeeseaVariantDetailFixtures }
      throw 'Unexpected catalog fixture query.'
    }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'Expected one exact LM Studio detail record'
    }

    $threw | Should Be $true
  }

  It 'does not resolve a remote LM Link catalog record as the local profile' {
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCatalogFixture = New-PeeseaCatalogBaseFixture -Profile $profile -DeviceIdentifier 'remote-device'
    Mock Get-PeeseaLmsJson { @($global:PeeseaBaseCatalogFixture) }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'Expected one local LM Studio catalog record'
    }

    $threw | Should Be $true
  }

  It 'refuses a catalog record whose logical base path differs from the known key' {
    $profile = Get-PeeseaProfile -Model Coder
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 2) {
        $catalog = @(New-PeeseaCatalogBaseFixture -Profile $profile -Path 'qwen/not-the-known-key')
        return $catalog
      }
      throw 'Variant lookup must not follow a mismatched logical base path.'
    }
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'does not identify its known local physical model'
    }

    $threw | Should Be $true
  }

  It 'refuses duplicate downloaded records for the exact target file' {
    $profile = Get-PeeseaProfile -Model Coder
    $global:PeeseaTestJsonFixture = @(
      (New-PeeseaCatalogBaseFixture -Profile $profile)
      (New-PeeseaCatalogBaseFixture -Profile $profile)
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
    $global:PeeseaOtherProfileVariantQueries = @()
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3-coder-30b') {
        $global:PeeseaOtherProfileVariantQueries += ,@($Arguments)
      }
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
    }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      $embedding = New-PeeseaLoadedEmbeddingFixture
      if ($global:PeeseaTestLoadedReadCount -eq 1) {
        return @($embedding, (New-PeeseaLoadedLlmFixture -Profile $coder))
      }
      if ($global:PeeseaTestLoadedReadCount -eq 2) { return @($embedding) }
      return @($embedding, (New-PeeseaLoadedLlmFixture -Profile $qwen))
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $true
    $callText = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^unload qwen3-coder-4090$'
    $callText | Should Match '(?m)^load qwen/qwen3\.8-27b --exact --context-length 81920 --gpu max --identifier qwen/qwen3\.8-27b$'
    $callText | Should Not Match 'unload text-embedding-nomic-embed-text-v1\.5'
    $global:PeeseaOtherProfileVariantQueries.Count | Should Be 1
  }

  It 'loads Swift 1.5 by its exact standalone Q4_K_M path and preserves the embedding model' {
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    $global:PeeseaSwiftVariantQueries = @()
    Mock Get-PeeseaLmsJson {
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'swift-1.5-qwen3.8-27b') {
        $global:PeeseaSwiftVariantQueries += ,@($Arguments)
      }
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
    }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      $profile = Get-PeeseaProfile -Model Swift27B
      $embedding = New-PeeseaLoadedEmbeddingFixture
      if ($global:PeeseaTestLoadedReadCount -eq 1) { return @($embedding) }
      return @(
        $embedding
        (New-PeeseaLoadedLlmFixture -Profile $profile -CatalogPath $profile.IndexedModelIdentifier -IndexedModelIdentifier $profile.IndexedModelIdentifier -SelectedVariant '' -QuantizationName 'Q4_K_M' -VariantKeys @())
      )
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $profile = Get-PeeseaProfile -Model Swift27B
    $result = Invoke-PeeseaInference -Model Swift27B

    $result.Ready | Should Be $true
    $result.Message | Should Match 'Ready: loaded Swift27B'
    $loadCalls = @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'load' })
    $loadCalls.Count | Should Be 1
    $loadCalls[0][1] | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    ($loadCalls[0] -contains '--exact') | Should Be $true
    $loadCalls[0][$loadCalls[0].IndexOf('--context-length') + 1] | Should Be '81920'
    $loadCalls[0][$loadCalls[0].IndexOf('--identifier') + 1] | Should Be 'swift-1.5-qwen3.8-27b'
    @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'unload' -and $_[1] -eq 'text-embedding-nomic-embed-text-v1.5' }).Count | Should Be 0
    $global:PeeseaSwiftVariantQueries.Count | Should Be 0
    $profile.QuantizationName | Should Be 'Q4_K_M'
  }

  It 'loads a standalone physical-path record with its exact original selector' {
    $profile = Get-PeeseaProfile -Model Coder
    $relativePhysicalPath = 'lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $global:PeeseaStandaloneFixture = New-PeeseaStandaloneModelFixture -Profile $profile -Path $relativePhysicalPath
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLmsJson { @($global:PeeseaStandaloneFixture) }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      if ($global:PeeseaTestLoadedReadCount -eq 1) { return @() }
      return @(
        (New-PeeseaLoadedLlmFixture -Profile $profile -CatalogPath $profile.ModelPath -SelectedVariant '' -QuantizationName '' -VariantKeys @())
      )
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Coder

    $result.Ready | Should Be $true
    $loadCalls = @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'load' })
    $loadCalls.Count | Should Be 1
    $loadCalls[0][1] | Should Be $relativePhysicalPath
    ($loadCalls[0] -contains '--exact') | Should Be $true
    $result.Message | Should Match 'Ready: loaded Coder'
  }

  It 'revalidates variant selection before unloading the other known LLM' {
    $global:PeeseaVariantCatalogReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      if ($Arguments.Count -eq 2) {
        $global:PeeseaVariantCatalogReadCount++
        $selected = if ($global:PeeseaVariantCatalogReadCount -ge 3) { 'qwen/qwen3.8-27b@q4_k_l' } else { $qwen.VariantKey }
        return @(
          (New-PeeseaCatalogBaseFixture -Profile $coder)
          (New-PeeseaCatalogBaseFixture -Profile $qwen -SelectedVariant $selected)
        )
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $coder.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $coder)
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $qwen.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $qwen)
      }
      throw 'Unexpected catalog revalidation query.'
    }
    Mock Get-PeeseaLoadedModels { @(New-PeeseaLoadedLlmFixture -Profile (Get-PeeseaProfile -Model Coder)) }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $false
    $result.Message | Should Match 'Selected LM Studio variant'
    $global:PeeseaVariantCatalogReadCount | Should Be 5
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
  }

  It 'revalidates variant selection after unload before loading the selected model' {
    $global:PeeseaVariantCatalogReadCount = 0
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      if ($Arguments.Count -eq 2) {
        $global:PeeseaVariantCatalogReadCount++
        $selected = if ($global:PeeseaVariantCatalogReadCount -ge 7) { 'qwen/qwen3.8-27b@q4_k_l' } else { $qwen.VariantKey }
        return @(
          (New-PeeseaCatalogBaseFixture -Profile $coder)
          (New-PeeseaCatalogBaseFixture -Profile $qwen -SelectedVariant $selected)
        )
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $coder.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $coder)
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $qwen.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $qwen)
      }
      throw 'Unexpected catalog revalidation query.'
    }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      if ($global:PeeseaTestLoadedReadCount -eq 1) {
        return @(New-PeeseaLoadedLlmFixture -Profile (Get-PeeseaProfile -Model Coder))
      }
      return @()
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $false
    $result.Message | Should Match 'Selected LM Studio variant'
    $callText = @($global:PeeseaTestLmsCalls | ForEach-Object { $_ -join ' ' }) -join "`n"
    $callText | Should Match '(?m)^unload qwen3-coder-4090$'
    $callText | Should Not Match '(?m)^load '
  }

  It 'does not report Ready or retry when selection changes after loading' {
    $global:PeeseaVariantCatalogReadCount = 0
    $global:PeeseaTestLoadedReadCount = 0
    $global:PeeseaTestLmsCalls = @()
    Mock Get-PeeseaLmsJson {
      $coder = Get-PeeseaProfile -Model Coder
      $qwen = Get-PeeseaProfile -Model Qwen27B
      if ($Arguments.Count -eq 2) {
        $global:PeeseaVariantCatalogReadCount++
        $selected = if ($global:PeeseaVariantCatalogReadCount -ge 5) { 'qwen/qwen3.8-27b@q4_k_l' } else { $qwen.VariantKey }
        return @(
          (New-PeeseaCatalogBaseFixture -Profile $coder)
          (New-PeeseaCatalogBaseFixture -Profile $qwen -SelectedVariant $selected)
        )
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $coder.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $coder)
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq $qwen.ModelKey) {
        return @(New-PeeseaVariantDetailFixture -Profile $qwen)
      }
      throw 'Unexpected catalog revalidation query.'
    }
    Mock Get-PeeseaLoadedModels {
      $global:PeeseaTestLoadedReadCount++
      if ($global:PeeseaTestLoadedReadCount -eq 1) { return @() }
      return @(New-PeeseaLoadedLlmFixture -Profile (Get-PeeseaProfile -Model Qwen27B))
    }
    Mock Invoke-PeeseaLms {
      $global:PeeseaTestLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = '' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $false
    $result.Message | Should Match 'LM Studio did not verify exactly one loaded Qwen27B variant|Selected LM Studio variant'
    $loadCalls = @($global:PeeseaTestLmsCalls | Where-Object { $_[0] -eq 'load' })
    $loadCalls.Count | Should Be 1
    $loadCalls[0][1] | Should Be 'qwen/qwen3.8-27b'
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

  It 'treats an unknown local LLM as unknown and refuses to act on it' {
    Mock Get-PeeseaLoadedModels {
      @([pscustomobject]@{
        Type = 'llm'
        Identifier = 'unknown-qwen3.8-27b'
        ModelKey = 'unknown-qwen3.8-27b'
        CatalogPath = 'ukisai/other-model/unknown.gguf'
        IndexedModelIdentifier = 'ukisai/other-model/unknown.gguf'
        SelectedVariant = ''
        VariantKeys = @()
        QuantizationName = 'Q4_K_L'
        DeviceIdentifier = $null
        ContextLength = 81920
        Status = 'idle'
        Queued = 0
      })
    }

    $swift = @(Get-PeeseaLoadedModels)
    (Get-PeeseaProfileForLoadedModel -LoadedModel $swift[0]) | Should Be $null

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'unknown catalog or physical identity'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'does not classify or unload the original Swift Q4_K_L model as Swift 1.5' {
    Mock Get-PeeseaLoadedModels {
      @([pscustomobject]@{
        Type = 'llm'
        Identifier = 'swift-qwen3.8-27b'
        ModelKey = 'swift-qwen3.8-27b'
        CatalogPath = 'ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf'
        IndexedModelIdentifier = 'ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf'
        SelectedVariant = ''
        VariantKeys = @()
        QuantizationName = 'Q4_K_L'
        DeviceIdentifier = $null
        ContextLength = 81920
        Status = 'idle'
        Queued = 0
      })
    }

    $result = Invoke-PeeseaInference -Model Swift27B

    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'unknown catalog or physical identity'
    Assert-MockCalled Invoke-PeeseaLms -Times 0 -Scope It
    Assert-MockCalled Exit-PeeseaLaunchLock -Times 1 -Scope It
  }

  It 'supports legacy physical loaded paths only when they stay under the model root' {
    $profile = Get-PeeseaProfile -Model Coder
    $legacy = New-PeeseaLoadedLlmFixture -Profile $profile -CatalogPath $profile.ModelPath -SelectedVariant '' -QuantizationName '' -VariantKeys @()
    $outside = New-PeeseaLoadedLlmFixture -Profile $profile -CatalogPath 'C:\Users\skwid\outside\wrong.gguf' -SelectedVariant '' -QuantizationName '' -VariantKeys @()

    (Get-PeeseaProfileForLoadedModel -LoadedModel $legacy).Name | Should Be 'Coder'
    (Get-PeeseaProfileForLoadedModel -LoadedModel $outside) | Should Be $null
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
      @(New-PeeseaLoadedLlmFixture -Profile $profile -ContextLength 40960)
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
    Remove-Variable -Name PeeseaTestLoadedReadCount, PeeseaTestStatusReadCount, PeeseaTestListenerReadCount, PeeseaTestLmsCalls, PeeseaTestCurrentSid, PeeseaTestCleanupActions, PeeseaTestProcessRecords, PeeseaTestStart, PeeseaTestReusedRecord, PeeseaTestJsonFixture, PeeseaBaseCatalogFixture, PeeseaVariantDetailFixture, PeeseaStandaloneFixture -Scope Global -ErrorAction SilentlyContinue
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

  It 'parses Qwen base and variant JSON through the real CLI mapper' {
    $coder = Get-PeeseaProfile -Model Coder
    $profile = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaBaseCliJson = ConvertTo-Json -InputObject @(
      (New-PeeseaCatalogBaseFixture -Profile $coder)
      (New-PeeseaCatalogBaseFixture -Profile $profile)
    ) -Depth 8 -Compress
    $global:PeeseaDetailCliJson = ConvertTo-Json -InputObject @(
      (New-PeeseaVariantDetailFixture -Profile $profile)
    ) -Depth 8 -Compress
    Mock Test-PeeseaModelFile { $true }
    Mock Invoke-PeeseaLms {
      if ($Arguments.Count -eq 2 -and $Arguments[1] -eq '--json') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaBaseCliJson }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaDetailCliJson }
      }
      throw 'Unexpected pinned lms ls fixture query.'
    }

    $target = Resolve-PeeseaTarget -Profile $profile

    $target.PhysicalPath | Should Be $profile.ModelPath
    $target.LmsPath | Should Be 'qwen/qwen3.8-27b'
    $target.VariantKey | Should Be $profile.VariantKey
    $target.IndexedModelIdentifier | Should Be $profile.IndexedModelIdentifier
    Assert-MockCalled Invoke-PeeseaLms -Times 3 -Scope It
  }

  It 'maps the sanitized Peesea catalog snapshot without selecting the first unrelated model' {
    $global:PeeseaRawCatalogSnapshot = @'
[
  {"type":"llm","modelKey":"swift-qwen3.8-27b","format":"gguf","displayName":"Swift Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf","sizeBytes":19960648224,"indexedModelIdentifier":"ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_L","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"llm","modelKey":"swift-1.5-qwen3.8-27b","format":"gguf","displayName":"Swift 1.5 Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","sizeBytes":18370006848,"indexedModelIdentifier":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"llm","modelKey":"qwen/qwen3.8-27b","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3.8-27b@q4_k_m"],"selectedVariant":"qwen/qwen3.8-27b@q4_k_m","vision":true,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"llm","modelKey":"qwen/qwen3-coder-30b","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3-coder-30b@q4_k_m"],"selectedVariant":"qwen/qwen3-coder-30b@q4_k_m","vision":false,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"maxContextLength":2048}
]
'@
    $global:PeeseaRawQwenVariantDetail = @'
[{"type":"llm","modelKey":"qwen/qwen3.8-27b@q4_k_m","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b@lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaRawCoderVariantDetail = @'
[{"type":"llm","modelKey":"qwen/qwen3-coder-30b@q4_k_m","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b@lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"vision":false,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaRawLoadedQwen = @'
[{"type":"llm","modelKey":"qwen/qwen3.8-27b","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3.8-27b@q4_k_m"],"selectedVariant":"qwen/qwen3.8-27b@q4_k_m","identifier":"qwen/qwen3.8-27b","ttlMs":null,"lastUsedTime":1793280378610,"vision":true,"trainedForToolUse":true,"maxContextLength":262144,"contextLength":81920,"status":"idle","queued":0,"parallel":4,"engineConfigFileEnabled":false}]
'@
    Mock Test-PeeseaModelFile { $true }
    Mock Invoke-PeeseaLms {
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaRawCatalogSnapshot }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaRawQwenVariantDetail }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3-coder-30b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaRawCoderVariantDetail }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ps') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaRawLoadedQwen }
      }
      throw 'Unexpected command in the raw Peesea catalog snapshot test.'
    }

    $records = @(Get-PeeseaLmsJson -Arguments @('ls', '--json'))
    $coder = Get-PeeseaProfile -Model Coder
    $qwenProfile = Get-PeeseaProfile -Model Qwen27B
    $coderTarget = Resolve-PeeseaTarget -Profile $coder
    $qwenTarget = Resolve-PeeseaTarget -Profile $qwenProfile
    $loaded = @(Get-PeeseaLoadedModels)
    $mappedProfile = Get-PeeseaProfileForLoadedModel -LoadedModel $loaded[0]

    $records.Count | Should Be 5
    $records[0].modelKey | Should Be 'swift-qwen3.8-27b'
    $records[1].modelKey | Should Be 'swift-1.5-qwen3.8-27b'
    $records[1].path | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    $coderTarget.LmsPath | Should Be 'qwen/qwen3-coder-30b'
    $coderTarget.VariantKey | Should Be 'qwen/qwen3-coder-30b@q4_k_m'
    $coderTarget.IndexedModelIdentifier | Should Be 'qwen/qwen3-coder-30b@lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    [IO.Path]::GetFileName($coderTarget.PhysicalPath) | Should Be 'Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
    $qwenTarget.LmsPath | Should Be 'qwen/qwen3.8-27b'
    $qwenTarget.VariantKey | Should Be 'qwen/qwen3.8-27b@q4_k_m'
    $qwenTarget.IndexedModelIdentifier | Should Be 'qwen/qwen3.8-27b@lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf'
    $loaded.Count | Should Be 1
    $mappedProfile.Name | Should Be 'Qwen27B'
    $loaded[0].ContextLength | Should Be 81920
    $loaded[0].SelectedVariant | Should Be 'qwen/qwen3.8-27b@q4_k_m'
    $loaded[0].QuantizationName | Should Be 'Q4_K_M'
    $loaded[0].DeviceIdentifier | Should Be $null
  }

  It 'reuses the currently loaded Qwen variant from pinned ls and ps JSON without load or unload' {
    $coder = Get-PeeseaProfile -Model Coder
    $qwen = Get-PeeseaProfile -Model Qwen27B
    $global:PeeseaLmsCallLog = @()
    $global:PeeseaLsJson = ConvertTo-Json -InputObject @(
      (New-PeeseaCatalogBaseFixture -Profile $coder)
      (New-PeeseaCatalogBaseFixture -Profile $qwen)
    ) -Depth 10 -Compress
    $global:PeeseaQwenVariantJson = ConvertTo-Json -InputObject @(
      (New-PeeseaVariantDetailFixture -Profile $qwen)
    ) -Depth 10 -Compress
    $global:PeeseaLoadedQwenJson = ConvertTo-Json -InputObject @(
      (New-PeeseaPsLlmJsonFixture -Profile $qwen -ContextLength 81920)
    ) -Depth 10 -Compress

    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Get-PeeseaCurrentUserSid { 'S-1-5-21-cli-boundary-test' }
    Mock Get-PeeseaProcessRecords { @() }
    Mock Test-PeeseaModelFile { $true }
    Mock Get-PeeseaServerListener {
      $expectedPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
      [pscustomobject]@{
        Exists = $true; Port = 1234; LocalAddress = '0.0.0.0'; ProcessId = 13088
        ProcessName = 'LM Studio.exe'; ProcessPath = $expectedPath; ExpectedProcessPath = $expectedPath
      }
    }
    Mock Get-PeeseaServerStatus { [pscustomobject]@{ Running = $true; Port = 1234 } }
    Mock Invoke-PeeseaLms {
      $global:PeeseaLmsCallLog += ,@($Arguments)
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'server' -and $Arguments[1] -eq 'status') {
        return [pscustomobject]@{ ExitCode = 0; Output = '{"running":true,"port":1234}' }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaLsJson }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaQwenVariantJson }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ps') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaLoadedQwenJson }
      }
      return [pscustomobject]@{ ExitCode = 91; Output = 'Unexpected LM Studio command in reuse fixture.' }
    }

    $result = Invoke-PeeseaInference -Model Qwen27B

    $result.Ready | Should Be $true
    $result.Message | Should Match 'reused Qwen27B.*context 81920'
    $mutatingCalls = @($global:PeeseaLmsCallLog | Where-Object {
        $_[0] -in @('load', 'unload') -or ($_[0] -eq 'server' -and $_[1] -in @('start', 'stop'))
      })
    $mutatingCalls.Count | Should Be 0
  }

  It 'maps pinned logical loaded-model identity and preserves the embedding model' {
    $coder = Get-PeeseaProfile -Model Coder
    $embeddingIdentifier = 'text-embedding-nomic-embed-text-v1.5'
    $fixtureRecords = @(
      (New-PeeseaPsLlmJsonFixture -Profile $coder)
      [pscustomobject]@{
        type = 'embedding'; modelKey = 'text-embedding-nomic-embed-text-v1.5'; identifier = $embeddingIdentifier
        format = 'gguf'; displayName = 'Nomic Embed Text v1.5'; publisher = 'nomic-ai'
        path = 'nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf'
        sizeBytes = 84106624
        indexedModelIdentifier = 'nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf'
        deviceIdentifier = $null; paramsString = $null; architecture = 'nomic-bert'
        quantization = [pscustomobject]@{ name = 'Q4_K_M'; bits = 4 }
        ttlMs = $null; lastUsedTime = $null; maxContextLength = 2048
        status = 'idle'; queued = 0; parallel = $null; engineConfigFileEnabled = $false
      }
    )
    $global:PeeseaCliFixture = ConvertTo-Json -InputObject $fixtureRecords -Depth 8 -Compress
    Mock Invoke-PeeseaLms {
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
    }

    $models = @(Get-PeeseaLoadedModels)

    $models.Count | Should Be 2
    $models[0].CatalogPath | Should Be $coder.CatalogPath
    $models[0].IndexedModelIdentifier | Should Be $coder.ModelKey
    $models[0].SelectedVariant | Should Be $coder.VariantKey
    $models[0].QuantizationName | Should Be $coder.QuantizationName
    $models[0].Identifier | Should Be $coder.Identifier
    $models[0].ContextLength | Should Be 81920
    $models[1].Type | Should Be 'embedding'
    $models[1].Identifier | Should Be $embeddingIdentifier
    $models[1].CatalogPath | Should Be 'nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf'
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
  }

  It 'maps the currently loaded Qwen profile as reusable at the verified 81920 context' {
    $qwen = Get-PeeseaProfile -Model Qwen27B
    $coder = Get-PeeseaProfile -Model Coder
    $global:PeeseaLsJson = ConvertTo-Json -InputObject @(
      (New-PeeseaCatalogBaseFixture -Profile $coder)
      (New-PeeseaCatalogBaseFixture -Profile $qwen)
    ) -Depth 10 -Compress
    $global:PeeseaQwenVariantJson = ConvertTo-Json -InputObject @(
      (New-PeeseaVariantDetailFixture -Profile $qwen)
    ) -Depth 10 -Compress
    $global:PeeseaCliFixture = ConvertTo-Json -InputObject @(
      (New-PeeseaPsLlmJsonFixture -Profile $qwen -ContextLength 81920)
    ) -Depth 8 -Compress
    Mock Invoke-PeeseaLms {
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaLsJson }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq $qwen.ModelKey) {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaQwenVariantJson }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ps') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaCliFixture }
      }
      throw "Unexpected LM Studio mapper query: $($Arguments -join ' ')"
    }

    $loaded = @(Get-PeeseaLoadedModels)
    $profile = Get-PeeseaProfileForLoadedModel -LoadedModel $loaded[0]

    $loaded.Count | Should Be 1
    $profile.Name | Should Be 'Qwen27B'
    $loaded[0].Identifier | Should Be 'qwen/qwen3.8-27b'
    $loaded[0].CatalogPath | Should Be 'qwen/qwen3.8-27b'
    $loaded[0].SelectedVariant | Should Be 'qwen/qwen3.8-27b@q4_k_m'
    $loaded[0].QuantizationName | Should Be 'Q4_K_M'
    $loaded[0].ContextLength | Should Be 81920
  }

  It 'does not accept an LM Link model as the known local LLM' {
    $profile = Get-PeeseaProfile -Model Coder
    $record = New-PeeseaPsLlmJsonFixture -Profile $profile -DeviceIdentifier 'remote-device'
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
    $record = New-PeeseaPsLlmJsonFixture -Profile $profile -ContextLength 0
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
    $record = New-PeeseaPsLlmJsonFixture -Profile $profile -ContextLength -1
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
    $missingContext = New-PeeseaPsLlmJsonFixture -Profile $profile
    $missingContext.PSObject.Properties.Remove('contextLength') | Out-Null
    $nonnumericContext = New-PeeseaPsLlmJsonFixture -Profile $profile
    $nonnumericContext.contextLength = 'not-an-integer'
    $global:PeeseaContextFixtures = @(
      $missingContext
      $nonnumericContext
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
    Remove-Variable -Name PeeseaCliFixture, PeeseaContextFixtures, PeeseaContextFixtureIndex, PeeseaBaseCliJson, PeeseaDetailCliJson, PeeseaLmsCallLog, PeeseaLsJson, PeeseaQwenVariantJson, PeeseaLoadedQwenJson -Scope Global -ErrorAction SilentlyContinue
  }
}

Describe 'Peesea streamed process adapter' {
  It 'streams an ANSI progress chunk before the child exits and preserves argument boundaries' {
    $fakeRoot = Join-Path $env:TEMP ('peesea progress fake ' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fakeRoot | Out-Null
    $fakeScript = Join-Path $fakeRoot 'fake action.ps1'
    $childResultPath = Join-Path $fakeRoot 'child result.txt'
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    $token = 'token with spaces "and quotes" plus trailing slash\'
    $global:PeeseaFakePowerShellPath = $powershellPath
    $fakeChild = @'
param([string]$ChildResultPath, [string]$Token)
[Console]::Out.Write(([char]27).ToString() + '[2KPEESEA_PROGRESS_TOKEN')
[Console]::Out.Flush()
Start-Sleep -Milliseconds 400
[IO.File]::WriteAllText($ChildResultPath, 'progress-emitted-before-exit|' + $Token)
exit 0
'@
    [IO.File]::WriteAllText($fakeScript, $fakeChild, [Text.Encoding]::Unicode)
    Mock Get-Command {
      if ($Name -eq 'lms') {
        return [pscustomobject]@{ Source = $global:PeeseaFakePowerShellPath }
      }
      throw "Unexpected command discovery in the native progress test: $Name"
    }
    try {
      $result = Invoke-PeeseaLms -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', $fakeScript, $childResultPath, $token
      )

      $result.ExitCode | Should Be 0
      $result.Output | Should Be ''
      (Get-Content -LiteralPath $childResultPath -Raw) | Should Be "progress-emitted-before-exit|$token"
      ($result -is [System.Array]) | Should Be $false
    } finally {
      Remove-Variable -Name PeeseaFakePowerShellPath -Scope Global -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $fakeRoot) {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force
      }
    }
  }

  It 'observes ANSI progress before native-child exit through the outer controller result capture' {
    $fakeRoot = Join-Path $env:TEMP ('peesea temporal progress fake ' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fakeRoot | Out-Null
    $wrapperScript = Join-Path $fakeRoot 'outer controller harness.ps1'
    $nativeScript = Join-Path $fakeRoot 'fake native load.ps1'
    $releasePath = Join-Path $fakeRoot 'release native child.flag'
    $nativeDonePath = Join-Path $fakeRoot 'native child result.txt'
    $controllerResultPath = Join-Path $fakeRoot 'controller result.json'
    $fakeNative = @'
param([string]$ReleasePath, [string]$DonePath)
[Console]::Out.Write(([char]27).ToString() + '[2KPEESEA_TEMPORAL_PROGRESS_TOKEN')
[Console]::Out.Flush()
$deadline = [DateTime]::UtcNow.AddSeconds(7)
while (-not (Test-Path -LiteralPath $ReleasePath) -and [DateTime]::UtcNow -lt $deadline) {
  Start-Sleep -Milliseconds 25
}
if (Test-Path -LiteralPath $ReleasePath) {
  [IO.File]::WriteAllText($DonePath, 'released-before-native-exit')
  exit 0
}
[IO.File]::WriteAllText($DonePath, 'native-child-timed-out')
exit 19
'@
    [IO.File]::WriteAllText($nativeScript, $fakeNative, [Text.Encoding]::Unicode)
$fakeWrapper = @'
param([string]$LauncherScript, [string]$NativeScript, [string]$ReleasePath, [string]$NativeDonePath, [string]$ResultPath, [string]$UseOldCapture)
. $LauncherScript
if ($UseOldCapture -eq 'True') {
  function Invoke-PeeseaStreamedNativeCall {
    param([string]$ExecutablePath, [string[]]$Arguments)
    $discardedOutput = & $ExecutablePath @Arguments 2>&1
    return [int]$LASTEXITCODE
  }
}
$global:PeeseaOuterLoadedState = 'empty'
$global:PeeseaOuterLockReleased = $false
$global:PeeseaOuterNativeScript = $NativeScript
$global:PeeseaOuterReleasePath = $ReleasePath
$global:PeeseaOuterNativeDonePath = $NativeDonePath
function Invoke-PeeseaCleanup {}
function Enter-PeeseaLaunchLock { return 'owned-fake-lock' }
function Exit-PeeseaLaunchLock { param($Lock); $global:PeeseaOuterLockReleased = $true }
function Test-PeeseaModelFile { param([string]$Path); return $true }
function Get-PeeseaServerStatus { return [pscustomobject]@{ Running = $true; Port = 1234 } }
function Get-PeeseaServerListener {
  param([int]$Port)
  $path = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
  return [pscustomobject]@{
    Exists = $true; Port = 1234; LocalAddress = '0.0.0.0'; ProcessName = 'LM Studio.exe'
    ProcessPath = $path; ExpectedProcessPath = $path
  }
}
function Get-PeeseaLoadedModels {
  if ($global:PeeseaOuterLoadedState -ne 'loaded') { return @() }
  $profile = Get-PeeseaProfile -Model Coder
  return @([pscustomobject]@{
    Type = 'llm'; Identifier = $profile.Identifier; ModelKey = $profile.ModelKey
    CatalogPath = $profile.CatalogPath; IndexedModelIdentifier = $profile.ModelKey
    SelectedVariant = $profile.VariantKey; VariantKeys = @($profile.VariantKey)
    QuantizationName = $profile.QuantizationName; DeviceIdentifier = $null
    ContextLength = 81920; Status = 'idle'; Queued = 0
  })
}
function Invoke-PeeseaLms {
  param([string[]]$Arguments)
  if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq '--json') {
    return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaOuterBaseJson }
  }
  if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3-coder-30b') {
    return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaOuterDetailJson }
  }
  if ($Arguments[0] -eq 'load') {
    $exitCode = Invoke-PeeseaStreamedNativeCall -ExecutablePath (Join-Path $PSHOME 'powershell.exe') -Arguments @(
      '-NoProfile', '-NonInteractive', '-File', $global:PeeseaOuterNativeScript,
      $global:PeeseaOuterReleasePath, $global:PeeseaOuterNativeDonePath
    )
    if ($exitCode -eq 0) { $global:PeeseaOuterLoadedState = 'loaded' }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = '' }
  }
  throw "Unexpected fake lms call: $($Arguments -join ' ')"
}
$global:PeeseaOuterBaseJson = '[{"type":"llm","modelKey":"qwen/qwen3-coder-30b","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3-coder-30b@q4_k_m"],"selectedVariant":"qwen/qwen3-coder-30b@q4_k_m","vision":false,"trainedForToolUse":true,"maxContextLength":262144}]'
$global:PeeseaOuterDetailJson = '[{"type":"llm","modelKey":"qwen/qwen3-coder-30b@q4_k_m","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b@lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"vision":false,"trainedForToolUse":true,"maxContextLength":262144}]'
$result = Invoke-PeeseaInference -Model Coder
[IO.File]::WriteAllText($ResultPath, (ConvertTo-Json -InputObject ([pscustomobject]@{
  Ready = $result.Ready
  ExitCode = $result.ExitCode
  Message = $result.Message
  ResultProperties = @($result.PSObject.Properties.Name) -join ','
  LockReleased = $global:PeeseaOuterLockReleased
}) -Compress))
'@
    [IO.File]::WriteAllText($wrapperScript, $fakeWrapper, [Text.Encoding]::Unicode)
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    $process = $null
    $modes = @(
      [pscustomobject]@{ Name = 'old-capture'; UseOldCapture = $true; ExpectProgressBeforeRelease = $false }
      [pscustomobject]@{ Name = 'streamed'; UseOldCapture = $false; ExpectProgressBeforeRelease = $true }
    )

    try {
      foreach ($mode in $modes) {
        $releasePath = Join-Path $fakeRoot ($mode.Name + '.release')
        $nativeDonePath = Join-Path $fakeRoot ($mode.Name + '.native-result')
        $controllerResultPath = Join-Path $fakeRoot ($mode.Name + '.controller-result')
        $wrapperArguments = @(
          '-NoProfile', '-NonInteractive', '-File', $wrapperScript,
          $script:PeeseaInferenceScript, $nativeScript, $releasePath, $nativeDonePath,
          $controllerResultPath, [string]$mode.UseOldCapture
        )
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellPath
        $startInfo.Arguments = (($wrapperArguments | ForEach-Object {
              ConvertTo-PeeseaNativeCommandLineArgument -Argument $_
            }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $false
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Could not start the $($mode.Name) controller fake process." }
        $ownedPid = $process.Id
        $ownedStartTime = $process.StartTime

        $buffer = New-Object char[] 512
        $capturedOutput = ''
        $observedBeforeRelease = $false
        $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        $observeSeconds = if ($mode.UseOldCapture) { 3 } else { 4 }
        $observeDeadline = [DateTime]::UtcNow.AddSeconds($observeSeconds)
        while (-not $observedBeforeRelease -and -not $process.HasExited -and
          [DateTime]::UtcNow -lt $observeDeadline) {
          if ($readTask.Wait(100)) {
            $readCount = $readTask.Result
            if ($readCount -le 0) { break }
            $capturedOutput += [string]::new($buffer, 0, $readCount)
            $observedBeforeRelease = $capturedOutput.Contains('PEESEA_TEMPORAL_PROGRESS_TOKEN')
            if (-not $observedBeforeRelease) {
              $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
            }
          }
        }

        $wrapperWasAliveBeforeRelease = -not $process.HasExited
        $resultWasAbsentBeforeRelease = -not (Test-Path -LiteralPath $controllerResultPath)
        [IO.File]::WriteAllText($releasePath, 'release')
        $process.WaitForExit(8000) | Should Be $true
        if (-not $readTask.IsCompleted) { $readTask.Wait(1000) | Out-Null }
        if ($readTask.IsCompleted) {
          $remainingCount = $readTask.Result
          if ($remainingCount -gt 0) {
            $capturedOutput += [string]::new($buffer, 0, $remainingCount)
          }
        }
        $controllerResult = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $controllerResultPath -Raw)

        $observedBeforeRelease | Should Be $mode.ExpectProgressBeforeRelease
        if ($mode.ExpectProgressBeforeRelease) {
          $progressIndex = $capturedOutput.IndexOf('PEESEA_TEMPORAL_PROGRESS_TOKEN')
          ($progressIndex -gt 3) | Should Be $true
          $progressSequence = $capturedOutput.Substring($progressIndex - 4, 4 + 'PEESEA_TEMPORAL_PROGRESS_TOKEN'.Length)
          $progressSequence | Should Be (([char]27).ToString() + '[2KPEESEA_TEMPORAL_PROGRESS_TOKEN')
        }
        $wrapperWasAliveBeforeRelease | Should Be $true
        $resultWasAbsentBeforeRelease | Should Be $true
        (Get-Content -LiteralPath $nativeDonePath -Raw) | Should Be 'released-before-native-exit'
        $controllerResult.Ready | Should Be $true
        $controllerResult.ExitCode | Should Be 0
        $controllerResult.Message | Should Match 'Ready: loaded Coder'
        $controllerResult.Message | Should Not Match 'PEESEA_TEMPORAL_PROGRESS_TOKEN'
        $controllerResult.ResultProperties | Should Be 'Ready,ExitCode,Message'
        $controllerResult.LockReleased | Should Be $true
        $process.Dispose()
        $process = $null
      }
    } finally {
      foreach ($modeName in @('old-capture', 'streamed')) {
        [IO.File]::WriteAllText((Join-Path $fakeRoot ($modeName + '.release')), 'release')
      }
      if ($null -ne $process -and -not $process.HasExited) {
        try {
          $process.WaitForExit(8000) | Out-Null
        } catch { }
        if (-not $process.HasExited) {
          $currentProcess = Get-Process -Id $ownedPid -ErrorAction SilentlyContinue
          if ($null -ne $currentProcess -and $currentProcess.StartTime -eq $ownedStartTime) {
            $process.Kill()
            $process.WaitForExit()
          }
        }
      }
      if ($null -ne $process) { $process.Dispose() }
      if (Test-Path -LiteralPath $fakeRoot) {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force
      }
    }
  }
}

Describe 'Peesea launcher completion' {
  It 'exposes an explicit keep-console-open switch for desktop launchers' {
    $scriptCommand = Get-Command -Name $script:PeeseaInferenceScript -CommandType ExternalScript

    $scriptCommand.Parameters.ContainsKey('KeepConsoleOpen') | Should Be $true
  }

  It 'keeps desktop success and failure results visible in a NoExit shell' {
    $fakeRoot = Join-Path $env:TEMP ('peesea desktop completion fake ' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fakeRoot | Out-Null
    $harness = Join-Path $fakeRoot 'desktop harness.ps1'
    $fakeHarness = @'
param([string]$LauncherScript, [int]$ExitCode, [string]$Message, [string]$CompletionMarker)
. $LauncherScript
$global:PeeseaFakeLauncherResult = [pscustomobject]@{
  Ready = ($ExitCode -eq 0)
  ExitCode = $ExitCode
  Message = $Message
}
function Invoke-PeeseaInference {
  param([ValidateSet('Coder', 'Qwen27B')][string]$Model = 'Coder')
  return $global:PeeseaFakeLauncherResult
}
try {
  Invoke-PeeseaLauncherEntryPoint -Model Coder -KeepConsoleOpen | Out-Null
  [IO.File]::WriteAllText($CompletionMarker, 'entry-returned')
} catch {
  [IO.File]::WriteAllText($CompletionMarker, 'entry-failed:' + $_.Exception.Message)
  exit 91
}
'@
    [IO.File]::WriteAllText($harness, $fakeHarness, [Text.Encoding]::Unicode)
    $powershellPath = Join-Path $PSHOME 'powershell.exe'

    try {
      foreach ($case in @(
        [pscustomobject]@{ ExitCode = 0; Message = 'Ready: reused Coder' }
        [pscustomobject]@{ ExitCode = 1; Message = 'Inference launcher failed: fake error' }
      )) {
        $completionMarker = Join-Path $fakeRoot ('completion-' + $case.ExitCode + '.txt')
        $arguments = @(
          '-NoProfile', '-NoLogo', '-NoExit', '-File', $harness,
          $script:PeeseaInferenceScript, [string]$case.ExitCode, $case.Message, $completionMarker
        )
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellPath
        $startInfo.Arguments = (($arguments | ForEach-Object {
              ConvertTo-PeeseaNativeCommandLineArgument -Argument $_
            }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Could not start the desktop completion fake process.' }
        try {
          $deadline = [DateTime]::UtcNow.AddSeconds(5)
          while (-not (Test-Path -LiteralPath $completionMarker) -and
            -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
          }
          (Test-Path -LiteralPath $completionMarker) | Should Be $true
          $process.HasExited | Should Be $false
          (Get-Content -LiteralPath $completionMarker -Raw) | Should Be 'entry-returned'

          $process.StandardInput.WriteLine('exit')
          $process.StandardInput.Flush()
          $process.WaitForExit(5000) | Should Be $true
          $output = $process.StandardOutput.ReadToEnd()
          $output | Should Match ([regex]::Escape($case.Message))
        } finally {
          if (-not $process.HasExited) {
            try {
              $process.StandardInput.WriteLine('exit')
              $process.StandardInput.Flush()
            } catch { }
            if (-not $process.WaitForExit(2000)) {
              $process.Kill()
              $process.WaitForExit()
            }
          }
          $process.Dispose()
        }
      }
    } finally {
      if (Test-Path -LiteralPath $fakeRoot) {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force
      }
    }
  }

  It 'preserves headless zero and nonzero process exits without prompts' {
    $fakeRoot = Join-Path $env:TEMP ('peesea headless completion fake ' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fakeRoot | Out-Null
    $harness = Join-Path $fakeRoot 'headless harness.ps1'
    $fakeHarness = @'
param([string]$LauncherScript, [int]$ExitCode, [string]$Message, [string]$ReturnedMarker)
. $LauncherScript
$global:PeeseaFakeLauncherResult = [pscustomobject]@{
  Ready = ($ExitCode -eq 0)
  ExitCode = $ExitCode
  Message = $Message
}
function Invoke-PeeseaInference {
  param([ValidateSet('Coder', 'Qwen27B')][string]$Model = 'Coder')
  return $global:PeeseaFakeLauncherResult
}
Invoke-PeeseaLauncherEntryPoint -Model Coder | Out-Null
[IO.File]::WriteAllText($ReturnedMarker, 'unexpected-return')
exit 99
'@
    [IO.File]::WriteAllText($harness, $fakeHarness, [Text.Encoding]::Unicode)
    $powershellPath = Join-Path $PSHOME 'powershell.exe'

    try {
      foreach ($case in @(
        [pscustomobject]@{ ExitCode = 0; Message = 'Ready: loaded Coder' }
        [pscustomobject]@{ ExitCode = 1; Message = 'Inference launcher failed: fake error' }
      )) {
        $returnedMarker = Join-Path $fakeRoot ('unexpected-return-' + $case.ExitCode + '.txt')
        $arguments = @(
          '-NoProfile', '-NoLogo', '-NonInteractive', '-File', $harness,
          $script:PeeseaInferenceScript, [string]$case.ExitCode, $case.Message, $returnedMarker
        )
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellPath
        $startInfo.Arguments = (($arguments | ForEach-Object {
              ConvertTo-PeeseaNativeCommandLineArgument -Argument $_
            }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Could not start the headless completion fake process.' }
        try {
          $process.WaitForExit(5000) | Should Be $true
          $process.ExitCode | Should Be $case.ExitCode
          (Test-Path -LiteralPath $returnedMarker) | Should Be $false
          $output = $process.StandardOutput.ReadToEnd()
          $output | Should Match ([regex]::Escape($case.Message))
        } finally {
          if (-not $process.HasExited) {
            try {
              $process.StandardInput.WriteLine('exit')
              $process.StandardInput.Flush()
            } catch { }
            if (-not $process.WaitForExit(2000)) {
              $process.Kill()
              $process.WaitForExit()
            }
          }
          $process.Dispose()
        }
      }
    } finally {
      if (Test-Path -LiteralPath $fakeRoot) {
        Remove-Item -LiteralPath $fakeRoot -Recurse -Force
      }
    }
  }
}

Describe 'Peesea Swift profile resolution' {
  It 'binds the observed Swift 1.5 record to the exact ukisai Q4_K_M physical GGUF' {
    $global:PeeseaSwiftCatalogJson = @'
[{"type":"llm","modelKey":"swift-1.5-qwen3.8-27b","format":"gguf","displayName":"Swift 1.5 Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","sizeBytes":18370006848,"indexedModelIdentifier":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaSwiftLmsCalls = @()
    Mock Test-PeeseaModelFile { $true }
    Mock Invoke-PeeseaLms {
      $global:PeeseaSwiftLmsCalls += ,@($Arguments)
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq '--json') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaSwiftCatalogJson }
      }
      throw "Unexpected Swift catalog command: $($Arguments -join ' ')"
    }

    $profile = Get-PeeseaProfile -Model Swift27B
    $target = Resolve-PeeseaTarget -Profile $profile
    $expectedPhysicalPath = Join-Path $env:USERPROFILE '.lmstudio\models\ukisai\Swift-1.5-Qwen3.8-27B-GGUF\Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'

    $profile.IdentityKind | Should Be 'StandalonePhysical'
    $profile.ModelPath | Should Be $expectedPhysicalPath
    $target.IdentityKind | Should Be 'StandalonePhysical'
    $target.LmsPath | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    $target.PhysicalPath | Should Be $expectedPhysicalPath
    $target.VariantKey | Should Be $null
    $target.IndexedModelIdentifier | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    $target.QuantizationName | Should Be 'Q4_K_M'
    $global:PeeseaSwiftLmsCalls.Count | Should Be 2
  }

  It 'rejects IQ4_NL metadata even when the standalone row reports the Q4_K_M file size' {
    $global:PeeseaSwiftCatalogJson = @'
[{"type":"llm","modelKey":"swift-1.5-qwen3.8-27b","format":"gguf","displayName":"Swift 1.5 Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","sizeBytes":18370006848,"indexedModelIdentifier":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"IQ4_NL","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaSwiftLmsCalls = @()
    Mock Test-PeeseaModelFile { $true }
    Mock Invoke-PeeseaLms {
      $global:PeeseaSwiftLmsCalls += ,@($Arguments)
      [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaSwiftCatalogJson }
    }
    $profile = Get-PeeseaProfile -Model Swift27B
    $threw = $false

    try {
      Resolve-PeeseaTarget -Profile $profile | Out-Null
    } catch {
      $threw = $_.Exception.Message -match 'different quantization'
    }

    $threw | Should Be $true
    @($global:PeeseaSwiftLmsCalls | Where-Object { $_.Count -eq 2 -and $_[0] -eq 'ls' -and $_[1] -eq '--json' }).Count | Should Be 1
    @($global:PeeseaSwiftLmsCalls | Where-Object { $_.Count -eq 3 }).Count | Should Be 0
  }

  It 'maps a loaded Swift standalone record without inventing a catalog variant' {
    $global:PeeseaSwiftLoadedJson = @'
[{"type":"llm","modelKey":"swift-1.5-qwen3.8-27b","format":"gguf","displayName":"Swift 1.5 Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","sizeBytes":18370006848,"indexedModelIdentifier":"ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"identifier":"swift-1.5-qwen3.8-27b","ttlMs":null,"vision":true,"trainedForToolUse":true,"maxContextLength":262144,"contextLength":81920,"status":"idle","queued":0,"parallel":4,"engineConfigFileEnabled":false}]
'@
    Mock Invoke-PeeseaLms {
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ps' -and $Arguments[1] -eq '--json') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaSwiftLoadedJson }
      }
      throw "Unexpected Swift loaded-model command: $($Arguments -join ' ')"
    }

    $loaded = @(Get-PeeseaLoadedModels)
    $profile = Get-PeeseaProfileForLoadedModel -LoadedModel $loaded[0]

    $loaded.Count | Should Be 1
    $profile.Name | Should Be 'Swift27B'
    $loaded[0].CatalogPath | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    $loaded[0].IndexedModelIdentifier | Should Be 'ukisai/Swift-1.5-Qwen3.8-27B-GGUF/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf'
    $loaded[0].SelectedVariant | Should Be ''
    $loaded[0].QuantizationName | Should Be 'Q4_K_M'
    $loaded[0].ContextLength | Should Be 81920
    Assert-MockCalled Invoke-PeeseaLms -Times 1 -Scope It
  }

  AfterEach {
    Remove-Variable -Name PeeseaSwiftCatalogJson, PeeseaSwiftLmsCalls, PeeseaSwiftLoadedJson -Scope Global -ErrorAction SilentlyContinue
  }
}

Describe 'Peesea loaded catalog identity verification' {
  It 'does not unload a catalog-loaded Coder when its selected detail points to a different GGUF' {
    $global:PeeseaBoundaryLoadedState = 'coder-loaded'
    $global:PeeseaBoundaryLmsCalls = @()
    $global:PeeseaBoundaryCatalogJson = @'
[
  {"type":"llm","modelKey":"swift-qwen3.8-27b","format":"gguf","displayName":"Swift Qwen3.8 27B","publisher":"ukisai","path":"ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf","sizeBytes":19960648224,"indexedModelIdentifier":"ukisai/Swift-Qwen3.8-27B-GGUF/Swift-Qwen3.8-27B-Q4_K_L.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_L","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"llm","modelKey":"qwen/qwen3.8-27b","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3.8-27b@q4_k_m"],"selectedVariant":"qwen/qwen3.8-27b@q4_k_m","vision":true,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"llm","modelKey":"qwen/qwen3-coder-30b","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3-coder-30b@q4_k_m"],"selectedVariant":"qwen/qwen3-coder-30b@q4_k_m","vision":false,"trainedForToolUse":true,"maxContextLength":262144},
  {"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"maxContextLength":2048}
]
'@
    $global:PeeseaBoundaryQwenDetailJson = @'
[{"type":"llm","modelKey":"qwen/qwen3.8-27b@q4_k_m","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b@lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaBoundaryWrongCoderDetailJson = @'
[{"type":"llm","modelKey":"qwen/qwen3-coder-30b@q4_k_m","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b@lmstudio-community/other/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"vision":false,"trainedForToolUse":true,"maxContextLength":262144}]
'@
    $global:PeeseaBoundaryCoderAndEmbeddingPsJson = @'
[
  {"type":"llm","modelKey":"qwen/qwen3-coder-30b","format":"gguf","displayName":"Qwen3 Coder 30B","publisher":"qwen","path":"qwen/qwen3-coder-30b","sizeBytes":18632365388,"indexedModelIdentifier":"qwen/qwen3-coder-30b","deviceIdentifier":null,"paramsString":"30B-A3B","architecture":"qwen3moe","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3-coder-30b@q4_k_m"],"selectedVariant":"qwen/qwen3-coder-30b@q4_k_m","identifier":"qwen3-coder-4090","vision":false,"trainedForToolUse":true,"maxContextLength":262144,"contextLength":81920,"status":"idle","queued":0,"parallel":4,"engineConfigFileEnabled":false},
  {"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","identifier":"text-embedding-nomic-embed-text-v1.5","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"ttlMs":null,"lastUsedTime":null,"maxContextLength":2048,"status":"idle","queued":0,"parallel":null,"engineConfigFileEnabled":false}
]
'@
    $global:PeeseaBoundaryEmbeddingPsJson = @'
[{"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","identifier":"text-embedding-nomic-embed-text-v1.5","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"ttlMs":null,"lastUsedTime":null,"maxContextLength":2048,"status":"idle","queued":0,"parallel":null,"engineConfigFileEnabled":false}]
'@
    $global:PeeseaBoundaryQwenAndEmbeddingPsJson = @'
[
  {"type":"llm","modelKey":"qwen/qwen3.8-27b","format":"gguf","displayName":"Qwen3.8 27B","publisher":"qwen","path":"qwen/qwen3.8-27b","sizeBytes":17742040464,"indexedModelIdentifier":"qwen/qwen3.8-27b","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen35","quantization":{"name":"Q4_K_M","bits":4},"variants":["qwen/qwen3.8-27b@q4_k_m"],"selectedVariant":"qwen/qwen3.8-27b@q4_k_m","identifier":"qwen/qwen3.8-27b","ttlMs":null,"lastUsedTime":1793280378610,"vision":true,"trainedForToolUse":true,"maxContextLength":262144,"contextLength":81920,"status":"idle","queued":0,"parallel":4,"engineConfigFileEnabled":false},
  {"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5","format":"gguf","displayName":"Nomic Embed Text v1.5","publisher":"nomic-ai","path":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","sizeBytes":84106624,"indexedModelIdentifier":"nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf","identifier":"text-embedding-nomic-embed-text-v1.5","deviceIdentifier":null,"architecture":"nomic-bert","quantization":{"name":"Q4_K_M","bits":4},"ttlMs":null,"lastUsedTime":null,"maxContextLength":2048,"status":"idle","queued":0,"parallel":null,"engineConfigFileEnabled":false}
]
'@

    Mock Invoke-PeeseaCleanup {}
    Mock Enter-PeeseaLaunchLock { $true }
    Mock Exit-PeeseaLaunchLock {}
    Mock Test-PeeseaModelFile { $true }
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
    Mock Invoke-PeeseaLms {
      $global:PeeseaBoundaryLmsCalls += ,@($Arguments)
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq '--json') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaBoundaryCatalogJson }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaBoundaryQwenDetailJson }
      }
      if ($Arguments.Count -eq 3 -and $Arguments[0] -eq 'ls' -and $Arguments[1] -eq 'qwen/qwen3-coder-30b') {
        return [pscustomobject]@{ ExitCode = 0; Output = $global:PeeseaBoundaryWrongCoderDetailJson }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'ps') {
        $loadedJson = switch ($global:PeeseaBoundaryLoadedState) {
          'coder-loaded' { $global:PeeseaBoundaryCoderAndEmbeddingPsJson; break }
          'coder-unloaded' { $global:PeeseaBoundaryEmbeddingPsJson; break }
          'qwen-loaded' { $global:PeeseaBoundaryQwenAndEmbeddingPsJson; break }
          default { throw "Unexpected test loaded state: $global:PeeseaBoundaryLoadedState" }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $loadedJson }
      }
      if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'unload' -and $Arguments[1] -eq 'qwen3-coder-4090') {
        $global:PeeseaBoundaryLoadedState = 'coder-unloaded'
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
      }
      if ($Arguments.Count -gt 1 -and $Arguments[0] -eq 'load' -and $Arguments[1] -eq 'qwen/qwen3.8-27b') {
        $global:PeeseaBoundaryLoadedState = 'qwen-loaded'
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
      }
      throw "Unexpected mocked LM Studio command: $($Arguments -join ' ')"
    }

    $result = Invoke-PeeseaInference -Model Qwen27B
    $mutatingCalls = @($global:PeeseaBoundaryLmsCalls | Where-Object { $_[0] -in @('load', 'unload') })

    $mutatingCalls.Count | Should Be 0
    $result.Ready | Should Be $false
    $result.ExitCode | Should Be 1
    $result.Message | Should Match 'unknown catalog or physical identity'
    $coderDetailLookups = @($global:PeeseaBoundaryLmsCalls | Where-Object {
        $_.Count -eq 3 -and $_[0] -eq 'ls' -and $_[1] -eq 'qwen/qwen3-coder-30b'
      })
    $coderDetailLookups.Count | Should Be 1
    @($global:PeeseaBoundaryLmsCalls | Where-Object { $_[0] -eq 'unload' -and $_[1] -eq 'text-embedding-nomic-embed-text-v1.5' }).Count | Should Be 0

    $global:PeeseaBoundaryLoadedState = 'coder-loaded'
    $global:PeeseaBoundaryWrongCoderDetailJson = '[]'
    $global:PeeseaBoundaryLmsCalls = @()
    $missingDetailResult = Invoke-PeeseaInference -Model Qwen27B
    $mutatingCalls = @($global:PeeseaBoundaryLmsCalls | Where-Object { $_[0] -in @('load', 'unload') })

    $mutatingCalls.Count | Should Be 0
    $missingDetailResult.Ready | Should Be $false
    $missingDetailResult.ExitCode | Should Be 1
    $missingDetailResult.Message | Should Match 'unknown catalog or physical identity'
    @($global:PeeseaBoundaryLmsCalls | Where-Object {
        $_.Count -eq 3 -and $_[0] -eq 'ls' -and $_[1] -eq 'qwen/qwen3-coder-30b'
      }).Count | Should Be 1
  }

  AfterEach {
    Remove-Variable -Name PeeseaBoundaryLoadedState, PeeseaBoundaryLmsCalls, PeeseaBoundaryCatalogJson, PeeseaBoundaryQwenDetailJson, PeeseaBoundaryWrongCoderDetailJson, PeeseaBoundaryCoderAndEmbeddingPsJson, PeeseaBoundaryEmbeddingPsJson, PeeseaBoundaryQwenAndEmbeddingPsJson -Scope Global -ErrorAction SilentlyContinue
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
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
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
      @(New-PeeseaLoadedLlmFixture -Profile $profile)
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
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
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
      Get-PeeseaCatalogJsonFixture -Arguments $Arguments
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

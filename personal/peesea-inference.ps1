<#
.SYNOPSIS
Launch the selected Peesea LM Studio inference profile.

.DESCRIPTION
Runs the approved per-user process cleanup, then starts or reuses the known
LM Studio server and selected local model. Coder is the default profile;
Qwen27B selects Qwen3.8 27B. A profile switch or reload can interrupt a
prediction on a known model, and LM Studio does not expose a reliable active
prediction count. Browsers are closed gracefully; unrelated processes are
left alone.

.PARAMETER Model
Select Coder (the default) or Qwen27B.

.EXAMPLE
Get-Help .\personal\peesea-inference.ps1

.EXAMPLE
.\personal\peesea-inference.ps1 -Model Qwen27B
#>
[CmdletBinding()]
param(
  [ValidateSet('Coder', 'Qwen27B')]
  [string]$Model = 'Coder'
)

function Get-PeeseaProfile {
  param(
    [ValidateSet('Coder', 'Qwen27B')]
    [string]$Model = 'Coder'
  )

  $root = Join-Path $env:USERPROFILE '.lmstudio\models\lmstudio-community'
  if ($Model -eq 'Coder') {
    return [pscustomobject]@{
      Name = 'Coder'
      ModelKey = 'qwen/qwen3-coder-30b'
      Identifier = 'qwen3-coder-4090'
      ModelPath = Join-Path $root 'Qwen3-Coder-30B-A3B-Instruct-GGUF\Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
      MinimumContext = 81920
      Port = 1234
      Bind = '0.0.0.0'
    }
  }

  return [pscustomobject]@{
    Name = 'Qwen27B'
    ModelKey = 'qwen/qwen3.8-27b'
    Identifier = 'qwen/qwen3.8-27b'
    ModelPath = Join-Path $root 'Qwen3.8-27B-GGUF\Qwen3.8-27B-Q4_K_M.gguf'
    MinimumContext = 81920
    Port = 1234
    Bind = '0.0.0.0'
  }
}

function Enter-PeeseaLaunchLock {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Global\PeeseaInference-$sid")
  try {
    $acquired = $mutex.WaitOne(0)
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  } catch {
    $mutex.Dispose()
    throw
  }
  if (-not $acquired) {
    $mutex.Dispose()
    return $null
  }
  return $mutex
}

function Exit-PeeseaLaunchLock {
  param([Parameter(Mandatory)]$Lock)

  try {
    $Lock.ReleaseMutex()
  } finally {
    $Lock.Dispose()
  }
}

function Invoke-PeeseaLms {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $command = Get-Command lms -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) {
    $lmsPath = $command.Source
  } else {
    $lmsPath = Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'
    if (-not (Test-Path -LiteralPath $lmsPath -PathType Leaf)) {
      throw "LM Studio CLI was not found on PATH or at $lmsPath."
    }
  }

  $output = & $lmsPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Output = ($output -join [Environment]::NewLine)
  }
}

function Get-PeeseaLmsJson {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $result = Invoke-PeeseaLms -Arguments $Arguments
  if ($result.ExitCode -ne 0) {
    throw "lms $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.Output)"
  }
  try {
    $json = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop
    return $json
  } catch {
    throw "lms $($Arguments -join ' ') returned invalid JSON: $($_.Exception.Message)"
  }
}

function Test-PeeseaModelFile {
  param([Parameter(Mandatory)][string]$Path)

  return Test-Path -LiteralPath $Path -PathType Leaf
}

function ConvertTo-PeeseaPhysicalModelPath {
  param([Parameter(Mandatory)][string]$LmsPath)

  if ([string]::IsNullOrWhiteSpace($LmsPath)) {
    throw 'LM Studio returned an empty model path.'
  }
  $modelsRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.lmstudio\models'))
  $normalizedPath = $LmsPath.Replace('/', '\')
  try {
    $physicalPath = if ([IO.Path]::IsPathRooted($normalizedPath)) {
      [IO.Path]::GetFullPath($normalizedPath)
    } else {
      [IO.Path]::GetFullPath((Join-Path $modelsRoot $normalizedPath))
    }
  } catch {
    throw "LM Studio returned an invalid model path: $($_.Exception.Message)"
  }

  $modelsRootPrefix = $modelsRoot + [IO.Path]::DirectorySeparatorChar
  if (-not $physicalPath.StartsWith($modelsRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'LM Studio model path resolves outside the local models directory.'
  }
  return $physicalPath
}

function Resolve-PeeseaTarget {
  param([Parameter(Mandatory)]$Profile)

  if (-not (Test-PeeseaModelFile -Path $Profile.ModelPath)) {
    throw "The known $($Profile.Name) model file is missing: $($Profile.ModelPath)"
  }
  $models = @(Get-PeeseaLmsJson -Arguments @('ls', '--json'))
  $candidates = @($models | Where-Object {
      $_.type -eq 'llm' -and $_.modelKey -eq $Profile.ModelKey -and $_.path -and
      [string]::IsNullOrEmpty([string]$_.deviceIdentifier)
    })
  $matches = @()
  foreach ($candidate in $candidates) {
    $physicalPath = ConvertTo-PeeseaPhysicalModelPath -LmsPath ([string]$candidate.path)
    if ([string]::Equals($physicalPath, [string]$Profile.ModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      $matches += [pscustomobject]@{ LmsPath = [string]$candidate.path; PhysicalPath = $physicalPath }
    }
  }
  if ($matches.Count -ne 1) {
    throw "Expected exactly one downloaded LM Studio LLM at the known $($Profile.Name) path; found $($matches.Count)."
  }
  return [pscustomobject]@{
    Profile = $Profile
    PhysicalPath = $matches[0].PhysicalPath
    LmsPath = $matches[0].LmsPath
  }
}

function Get-PeeseaServerStatus {
  $status = Get-PeeseaLmsJson -Arguments @('server', 'status', '--json')
  if ($null -eq $status -or $status -is [array] -or $status -isnot [pscustomobject] -or
    $status.running -isnot [bool]) {
    throw 'LM Studio server status JSON did not contain a boolean running field.'
  }
  $port = 0
  if ($null -ne $status.port -and -not [int]::TryParse([string]$status.port, [ref]$port)) {
    throw 'LM Studio server status JSON contained an invalid port.'
  }
  return [pscustomobject]@{ Running = $status.running; Port = $port }
}

function Get-PeeseaServerListener {
  param([Parameter(Mandatory)][int]$Port)

  $appPath = Join-Path $env:LOCALAPPDATA 'Programs\LM Studio\LM Studio.exe'
  try {
    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
  } catch {
    if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound -and
      $_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,Get-NetTCPConnection*') {
      return @()
    }
    throw
  }
  foreach ($connection in $connections) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction Stop
    [pscustomobject]@{
      Exists = $true
      Port = [int]$connection.LocalPort
      LocalAddress = [string]$connection.LocalAddress
      ProcessId = [int]$connection.OwningProcess
      ProcessName = if ($process) { [string]$process.Name } else { '' }
      ProcessPath = if ($process) { [string]$process.ExecutablePath } else { '' }
      ExpectedProcessPath = $appPath
    }
  }
}

function Get-PeeseaLoadedModels {
  $models = @(Get-PeeseaLmsJson -Arguments @('ps', '--json'))
  foreach ($model in $models) {
    if ($model -isnot [pscustomobject] -or -not $model.identifier -or -not $model.path -or -not $model.type) {
      throw 'LM Studio loaded-model JSON contains a record without type, identifier, or path.'
    }
    [long]$context = 0
    if ($model.type -eq 'llm' -and
      (-not [long]::TryParse([string]$model.contextLength, [ref]$context) -or $context -le 0)) {
      throw "LM Studio did not report a valid context for loaded LLM $($model.identifier)."
    }
    $deviceIdentifier = $model.deviceIdentifier
    $rawPath = [string]$model.path
    $physicalPath = $rawPath
    if ($model.type -eq 'llm' -and [string]::IsNullOrEmpty([string]$deviceIdentifier)) {
      $physicalPath = ConvertTo-PeeseaPhysicalModelPath -LmsPath $rawPath
    }
    [pscustomobject]@{
      Type = [string]$model.type
      Identifier = [string]$model.identifier
      ModelKey = [string]$model.modelKey
      ModelPath = $physicalPath
      LmsPath = $rawPath
      DeviceIdentifier = $deviceIdentifier
      ContextLength = $context
      Status = [string]$model.status
      Queued = $model.queued
    }
  }
}

function Get-PeeseaCurrentUserSid {
  return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-PeeseaProcessRecords {
  return @(Get-CimInstance Win32_Process -ErrorAction Stop)
}

function Get-PeeseaProcessRecordById {
  param([Parameter(Mandatory)][int]$ProcessId)

  return Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-PeeseaProcessOwnerSid {
  param([Parameter(Mandatory)]$ProcessRecord)

  try {
    $owner = Invoke-CimMethod -InputObject $ProcessRecord -MethodName GetOwnerSid -ErrorAction Stop
    if ($owner.ReturnValue -eq 0) { return [string]$owner.Sid }
  } catch {
    return $null
  }
  return $null
}

function Get-PeeseaProcessObject {
  param([Parameter(Mandatory)][int]$ProcessId)

  return Get-Process -Id $ProcessId -ErrorAction Stop
}

function ConvertTo-PeeseaProcessCreationUtc {
  param([Parameter(Mandatory)]$CreationDate)

  if ($CreationDate -is [datetime]) {
    return $CreationDate.ToUniversalTime()
  }
  if ($CreationDate -is [string] -and -not [string]::IsNullOrWhiteSpace($CreationDate)) {
    return [Management.ManagementDateTimeConverter]::ToDateTime($CreationDate).ToUniversalTime()
  }
  throw 'Process creation timestamp is missing or has an unsupported type.'
}

function Test-PeeseaSameCreationTime {
  param(
    [Parameter(Mandatory)]$First,
    [Parameter(Mandatory)]$Second
  )

  try {
    $firstUtc = ConvertTo-PeeseaProcessCreationUtc -CreationDate $First
    $secondUtc = ConvertTo-PeeseaProcessCreationUtc -CreationDate $Second
    # Win32_Process DMTF timestamps have microsecond precision; allow only one
    # microsecond for conversion rounding, not a coarse process-start window.
    return [math]::Abs($firstUtc.Ticks - $secondUtc.Ticks) -le 10
  } catch {
    return $false
  }
}

function Test-PeeseaProcessObjectIdentity {
  param(
    [Parameter(Mandatory)]$ProcessRecord,
    [Parameter(Mandatory)]$ProcessObject
  )

  if ($ProcessObject.Id -ne $ProcessRecord.ProcessId -or
    $ProcessObject.ProcessName -ne [IO.Path]::GetFileNameWithoutExtension([string]$ProcessRecord.Name)) {
    return $false
  }
  try {
    return Test-PeeseaSameCreationTime -First $ProcessRecord.CreationDate -Second $ProcessObject.StartTime
  } catch {
    return $false
  }
}

function Test-PeeseaSameProcessRecord {
  param($Original, $Current)

  if ($null -eq $Original -or $null -eq $Current) { return $false }
  return $Original.ProcessId -eq $Current.ProcessId -and
    $Original.Name -ceq $Current.Name -and
    (Test-PeeseaSameCreationTime -First $Original.CreationDate -Second $Current.CreationDate)
}

function Close-PeeseaBrowserProcess {
  param([Parameter(Mandatory)]$ProcessObject)

  try {
    if ($ProcessObject.MainWindowHandle -eq 0 -or -not $ProcessObject.CloseMainWindow()) {
      return $false
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 5) {
      try {
        $ProcessObject.Refresh()
        if ($ProcessObject.HasExited) { return $true }
      } catch {
        return $true
      }
      Start-Sleep -Milliseconds 200
    }
    return $false
  } catch {
    return $false
  }
}

function Stop-PeeseaHelperProcess {
  param([Parameter(Mandatory)]$ProcessObject)

  try {
    if (-not $ProcessObject.HasExited) { $ProcessObject.Kill() }
    return $ProcessObject.WaitForExit(2000)
  } catch {
    return $false
  }
}

function Invoke-PeeseaProcessAction {
  param(
    [Parameter(Mandatory)]$ProcessRecord,
    [Parameter(Mandatory)][string]$CurrentSid,
    [Parameter(Mandatory)][ValidateSet('Browser', 'Helper')][string]$Action
  )

  $current = Get-PeeseaProcessRecordById -ProcessId ([int]$ProcessRecord.ProcessId)
  if (-not (Test-PeeseaSameProcessRecord -Original $ProcessRecord -Current $current)) {
    Write-Warning "Skipped process $($ProcessRecord.ProcessId): PID, name, or start identity changed before cleanup."
    return
  }
  if ((Get-PeeseaProcessOwnerSid -ProcessRecord $current) -ne $CurrentSid) {
    Write-Warning "Skipped process $($ProcessRecord.ProcessId): owner could not be verified as the current Windows user."
    return
  }
  try {
    $processObject = Get-PeeseaProcessObject -ProcessId ([int]$ProcessRecord.ProcessId)
  } catch {
    Write-Warning "Could not inspect approved process $($ProcessRecord.ProcessId): $($_.Exception.Message)"
    return
  }
  if (-not (Test-PeeseaProcessObjectIdentity -ProcessRecord $current -ProcessObject $processObject)) {
    Write-Warning "Skipped process $($ProcessRecord.ProcessId): process start identity could not be verified."
    return
  }

  if ($Action -eq 'Browser') {
    if (-not (Close-PeeseaBrowserProcess -ProcessObject $processObject)) {
      Write-Warning "Browser process $($ProcessRecord.Name) (PID $($ProcessRecord.ProcessId)) did not close gracefully; it was left running."
    }
  } elseif (-not (Stop-PeeseaHelperProcess -ProcessObject $processObject)) {
    Write-Warning "Approved background helper $($ProcessRecord.Name) (PID $($ProcessRecord.ProcessId)) could not be terminated."
  }
}

function Invoke-PeeseaCleanup {
  try {
    $sid = Get-PeeseaCurrentUserSid
  } catch {
    Write-Warning "Could not identify the current Windows user; cleanup was skipped: $($_.Exception.Message)"
    return
  }
  $browsers = @('firefox.exe', 'msedge.exe')
  $helpers = @(
    'XboxPcTray.exe', 'PhoneExperienceHost.exe', 'CrossDeviceResume.exe', 'NVIDIA Overlay.exe',
    'SteelSeriesGGEZ.exe', 'SteelSeriesSonar.exe', 'SteelSeriesEngine.exe', 'OneDrive.exe'
  )
  try {
    $browserSnapshot = @(Get-PeeseaProcessRecords)
  } catch {
    $browserSnapshot = @()
    Write-Warning "Could not inspect approved browser processes; they were not closed: $($_.Exception.Message)"
  }

  foreach ($name in $browsers) {
    $processes = @($browserSnapshot | Where-Object { $_.Name -ceq $name })
    foreach ($process in $processes) {
      try {
        $ownerSid = Get-PeeseaProcessOwnerSid -ProcessRecord $process
      } catch {
        $ownerSid = $null
      }
      if ($ownerSid -eq $sid) {
        try {
          Invoke-PeeseaProcessAction -ProcessRecord $process -CurrentSid $sid -Action Browser
        } catch {
          Write-Warning "Cleanup of approved browser process $($process.ProcessId) failed: $($_.Exception.Message)"
        }
      } elseif (-not $ownerSid) {
        Write-Warning "Skipped browser process $($process.ProcessId): process ownership could not be verified."
      }
    }
  }

  try {
    $helperSnapshot = @(Get-PeeseaProcessRecords)
  } catch {
    $helperSnapshot = @()
    Write-Warning "Could not inspect approved background helpers; they were left running: $($_.Exception.Message)"
  }
  foreach ($name in $helpers) {
    $processes = @($helperSnapshot | Where-Object { $_.Name -ceq $name })
    foreach ($process in $processes) {
      try {
        $ownerSid = Get-PeeseaProcessOwnerSid -ProcessRecord $process
      } catch {
        $ownerSid = $null
      }
      if ($ownerSid -eq $sid) {
        try {
          Invoke-PeeseaProcessAction -ProcessRecord $process -CurrentSid $sid -Action Helper
        } catch {
          Write-Warning "Cleanup of approved background helper $($process.ProcessId) failed: $($_.Exception.Message)"
        }
      } elseif (-not $ownerSid) {
        Write-Warning "Skipped background helper $($process.ProcessId): process ownership could not be verified."
      }
    }
  }
}

function Test-PeeseaSamePath {
  param([string]$First, [string]$Second)
  return [string]::Equals($First, $Second, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PeeseaServerIdentity {
  param(
    [Parameter(Mandatory)]$Status,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Listeners,
    [Parameter(Mandatory)]$Profile
  )

  if (-not $Status.Running -or $Status.Port -ne $Profile.Port) {
    throw "LM Studio server status does not identify a running server on port $($Profile.Port); refusing to stop or replace it."
  }
  if ($Listeners.Count -ne 1) {
    throw "Expected one verified LM Studio listener on port $($Profile.Port); found $($Listeners.Count)."
  }
  $listener = $Listeners[0]
  if ($listener.Port -ne $Profile.Port -or $listener.LocalAddress -ne $Profile.Bind -or
    $listener.ProcessName -ne 'LM Studio.exe' -or
    -not (Test-PeeseaSamePath $listener.ProcessPath $listener.ExpectedProcessPath)) {
    throw "Port $($Profile.Port) is not owned by the expected LM Studio instance bound to $($Profile.Bind); refusing to hijack it."
  }
}

function Ensure-PeeseaServer {
  param([Parameter(Mandatory)]$Profile)

  $status = Get-PeeseaServerStatus
  $listeners = @(Get-PeeseaServerListener -Port $Profile.Port)
  if ($status.Running) {
    Assert-PeeseaServerIdentity -Status $status -Listeners $listeners -Profile $Profile
    return
  }
  if ($listeners.Count -gt 0) {
    throw "Port $($Profile.Port) has a listener while LM Studio reports the server stopped; refusing to hijack it."
  }

  Invoke-PeeseaLmsChecked -Arguments @('server', 'start', '--bind', $Profile.Bind, '--port', [string]$Profile.Port) | Out-Null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $status = Get-PeeseaServerStatus
    $listeners = @(Get-PeeseaServerListener -Port $Profile.Port)
    if ($status.Running) {
      Assert-PeeseaServerIdentity -Status $status -Listeners $listeners -Profile $Profile
      return
    }
    if ($listeners.Count -gt 0) {
      throw "Port $($Profile.Port) acquired a listener, but LM Studio does not report it running; refusing to hijack it."
    }
    Start-Sleep -Milliseconds 500
  }
  throw "LM Studio server did not become ready on port $($Profile.Port) after start."
}

function Confirm-PeeseaServerReady {
  param([Parameter(Mandatory)]$Profile)

  $status = Get-PeeseaServerStatus
  $listeners = @(Get-PeeseaServerListener -Port $Profile.Port)
  Assert-PeeseaServerIdentity -Status $status -Listeners $listeners -Profile $Profile
}

function New-PeeseaResult {
  param([bool]$Ready, [int]$ExitCode, [string]$Message)
  return [pscustomobject]@{ Ready = $Ready; ExitCode = $ExitCode; Message = $Message }
}

function Invoke-PeeseaLmsChecked {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $result = Invoke-PeeseaLms -Arguments $Arguments
  if ($result.ExitCode -ne 0) {
    throw "lms $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.Output)"
  }
  return $result
}

function Get-PeeseaProfileForLoadedModel {
  param([Parameter(Mandatory)]$LoadedModel)

  if (-not [string]::IsNullOrEmpty([string]$LoadedModel.DeviceIdentifier)) {
    return $null
  }
  foreach ($name in @('Coder', 'Qwen27B')) {
    $knownProfile = Get-PeeseaProfile -Model $name
    if (Test-PeeseaSamePath $LoadedModel.ModelPath $knownProfile.ModelPath) {
      return $knownProfile
    }
  }
  return $null
}

function Assert-PeeseaUniqueLoadedIdentifiers {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LoadedModels)

  $duplicates = @($LoadedModels | Group-Object -Property Identifier | Where-Object {
      $_.Name -and $_.Count -gt 1
    })
  if ($duplicates.Count -gt 0) {
    throw "Loaded model identity is ambiguous for identifier '$($duplicates[0].Name)'; refusing to unload or load."
  }
}

function Invoke-PeeseaInference {
  param(
    [ValidateSet('Coder', 'Qwen27B')]
    [string]$Model = 'Coder'
  )

  $launchLock = $null
  try {
    $launchLock = Enter-PeeseaLaunchLock
  } catch {
    return New-PeeseaResult -Ready $false -ExitCode 1 -Message "Could not acquire the launch lock: $($_.Exception.Message)"
  }

  if ($null -eq $launchLock) {
    return New-PeeseaResult -Ready $false -ExitCode 1 -Message 'Another Peesea inference launcher is already running; no action was taken.'
  }

  try {
    Invoke-PeeseaCleanup
    $profile = Get-PeeseaProfile -Model $Model
    $target = Resolve-PeeseaTarget -Profile $profile
    Ensure-PeeseaServer -Profile $profile

    $loaded = @(Get-PeeseaLoadedModels)
    Assert-PeeseaUniqueLoadedIdentifiers -LoadedModels $loaded
    $loadedLlms = @($loaded | Where-Object { $_.Type -eq 'llm' })
    $knownLoaded = @()
    foreach ($loadedLlm in $loadedLlms) {
      $knownProfile = Get-PeeseaProfileForLoadedModel -LoadedModel $loadedLlm
      if ($null -eq $knownProfile) {
        throw "Loaded LLM '$($loadedLlm.Identifier)' has an unknown physical model path; refusing to unload or load."
      }
      $knownLoaded += [pscustomobject]@{ Profile = $knownProfile; Model = $loadedLlm }
    }

    $targetModels = @($knownLoaded | Where-Object { $_.Profile.Name -eq $profile.Name })
    if ($targetModels.Count -gt 1) {
      throw "More than one loaded instance matches the known $($profile.Name) model; refusing to guess."
    }
    $targetCompatible = $targetModels.Count -eq 1 -and
      $targetModels[0].Model.Identifier -eq $profile.Identifier -and
      $targetModels[0].Model.ContextLength -ge $profile.MinimumContext
    $reused = $targetCompatible

    $toUnload = @($knownLoaded | Where-Object {
        $_.Profile.Name -ne $profile.Name -or -not $targetCompatible
      })
    foreach ($entry in $toUnload) {
      Write-Warning 'Switching/reloading a known model may interrupt its active prediction; LM Studio does not expose a reliable active-prediction count.'
      Invoke-PeeseaLmsChecked -Arguments @('unload', $entry.Model.Identifier) | Out-Null
    }

    if ($toUnload.Count -gt 0) {
      $remaining = @(Get-PeeseaLoadedModels)
      Assert-PeeseaUniqueLoadedIdentifiers -LoadedModels $remaining
      foreach ($entry in $toUnload) {
        if (@($remaining | Where-Object { $_.Identifier -eq $entry.Model.Identifier }).Count -gt 0) {
          throw "LM Studio still reports known model '$($entry.Model.Identifier)' after unload; refusing to continue."
        }
      }
      $loaded = $remaining
    }

    if (-not $targetCompatible) {
      $loadArguments = @(
        'load', $target.LmsPath, '--exact', '--context-length', [string]$profile.MinimumContext,
        '--gpu', 'max', '--identifier', $profile.Identifier
      )
      Invoke-PeeseaLmsChecked -Arguments $loadArguments | Out-Null
    }

    $verifiedLoaded = @(Get-PeeseaLoadedModels)
    Assert-PeeseaUniqueLoadedIdentifiers -LoadedModels $verifiedLoaded
    $verifiedTarget = @($verifiedLoaded | Where-Object {
        $_.Type -eq 'llm' -and (Test-PeeseaSamePath $_.ModelPath $target.PhysicalPath) -and
        $_.Identifier -eq $profile.Identifier -and $_.ContextLength -ge $profile.MinimumContext
      })
    if ($verifiedTarget.Count -ne 1) {
      throw "LM Studio did not verify exactly one loaded $($profile.Name) model with identifier $($profile.Identifier) and context at least $($profile.MinimumContext)."
    }
    $otherLlms = @($verifiedLoaded | Where-Object {
        $_.Type -eq 'llm' -and -not (Test-PeeseaSamePath $_.ModelPath $target.PhysicalPath)
      })
    if ($otherLlms.Count -gt 0) {
      throw 'An unexpected LLM appeared during launch; refusing to report Ready.'
    }
    Confirm-PeeseaServerReady -Profile $profile
    $action = if ($reused) { 'reused' } else { 'loaded' }
    return New-PeeseaResult -Ready $true -ExitCode 0 -Message "Ready: $action $($profile.Name) ($($profile.Identifier)), context $($verifiedTarget[0].ContextLength), server port $($profile.Port)."
  } catch {
    return New-PeeseaResult -Ready $false -ExitCode 1 -Message "Inference launcher failed: $($_.Exception.Message)"
  } finally {
    try {
      Exit-PeeseaLaunchLock -Lock $launchLock
    } catch {
      Write-Warning "Could not release the inference launch lock: $($_.Exception.Message)"
    }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  $result = Invoke-PeeseaInference -Model $Model
  if ($result.Message) { Write-Host $result.Message }
  exit $result.ExitCode
}

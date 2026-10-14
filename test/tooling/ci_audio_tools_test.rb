require 'json'
require 'open3'
require 'tempfile'
require 'yaml'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
workflow = YAML.safe_load(File.read(File.join(root, '.github/workflows/tests.yml')))
steps = workflow.fetch('jobs').fetch('test').fetch('steps')
step = steps.find { |item| item['name'] == 'Install audio validation tools' }
assert_equal("matrix.suite == 'tooling'", step.fetch('if'))
assert(steps.index(step) < steps.index { |item| item['name'] == 'Run tests' })

# Execute the actual CI step in isolated PowerShell processes. The doubles
# never install software, sleep, modify PATH or access the network.
prefix = <<~'POWERSHELL'
  param([string]$Mode)
  $ErrorActionPreference = 'Stop'
  $WarningPreference = 'SilentlyContinue'
  $global:ciAudioMode = $Mode
  $global:ciAudioAvailable = $Mode -in @('installed', 'broken')
  $global:ciAudioAttempts = 0
  $global:ciAudioSleeps = @()
  $global:ciAudioProbes = @()
  function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($global:ciAudioAvailable) { [pscustomobject]@{Name=$Name} }
  }
  function choco {
    $global:ciAudioAttempts++
    $global:ciAudioAvailable = $global:ciAudioMode -ne 'unavailable' -and $global:ciAudioAttempts -ge 2
    $global:LASTEXITCODE = if ($global:ciAudioMode -eq 'empty_success' -or $global:ciAudioAvailable) { 0 } else { 1 }
    if ($global:ciAudioMode -eq 'exception' -and -not $global:ciAudioAvailable) { throw 'Simulated download failure' }
  }
  function Start-Sleep { param($Seconds); $global:ciAudioSleeps += $Seconds }
  function ffmpeg { $global:ciAudioProbes += 'ffmpeg'; $global:LASTEXITCODE = 0 }
  function ffprobe {
    $global:ciAudioProbes += 'ffprobe'
    $global:LASTEXITCODE = if ($global:ciAudioMode -eq 'broken') { 1 } else { 0 }
  }
  $failed = $false
  try {
POWERSHELL
suffix = <<~'POWERSHELL'
  } catch { $failed = $true }
  @{attempts=$global:ciAudioAttempts; sleeps=@($global:ciAudioSleeps);
    probes=@($global:ciAudioProbes); failed=$failed} | ConvertTo-Json -Compress
POWERSHELL

cases = {
  'installed' => [0, [], false],
  'retry' => [2, [10], false],
  'empty_success' => [2, [10], false],
  'exception' => [2, [10], false],
  'unavailable' => [3, [10, 20], true],
  'broken' => [0, [], true]
}
Tempfile.create(['ci-audio-', '.ps1']) do |file|
  file.write(prefix + step.fetch('run') + "\n" + suffix)
  file.close
  cases.each do |mode, (attempts, sleeps, failed)|
    output, error, status = Open3.capture3('pwsh', '-NoProfile', '-NonInteractive', '-File', file.path, mode)
    assert(status.success?, "PowerShell fixture failed: #{error}")
    result = JSON.parse(output)
    assert_equal(attempts, result.fetch('attempts'), mode)
    assert_equal(sleeps, result.fetch('sleeps'), mode)
    assert_equal(failed, result.fetch('failed'), mode)
    assert_equal(mode == 'unavailable' ? [] : %w[ffmpeg ffprobe], result.fetch('probes'), mode)
  end
end
puts 'PASS CI audio tools: existing install, bounded retry, false success, exception, persistent failure and broken executable'

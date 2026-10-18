require 'yaml'
require 'json'
require 'open3'
require 'tempfile'
require 'rbconfig'
require_relative '../support/assertions'
include GameRoomTest::Assertions

root = File.expand_path('../..', __dir__)
workflow = YAML.safe_load(File.read(File.join(root, '.github/workflows/tests.yml')))
steps = workflow.fetch('jobs').fetch('test').fetch('steps')
step = steps.find { |item| item['name'] == 'Check generated runtime sources' }
assert(step, 'The CI generated-source gate is missing')

# Execute the actual workflow body, not the generators. A local child Ruby
# process supplies each exit status, as a native checker does in PowerShell.
# No generated file, installed tool, network resource or package is touched.
prefix = <<~POWERSHELL
  param([int]$FirstCode, [int]$SecondCode)
  $ErrorActionPreference = 'Stop'
  $global:generatorCodes = @($FirstCode, $SecondCode)
  $global:generatorCalls = 0
  function ruby {
    $index = $global:generatorCalls
    $global:generatorCalls++
    Write-Output ('CHECKER ' + $index)
    & '#{RbConfig.ruby.gsub("'", "''")}' -e 'exit Integer(ARGV.fetch(0))' $global:generatorCodes[$index]
    $global:LASTEXITCODE = $LASTEXITCODE
  }
POWERSHELL
suffix = <<~POWERSHELL
  # GitHub's pwsh step wrapper propagates the last native exit status.
  if (Test-Path -LiteralPath variable:\\LASTEXITCODE) { exit $LASTEXITCODE }
POWERSHELL

Tempfile.create(['ci-generated-', '.ps1']) do |file|
  file.write(prefix + step.fetch('run') + "\n" + suffix)
  file.close
  [[17, 0, 17, 1], [0, 23, 23, 2], [0, 0, 0, 2]].each do |first, second, expected, count|
    output, error, status = Open3.capture3('pwsh', '-NoProfile', '-NonInteractive', '-File', file.path, first.to_s, second.to_s)
    assert_equal(expected, status.exitstatus,
      "Generated-source checker failure was masked: #{[first, second].inspect}; #{output}; #{error}")
    assert_equal(count, output.scan(/^CHECKER /).size, 'Checks continued after an earlier failed generator')
  end
end
puts 'PASS CI generator gate: first failure, second failure and success retain native status without generating files'

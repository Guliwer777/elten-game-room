require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative '../../support/assertions'
require_relative '../../../tools/spades'
include GameRoomTest::Assertions

script = File.expand_path('../../../tools/spades.rb', __dir__)
Dir.mktmpdir('spades-default-profiles-') do |folder|
  profile = SpadesLearning::ARRANGEMENT_PROFILES.keys.first
  trained = File.join(folder, 'training.json')
  output, status = Open3.capture2e(RbConfig.ruby, script, 'train', '--profiles', profile,
    '--score-limits', '100', '--max-series', '1', '--generations', '1', '--population', '1',
    '--evaluation-seeds', '1', '--validation-seeds', '1', '--holdout-seeds', '1',
    '--training-max-actions', '1', '--validation-max-actions', '1', '--output', trained)
  assert_equal(2, status.exitstatus, "bounded producer failed: #{output}")
  original = File.binread(trained)
  campaign = JSON.parse(original)
  selected = campaign.fetch('selected_profiles')
  expected = selected.keys - SpadesLearning::PROFILE_KEYS
  assert(expected.length > 1, 'producer did not exercise inherited arrangement profiles')

  arguments = ['evaluate', '--report', trained, '--score-limits', '100', '--seeds', '1',
    '--max-actions', '1', '--skip-calibration']
  output, error, status = Open3.capture3(RbConfig.ruby, script, *arguments)
  assert_equal(2, status.exitstatus, "default evaluation rejected its own report: #{error}")
  records = JSON.parse(output).fetch('arrangements')
  assert_equal(expected, records.map { |entry| entry.fetch('arrangement') })
  records.each do |record|
    assert_equal(1, record.fetch('average_actions'), 'default evaluation ignored its budget')
    assert(record.fetch('incomplete_games').positive?, 'truncated evaluation claimed completion')
    assert(record['candidate_calibration'].nil?, 'disabled calibration ran')
  end

  output, error, status = Open3.capture3(RbConfig.ruby, script, *arguments, '--profiles', profile)
  assert_equal(2, status.exitstatus, "explicit arrangement rejected: #{error}")
  assert_equal([profile], JSON.parse(output).fetch('arrangements').map { |entry| entry.fetch('arrangement') })
  assert_equal(original, File.binread(trained), 'evaluation changed the supplied report')
  assert_equal(SpadesLearning::PolicySet.default.to_h, selected, 'bounded rejected training changed weights')

  [SpadesLearning::PROFILE_KEYS.first, 'missing'].each do |invalid|
    output, status = Open3.capture2e(RbConfig.ruby, script, *arguments, '--profiles', invalid)
    assert_equal(1, status.exitstatus, 'explicit non-arrangement was accepted')
    assert(output.include?("Unknown arrangements: #{invalid}"), 'explicit refusal lost its explanation')
  end

  unknown = File.join(folder, 'unknown.json')
  campaign.fetch('selected_profiles')['missing'] = selected.fetch(profile)
  File.write(unknown, JSON.generate(campaign))
  unknown_arguments = arguments.dup
  unknown_arguments[2] = unknown
  output, status = Open3.capture2e(RbConfig.ruby, script, *unknown_arguments)
  assert_equal(1, status.exitstatus, 'default selection silently ignored an unknown report profile')
  assert(output.include?('Unknown arrangements: missing'), 'unknown report arrangement was not identified')
end
puts 'PASS Spades report defaults: real train/evaluate, inherited arrangements, explicit selection, unknown rejection and unchanged weights'

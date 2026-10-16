require_relative '../run'
require 'tmpdir'

Dir.mktmpdir('score-direction-') do |scratch|
  result = GameRoomTestRunner.run([
    {script: 'test/tournaments/individual_score_policy_test.rb', args: %w[--lower --check-ui]}
  ], report: File.join(scratch, 'results.json'))
  raise "Score direction UI failed: #{scratch}" unless GameRoomTestRunner.success?(result)
end
puts 'PASS current small-score fixture and native standings: Polish/English, source/binary'

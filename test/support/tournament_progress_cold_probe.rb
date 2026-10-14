require_relative 'tournament_ft2b1_execution'
include GameRoomTest::Assertions
module Session
  def self.name; 'RealAuthenticatedUser'; end
end unless defined?(Session)
data = JSON.parse(File.read(ARGV.fetch(0)))
fixture = {program: TournamentEntryContextTest::Program.new(data['directory']), record: data['record'],
  sandbox: data['sandbox'], plans: data['plans'], now: data['now']}
path = File.join(fixture[:plans], 'fixed-teams-v1/execution-ft2-v1/state.json')
before = File.binread(path)
F = TournamentFT2B1
F.with_execution(fixture, 'Beata') do |execution|
  F.select_execution(execution, fixture[:record], 0, history: true)
  progress = execution.progress
  assert_equal('playing', progress['recommendation']['stage'])
  game = execution.local_game(action: :local_game_status)
  assert_equal(1, game[:status]['event_count'])
  assert_equal('bidding', game[:status]['phase'])
  assert(game[:status]['current_player'], 'Missing restored turn')
  assert_equal([], game[:status]['actions']) unless game[:status]['current_player'] == 'Beata'
end
assert_equal(before, File.binread(path))
puts 'PASS cold tournament progress and original native game without new writes'

require_relative '../support/tournament_realtime_team_play'
require_relative '../support/tournament_declared_team_execution'
require 'open3'
require 'rbconfig'
include TournamentRealtimeTeamPlay
future = ARGV.include?('--future')
game_id = future ? 'future_realtime_team' : 'axel_pong'
registry = future ? GameRoomGames::Registry.new([Class.new(GameRoomGames::AxelPong) do
  def id; 'future_realtime_team'; end
end]) : GameRoomGames::CATALOG
with_fixture(game: game_id, registry: registry, names: %w[Alice Bob Carol Dave], players_per_match: 4,
  rematch: false, game_options: {'team_size' => 2, 'target' => 7}) do |fixture|
  record = nil
  with_declared_team_backend(fixture, 'Organizator') do |backend, _authority, _directory|
    record = backend.accept(preview: backend.preview_pairs(publication_ref: fixture.reference,
      pairs: [%w[alice bob], %w[carol dave]], team_template: [0, 1, 0, 1], intent_id: 'realtime-teams'))
  end
  assert_equal(T::GameResult::CURRENT_RESULT_POLICY, record['evidence']['source']['result_policy'])
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
  owner = people.first
  with_declared_team_dispatch(fixture, record, 'Organizator') { |dispatcher| dispatcher.configure(intent_id: 'realtime-teams', max_tables: 1) }
  people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.available(intent_id: 'realtime-teams', available: true) } }
  2.times { people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.advance(intent_id: 'realtime-teams') } } }
  people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| assert_equal(:confirmed, dispatcher.accept(intent_id: 'realtime-teams')[:state]) } }
  people.each { |actor| with_declared_team_dispatch(fixture, record, actor) { |dispatcher| dispatcher.advance(intent_id: 'realtime-teams') } }
  resume = ARGV.include?('--resume')
  checkpoint = lambda do
    output, error, process = Open3.capture3(RbConfig.ruby, File.expand_path('../support/tournament_realtime_team_probe.rb', __dir__), fixture.directory, game_id, 'running')
    assert(process.success?, "Independent unfinished team archive failed: #{output}\n#{error}")
    puts output
  end
  result = play_realtime_team_match(fixture, record, resume_after: resume ? 3 : nil, checkpoint: checkpoint)
  assert_equal([2, 0], result[:status]['standings'].map { |row| row['points'] }.sort.reverse)
  assert_equal(2, result[:status]['standings'].size, 'Tournament points belong to full teams, once per team')
  path = File.join(fixture.directory, 'team-plans/fixed-teams-v1/execution-ft2-v1/state.json')
  assert_equal({}, JSON.parse(File.binread(path))['busy'])
  output, error, process = Open3.capture3(RbConfig.ruby, File.expand_path('../support/tournament_realtime_team_probe.rb', __dir__), fixture.directory, game_id)
  assert(process.success?, "Independent team archive failed: #{output}\n#{error}")
  puts output
end
puts 'PASS realtime full teams: automatic invitations, four explicit admissions, one Start, four genuine clients, seven agreed points, team small scores once, 2/0, busy release and independent archive'

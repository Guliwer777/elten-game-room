# encoding: UTF-8
require_relative '../support/tournament_moves_fixture'
$stdout.sync = true
include GameRoomTest::Assertions
F = TournamentFT2B1
module Session
  def self.name; 'RealAuthenticatedUser'; end
end unless defined?(Session)
fixture = if ARGV.include?('--resume-release-probe')
  data = JSON.parse(File.read(File.expand_path('../../tmp/result-fixture.json', __dir__)))
  {program: TournamentEntryContextTest::Program.new(data['directory']), record: data['record'],
    sandbox: data['sandbox'], plans: data['plans'], now: data['now']}
else
  TournamentMovesFixture.build(game_options: {'score_limit' => 1})
end
contexts = {}
walk = lambda do |names, &body|
  if names.empty?
    body.call
  else
    name = names.first
    F.with_execution(fixture, name) do |execution|
      F.select_execution(execution, fixture[:record])
      contexts[name] = execution
      walk.call(names.drop(1), &body)
    end
  end
end
walk.call(%w[Ala Anna Bartek Beata]) do
  owner = contexts.fetch('Ala')
  view = owner.local_game(action: :local_game_status)[:status]
  assert_equal(:game_not_finished, owner.local_game(action: :finalize_local_game, revision: view['revision'])[:reason])
  finished = false
  60.times do |index|
    view = owner.local_game(action: :local_game_status).fetch(:status)
    if view['finished']
      finished = true
      break
    end
    name = view['current_player'] || view['players'].first
    executor = contexts.fetch(name)
    own = executor.local_game(action: :local_game_status).fetch(:status)
    selection = own['actions'].find { |a| a['action'] == 'bid_3' } || own['actions'].first
    raise "No action for #{name}: #{own.inspect}" unless selection
    result = executor.local_game(action: :local_game_move, operation_id: "result-move-#{index}",
      revision: own['revision'], move_selection: selection)
    assert_equal(:confirmed, result[:state])
    puts "Recorded #{index + 1} moves" if index % 10 == 0
  end
  assert_equal(true, finished)
  assert_equal(57, view['event_count'])
  assert_equal(:not_coordinator, contexts['Beata'].local_game(action: :finalize_local_game, revision: view['revision'])[:reason])
  assert_equal(:stale_view, owner.local_game(action: :finalize_local_game, revision: 'old')[:reason])
  fault = Module.new do
    def write(document, receipt: nil)
      value = super
      if $result_lost && receipt && receipt['kind'] == 'result'
        $result_lost = false
        raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-result', receipt: receipt)
      end
      value
    end
  end
  F::T::LocalFixedTeamExecutionStorage.prepend(fault)
  $result_lost = true
  uncertain = owner.local_game(action: :finalize_local_game, revision: view['revision'])
  assert_equal(:uncertain, uncertain[:state])
  recovered = owner.local_game(action: :local_game_status)
  assert_equal(uncertain[:receipt], recovered[:status]['result'])
  saved = owner.local_game(action: :finalize_local_game, revision: view['revision'])
  assert_equal(:confirmed, saved[:state])
  again = owner.local_game(action: :finalize_local_game, revision: view['revision'])
  assert_equal(saved[:effect], again[:effect])
  assert_equal(1, again[:status]['results'].size)
  assert_equal([0, 1, 1], again[:status]['standings'].map { |r| r['played'] }.sort)
  assert_equal(1, again[:status]['standings'].sum { |r| r['wins'] })
  assert_equal(1, again[:status]['standings'].sum { |r| r['losses'] })
  assert_equal([], again[:status]['actions'])
  assert_equal(:game_finalized, contexts['Beata'].local_game(action: :local_game_move,
    operation_id: 'late', revision: view['revision'], move_selection: {'kind' => 'command', 'action' => 'deal'})[:reason])
end unless ARGV.include?('--resume-release-probe')
F.with_execution(fixture, 'Ala') do |execution|
  F.select_execution(execution, fixture[:record], 0, history: true)
  assert_equal(1, execution.local_game(action: :local_game_status)[:status]['results'].size)
end
matches = fixture[:record]['evidence']['plan']['matches']
next_index = matches.index { |m| m['leg'] == 2 && m['players'].map { |p| p['account'] }.sort == matches.first['players'].map { |p| p['account'] }.sort }
raise 'Missing rematch' unless next_index
deadline = matches[next_index]['windows'].first['closes'] - 60
%w[Ala Anna Bartek Beata].each do |actor|
  F.with_execution(fixture, actor) do |execution|
    F.select_execution(execution, fixture[:record], next_index)
    readiness = execution.declare(availability: 'ready', expected_revision: 0)
    assert_equal(:confirmed, readiness[:state]) unless ARGV.include?('--resume-release-probe')
  end
end
F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
  F.select_execution(execution, fixture[:record], next_index)
  assert_equal(:bound, execution.request_match[:state])
end
F.with_execution(fixture, 'Ala') do |execution|
  F.select_execution(execution, fixture[:record], 0, history: true)
  old = execution.local_game(action: :local_game_status)[:status]
  assert_equal(:confirmed, execution.local_game(action: :finalize_local_game, revision: old['revision'])[:state])
end
F.with_execution(fixture, 'Ala', expires_at: deadline) do |execution|
  F.select_execution(execution, fixture[:record], next_index)
  assert_equal(:bound, execution.request_match[:state])
end
File.write(File.expand_path('../../tmp/result-fixture.json', __dir__), JSON.generate({
  'directory' => fixture[:program].data_path, 'sandbox' => fixture[:sandbox], 'plans' => fixture[:plans],
  'record' => fixture[:record], 'now' => fixture[:now]}))
puts(ARGV.include?('--resume-release-probe') ? 'PASS resumed release probe: rematch binding and old result cannot release new players' :
  'PASS finished native game, result authority, lost response, stale view, idempotence, standings, cold archive and rematch release guard')

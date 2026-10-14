if ARGV.first
  previous = ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS'] = previous
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/operations_screen'
include GameRoomTest::Assertions
I = TournamentIndividualUI
F = I::F
GameRoomLocalization.boot(settings: {'interface_language' => 'pl', 'known_languages' => ['pl']})
L = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
fixture = I.fixture
fixture[:program].define_singleton_method(:ordinary_tournament_results) do |_publication|
  {'results'=>[{'match_id'=>'a'*64,'leg'=>1,'summary'=>{'draw'=>false,'winners'=>['guliwer'],'participants'=>%w[Żółw guliwer],'scores'=>{'Żółw'=>4,'guliwer'=>7}}}], 'standings'=>[]}
end
label = GameRoomTournaments::OperationsScreen.allocate.send(:label,
  {'kind' => 'plan_document', 'status' => 'attempted', 'values' => {'tournament_id' => 7}})
assert_equal((L.call('Server match plan: tournament %{id}') % {id: 7}) + '; ' + L.call('attempted; not confirmed'), label)
workspace = Object.new
workspace.define_singleton_method(:actor) { F::OWNER }
calls = 0
workspace.define_singleton_method(:shared_schedule) do |publication_ref:, context:, lease:|
  raise 'Stale context' unless context.current?(lease)
  calls += 1
  next nil if calls > 1
  {'storage' => 'confirmed', 'candidate' => {'groups' => [{'id' => 'group-1', 'units' => %w[Żółw guliwer], 'matches' => ['a'*64]}],
    'matches' => [{'match_id' => 'a'*64, 'leg' => 1, 'players' => %w[Żółw guliwer]},
      {'match_id' => 'b'*64, 'leg' => 2, 'players' => %w[Żółw guliwer]}]}}
end
owner = GameRoomTournaments::LocalTestDialogs::Owner.new(-> { F::OWNER }, ->(message) { raise message })
driver = TournamentNativeDriver.new
driver.step(L.call('Matches, groups and standings'), [13]) do |form|
  assert(form.fields.first.text.include?(L.call('Match plan read from the server. Select your match to create or join its ordinary table. Results are saved automatically for supported individual and team matches.')), 'Missing shared plan explanation')
  assert(form.fields.first.text.include?('Żółw — guliwer'), 'Names missing')
  assert(form.fields.first.text.include?(L.call('Winner: %{players}')%{players:'guliwer'}),'Winner missing')
  assert(form.fields.first.text.include?('Żółw: 4; guliwer: 7'),'Numeric score missing')
  assert(form.fields.first.text.include?(L.call('Match %{number}, return match: %{players}') % {number: 2, players: 'guliwer — Żółw'}), 'Return leg missing')
  assert(!form.fields.first.text.include?('a'*64), 'Digest leaked as a player-facing match label')
  assert_equal([L.call('Refresh'), L.call('Back')], form.fields.grep(Button).map(&:label))
  form.index = form.fields.index(F.button(form, L.call('Refresh')))
end
driver.step(L.call('Matches, groups and standings'), [27]) do |form|
  assert(!form.fields.first.text.include?('Żółw'), 'Failed refresh left an old plan visible')
end
begin
  GameRoomTournaments::ServerScheduleOverview.new(program: fixture[:program], workspace: workspace, owner: owner,
    publication: {'title' => 'Podgląd wspólnego planu', '__insertion_user' => F::OWNER, 'publication_key' => 'test-plan'}).run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native Polish shared plan: names, groups, return leg, read-only controls, failed-refresh clearing and closed resources'

%w[en pl cs es ru].each do |language|
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  summary={'draw'=>false,'winners'=>['red'],'participants'=>%w[blue red],'scores'=>{'red'=>12,'blue'=>4}}
  label=GameRoomTournaments::ServerScheduleOverview.allocate.send(:result_label,summary,{'red'=>'Alice + Bob','blue'=>'Carol + Dave'})
  assert(label.include?('Alice + Bob: 12') && label.include?('Carol + Dave: 4'),'Team small scores missing names')
  assert(!label.include?('red') && !label.include?('blue'),'Internal team ID leaked into result')
end
puts 'PASS EN/PL/CS/ES/RU shared team result presentation'

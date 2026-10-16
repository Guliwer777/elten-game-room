# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/local_readiness_session'
require_relative '../../lib/tournaments/coordination_request'
file = File.expand_path('../../lib/tournaments/local_fixed_team_plan_backend.rb', __dir__)
require file if File.file?(file)
include TournamentFixedTeamsSupport
context, service, reference = fixture
assert(T.const_defined?(:LocalFixedTeamPlanBackend), 'RED_FT1: brak atomowego trwałego producenta membership i planu')
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
first = source['candidate']['matches'].select { |match| match['leg'] == 1 }
base_rows = [%w[beata anna bartek ala], %w[ala cezary anna celina], %w[celina beata cezary bartek]]
base = first.zip(base_rows).to_h { |match, accounts| [match['match_id'], accounts] }
expected_rows = base_rows + [%w[anna beata ala bartek], %w[cezary ala celina anna], %w[beata celina bartek cezary]]
directory = File.join(context.directory, 'plany')
identity = T::LocalFixedTeamPlanBackend.identity(directory: directory, source_identity: context.provider.backend_identity)
program = TournamentEntryContextTest::Program.new(directory)
session = T::LocalReadinessSession.new
session.choose_actor('Organizator')
session.bind_backend(identity)
reader = -> { 'WlascicielPlikow' }
entry = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader, account_events: session.actor_events)
authority = session.context(program: program, owner_reader: reader, entry: entry, lease: entry.capture, actor: 'Organizator', identity: identity)
build = -> { T::LocalFixedTeamPlanBackend.new(directory: directory, tables: context.provider, journal: context.journal,
  actor: 'Organizator', registry: REGISTRY, clock: -> { context.now }, context: authority) }
begin
  backend = build.call
  shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: base, intent_id: 'pierwszy')
  record = backend.accept(preview: shown)
  path = File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')
  bytes = File.binread(path)
  assert_equal(record, build.call.readback(intent_id: 'pierwszy'), 'Nowa instancja odczytuje cały rekord')
  assert_equal(record, build.call.current(intent_id: 'pierwszy'), 'Current nie obraca miejsc ponownie')
  assert_equal(record, build.call.accept(preview: shown), 'Retry odzyskuje oryginalne ID')
  assert_equal(bytes, File.binread(path), 'Odczyty i retry bez przepisywania pliku')
  document = JSON.parse(bytes)
  assert_equal(1, document['records'].size)
  assert_equal(membership, record['preview']['membership'], 'Membership utrwalone w tym samym zapisie co plan')
  evidence = record['evidence']
  assert_equal(2, evidence['version'])
  assert_equal(expected_rows, evidence['plan']['matches'].map { |match| match['players'].map { |person| person['account'] } })
  all = evidence['plan']['matches'].map do |match|
    assert_equal([0, 1, 2, 3], match['players'].map { |person| person['seat'] })
    assert_equal(%w[seat:0 seat:1 seat:2 seat:3], match['players'].map { |person| person['game_role'] })
    match['windows'].map do |window|
      request = T::CoordinationRequest.from_execution_plan(evidence: evidence, expected_source: record['expected_source'],
        match_id: match['match_id'], leg: match['leg'], window_id: window['id'], registry: REGISTRY)
      assert_equal(source['candidate']['game_options'].merge('team_seats' => TEMPLATE), request.to_h['options'])
      assert(!request.to_h['options'].key?('team_players'), 'Natywne metadata poza publicznym requestem')
      {'request' => request.to_h, 'digest' => request.digest}
    end
  end
  alias_shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: base, intent_id: 'alias')
  assert_equal(record, backend.accept(preview: alias_shown))
  assert_equal(record, build.call.readback(intent_id: 'alias'))
  changed = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE,
    base_seats: base.transform_values(&:reverse), intent_id: 'inna-obsada')
  before_conflict = File.binread(path)
  error = assert_raises(T::Publication::Invalid) { backend.accept(preview: changed) }
  assert_equal(:source_conflict, error.code)
  assert_equal(before_conflict, File.binread(path))
  oracle_file('oracle.json', {'source' => source, 'base' => base, 'expected_rows' => expected_rows, 'record' => record, 'requests' => all,
    'document' => JSON.parse(File.binread(path)), 'conflict' => error.code})
ensure
  authority.close
  entry.close
  session.close
  program.finalize
  program.class.app_runtime.close
end
puts 'FT1: trwały plan, pełne miejsca, rzeczywiste requesty, alias i konflikt — OK'

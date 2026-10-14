# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
all = []
[32, 33, 64].each do |size|
  raw = 'İ' * size
  names = [raw] + NAMES.drop(1)
  context, service, reference = fixture(names: size == 32 ? names : NAMES.drop(1), pairing: 'balanced_cycle')
  if size > 32
    # Granica readonly journal jest już obecna w bazie; test źródła używa legalnych tabel.
    row = service.list['announcements'].first
    context.actor, context.insert_time = raw, 150
    context.provider.insert_row(TournamentPublicServiceSupport::REG,
      T::RegistrationProjection.join_values(tournament_id: row['__id'], operation_key: "unicode-#{size}"))
    context.actor = 'Organizator'
  end
  members = membership
  members['units'][0]['accounts'][0] = raw.downcase
  context.reads.clear
  source = service.fixed_team_execution_source(publication_ref: reference, membership: members, team_template: TEMPLATE)
  assert_equal(%w[tournament_announcements tournament_registrations], context.reads)
  candidate = source['candidate']
  assert_equal('balanced_cycle', candidate['pairing'])
  expected_pairs = [[%w[unit-A unit-B], 1], [%w[unit-A unit-C], 1], [%w[unit-B unit-C], 1],
    [%w[unit-A unit-B], 2], [%w[unit-A unit-C], 2], [%w[unit-B unit-C], 2]]
  assert_equal(expected_pairs, candidate['matches'].map { |match| match.values_at('unit_ids', 'leg') })
  assert_equal(raw, source['projection']['members'].find { |person| person['account'] == raw.downcase }['username'])
  base = bases(source).transform_values { |row| row.map { |account| account == 'ala' ? raw.downcase : account } }
  with_backend(context) do |backend|
    shown = backend.preview(publication_ref: reference, membership: members, team_template: TEMPLATE, base_seats: base, intent_id: 'unicode')
    record = backend.accept(preview: shown)
    record['evidence']['plan']['matches'].each do |match|
      person = match['players'].find { |entry| entry['account'] == raw.downcase }
      assert_equal(raw, person['username']) if person
    end
    all << {'raw' => raw, 'source' => source, 'record' => record}
  end
end
context, service, reference = fixture
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, _, _, _, directory|
  initial = bases(source)
  bad_bases = [nil, {}, initial.merge('obcy-mecz' => NAMES.first(4).map(&:downcase)), initial.reject { |key, _| key == initial.keys.first },
    initial.transform_values { |row| row.take(3) }, initial.transform_values { |row| [row[0], row[0], row[2], row[3]] },
    initial.transform_values { |row| [row[0], row[2], row[1], row[3]] }]
  writes, assignments = [], []
  trace = TracePoint.new(:call) do |event|
    writes << event.method_id if event.defined_class == T::LocalExecutionPlanStorage && event.method_id == :write
    assignments << event.method_id if event.defined_class == GameRoomTeams::Assignment && event.method_id == :initialize
  end
  trace.enable(target_thread: nil)
  begin
    bad_bases.each do |base|
      error = assert_raises(T::Publication::Invalid) { backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: base, intent_id: 'bad') }
      assert_equal(:invalid_base_seats, error.code)
    end
  ensure
    trace.disable
  end
  assert_equal([], writes)
  assert_equal([], assignments)
  assert(!File.exist?(File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')))
  all << {'bad_bases' => bad_bases, 'writes' => writes, 'assignments' => assignments}
end
# Dwie różne diagnostyki nie stają się po cichu mniejszym rosterem.
[:publication, :join].each do |kind|
  context, service, reference = fixture
  source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
  if kind == :publication
    values = source['announcements'].first.reject { |key, _| key.start_with?('__') }.merge('title' => 'Sprzeczny tytuł')
    context.provider.insert_row(TournamentPublicServiceSupport::ANN, values)
  else
    old = source['registrations'].first
    context.actor = old['__insertion_user']
    context.provider.insert_row(TournamentPublicServiceSupport::REG, old.reject { |key, _| key.start_with?('__') }.merge('kind' => 'nielegalny'))
    context.actor = 'Organizator'
  end
  diagnostics = service.list['diagnostics']
  error = assert_raises(T::Publication::Invalid) { service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE) }
  assert_equal(:unresolved_source_diagnostics, error.code)
  all << {'conflict' => kind, 'diagnostics' => diagnostics, 'code' => error.code}
end
context, service, reference = fixture(game: 'axel_pong')
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
with_backend(context) do |backend, _, _, _, directory|
  shown = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: bases(source), intent_id: 'pong-realtime')
  assert(shown.is_a?(Hash), 'Declared realtime team source must produce an explicit reviewable preview')
  assert(!File.exist?(File.join(directory, 'fixed-teams-v1', 'sandbox-k02.json')))
  all << {'realtime_source' => source, 'backend_preview' => shown}
end
oracle_file('oracle.json', all)
puts 'FT1: surowy Unicode, pełne diagnostyki, wadliwe base i jawny podgląd podłączonego realtime bez zapisu — OK'

# encoding: UTF-8
require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
require_relative '../../lib/tournaments/schedule_candidate'
include GameRoomTest::Assertions
extend TournamentPublicServiceSupport
G = GameRoomTournaments
Dir.mktmpdir('entry-public-', ENV.fetch('TMPDIR')) do |directory|
  context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator')
  service = context.service
  assert(service.respond_to?(:schedule_candidate), 'R1: PublicService nie udostępnia odczytu oryginalnej projekcji do ScheduleCandidate')
  %w[chess three_five_eight].each do |game|
    draft_value = draft(game).merge('rematch' => true)
    original_draft = Marshal.dump(draft_value)
    context.actor = 'Organizator'
    service = context.service(journal: context.reopen_journal)
    operation = service.publish(**params(game, draft: draft_value))
    assert(operation['status'] == 'confirmed', 'Fixture publikacji niepotwierdzony')
    row = service.list['announcements'].find { |item| item['game'] == game }
    reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
    %w[Alicja Bob Celina Dawid].each do |actor|
      context.actor = actor
      member = context.service(journal: context.reopen_journal).join(tournament_id: row['__id'])
      assert(member['status'] == 'confirmed', 'Fixture join niepotwierdzony')
    end
    context.actor = 'Bob'
    service = context.service(journal: context.reopen_journal)
    context.now = 199
    error = assert_raises(G::Publication::Invalid) { service.schedule_candidate(publication_ref: reference) }
    assert(error.code == :registration_open, 'Zgubiono powód otwartych zapisów')
    context.now = 200
    inserts = context.inserts.length
    reads = context.reads.length
    candidate = service.schedule_candidate(publication_ref: reference)
    data = candidate.to_h
    assert(candidate.instance_of?(G::ScheduleCandidate), 'Zmieniono typ kandydata')
    assert(context.reads.drop(reads) == [TournamentPublicServiceSupport::ANN, TournamentPublicServiceSupport::REG], 'Nie wykonano dokładnie jednego świeżego snapshotu')
    assert(data['roster'] == %w[alicja bob celina dawid], 'Użyto rosteru szkicu zamiast join')
    assert(data['matches'].all? { |match| match['players'].length == draft_value['players_per_match'] }, 'Zmieniono pełne składy')
    assert(data['matches'].map { |match| match['leg'] }.uniq.sort == [1,2], 'Zgubiono rewanż')
    assert(data['finality'] == 'unknown' && data['roles_teams'] == 'unassigned' && data['start_allowed'] == false && data['dispatch_allowed'] == false, 'Kandydat dostał autorytet')
    assert(data['game_options'] == draft_value['game_options'] && data['windows'] == draft_value['windows'], 'Zmieniono opcje/okna')
    again = service.schedule_candidate(publication_ref: reference).to_h
    assert(data == again && context.inserts.length == inserts, 'Niestabilne ID lub mutacja odczytu')
    assert(Marshal.dump(draft_value) == original_draft, 'Zmieniono szkic')
    context.now = 150
  end
end
puts 'PASS R1: świeża projekcja, rzeczywiste join 2/3 osoby, całe składy, leg, opcje, okna i stabilne ID; bez insert'

sandbox do |c|
  c.service.publish(**params)
  c.service.join(tournament_id: 1)
  c.actor = 'Bob'
  service = c.service(journal: c.reopen_journal)
  service.join(tournament_id: 1)
  row = service.list['announcements'].first
  reference = {'author' => row['__insertion_user'], 'publication_key' => row['publication_key']}
  c.now = nil
  error = assert_raises(G::PublicService::Error) { service.schedule_candidate(publication_ref: reference) }
  assert(error.code == :invalid_clock, 'Zły zegar przeszedł')
  c.now = 200
  build = G::ScheduleCandidate.method(:build)
  reached = 0
  G::ScheduleCandidate.define_singleton_method(:build) do |**args|
    assert(args[:projection].instance_of?(G::RegistrationProjection), 'Nie przekazano oryginalnego modelu')
    result = build.call(**args)
    reached += 1
    c.actor = 'ObceKonto'
    result
  end
  begin
    error = assert_raises(G::PublicService::Error) { service.schedule_candidate(publication_ref: reference) }
    assert(reached == 1 && error.code == :account_changed, 'Brak sprawdzenia konta po obliczeniu kandydata')
  ensure
    G::ScheduleCandidate.define_singleton_method(:build, build)
  end
end
puts 'PASS R1 boundary: niepoprawny zegar, oryginalny model i zmiana konta po rzeczywistym build przed zwrotem'

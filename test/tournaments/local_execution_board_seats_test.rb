# encoding: UTF-8
require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
include TournamentLocalExecutionPlanSupport

with_fixture(game: 'four_in_a_row') do |f|
  candidate = f.author_service.schedule_candidate(publication_ref: f.reference).to_h
  base = f.base
  assert_equal(%w[beta alpha], base.values.first, 'Jawne pierwsze miejsca przeciw sortowaniu')
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: base, intent_id: 'planszowy-1')
  record = backend.accept(preview: shown)
  assert_equal(candidate['matches'].map { |m| m.values_at('match_id','leg','players') },
    record['evidence']['source']['matches'].map { |m| m.values_at('match_id','leg','accounts') })
  assert_equal(2, record['evidence']['plan']['matches'].size)
  record['evidence']['plan']['matches'].each do |match|
    value = request(record, match)
    assert_equal(match['leg'] == 1 ? %w[beta alpha] : %w[alpha beta], value['players'].map { |p| p['account'] })
    assert_equal([0,1], value['players'].map { |p| p['seat'] })
    assert_equal(%w[seat:0 seat:1], value['players'].map { |p| p['game_role'] })
    assert_equal('local-test-board-seats-explicit-reverse-v1', value['role_policy_ref'])
    assert_equal(candidate['game_options'], value['options'])
  end
  path = File.join(f.directory, 'k02', 'sandbox-k02.json')
  bytes = File.binread(path)
  assert_equal(record, f.backend.readback(intent_id: 'planszowy-1'))
  assert_equal(record, f.backend.accept(preview: shown))
  assert_equal(bytes, File.binread(path), 'Readback/retry bez nowego zapisu')
end
puts 'PASS czwórki: cały rzeczywisty plan, jawna baza, rewanż, fabryka A i trwałość'

require_relative '../support/tournament_board_seats'
include TournamentBoardSeatsSupport

%w[four_in_a_row tic_tac_toe checkers reversi battleship mancala].each do |game|
  options = case game
  when 'checkers' then {'board_size' => 10}
  when 'battleship' then {'touching' => true}
  when 'mancala' then {'variant' => 'kalah', 'stones' => 5, 'capture' => false}
  else {}
  end
  with_board(game: game, names: ['Żaneta', 'Alpha', 'İpek'], options: options) do |f|
    candidate = f.author_service.schedule_candidate(publication_ref: f.reference).to_h
    base = f.base
    assert_equal(3, base.size, 'Cały terminarz trzech osób, nie stała para')
    backend = f.backend
    record = backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: base, intent_id: "rodzina-#{game}"))
    assert_equal(candidate['matches'].map { |m| m.values_at('match_id','leg') }, record['evidence']['plan']['matches'].map { |m| m.values_at('match_id','leg') })
    record['evidence']['plan']['matches'].each do |match|
      value = request(record, match)
      original = candidate['matches'].find { |m| m['match_id'] == match['match_id'] }
      first = candidate['matches'].find { |m| m['leg'] == 1 && m['players'] == original['players'] }
      expected = base.fetch(first['match_id'])
      expected = expected.reverse if match['leg'] == 2
      assert_equal(expected, value['players'].map { |p| p['account'] })
      assert_equal(%w[seat:0 seat:1], value['players'].map { |p| p['game_role'] })
      assert_equal('local-test-board-seats-explicit-reverse-v1', value['role_policy_ref'])
      assert_equal(candidate['game_options'], value['options'])
      assert_equal([nil,nil], value['players'].map { |p| p['team'] })
      assert_equal(%w[player player], value['players'].map { |p| p['role'] })
      assert_equal([], value['observers'])
      assert_equal(record['evidence']['source']['windows'], match['windows'])
      value['players'].each do |p|
        assert_equal(['Żaneta','Alpha','İpek'].find { |raw| raw.downcase == p['account'] }, p['username'])
      end
      check_board_model(value)
    end
    assert_equal(record, f.backend.readback(intent_id: "rodzina-#{game}"))
  end
  puts "PASS #{game}: sześć spotkań, surowe Unicode, opcje i rzeczywiste modele z requestów obu legów"
end

%w[four_in_a_row tic_tac_toe checkers reversi battleship mancala].each do |game|
  with_board(game: game, rematch: false, names: %w[Gamma Beta Alpha]) do |f|
    backend = f.backend
    record = backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'bez-rewanzu'))
    assert_equal(3, record['evidence']['plan']['matches'].size)
    assert_equal([1], record['evidence']['plan']['matches'].map { |m| m['leg'] }.uniq)
    record['evidence']['plan']['matches'].each { |m| assert_equal(f.base[m['match_id']], request(record, m)['players'].map { |p| p['account'] }) }
  end
end
puts 'PASS sześć gier bez rewanżu: brak dopisanych legów'

with_board(game: 'four_in_a_row', names: %w[Gamma Beta Alpha]) do |f|
  b, base = f.backend, f.base
  path = File.join(f.directory, 'k02', 'sandbox-k02.json')
  invalid = [nil, [], base.merge('obcy' => %w[alpha beta]), base.reject { |key, _| key == base.keys.first },
    base.merge(base.keys.first => %w[alpha alpha]), base.merge(base.keys.first => %w[obcy beta]),
    base.merge(base.keys.first => base.values.first.map(&:upcase))]
  invalid.each do |value|
    without_board_write(path) do
      error = assert_raises(T::Publication::Invalid) { b.preview(publication_ref: f.reference, base_seats: value, intent_id: 'blad-bazy') }
      assert_equal(:invalid_base_seats, error.code)
    end
  end
  shown = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'dowod')
  [->(p) { p['assignments'].last['players'].first['game_role'] = 'w' },
    ->(p) { p['role_policy_ref'] = T::LocalExecutionPlanBackend::ROLE_POLICY }].each do |mutate|
    proof = JSON.parse(JSON.generate(shown))
    mutate.call(proof)
    proof['digest'] = b.send(:digest, b.send(:semantic, proof))
    without_board_write(path) do
      error = assert_raises(T::Publication::Invalid) { b.accept(preview: proof) }
      assert_equal(:invalid_preview, error.code)
    end
  end
  record = b.accept(preview: shown)
  conflict = b.preview(publication_ref: f.reference, base_seats: base.transform_values(&:reverse), intent_id: 'drugi-przydzial')
  without_board_write(path) do
    error = assert_raises(T::Publication::Invalid) { b.accept(preview: conflict) }
    assert_equal(:source_conflict, error.code)
    assert_equal(record, f.backend.accept(preview: shown))
  end
  alias_proof = b.preview(publication_ref: f.reference, base_seats: base, intent_id: 'alias-przydzialu')
  assert_equal(record, b.accept(preview: alias_proof))
  without_board_write(path) { assert_equal(record, f.backend.readback(intent_id: 'alias-przydzialu')) }
  original = File.binread(path)
  [->(m) { m['players'].first['game_role'] = 'w' },
    ->(m) { m['role_policy_ref'] = T::LocalExecutionPlanBackend::ROLE_POLICY }].each do |mutate|
    document = JSON.parse(original)
    stored = document['records'].first
    mutate.call(stored['evidence']['plan']['matches'].last)
    stored['evidence']['plan_digest'] = T::ExecutionPlanContract.digest(stored['evidence'].slice('scope','plan'))
    File.binwrite(path, JSON.generate(document))
    without_board_write(path) do
      [:readback, :accept].each do |action|
        error = assert_raises(T::Publication::Invalid) do
          action == :readback ? f.backend.readback(intent_id: 'nie-wybrany') : f.backend.accept(preview: shown)
        end
        assert_equal(:sandbox_corrupt, error.code, 'Cały magazyn odrzuca obcą rolę/politykę mimo nowego digestu')
      end
    end
    File.binwrite(path, original)
  end
end
puts 'PASS pełna baza, fałszywy proof, retry, alias, konflikt A-source, role/policy w magazynie bez zapisu'

with_board do |f|
  backend = f.backend
  chess = backend.accept(preview: backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'pierwotne-szachy'))
  ref, base = publish_board(f, 'mancala', intent: 'nowa-publikacja', options: {'stones' => 6})
  shown = backend.preview(publication_ref: ref, base_seats: base, intent_id: 'pierwotna-plansza')
  board = backend.accept(preview: shown)
  path = File.join(f.directory, 'k02', 'sandbox-k02.json')
  without_board_write(path) do
    assert_equal(chess, f.backend.readback(intent_id: 'pierwotne-szachy'))
    assert_equal(board, f.backend.readback(intent_id: 'pierwotna-plansza'))
  end
  original = File.binread(path)
  proof = backend.preview(publication_ref: ref, base_seats: base, intent_id: 'pierwotne-szachy')
  document = JSON.parse(original)
  link = document['intents'].find { |i| i['intent_id'] == 'pierwotne-szachy' }
  link.merge!('record_intent_id' => 'pierwotna-plansza', 'digest' => proof['digest'], 'preview' => proof)
  File.binwrite(path, JSON.generate(document))
  without_board_write(path) do
    error = assert_raises(T::Publication::Invalid) { f.backend.readback(intent_id: 'pierwotna-plansza') }
    assert_equal(:sandbox_corrupt, error.code, 'Pierwotne ID szachów nie może zostać aliasem drugiej legalnej gry')
    error = assert_raises(T::Publication::Invalid) { f.backend.accept(preview: shown) }
    assert_equal(:sandbox_corrupt, error.code)
  end
  File.binwrite(path, original)
  f.owner = 'InnyWlasciciel'
  without_board_write(path) do
    error = assert_raises(T::Publication::Invalid) { backend.readback(intent_id: 'pierwotna-plansza') }
    assert_equal(:context_changed, error.code)
  end
end
puts 'PASS mieszane szachy/plansza, globalna własność pierwotnych intentów i granica właściciela'

%w[war poker audio_ball spades taboo].each do |game|
  with_board(game: game, names: %w[Alpha Beta Gamma Delta], rematch: false) do |f|
    without_board_write(File.join(f.directory, 'k02', 'sandbox-k02.json')) do
      error = assert_raises(T::Publication::Invalid) { f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'poza-rodzina') }
      assert_equal(:unsupported_role_family, error.code)
    end
  end
end
puts 'PASS inne rodziny: karty, poker/dealer, realtime, drużyny i stały sędzia nadal unsupported'

with_board(game: 'four_in_a_row', names: (1..17).map { |i| "Osoba#{i}" }) do |f|
  assert_equal(272, f.author_service.schedule_candidate(publication_ref: f.reference).to_h['matches'].size)
  without_board_write(File.join(f.directory, 'k02', 'sandbox-k02.json')) do
    error = assert_raises(T::Publication::Invalid) { f.backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'nadmiar') }
    assert_equal(:execution_plan_limit, error.code)
  end
end
puts 'PASS 272 spotkania odrzucone w całości, bez obcinania do 256'

windows = (0...8).map do |index|
  date = (Date.new(2030,1,1) + index).strftime('%Y-%m-%d')
  {'date' => date, 'start' => '12:00', 'end_date' => date, 'end' => '21:00'}
end
with_board(game: 'four_in_a_row', names: (1..16).map { |i| "Osoba#{i}" }, windows: windows) do |f|
  backend = f.backend
  shown = backend.preview(publication_ref: f.reference, base_seats: f.base, intent_id: 'pelny-budzet-A')
  assert_equal(240, shown['source']['candidate']['matches'].size)
  without_board_write(File.join(f.directory, 'k02', 'sandbox-k02.json')) do
    error = assert_raises(T::Publication::Invalid) { backend.accept(preview: shown) }
    assert_equal(:json_budget, error.code, 'Cały A podlega istniejącemu budżetowi 262144 B / 16384 węzłów')
  end
end
puts 'PASS liczność poniżej 256 nie omija budżetu całego planu A'

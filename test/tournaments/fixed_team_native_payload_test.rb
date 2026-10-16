# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
require_relative '../../lib/game_repository'
file = File.expand_path('../../lib/tournaments/fixed_team_native_payload.rb', __dir__)
require file if File.file?(file)
include TournamentFixedTeamsSupport
assert(T.const_defined?(:FixedTeamNativePayload), 'RED_FT1: brak fabryki rzeczywistych natywnych metadanych')
outputs = []
[TEMPLATE, [0, 0, 1, 1]].each do |template|
  [true, false].each do |rematch|
    context, service, reference = fixture(rematch: rematch)
    source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: template)
    with_backend(context) do |backend, _, _, _, directory|
      shown = backend.preview(publication_ref: reference, membership: membership, team_template: template, base_seats: bases(source, template), intent_id: 'native')
      record = backend.accept(preview: shown)
      evidence = record['evidence']
      expected = template == TEMPLATE ?
        [%w[Beata Anna Bartek Ala], %w[Ala Cezary Anna Celina], %w[Celina Beata Cezary Bartek],
         %w[Anna Beata Ala Bartek], %w[Cezary Ala Celina Anna], %w[Beata Celina Bartek Cezary]] :
        [%w[Beata Bartek Anna Ala], %w[Ala Anna Cezary Celina], %w[Celina Cezary Beata Bartek],
         %w[Anna Ala Beata Bartek], %w[Cezary Celina Ala Anna], %w[Beata Bartek Celina Cezary]]
      expected = expected.first(3) unless rematch
      assert_equal(expected, evidence['plan']['matches'].map { |match| match['players'].map { |person| person['username'] } })
      game = REGISTRY.build('spades')
      repo = GameRepository.new(nil, transport: Object.new)
      rows = evidence['plan']['matches'].each_with_index.map do |match, index|
        match['windows'].map do |window|
          native = T::FixedTeamNativePayload.from_execution_plan(evidence: evidence, expected_source: record['expected_source'],
            match_id: match['match_id'], leg: match['leg'], window_id: window['id'], registry: REGISTRY)
          data = native.to_h
          request = T::CoordinationRequest.from_execution_plan(evidence: evidence, expected_source: record['expected_source'],
            match_id: match['match_id'], leg: match['leg'], window_id: window['id'], registry: REGISTRY)
          assert_equal(request.digest, data['request_digest'])
          assert_equal(expected[index], data['players'])
          exact = request.to_h['options'].merge('team_players' => expected[index])
          assert_equal(exact, data['options'])
          assert_equal(T::ExecutionPlanContract.digest(data), native.digest)
          assert_equal(false, data['dispatch_allowed'])
          assert_equal(false, data['start_allowed'])
          assert(data.frozen? && data['options'].frozen? && data['players'].all?(&:frozen?))
          assert_equal(native.digest, record['native_payload_digests'][match['match_id']][window['id']])
          consumed = game.options_for_team_roster(game.new_game_options(game.options_from_json(JSON.generate(exact))), players: expected[index])
          assert_equal(exact, consumed)
          session = {'__players' => expected[index], 'options' => JSON.generate(consumed)}
          replay = game.replay(session, [], repo)
          assert_equal(expected[index], replay.players)
          assert_equal(nil, replay.state[:dealer_index], 'Miejsca nie ustalają dealera')
          groups = [0, 1].map { |side| expected[index].each_with_index.filter_map { |name, seat| name if template[seat] == side } }
          scoring = GameRoomGames::Spades::Scoring.new(replay.players, replay.state[:options])
          assert_equal(groups, scoring.unit_ids.map { |id| scoring.members_for(id) })
          deal = {'__id' => 1, '__insertion_user' => expected[index].first, 'actor' => expected[index].first, 'action' => 'deal', 'value' => '1|3|' + '0' * 32}
          dealt = game.replay(session, [deal], repo)
          assert_equal([deal], dealt.accepted_events)
          assert_equal(3, dealt.state[:dealer_index])
          assert_equal(nil, game.prepared_team_assignment(exact.merge('team_players' => ['Obcy'] + expected[index].drop(1)), players: expected[index]))
          assert_equal(nil, game.prepared_team_assignment(exact, players: ['Obcy'] + expected[index].drop(1)))
          {'request' => request.to_h, 'native' => data, 'digest' => native.digest, 'groups' => groups, 'dealer' => dealt.state[:dealer_index]}
        end
      end
      outputs << {'template' => template, 'rematch' => rematch, 'source' => source, 'shown' => shown, 'record' => record, 'expected_players' => expected, 'consumers' => rows}
    end
  end
end
# Wspólny adapter bez aktywacji backendu Taboo.
game = REGISTRY.build('taboo')
people = %w[Ala Bartek Anna Beata].each_with_index.map do |name, seat|
  {'username' => name, 'account' => name.downcase, 'seat' => seat, 'team' => ['unit-A', 'unit-B'][seat % 2]}
end
options = game.normalize_options({})
native = T::FixedTeamSeats.native(game: game, options: options.merge('team_seats' => TEMPLATE), people: people, template: TEMPLATE)
assert_equal(%w[Ala Bartek Anna Beata], native['team_players'])
assert_equal([%w[Ala Anna], %w[Bartek Beata]], [0, 1].map { |side| game.prepared_team_assignment(native, players: native['team_players']).members_for(side) })
oracle_file('oracle.json', {'scenarios' => outputs, 'taboo_native' => native})
puts 'FT1: dwa szablony, pełne legi i okna, natywny replay oraz scoring — OK'

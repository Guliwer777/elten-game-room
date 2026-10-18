require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport

checks = 0
values = [nil, true, false, 0, 0.0, '', [], {}]
%w[spades taboo].each do |game|
  names = game == 'spades' ? %w[Alpha Beta Gamma Delta] : %w[Alpha Beta Gamma Delta Epsilon Zeta]
  options = game == 'spades' ? {'team_size' => 2} : nil
  with_fixture(game: game, names: names, players_per_match: names.size,
      rematch: false, game_options: options) do |fixture|
    with_declared_team_backend(fixture, 'Organizator') do |backend|
      input = {publication_ref: fixture.reference, intent_id: "candidate-boundary-#{game}"}
      shown = if game == 'spades'
        backend.preview_pairs(**input, pairs: [%w[alpha beta], %w[gamma delta]], team_template: [0, 1, 0, 1])
      else
        backend.preview_teams(**input, teams: [%w[alpha beta gamma], %w[delta epsilon zeta]], team_template: [0, 1, 0, 1, 0, 1])
      end
      accepted = backend.accept(preview: shown)
      snapshot = lambda do
        Dir.glob(File.join(fixture.directory, '**', '*.json')).sort.to_h { |path| [path, File.binread(path)] }
      end
      before = snapshot.call
      %w[game_id game_options membership players_per_match].each do |field|
        values.each do |value|
          changed = JSON.parse(JSON.generate(shown))
          changed['source']['candidate'][field] = value
          input_before = JSON.generate(changed)
          assert_raises(T::Publication::Invalid) { backend.accept(preview: changed) }
          assert_equal(input_before, JSON.generate(changed), 'Invalid input must not be normalized or rewritten')
          assert_equal(before, snapshot.call, 'Refusal must leave all accepted source and journal bytes unchanged')
          checks += 1
        end
      end
      assert_equal(accepted, backend.accept(preview: shown), 'Valid producer preview still accepts idempotently')
      assert_equal(accepted, backend.readback(intent_id: shown['intent_id']))
    end
  end
end
puts "PASS fixed-team candidate boundary: #{checks} malformed fields refused before policy; valid Spades/Taboo plans and unchanged durable bytes"

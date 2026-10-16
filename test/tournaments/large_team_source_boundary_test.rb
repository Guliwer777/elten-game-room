require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport
names = %w[Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota]
with_fixture(game: 'taboo', names: names, players_per_match: 6, rematch: true) do |fixture|
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    teams = names.each_slice(3).map { |team| team.map(&:downcase) }
    template = [0, 1, 0, 1, 0, 1]
    shown = backend.preview_teams(publication_ref: fixture.reference, teams: teams,
      team_template: template, intent_id: 'larger-rematch')
    assert_equal(6, shown['assignments'].size)
    shown['assignments'].take(3).zip(shown['assignments'].drop(3)).each do |first, second|
      assert_equal(1, first['leg'])
      assert_equal(2, second['leg'])
      a = first['players'].sort_by { |person| person['seat'] }.map { |person| person['account'] }
      b = second['players'].sort_by { |person| person['seat'] }.map { |person| person['account'] }
      assert_equal([a[1], a[0], a[3], a[2], a[5], a[4]], b)
      [first, second].each do |match|
        assert_equal([3, 3], match['players'].group_by { |person| person['team'] }.values.map(&:size))
      end
    end
    roster = shown['source']['candidate']['roster'].map { |account| {'account' => account, 'username' => names.find { |name| name.downcase == account }} }
    members = shown['membership']
    [nil, '3', 3.0, 2, 0, 129].each do |size|
      invalid = T::Publication::Data.copy(members).merge('team_size' => size)
      assert_raises(T::Publication::Invalid) { T::FixedTeamSeats.membership(invalid, roster) }
    end
    invalid = T::Publication::Data.copy(members).merge('version' => 1)
    assert_raises(T::Publication::Invalid) { T::FixedTeamSeats.membership(invalid, roster) }
    invalid = T::Publication::Data.copy(members)
    invalid['units'][1]['unit_id'] = invalid['units'][0]['unit_id'].upcase
    assert_raises(T::Publication::Invalid) { T::FixedTeamSeats.membership(invalid, roster) }
    assert_raises(T::Publication::Invalid) { T::FixedTeamSeats.template(template, options: {}) }
    record = backend.accept(preview: shown)
    source = record['evidence']['source']
    assert_raises(T::Publication::Invalid) { T::FixedTeamPlanContract.source!(T::Publication::Data.copy(source).merge('source_version' => 1)) }
    [nil, T::GameResult::RESULT_EXPORT_POLICY].each do |policy|
      assert_raises(T::Publication::Invalid) { T::FixedTeamPlanContract.source!(T::Publication::Data.copy(source).merge('result_policy' => policy)) }
    end
    assert_equal(record, backend.readback(intent_id: 'larger-rematch'))
  end
end
puts 'PASS larger-team source boundaries: equal whole units, strict integers/version/policy, six-player rematches swap all seats, immutable accepted plan'

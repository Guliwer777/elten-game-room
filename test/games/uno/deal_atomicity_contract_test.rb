require_relative '../../support/new_games_fixture'

# This is a model/reducer boundary test, not a live server test. Exercise
# every seat position and elimination pattern rather than one chosen dealer.
game = GameRoomGames::Uno.new
cases = 0
%w[classic no_mercy].each do |deck|
  (2..8).each do |count|
    players = Array.new(count) { |index| "Player#{index}" }
    repository = NewGames116Repository.new(players)
    [[], [players.first], players[0...-1]].each do |eliminated|
      (-count-1..count).each do |dealer|
        state = game.send(:initial_state, players, game.normalize_options('deck' => deck))
        state.update(phase: :round_complete, round: 1, dealer_index: 0)
        state[:round_eliminated][players.last] = true
        eliminated.each { |name| state[:eliminated][name] = true }
        before = Marshal.dump(state)
        history = []
        event = {'id' => 21, 'actor' => players.first, 'action' => 'deal',
          'value' => "2|#{dealer}|#{'5' * 32}|0"}
        accepted = game.send(:apply_deal, state, event, players.first, repository, history)
        expected = dealer.between?(0, count - 1) &&
          !eliminated.include?(players[dealer]) && count - eliminated.length >= 2
        assert(accepted == expected, "Wrong dealer decision: #{deck}/#{count}/#{eliminated}/#{dealer}")
        if accepted
          assert(history.size == 1 && state[:round] == 2, 'Legal deal recorded more than once')
          players.each do |name|
            assert(state[:hands][name].size == (eliminated.include?(name) ? 0 : 7), 'Wrong participant returned')
          end
          assert(state[:round_eliminated].values.none?, 'Temporary elimination survived the new deal')
        else
          assert(Marshal.dump(state) == before && history.empty?, 'Rejected dealer changed the model')
        end
        cases += 1
      end
    end
  end
end
puts "PASS UNO: #{cases} dealer/seat/elimination model boundaries remain atomic"

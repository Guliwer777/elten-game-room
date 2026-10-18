require_relative 'session_runner'
require_relative 'native_private_pools'

module PrivateCardGamesTest
  module_function

  def create(game, users:, options: {}, random_values: nil)
    marker = {'publication_ref'=>{'author'=>users.first, 'publication_key'=>'private-cards'},
      'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
    h = NativeRoomHarness.new(game: game, users: users, tournament: marker,
      options: game.default_options.merge('bot_delay'=>0).merge(options))
    h.start
    h.view(users.first).next_random_values = random_values if random_values
    runners = users.to_h { |user| [user, runner_for(h, user)] }
    16.times { tick(h, runners) }
    [h, runners]
  end

  def tick(h, runners)
    runners.each { |user, runner| step(h, runner, user) }
  end

  def assert_private(h)
    public_states = h.users.map do |user|
      replay = h.replay(user)
      state = replay.state
      assert(!state[:private_error], "#{h.game.id}: #{state[:private_error]}")
      assert(state[:hands][user].none? { |card| GameRoomPrivateCardLedger.hidden?(card) },
        "#{h.game.id}: own card missing for #{user}, phase #{state[:phase]}, round #{state[:round]}, " +
        "hand #{state[:hands][user].inspect}, effect #{state[:private_effect].inspect}")
      h.users.reject { |player| player == user }.each do |other|
        assert(state[:hands][other].all? { |card| GameRoomPrivateCardLedger.hidden?(card) || state[:private_public].include?(card) },
          "#{h.game.id}: foreign private card leaked")
      end
      state.reject { |key, value| key.to_s.start_with?('private_') || key == :hands || value.equal?(state[:hands]) }.
        merge(hand_counts: state[:hands].transform_values(&:size))
    end
    differences = public_states.first.keys.select { |key| public_states.map { |state| state[key] }.uniq.size > 1 }
    assert(differences.empty?, "#{h.game.id}: public state diverged #{differences.to_h { |key| [key, public_states.map { |state| state[key] }] }.inspect}")
  end

  def submit(h, runners, user, selection)
    h.as(user) do
      snapshot = h.repositories[user].snapshot_for(h.session)
      mine = h.game.replay(snapshot.session, snapshot.events, h.repositories[user])
      result = runners[user].submit(session: snapshot.session, replay: mine, selection: selection, actor: user)
      assert(result.first == :ok, "#{h.game.id}: #{user} rejected #{selection.inspect}: #{result.inspect}")
    end
  end
end

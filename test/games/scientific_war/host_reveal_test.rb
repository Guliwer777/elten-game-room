require_relative '../../support/session_runner'
require_relative '../../support/hidden_submission_files'
require_relative '../../../games/scientific_war'

Dir.mktmpdir('scientific-war-owner-reveal-') do |directory|
  game = GameRoomGames::ScientificWar.new
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  stores = h.users.to_h { |user| [user, HiddenSubmissionFiles.new(File.join(directory, user))] }
  runners = h.users.to_h do |user|
    runner = runner_for(h, user)
    runner.instance_variable_get(:@context_template).hidden_submissions = HiddenSubmissions::Vault.new(stores.fetch(user).storage)
    [user, runner]
  end
  begin
    [%w[Alice Bob], %w[Bob Alice]].each_with_index do |(old_owner, new_owner), index|
      h.as(old_owner) do
        h.transports.fetch(old_owner).transfer_room_owner(h.table, new_owner, control_guard: -> {
          assert(game.controller_change_error(h.replay(old_owner)).nil?, 'Owner transfer was not at a safe boundary')
        })
      end
      assert(h.view(new_owner).owner?, 'Native ownership did not change')
      h.users.each { |user| step(h, runners.fetch(user), user) }
      h.users.each do |user|
        h.as(user) do
          snapshot = h.repositories.fetch(user).snapshot_for(h.session)
          replay = game.replay(snapshot.session, snapshot.events, h.repositories.fetch(user))
          # Avoid a spy power in the following trick: this is a reveal/owner test.
          action = game.legal_actions(replay, user).find { |item| item['action'] == 'select' && game.send(:playing_card_rank, item['card']) != 'Q' }
          assert(action, 'No ordinary selectable card')
          status, = runners.fetch(user).submit(session: snapshot.session, replay: replay, selection: action, actor: user)
          assert(status == :ok, "#{user} choice was rejected: #{status}")
        end
      end
      3.times { h.users.each { |user| step(h, runners.fetch(user), user) } }
      assert(h.replay(new_owner).state[:trick] == index + 2, 'New owner did not automatically reveal their own card')
      h.users.each do |user|
        cold = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(stores.fetch(user).directory).storage)
        assert(cold.reveal(session_id: h.session['__id'], round_id: "trick:#{index + 1}", user: user).nil?, 'Confirmed choice remained on disk')
      end
      h.assert_converged('Automatic reveal after owner transfer')
    end
  ensure
    runners.each_value(&:close)
  end
end

puts 'Scientific War: both owner-transfer directions finish by native runner automatic reveal, with cold cleanup and convergence'

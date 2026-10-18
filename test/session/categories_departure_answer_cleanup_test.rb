require_relative '../support/session_runner'
require_relative '../support/hidden_submission_files'

[['answerer', %w[Alice Bob Carol Dave], 'Bob', 'Bob', 'Alice'],
 ['judge', %w[Alice Bob Carol Dave], 'Carol', 'Alice', 'Bob'],
 ['terminal', %w[Alice Bob], 'Bob', 'Bob', 'Alice']].each do |name, users, submitter, departing, successor|
  Dir.mktmpdir('categories-departure-cleanup-') do |directory|
    game = GameRoomGames::Categories.new
    options = game.normalize_options(game.default_options.merge('round_time'=>0, 'target_score'=>100,
      'category_set'=>'custom', 'custom_categories'=>['country'], 'round_category_count'=>1))
    h = NativeRoomHarness.new(game:game, users:users, options:options)
    h.start
    programs = users.to_h { |user| [user, HiddenSubmissionFiles.new(File.join(directory, user))] }
    vaults = programs.transform_values { |program| HiddenSubmissions::Vault.new(program.storage) }
    contexts = users.to_h do |user|
      [user, GameRoomGames::ActionContext.new(session_id:h.session['__id'], table_id:h.table['__id'],
        now:Time.now.to_i, random_source:GameRoomRandom::LocalSecureSource.new, hidden_submissions:vaults.fetch(user), table_owner:'Alice')]
    end
    runners = {}
    read = lambda do |user, session = h.session['__id'], round = nil|
      HiddenSubmissions::Vault.new(HiddenSubmissions::ProgramStorage.new(programs.fetch(user)))
        .reveal(session_id:session, round_id:round, user:user)
    end
    begin
      h.submit('Alice', context:contexts.fetch('Alice'))
      round = game.send(:round_id, h.replay('Alice').state)
      answer = {'kind'=>'answer_sheet', 'action'=>'submit', 'answers'=>{'country'=>'Austria'}}
      h.submit(submitter, answer, context:contexts.fetch(submitter))
      h.submit('Carol', answer, context:contexts.fetch('Carol')) if name == 'answerer'
      original = read.call(submitter, h.session['__id'], round)
      assert(original, "#{name}: accepted answer missing from private storage")

      # A participant cannot manufacture an authenticated controller departure.
      prior = h.replay('Alice')
      h.write(submitter, [GameRoomGames::EventCommand.new(action:'participants_departed',
        value:JSON.generate([prior.state[:attempt], [users.index(submitter)], false]))])
      rejected = h.replay('Alice')
      assert(rejected.accepted_events == prior.accepted_events && rejected.state == prior.state,
        "#{name}: unauthorized departure mutated replay")
      game.cleanup_session_answers(rejected, session_id:h.session['__id'], actors:[submitter], hidden_submissions:vaults.fetch(submitter))
      assert(read.call(submitter, h.session['__id'], round), "#{name}: rejected departure erased active data")

      h.as(departing) { h.view(departing).leave }
      runners[successor] = runner_for(h, successor)
      step(h, runners.fetch(successor), successor, count:3)
      current = h.replay(successor)
      assert(current.state[:departed_players].include?(departing), "#{name}: native departure was not accepted")
      assert(!current.state[:commitments].key?(submitter), "#{name}: commitment still needed by active round")
      assert(h.join(departing), "#{name}: returning participant could not join") if departing == submitter
      runners[submitter] ||= runner_for(h, submitter)
      runners.fetch(submitter).instance_variable_get(:@context_template).hidden_submissions = vaults.fetch(submitter)
      step(h, runners.fetch(submitter), submitter, count:3)
      assert(read.call(submitter, h.session['__id'], round).nil?, "#{name}: invalidated answer remains in cold storage")
      if name == 'answerer'
        assert(current.state[:phase] == :answering && current.state[:active_players] == %w[Carol Dave], 'Active round was cancelled')
        game.cleanup_session_answers(current, session_id:h.session['__id'], actors:['Carol'], hidden_submissions:vaults['Carol'])
        assert(read.call('Carol', h.session['__id'], round), 'Still-present active answerer lost an unrevealed answer')
      elsif name == 'judge'
        assert(current.state[:phase] == :round_complete && current.state[:completed_rounds] == 0, 'Judge departure did not cancel only the attempt')
      else
        assert(current.state[:phase] == :interrupted && !current.finished?, 'Departure invented a completed result')
      end

      newer = vaults.fetch(submitter).prepare(session_id:h.session['__id'], round_id:round, user:submitter, payload:{'country'=>'New uncertain answer'})
      other = vaults.fetch(submitter).prepare(session_id:h.session['__id'] + 1, round_id:round, user:submitter, payload:{'country'=>'Other session'})
      cold_game = game.build_session_game
      cold = cold_game.replay(h.session, h.events(successor), h.repositories.fetch(successor))
      cold_game.cleanup_session_answers(cold, session_id:h.session['__id'], actors:[submitter], hidden_submissions:vaults.fetch(submitter))
      assert(read.call(submitter, h.session['__id'], round).commitment == newer.commitment, "#{name}: new uncertain generation erased")
      assert(read.call(submitter, h.session['__id'] + 1, round).commitment == other.commitment, "#{name}: other session erased")
      assert(cold.state[:scores] == current.state[:scores] && cold.winner == current.winner, "#{name}: cleanup changed score or outcome")
    ensure
      runners.each_value(&:close)
      h.users.each { |user| h.as(user) { h.view(user)&.leave } }
    end
  end
end

puts 'PASS native Categories departure cleanup: answerer, judge, interruption; active and rejected departures preserved; cold files, uncertain generation and session isolation'

require_relative '../support/session_runner'
require_relative '../support/hidden_submission_files'
require_relative '../../games/scientific_war'

Dir.mktmpdir('named-bot-answer-cleanup-') do |directory|
  game = GameRoomGames::ScientificWar.new
  h = NativeRoomHarness.new(game: game, users: ['Alice'], bots: 1,
    options: game.default_options.merge('bot_delay' => 0))
  h.start
  files = HiddenSubmissionFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(files.storage)
  runner = runner_for(h, 'Alice')
  runner.instance_variable_get(:@context_template).hidden_submissions = vault
  begin
    bot = h.replay('Alice').players.find { |actor| GameRoomParticipants.bot?(actor) }
    assert(bot, 'No named bot in actual roster')
    8.times do
      step(h, runner, 'Alice')
      break if h.replay('Alice').state[:commits].key?(bot)
    end
    assert(vault.reveal(session_id: h.session['__id'], round_id: 'trick:1', user: bot), 'Bot did not durably seal its choice')
    h.as('Alice') do
      snapshot = h.repositories['Alice'].snapshot_for(h.session)
      replay = game.replay(snapshot.session, snapshot.events, h.repositories['Alice'])
      action = game.legal_actions(replay, 'Alice').find { |item| item['action'] == 'select' }
      status, = runner.submit(session: snapshot.session, replay: replay, selection: action, actor: 'Alice')
      assert(status == :ok, 'Human choice rejected')
    end
    12.times do
      step(h, runner, 'Alice')
      break if h.replay('Alice').state[:trick] == 2
    end
    step(h, runner, 'Alice')
    assert(h.replay('Alice').state[:trick] == 2, 'Human and bot failed to complete their choices')
    snapshot = h.repositories['Alice'].snapshot_for(h.session)
    assert(snapshot.session.fetch('__controllers', {}).empty?, 'Fixture accidentally uses legacy controlled seats')
    cold = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(directory).storage)
    ['Alice', bot].each do |actor|
      assert(cold.reveal(session_id: h.session['__id'], round_id: 'trick:1', user: actor).nil?, "Confirmed #{actor} choice retained")
    end
  ensure
    runner.close
  end
end

puts 'Shared worker cleans confirmed named-bot and human envelopes without manual reveal or legacy controller seats'

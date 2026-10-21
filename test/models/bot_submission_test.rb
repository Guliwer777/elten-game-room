require_relative "../support/session_runner"

[nil, :before, :after].each do |failure|
  h = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob], bots: 1)
  # Bob remains a real spectator/recipient; the match has Alice and the bot.
  bot = h.transports['Alice'].room_snapshot(h.table)[:bots].first
  session = h.as('Alice') do
    h.repositories['Alice'].start_session(table: h.table, game: h.game.id,
      players: ['Alice', bot], options: JSON.generate(h.game.default_options.merge('bot_delay' => 0)))
  end
  h.instance_variable_set(:@session, session)
  r = runner_for(h)
  step(h, r) # Publish playing status before injecting a move-write failure.
  submit(h, r)
  next_sequence = h.repositories['Alice'].next_sequence(session, h.replay('Alice').accepted_events)
  captured = []
  repository = h.repositories['Alice']
  append = repository.method(:append_events)
  repository.define_singleton_method(:append_events) do |**arguments|
    captured << arguments
    append.call(**arguments)
  end
  tick = 0.0
  r.instance_variable_get(:@sync).instance_variable_set(:@clock, -> { tick })
  h.view('Alice').fail_next_push = failure
  h.as('Alice') { r.step }
  error = r.take_error
  # An after-write timeout is reconciled immediately if the native local view
  # already confirms the exact action. A before-write failure needs backoff.
  assert(failure == :before ? error.is_a?(EltenAPI::LiveSessions::TimeoutError) : error.nil?,
    "wrong bot submission outcome #{failure.inspect}: #{error&.class}: #{error&.message}; attempts=#{captured.size}")
  assert(captured.one? && captured.first[:actor] == bot, 'bot action was lost or submitted as the human')
  assert(captured.first[:sequence] == next_sequence, 'bot bypassed normal sequence allocation')
  assert(captured.first[:recipients].sort == %w[Alice Bob], 'bot omitted a human recipient')
  assert(captured.first[:events].one?, 'bot changed its validated plan')
  assert(r.instance_variable_get(:@turn).waiting_for_confirmation?, 'write released the bot before confirmation')
  if error
    step(h, r, count: 30)
    assert(captured.one?, 'uncertain bot write ignored backoff')
    tick = 31.0
  end
  step(h, r, count: 5)
  h.broker.deliver(duplicate: true)
  h.assert_converged("bot write #{failure || 'confirmed'}", expected_count: 2)
  assert(h.events('Alice').last['actor'] == bot, 'confirmed move has the wrong identity')
  assert(h.replay('Alice').current_player == 'Alice', 'bot move failed to advance the game')
  assert(!r.instance_variable_get(:@turn).waiting_for_confirmation?, 'confirmed/missing write permanently blocked the bot')
  step(h, r, count: 30)
  assert(h.events('Alice').length == 2, 'duplicate delivery replayed the bot move')
  r.close
end
puts 'Production bot runner: identity, sequence, recipients, confirmation, failed/uncertain writes and no duplicates passed'

require_relative '../support/background_help_game_screen'

def stale_known_start_screen_case(mode)
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  old_id = h.session.fetch('__id')
  old_start = JSON.parse(JSON.generate(h.core.entries.find { |entry| entry['packet']['kind'] == 'game_started' }.fetch('packet')))
  h.start
  current_id = h.session.fetch('__id')
  displayed, submitted, forced_reads = [], [], []
  original = h.repositories.fetch('Alice').method(:session_for_table)
  ui_thread = Thread.current
  h.repositories.fetch('Alice').define_singleton_method(:session_for_table) do |table, force: false|
    forced_reads << $help_frames if force && Thread.current.equal?(ui_thread)
    original.call(table, force: force)
  end
  screen.singleton_class.prepend(Module.new do
    define_method(:prepare_action_view) do |replay|
      displayed << [instance_variable_get(:@session).fetch('__id'), $help_frames]
      super(replay)
    end
    define_method(:submit_action) do |replay, **options|
      result = super(replay, **options)
      submitted << result
      result
    end
  end)
  injected_at, restarted_at = nil, nil
  stage = :inject
  Form.driver = lambda do |_form|
    layout = screen.instance_variable_get(:@layout)
    sync = screen.instance_variable_get(:@synchronizer)
    case stage
    when :inject
      next unless screen.instance_variable_get(:@session)['__id'] == current_id
      assert(forced_reads.empty?, 'A valid new game needed an extra forced read')
      packet = JSON.parse(JSON.generate(old_start))
      sender = mode == :foreign_old ? 'Bob' : 'Alice'
      packet['actor'] = sender
      packet['data']['options'] = JSON.generate('team_seats' => true) if mode == :malformed_old
      injected_at = $help_frames
      h.view(sender).stack_push(packet, message_id: SecureRandom.uuid)
      stage = :after_rejected
    when :after_rejected
      next if $help_frames < injected_at + 20
      assert(displayed.none? { |id, frame| frame > injected_at && id == old_id },
        "#{mode}: rejected wake-up displayed a previously valid game")
      assert(screen.instance_variable_get(:@session)['__id'] == current_id, 'The current game changed')
      assert(!sync.recovery_pending? && screen.instance_variable_get(:@new_session_id).nil?, 'Rejected wake-up remained pending')
      assert(forced_reads.length == 1, 'A rejected old ID caused polling or skipped a fresh projection')
      stage = :current_move
      layout.surface.fields.first.trigger(:select, [0, 0])
    when :current_move
      next if submitted.empty?
      assert(submitted == [true], 'The first current-game gesture was lost or duplicated')
      h.assert_converged('current game after rejected old start', expected_count: 1)
      h.start
      current_id = h.session.fetch('__id')
      restarted_at = $help_frames
      stage = :after_restart
    when :after_restart
      next unless screen.instance_variable_get(:@session)['__id'] == current_id
      next if $help_frames < restarted_at + 10
      assert(forced_reads.length == 1, 'A valid rematch caused an additional forced read')
      assert(displayed.none? { |id, frame| frame > injected_at && id == old_id }, 'A rematch resurrected the rejected old game')
      stage = :rematch_move
      layout.surface.fields.first.trigger(:select, [1, 0])
    when :rematch_move
      next if submitted.length < 2
      assert(submitted == [true, true], 'The rematch gesture was lost or duplicated')
      h.assert_converged('valid rematch after rejected old start', expected_count: 1)
      h.users.each do |user|
        latest = h.as(user) { h.repositories.fetch(user).session_for_table(h.table) }
        assert(latest['__id'] == current_id, 'The native clients disagree on the latest session')
      end
      stage = :exit
      layout.back_button.trigger(:press)
    when :exit
      layout.back_button.trigger(:press)
    end
  end
  h.as('Alice') { assert(screen.run == :back, 'Normal departure changed') }
  assert(stage == :exit, 'The actual screen did not reach both move assertions')
  puts "PASS actual GameScreen: #{mode}, no historical rollback, valid rematch and both first gestures"
ensure
  Form.driver = nil
  h&.users&.each { |user| h.as(user) { h.view(user)&.close } }
end

[:foreign_old, :malformed_old].each { |mode| stale_known_start_screen_case(mode) }

require_relative '../support/background_help_game_screen'

def rejected_start_screen_case(mode)
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  expected_session_id = h.session['__id']
  trace, submitted, verification_reads = [], [], []
  ui_thread = Thread.current
  failed_read = false
  repository = h.repositories.fetch('Alice')
  original = repository.method(:session_for_table)
  repository.define_singleton_method(:session_for_table) do |table, force: false|
    if force && Thread.current.equal?(ui_thread)
      verification_reads << $help_frames
      if mode == :failed_rejected && !failed_read
        failed_read = true
        h.view('Alice').fail_next_read = EltenAPI::LiveSessions::TimeoutError.new('rejected start verification')
      end
    end
    original.call(table, force: force)
  end
  screen.singleton_class.prepend(Module.new do
    define_method(:switch_to_new_session) do
      result = super()
      sync = instance_variable_get(:@synchronizer)
      trace << [result, sync.waiting?, sync.recovery_pending?, instance_variable_get(:@new_session_id)]
      result
    end
    define_method(:submit_action) do |replay, **options|
      result = super(replay, **options)
      submitted << result
      result
    end
  end)
  stage, injected_frame, recovering = :inject, nil, false
  Form.driver = lambda do |_form|
    layout = screen.instance_variable_get(:@layout)
    sync = screen.instance_variable_get(:@synchronizer)
    case stage
    when :inject
      if [:real, :masked].include?(mode)
        h.start
        expected_session_id = h.session['__id']
      end
      if mode == :stale_metadata
        original_state = h.view('Alice').stack_state.dup
        h.broker.automatic_delivery = false
        start = JSON.parse(JSON.generate(h.core.entries.find { |entry| entry['packet']['kind'] == 'game_started' }.fetch('packet')))
        start['data']['session_id'] += 50
        expected_session_id = start['data']['session_id']
        h.view('Alice').stack_push(start, message_id: SecureRandom.uuid)
        h.view('Alice').define_singleton_method(:stack_state) { original_state.dup }
      end
      unless mode == :control || mode == :real
        template = h.core.entries.reverse.find { |entry| entry['packet']['kind'] == 'game_started' }.fetch('packet')
        values = mode == :burst ? [true, false, 1, 'teams', {}, [{}], [true], [[0]]] : [{}]
        values.each_with_index do |value, index|
          packet = JSON.parse(JSON.generate(template))
          packet['data']['session_id'] += 100 + index
          packet['data']['options'] = JSON.generate('team_seats' => value) unless mode == :foreign
          actor = mode == :foreign ? 'Bob' : 'Alice'
          packet['actor'] = actor
          h.view(actor).stack_push(packet, message_id: SecureRandom.uuid)
        end
      end
      if mode == :stale_metadata
        # Deliver only the later rejected packet while the valid start remains
        # in the real broker stack. The local advertised sequence is stale.
        entry = h.core.entries.last
        info = NativeLiveSessionsBroker::Info.new(sequence: entry['seq'], id: entry['message_id'], created_at: entry['created_at'])
        h.view('Alice').stack_message(NativeLiveSessionsBroker::Participant.new(user: 'Alice'), entry['packet'], info)
      end
      injected_frame = $help_frames
      stage = :choose
    when :choose
      next if $help_frames < injected_frame + 12
      if mode == :failed_rejected && !recovering
        assert(failed_read && trace.any? { |row| row[0].nil? && row[1] && row[2] && row[3] }, 'A real read failure lost its target or recovery')
        recovering = true
        $help_clock += GameRoomSync::ERROR_BACKOFF + 1
      end
      if mode == :failed_rejected && (sync.recovery_pending? || screen.instance_variable_get(:@new_session_id))
        assert($help_frames < injected_frame + 200, 'A recovered rejected start retained its obsolete target')
        next
      end
      stage = :result
      layout.surface.fields.first.trigger(:select, [0, 0])
    when :result
      next if submitted.empty?
      assert(submitted == [true], "#{mode}: the first legal board gesture was lost or repeated")
      assert(!sync.recovery_pending? && !sync.waiting?, "#{mode}: a rejected notification left an outage")
      assert(screen.instance_variable_get(:@new_session_id).nil?, "#{mode}: the raw start ID survived validation")
      assert(screen.instance_variable_get(:@session)['__id'] == expected_session_id, "#{mode}: the wrong session is displayed")
      assert(screen.instance_variable_get(:@session_runner).is_a?(GameRoomSessionRunner), 'The real worker was not running')
      expected_reads = [:control, :real].include?(mode) ? 0 : 1
      assert(verification_reads.length == expected_reads, "#{mode}: start notifications caused repeated verification or polling")
      snapshots = h.users.map do |user|
        repo = h.repositories.fetch(user)
        current = repo.session_for_table(h.table, force: true)
        assert(current['__id'] == expected_session_id, "#{mode}: clients disagree on the active game")
        repo.snapshot_for(current)
      end
      assert(snapshots.all? { |snapshot| snapshot.events.length == 1 }, "#{mode}: clients did not receive exactly one move")
      boards = snapshots.zip(h.users).map { |snapshot, user| h.game.replay(snapshot.session, snapshot.events, h.repositories[user]).board }
      assert(boards.uniq.length == 1, "#{mode}: native replay diverged")
      stage = :exit
      layout.back_button.trigger(:press)
    when :exit
      layout.back_button.trigger(:press)
    end
  end
  h.as('Alice') { assert(screen.run == :back, "#{mode}: normal departure changed") }
  assert(stage == :exit, "#{mode}: the action assertions were not reached")
  puts "PASS actual GameScreen/runner after #{mode} start"
ensure
  Form.driver = nil
  h&.as('Alice') { h.view('Alice')&.close }
end

[:control, :rejected, :burst, :foreign, :real, :masked, :stale_metadata, :failed_rejected].each do |mode|
  rejected_start_screen_case(mode)
end

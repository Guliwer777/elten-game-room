require_relative '../support/room_interface'

module EltenAPI::Tasks
  def self.run(**options)
    yield nil, options[:cancellation_token] || CancellationToken.new
  end
end

context = {table_id: 7, session_id: 42, actor: 'Alice', owner: 'Alice', membership: Object.new}
[:waiting, :finished].each do |phase|
  [EltenAPI::Tasks::Cancelled, GameRoomNetworkErrors::UncertainWrite].each do |failure|
    layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new)
    layout.session_id = 42
    layout.begin_bindings
    layout.chat.set_text('Keep my draft')
    recovery = []
    sync = Object.new
    sync.define_singleton_method(:waiting?) { false }
    sync.define_singleton_method(:request_recovery!) { |**_| recovery << :requested }
    sync.define_singleton_method(:failed!) { |_| recovery << :failed }
    owner = if phase == :waiting
      EltenGameRoom.allocate.tap do |app|
        app.instance_variable_set(:@table_network_view, {layout: layout, table_id: 7, synchronizer: sync})
      end
    else
      GameScreen.allocate.tap do |screen|
        screen.instance_variable_set(:@layout, layout)
        screen.instance_variable_set(:@table, {'__id' => 7})
        screen.instance_variable_set(:@synchronizer, sync)
      end
    end
    task_method = phase == :waiting ? :run_network_task : :network_task
    attempts = 0
    result = owner.send(task_method, 'Adding computer', silent: true) do
      attempts += 1
      assert(layout.form.game_room_pending_operation.active?, 'The real UI gate is missing')
      4.times { assert(layout.computer_changes.enqueue(:add_bot, **context), 'Could not queue the pending intentions') }
      raise failure, 'The previous write has no confirmed outcome'
    end
    assert(result.nil? && attempts == 1, 'A failed roster operation was automatically repeated')
    assert(layout.computer_changes.take(**context).nil?, 'Recovery retained the following roster commands')
    assert(layout.form.game_room_pending_operation.nil?, 'Recovery retained the form activation gate')
    assert(layout.form.fields.all? { |field| field.game_room_activation_guard.nil? }, 'Recovery retained a control activation gate')
    assert(layout.chat.text == 'Keep my draft', 'Recovery erased the chat draft')
    assert(!recovery.empty? || phase == :waiting && failure == GameRoomNetworkErrors::UncertainWrite,
      'The game lost its normal recovery policy')
  end
end
puts 'PASS computer command recovery: waiting/finished forms, cancelled/uncertain writes, no retries, cleared intentions and retained drafts'

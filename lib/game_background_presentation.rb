require_relative 'host_bridge'
# Presentation belongs to the ACTIVE UI thread, even if it is displaying a
# native Messages/forum scene above Game Room. The model worker only publishes
# copied data. This bridge never ticks host extensions, performs network I/O
# inline or updates a game form. Tournament coordination drains its own finite
# worker here too: the host suspends extension ticks under a parallel scene.
class GameRoomBackgroundPresentation
  def self.attach(screen, program:, runner:, key:)
    new(screen, program: program, runner: runner, key: key).tap(&:register)
  end

  attr_reader :key

  def initialize(screen, program:, runner:, key:)
    @screen, @program, @runner, @key = screen, program, runner, key
    @runtime = program.class.app_runtime if program.class.respond_to?(:app_runtime)
    @closed = false
  end

  def register
    return self unless defined?(::EltenAPI::UI)

    target = ::EltenAPI::UI
    # Host-owned state survives removal of the app namespace on an update.
    # The bridge itself captures NO app classes or callbacks. Only registered,
    # managed, live screens are retained, and close removes their references.
    GameRoomHostBridge.registry(target, key: :@game_room_presenters,
      lock: :@game_room_presenters_lock, initial: []) { |_| }
    GameRoomHostBridge.prepare(target, marker: :@game_room_presentation_bridge)
    # Compile outside the app's lexical scope. A block in #register retains
    # its old namespace through Ruby's constant-resolution context on reload.
    if target.instance_variable_get(:@game_room_presentation_bridge_version) != 1
      TOPLEVEL_BINDING.eval(<<~'RUBY', __FILE__, __LINE__ + 1)
        ::EltenAPI::UI.instance_variable_get(:@game_room_presentation_bridge).module_eval do
          def loop_update(*args, **kwargs, &block)
            result = super(*args, **kwargs, &block)
            if defined?($currentthread) && Thread.current.equal?($currentthread) &&
                !Thread.current.thread_variable_get(:game_room_presenting)
              Thread.current.thread_variable_set(:game_room_presenting, true)
              begin
                host = ::EltenAPI::UI
                items = host.instance_variable_get(:@game_room_presenters_lock).synchronize do
                  host.instance_variable_get(:@game_room_presenters).dup
                end
                items.reject(&:closed?).group_by(&:key).each_value do |group|
                  # The active screen already has its own ordinary presenter.
                  group.last.tick if group.all?(&:covered?)
                end
              ensure
                Thread.current.thread_variable_set(:game_room_presenting, false)
              end
            end
            result
          end
          private :loop_update
        end
      RUBY
      target.instance_variable_set(:@game_room_presentation_bridge_version, 1)
    end
    @host = target
    GameRoomHostBridge.registry(@host, key: :@game_room_presenters,
      lock: :@game_room_presenters_lock, initial: []) { |items| items << self }
    @program.class.manage(self) if @program.class.respond_to?(:manage)
    self
  end

  def closed?; @closed; end
  def covered?; @runner.covered?; end

  def tick
    return if closed? || !covered?
    return unless defined?($currentthread) && Thread.current.equal?($currentthread)

    work = -> {
      if @runner.closed?
        @screen.send(:background_session_closed) if @screen.respond_to?(:background_session_closed, true)
        close
      else
        @screen.send(:present_background_session, @runner)
        @program.class.tournament_coordination_tick if @program.class.respond_to?(:tournament_coordination_tick)
      end
    }
    if @runtime && defined?(Programs) && Programs.respond_to?(:with_runtime)
      Programs.with_runtime(@runtime, &work)
    else
      work.call
    end
    @last_failure = nil
  rescue StandardError => error
    # Never tear down the unrelated scene or flood its log with one failure.
    # Each data packet is consumed once; pending sound queues still advance.
    identity = [error.class, error.message, @runner.presentation_snapshot&.object_id]
    if @last_failure != identity
      Log.warning("ELTEN Game Room background presentation failed: #{error.class}: #{error.message}") if defined?(Log)
      @last_failure = identity
    end
  end

  def close
    return if @closed
    @closed = true
    if @host
      GameRoomHostBridge.registry(@host, key: :@game_room_presenters,
        lock: :@game_room_presenters_lock, initial: []) { |items| items.delete(self) }
    end
    @program.class.release(self) if @program.class.respond_to?(:release)
    @screen = @runtime = nil
  end
end

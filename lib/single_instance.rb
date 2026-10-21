require "thread"

# Process-local UI ownership; not a restriction on server memberships/accounts.
# Focus uses the same switch request as ELTEN's Windows menu, without restarting
# the scene or invoking its main method for a second time.
module GameRoomSingleInstance
  @lock = Mutex.new
  @active = nil

  class << self
    # Read-only ownership snapshot for worker-side busy checks. This does not
    # focus a window, take input or transfer ownership to the widget instance.
    def active_program
      @lock.synchronize{@active && @active[:thread].alive? ? @active[:program] : nil}
    end

    def enter(program, method, arguments, launch: false)
      owner = @lock.synchronize do
        @active = nil if @active && !@active[:thread].alive?
        if @active
          @active
        elsif !launch
          requests = program.instance_variable_get(:@game_room_initial_requests) || []
          program.instance_variable_set(:@game_room_initial_requests, nil)
          @active = {program: program, thread: Thread.current, entry: method, requests: requests}
          program.instance_variable_set(:@game_room_redirected, false)
          nil
        end
      end
      if owner
        return yield if !launch && owner[:program].equal?(program) && owner[:thread].equal?(Thread.current) &&
          (program.instance_variable_get(:@game_room_dispatching_entry) ||
            (owner[:entry] == :notification_action && method == :open_widget_table))
        @lock.synchronize do
          if method != :program_main && @active.equal?(owner)
            request = [method, arguments]
            owner[:requests] << request unless owner[:requests].include?(request) || owner[:requests].size >= 8
          end
        end
        program.instance_variable_set(:@game_room_redirected, true) unless owner[:program].equal?(program)
        if defined?($mainthread) && $mainthread && !Thread.current.equal?($mainthread) &&
            !owner[:thread].equal?(Thread.current)
          # ELTEN creates the parallel launch before entering the program. Its
          # switcher can retain that thread in Windows even after it has exited.
          # Mark only our redirected launch; never retire a living host window.
          Thread.current.thread_variable_set(:game_room_redirected_launch, true)
        end
        $switchthread = owner[:thread] unless owner[:thread].equal?(Thread.current)
        $focus = true
        return true
      end
      if launch
        # A widget callback belongs to Scene_Main. Return to its loop before
        # opening a long-lived form, so Core owns the scene and its lifetime.
        # Never launch the widget's reusable service instance: Core finalizes
        # each launched instance when its interaction ends.
        scene = program.class.new
        scene.instance_variable_set(:@game_room_initial_entry, [method, arguments])
        return program.__send__(:insert_scene, scene, true)
      end
      begin
        if program.respond_to?(:prepare_game_room_update, true) && program.__send__(:prepare_game_room_update, method, arguments)
          return true
        end
        # Direct table entries bypass the ordinary lobby loop. Give them the
        # same table-switch boundary as normal launches and invitations.
        switched = catch(:game_room_table_switch) { [:completed, yield] }
        if switched.is_a?(Array) && switched.first == :completed
          switched.last
        else
          program.__send__(:run_program_interface, switched)
        end
      ensure
        finish_update(program) unless program.instance_variable_get(:@game_room_update_scene)
      end
    end

    def finish_update(program)
      @lock.synchronize do
        return [] unless @active && @active[:program].equal?(program)
        requests = @active[:requests]
        @active = nil
        requests
      end
    end

    def take(program)
      @lock.synchronize do
        return nil unless @active && @active[:program].equal?(program) && @active[:thread].equal?(Thread.current)
        @active[:requests].shift
      end
    end

    def discard_finished_launches
      return unless defined?($currentthread) && Thread.current.equal?($currentthread)
      return unless defined?($subthreads) && $subthreads

      # Run on an ordinary UI update after the switch, not inside finalize:
      # the host may add the finished launch to its list after finalize returns.
      $subthreads.delete_if do |thread|
        !thread.equal?($mainthread) && !thread.equal?($currentthread) &&
          thread.thread_variable_get(:game_room_redirected_launch) && !thread.alive?
      end
    end
  end

  module EntryPoints
    def cleanup_game_room_launches
      GameRoomSingleInstance.discard_finished_launches
    end

    def launch_game_room_entry(entry, *arguments)
      GameRoomSingleInstance.enter(self, entry, arguments, launch: true)
    end

    def program_main
      request = @game_room_initial_entry
      @game_room_initial_entry = nil
      # The ordinary entry guard still handles a different window which may
      # have acquired ownership since the native launch was requested.
      return __send__(request[0], *request[1]) if request

      GameRoomSingleInstance.enter(self, :program_main, []) { super }
    end

    [:notification_action, :open_widget_table, :create_table_from_widget, :accept_invitation_from_widget, :open_tournaments_from_widget, :open_tournament_browser_from_widget].each do |entry|
      define_method(entry) do |*arguments|
        GameRoomSingleInstance.enter(self, entry, arguments) { super(*arguments) }
      end
    end

    def dispatch_game_room_entry
      return if @game_room_dispatching_entry
      return if @table_network_view&.dig(:layout)&.form&.game_room_pending_operation
      request = GameRoomSingleInstance.take(self)
      return unless request
      begin
        @game_room_dispatching_entry = true
        __send__(request[0], *request[1])
      ensure
        @game_room_dispatching_entry = false
      end
    end

    def run_program_interface(row = nil)
      throw(:game_room_table_switch, row) if @game_room_dispatching_entry && row
      super
    end

    def show_table_screen(row)
      throw(:game_room_table_switch, row) if @game_room_dispatching_entry
      super
    end

    def finalize(value = nil, reason: :normal)
      if (update = @game_room_update_scene)
        @game_room_update_scene = nil
        finalized = false
        begin
          result = super(value, reason: reason == :error ? :error : :notification)
          finalized = true
          $scene = update unless reason == :error
          return result
        ensure
          GameRoomSingleInstance.finish_update(self) if reason == :error || !finalized
        end
      end
      return super unless @game_room_redirected
      # Program#finalize closes the class-wide sound pool. A discarded launch
      # must not silence the actual owner or announce that it has been closed.
      @program_finalized = true
      $scene = Scene_Main.new unless reason == :error
      value
    end
  end
end

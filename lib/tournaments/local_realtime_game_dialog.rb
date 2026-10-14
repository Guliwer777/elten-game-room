require_relative 'local_game_choice_dialog'
require_relative 'realtime_point_input'
require_relative '../game_room_background'
require_relative '../realtime/timer'
require_relative '../game_shortcut_bindings'
require_relative 'local_game_events'

module GameRoomTournaments
  class MatchEntryScreen
    class RealtimeGame < LocalTestDialogs::Window
      include LeaseWindow
      using GameRoomLocalization::Translations
      def initialize(program:, controller:, selectors:, result:, context:, lease:, services: {})
        @program, @controller, @selectors, @context, @lease = program, controller, selectors, context, lease
        @projection, @status = result.values_at(:effect, :status)
        @services = services
      end
      def run
        super
      ensure
        begin
          @changes&.close
          @subscription&.close
          @entry_timer&.stop
          @form.delete_timer(@entry_timer) if @form && @entry_timer
          @work&.close
        ensure
          @bridge&.close
        end
      end
      private
      def build_form
        require_relative '../game_surfaces'
        @game = @projection[:registry].build(@projection[:request].to_h['game_id'])
        @viewer = @projection[:viewer]
        @surface = GameSurfaces.build(@game.surface_spec(@projection[:replay], @viewer))
        @surface.action_guard = -> { @context.current?(@lease) }
        team_match = @projection[:request].to_h['players'].any? { |person| person['team'] }
        @status_field = readonly(team_match ? _("Fixed-team execution status") : _("Individual execution status"), '')
        check = button(_("Check status")) { request_refresh }
        finalize = button(_("Save finished local match result")) do
          begin_work(action: :finalize_local_game, revision: @status['revision']) if @status && @status['finished']
        end
        back = button(_("Back"))
        make_form(@surface.fields + [@status_field, check, finalize, back], cancel: back)
        unless @services[:channel_factory] || (defined?(Session) && Session.respond_to?(:name) &&
            Publication::Data.account(Session.name).downcase == @viewer.downcase)
          @blocked = true
          @status_field.set_text(_("The realtime game view must use your signed-in account."))
          return
        end
        @work = GameRoomBackground::Work.new(runtime: @program.class.app_runtime)
        @bridge = RealtimeMatchClient.new(program: @program, request: @projection[:request], native: @projection[:native],
          registry: @projection[:registry], viewer: @viewer, snapshot: -> { @projection }, services: @services)
        unless @bridge.start
          finish
          return
        end
        @bridge.attach_view(@form, @surface)
        bind_realtime_shortcuts
        @changes = LocalGameEvents::Pending.new
        @subscription = LocalGameEvents.subscribe(@projection.fetch(:change_identity), @changes)
        # Close the gap between the caller's initial read and subscribing.
        @changes.signal
        @entry_timer = GameRoomRealtime::Timer.new(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }) { advance_entry }
        @form.add_timer(@entry_timer)
        present_status
      end
      def request_refresh
        return if @blocked
        if @intent
          if @last_result && @last_result[:state] == :unknown
            begin_work(action: :local_game_move, **@intent)
          else
            begin_work(action: :local_move_status, operation_id: @intent[:operation_id])
          end
        else
          begin_work(action: :local_realtime_view)
        end
      end
      def bind_realtime_shortcuts
        require_relative '../game_layout'
        @form.extend(GameRoomLayout::ShortcutFormBehavior)
        shortcuts = GameRoomShortcutBindings.normalize(@game.game_shortcuts(@projection[:replay], @viewer))
        shortcuts = shortcuts.select { |item| [:surface, :announcement].include?(item.kind) }
        consume = lambda do |key|
          getkeychar if key.to_s.length == 1 || key.to_s == 'space'
          EltenAPI::KeyboardState.clear_current_frame if defined?(EltenAPI::KeyboardState)
        end
        GameRoomShortcutBindings.bind(@form, @surface.fields, shortcuts, consume: consume) do |shortcut|
          next if @blocked || @finished || !@context.current?(@lease)
          current = @game.game_shortcuts(@projection[:replay], @viewer).find do |item|
            item.key == shortcut.key && item.modifiers.to_a == shortcut.modifiers.to_a
          end
          next unless current
          if current.kind == :surface
            @surface.handle_command(current.action_name, current.payload)
          elsif current.kind == :announcement
            speak(current.message) unless current.message.to_s.empty?
          end
        end
      end
      def begin_work(**input)
        return if @pending || @finished || !@context.current?(@lease)
        @changes&.take if input[:action] == :local_realtime_view
        @pending = input.freeze
        started = @work.start do
          value = @controller.perform(**input, selectors: @selectors)
          result = value[:local_game] || value[:realtime_surface]
          view = result && [:confirmed, :unknown].include?(result[:state]) ?
            @controller.perform(action: :local_realtime_view, selectors: @selectors)[:realtime_surface] : nil
          [result, view]
        end
        raise 'Realtime worker refused an operation' unless started
      rescue Exception
        @pending = nil
        raise
      end
      def advance_entry
        return if @blocked || @finished || !@context.current?(@lease)
        if @pending && (outcome = @work.take)
          value, error = outcome
          raise error, cause: error.cause if error
          @pending = nil
          result, view = value
          @status = result[:status] if result && result[:status]
          @status = view[:status] if view && view[:state] == :confirmed && view[:status]
          @projection = view[:effect] if view && view[:state] == :confirmed
          @bridge.refresh if view
          @intent = nil if result && result[:state] == :confirmed
          @last_result = result
          present_status
        end
        return if @pending || @intent || @status&.[]('finished')
        if @changes.take
          begin_work(action: :local_realtime_view)
          return
        end
        automatic = @status && @status['actions'].find { |selection| selection['kind'] == 'command' && selection['action'] != @game.tournament_realtime_point_action }
        if automatic
          @intent = {operation_id: "realtime-start-#{@projection[:session]['__id']}",
            revision: @status['revision'], move_selection: automatic}.freeze
          begin_work(action: :local_game_move, **@intent)
          return
        end
        input = RealtimePointInput.capture(@bridge)
        return unless input
        @intent = {operation_id: "realtime-#{input.to_h['session_id']}-#{input.to_h['selection']['point']}",
          revision: @status.fetch('revision'), move_selection: input.to_h['selection'], realtime_input: input}.freeze
        begin_work(action: :local_game_move, **@intent)
      end
      def present_status
        message = @status ? @status['phase_label'].to_s : ''
        if @last_result && [:uncertain, :unknown].include?(@last_result[:state])
          message = [message, _("Move result is uncertain. Check original local move before submitting another move.")].reject(&:empty?).join("\n")
        elsif @last_result && @last_result[:state] == :blocked
          message = [message, _("The local result cannot be confirmed. Data has not been replaced. Read the original operation; do not send again.")].reject(&:empty?).join("\n")
        end
        @status_field.set_text(message)
      end
    end
  end
end

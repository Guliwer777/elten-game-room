# encoding: UTF-8
require_relative 'local_test_dialogs'
require_relative 'match_entry'
require_relative 'local_readiness_screen'

module GameRoomTournaments
  class MatchEntryScreen < LocalTestDialogs::Window
    using GameRoomLocalization::Translations
    include LocalReadinessScreen
    attr_reader :controller

    # Ochrona należy tylko do kontrolek tego wejścia. Natywny stos aktualizacji
    # jest przerywany po utracie lease, także po callbacku before_focus/move.
    module LeaseControl
      attr_accessor :entry_form
      def focus(*args)
        entry_form.entry_boundary do
          entry_form.restore_entry_presentation
          super
        end
      end
      def update(*args)
        entry_form.entry_boundary { super }
      end
      def trigger(*args)
        entry_form.entry_boundary do
          result = super
          entry_form.restore_entry_presentation if args.first == :before_focus
          result
        end
      end
      def on(*args, &callback)
        super(*args) { |*values| entry_form.entry_boundary { callback.call(*values) } }
      end
    end
    private_constant :LeaseControl

    class EntryForm < GameRoomUI::Form
      attr_writer :hub_interaction, :readiness_tick, :entry_presentation
      def initialize(fields, context:, lease:, on_expire: nil, **options)
        @entry_context, @entry_lease, @entry_on_expire = context, lease, on_expire
        @entry_abort = Object.new
        @entry_depth = 0
        fields.each do |field|
          field.singleton_class.prepend(LeaseControl)
          field.entry_form = self
        end
        super(fields, **options)
      end

      def entry_boundary
        if @entry_depth > 0 && @entry_fiber.equal?(Fiber.current)
          check_entry!
          value = yield
          check_entry!
          return value
        end
        previous_depth, previous_fiber = @entry_depth, @entry_fiber
        catch(@entry_abort) do
          begin
            @entry_depth, @entry_fiber = 1, Fiber.current
            check_entry!
            value = yield
            check_entry!
            value
          ensure
            @entry_depth, @entry_fiber = previous_depth, previous_fiber
          end
        end
      end

      # Domyślnie brak dodatkowej prezentacji; FT2 odtwarza swój pełny wybór.
      def restore_entry_presentation
        @entry_presentation&.call
      end

      def focus(*args)
        entry_boundary do
          restore_entry_presentation
          super
        end
      end
      def update
        entry_boundary do
          @readiness_tick&.call
          super
        end
      end
      def trigger(*args)
        entry_boundary { super }
      end
      def on(*args, &callback)
        super(*args) { |*values| entry_boundary { callback.call(*values) } }
      end
      def wait
        return unless entry_boundary { true }
        super
      end
      def resume
        @entry_ended = true
        super
      end
      def show_game_room_help
        entry_boundary do
          @hub_interaction ? @hub_interaction.call { super } : super
        end
      end
      def game_room_hotkey_action(key)
        action = super
        GameRoomUI::HotkeyAction.new(-> { entry_boundary { action.call } }) if action
      end

      private

      def check_entry!
        current = @entry_context.current?(@entry_lease)
        return if !@entry_ended && current
        @entry_ended = true
        callback, @entry_on_expire = @entry_on_expire, nil
        callback&.call unless current
        resume_for_refresh
        throw @entry_abort
      end
      def build_game_room_help_form(fields)
        EntryForm.new(fields, program: game_room_program, quiet: true,
          context: @entry_context, lease: @entry_lease, on_expire: @entry_on_expire)
      end
      def restore_game_room_help_focus(field)
        super unless @hub_interaction
      end
    end
    private_constant :EntryForm

    module LeaseWindow
      private
      def interaction(**options)
        primary = nil
        begin
          super(**options) do
            begin
              yield
            rescue Exception => error
              # Zapisz primary przed ensure bazowego Window, nie dopiero po nim.
              primary = error
              raise error, cause: error.cause
            end
          end
        ensure
          # Lokalny throw podczas odtwarzania fokusu nie może połknąć primary.
          raise primary, cause: primary.cause if primary
        end
      end

      def make_form(fields, cancel:)
        @form = EntryForm.new(fields, program: @program, quiet: true, context: @context, lease: @lease,
          on_expire: -> { @finished = true })
        @form.hub_interaction = method(:interaction)
        @form.cancel_button = cancel
        cancel.on(:press) { interaction { finish } }
        @form
      end
    end
    private_constant :LeaseWindow
    include LeaseWindow

    def initialize(program:, workspace:, owner:, controller: nil)
      @program, @workspace, @owner, @controller = program, workspace, owner, controller
    end

    def run
      return if @running || @finished
      context = @controller&.context
      primary = nil
      begin
        unless @controller
          context = EntryContext.new(program: @program, runtime: @program.class.app_runtime,
            owner_reader: @owner.method(:current), actor: @workspace.actor,
            account_events: local_readiness? ? @workspace.readiness_session.actor_events : nil)
          @controller = MatchEntry.new(workspace: @workspace, context: context)
        end
        @context = context
        @lease = context.capture
        super
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          context&.cleanup(primary: primary, phase: :readiness_close) { @controller&.close }
        ensure
          begin
            context&.cleanup(primary: primary, phase: :readiness_work_close) { @readiness_work&.close }
          ensure
            context&.close(primary: primary)
            raise primary, cause: primary.cause if primary
          end
        end
      end
    end

    private

    def finish(result = nil)
      primary = nil
      begin
        @controller.close
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          @context.cleanup(primary: primary, phase: :finish_resume) { super }
        ensure
          # Resume pompuje callbacki; lokalny throw lease też nie zastępuje primary.
          raise primary, cause: primary.cause if primary
        end
      end
    end

    def current?
      @controller.context.current?(@lease)
    end

    # Powrót z modalu należy do tego wejścia, nie do zakończonego workera.
    def interaction(restore: true)
      return if @busy || @readiness_pending || @finished
      @busy = true
      previous = @form&.index
      tournament_id = selected_id if @tournaments
      match_id = @controller.view[:matches][@matches.index]&.fetch('match_id') if @matches
      positions = @form ? @form.fields.filter_map do |field|
        [field, field.index, field.check] if field.is_a?(EditBox)
      end : []
      primary = nil
      begin
        if current?
          yield
        else
          finish
        end
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          @context.cleanup(primary: primary, phase: :interaction_restore) do
            if !@finished && @form && current?
              if restore
                index = @controller.view[:tournaments].index { |row| row.fetch('__id') == tournament_id }
                @tournaments.index = index if index && current?
                index = @controller.view[:matches].index { |row| row.fetch('match_id') == match_id }
                @matches.index = index if index && current?
                positions.each do |field, index, check|
                  break unless current?
                  field.index = index
                  field.check = check if field.is_a?(EditBox)
                end
                @form.index = previous unless previous.nil? || !current?
              end
              @form.index = @form.fields.index(@status) if @explanation && current?
              @explanation = false
              @form.focus if current?
            end
          end
        ensure
          @busy = false
          raise primary, cause: primary.cause if primary
        end
      end
    end

    def build_form
      @tournaments = ListBox.new([], header: text(_("My tournaments")), quiet: true)
      @matches = ListBox.new([], header: text(_("My matches")), quiet: true)
      @status = readonly(_("Readiness and coordination"), _("Use Check status to read your confirmed registrations. No readiness or coordination will be sent."))
      details = button(_("View details")) { preview }
      refresh_button = button(_("Check status")) { refresh }
      ready = button(_("Declare readiness")) { @controller.declare_ready; explain_unavailable }
      now = button(_("Propose playing now")) { @controller.propose_now; explain_unavailable }
      back = button(_("Back"))
      if local_readiness?
        build_readiness_controls(details, refresh_button, now, back)
      else
        make_form([@tournaments, @matches, @status, details, refresh_button, ready, now, back], cancel: back)
      end
      @form.accept_button = details
      @tournaments.on(:move) { interaction(restore: false) { refresh } }
      @form.game_room_general_help_tips = [@status.text]
    end

    def explain_unavailable
      return unless current?
      @status.set_text(status_text)
      @explanation = true
    end

    def selected_id
      @controller.view[:tournaments][@tournaments.index]&.fetch('__id')
    end

    def refresh
      view = @controller.refresh(selected_id: selected_id)
      return unless view && current?
      @tournaments.update_options(view[:tournaments].map { |row| text(row.fetch('title')) },
        keys: view[:tournaments].map { |row| row.fetch('__id') })
      return unless current?
      @tournaments.index = view[:tournaments].index { |row| row.fetch('__id') == view[:selected_id] } || 0
      return unless current?
      @matches.update_options(view[:matches].map { |match| match_text(match) },
        keys: view[:matches].map { |match| match.fetch('match_id') })
      @status.set_text(status_text) if current?
      start_readiness(:inspect) if local_readiness? && current?
    end

    def status_text
      return local_readiness_status if local_readiness?
      [entry_reason_text, text(_("Readiness is not confirmed. This candidate is not a final plan. Roles are unassigned. Readiness writes and match coordination are unavailable; no match can be started."))].join("\r\n")
    end

    def entry_reason_text(reason = @controller.reason)
      message = case reason
      when :not_read then _("Use Check status to read your confirmed registrations. No readiness or coordination will be sent.")
      when :no_membership then _("No confirmed registration for this test participant. Viewing does not join a tournament.")
      when :registration_open then _("Registration is still open. A schedule candidate cannot be calculated yet.")
      when :no_players, :too_few_players then _("There are too few confirmed participants for a complete match.")
      when :too_many_players, :plan_too_large then _("The confirmed roster exceeds the schedule candidate limit.")
      when :unsupported_format then _("This tournament format does not support a schedule candidate.")
      when :invalid_group_configuration then _("The confirmed roster does not fit the group settings. Check the number of groups, players per match and qualifying places.")
      when :unresolved_source_diagnostics then _("The registration source contains unresolved conflicts. The last valid view is retained.")
      when :missing_publication then _("The publication is no longer confirmed. The last valid view is retained.")
      when :read_failed then _("The status could not be read completely. The last valid view is retained.")
      when :history
        case @controller.readback_result.fetch(:state)
        when :bound then _("The original match binding is confirmed. This does not authorize starting the match.")
        when :pending then _("The original coordination operation is pending. Check again without sending a new operation.")
        when :unknown then _("The original coordination result is unknown. Check again without sending a new operation.")
        when :reserved then _("The original reservation is confirmed. No table creation or start was requested.")
        else _("The original coordination operation cannot be confirmed in this context. No new operation was sent.")
        end
      when :candidate then _("This is an observed candidate, not a final plan.")
      else raise ArgumentError, "Nieznany stan odczytu: #{reason}"
      end
      text(message)
    end

    def match_text(match)
      text(_("Match %{number}, leg %{leg}: %{players}")) % {number: match.fetch('number'),
        leg: match.fetch('leg'), players: match.fetch('players').join(', ')}
    end

    def show_local_plan(candidate)
      PlanApproval.new(program: @program, content: local_plan_text(candidate), context: @context, lease: @lease).run
    end

    def preview
      match = @controller.view[:matches][@matches.index]
      return unless match
      candidate = @controller.view[:candidate]
      content = [match_text(match), text(_("Game: %{game}")) % {game: candidate.fetch('game_id')},
        text(_("Options: %{options}")) % {options: candidate.fetch('game_options').to_json},
        text(_("Windows: %{windows}")) % {windows: candidate.fetch('windows').to_json},
        text(_("Match ID: %{id}")) % {id: match.fetch('match_id')}, @status.text].join("\r\n")
      Details.new(program: @program, content: content, context: @context, lease: @lease).run
    end

    class Details < LocalTestDialogs::Window
      using GameRoomLocalization::Translations
      include LeaseWindow
      def initialize(program:, content:, context:, lease:)
        @program, @content, @context, @lease = program, content, context, lease
      end
      private
      def build_form
        details = readonly(_("Match details"), @content)
        back = button(_("Back"))
        make_form([details, back], cancel: back)
        @form.accept_button = back
      end
    end
    class PlanApproval < Details
      using GameRoomLocalization::Translations
      private
      def build_form
        details = readonly(_("Local test plan"), @content)
        accept = button(_("Accept local test plan")) { finish(true) }
        back = button(_("Cancel"))
        make_form([details, accept, back], cancel: back)
        @form.game_room_general_help_tips = [text(_("Only Accept local test plan saves this local trial. Enter on the text does not accept. Escape cancels."))]
      end
    end
    private_constant :Details, :PlanApproval
  end
end

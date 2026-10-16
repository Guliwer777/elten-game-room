# encoding: UTF-8
require_relative 'window_fields'
require_relative 'local_registration_time'
require_relative 'local_fixed_team_execution_ui_modal'

module GameRoomTournaments
  class LocalFixedTeamExecutionScreen
    using GameRoomLocalization::Translations
    class Details < MatchEntryScreen.const_get(:Details, false)
      include LocalFixedTeamExecutionUIModal
    end
    private_constant :Details

    class Standings < Details
      using GameRoomLocalization::Translations
      private
      def build_form
        content = readonly(_("Tournament standings"), @content)
        back = button(_("Back"))
        make_form([content, back], cancel: back)
        @form.accept_button = back
      end
    end
    private_constant :Standings

    class KnockoutSeeds < Details
      using GameRoomLocalization::Translations
      def initialize(qualified:, **options)
        @qualified = qualified
        super(**options)
      end
      private
      def build_form
        qualified = readonly(_("Qualified units"), @content)
        instructions = readonly(_("Knockout seeding"), _("Enter the seed order explicitly, one qualified unit per line. The first seeds receive any byes. Preview does not accept or start a match."))
        @seeds = EditBox.new(text(_("Knockout seed order (one qualified unit per line)")),
          type: EditBox::Flags::MultiLine, text: '', max_length: 20000, quiet: true)
        @notice = readonly(_("Status"), '')
        preview = button(_("Preview knockout round")) { submit }
        cancel = button(_("Cancel"))
        make_form([qualified, instructions, @seeds, @notice, preview, cancel], cancel: cancel)
        @form.accept_button = preview
      end
      def submit
        seeds = text(@seeds.text).split(/\r?\n/).map(&:strip).reject(&:empty?)
        unless seeds.size == @qualified.size && seeds.uniq == seeds && (seeds - @qualified).empty?
          @notice.set_text(text(_("Enter every qualified unit exactly once in the chosen seed order.")))
          return
        end
        finish(Publication::Data.freeze_tree(Publication::Data.copy(seeds)))
      end
    end
    private_constant :KnockoutSeeds

    # Istniejący WindowFields i ochrona modalu, bez nowej pętli albo formatu daty.
    class Deadline < Details
      using GameRoomLocalization::Translations
      def initialize(window:, **options)
        @window = window
        super(**options)
      end
      private
      def build_form
        summary = readonly(_("Technical local trial deadline"), @content)
        @notice = readonly(_("Status"), _("Choose a date and time inside the selected window. This is not an invitation TTL or tournament rule."))
        @parts = WindowFields.new(date: nil, time: nil, start: false, notice: ->(message) { @notice.set_text(message) })
        use = button(_("Use technical deadline")) { choose }
        back = button(_("Cancel"))
        make_form([summary, *@parts.fields, @notice, use, back], cancel: back)
        @parts.bind(@form)
      end
      def choose
        value = LocalRegistrationTime.convert(@parts.date, @parts.time)
        unless @window['opens'] < value && value <= @window['closes']
          @notice.set_text(text(_("The technical deadline must be inside the selected execution window.")))
          return
        end
        finish(value)
      rescue LocalRegistrationTime::Invalid
        @notice.set_text(text(_("Select every date and time field. Ambiguous or nonexistent local times are not accepted.")))
      end
    end
    private_constant :Deadline

    private
    def choose_deadline
      selection = selectors
      return unless selection
      match = @controller.view[:matches][@matches.index]
      window = match['windows'][@windows.index]
      content = [match_text(match), text(_("Technical policy: %{policy}")) % {policy: connection_policy},
        text("#{Time.at(window['opens']).getlocal} — #{Time.at(window['closes']).getlocal}")].join("\r\n")
      value = Deadline.new(program: @program, content: content, context: @context, lease: @lease, window: window).run
      return unless current?
      # Natywne resume pompuje callbacki. Przywróć cel przed tekstem i fokusem
      # wspólnego interaction; nie wykonuj tu drugiej prezentacji fokusu.
      @matches.index = @controller.view[:matches].index { |row| row['match_id'] == selection[:match_id] }
      update_windows
      @windows.index = match['windows'].index { |row| row['id'] == selection[:window_id] }
      @deadline = {selectors: selection, value: value}.freeze if value
      @status.set_text(status_text)
    end

    def target_text(target)
      data = target.to_h
      binding, native, receipt, readback = data.values_at('binding', 'native', 'receipt', 'readback')
      people = binding['players'].map do |person|
        text(_("Planned player: %{name}; account: %{account}; team: %{team}; seat: %{seat}")) % {
          name: person['username'], account: person['account'], team: person['team'], seat: person['seat']}
      end
      [text(_("Confirmed private local target. Only its creator is present; no player consent or tournament entry was recorded.")),
        text(_("Game: %{game}")) % {game: binding['game_id']}, *people,
        text(_("Target: table %{table}; native UUID %{native}; owner %{owner}")) % {table: binding['table_id'], native: binding['native_uuid'], owner: readback['table']['owner']},
        text(_("Leg %{leg}; window %{window}; execution generation %{generation}")) % {leg: binding['leg'], window: @controller.view.fetch(:selection).fetch(:window_id), generation: binding['execution_generation']},
        text(_("Public digest: %{digest}")) % {digest: receipt['request_digest']},
        text(_("Native digest: %{digest}")) % {digest: receipt['native_digest']},
        text(_("Create UUID: %{id}; proof: %{proof}")) % {id: receipt['operation_id'], proof: receipt['proof_ref']},
        text(_("Native options: %{options}")) % {options: JSON.generate(native['options'])}].join("\r\n")
    end
  end
end

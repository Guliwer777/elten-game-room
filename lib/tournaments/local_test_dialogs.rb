# encoding: UTF-8
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative 'publication'
require_relative 'draft_preview'

module GameRoomTournaments
  # Wspólny lifecycle tylko nowych okien huba. Pomoc i klawisze pozostają
  # własnością GameRoomUI; otoczka chroni także modal, resume i powrót fokusu.
  module LocalTestDialogs
    # Zatrzask należy do całego wejścia, nie do aktualnie wybranego aktora.
    class Owner
      using GameRoomLocalization::Translations
      def initialize(user, alert)
        @user, @alert = user, alert
        @owner = account
        @changed = @owner.nil?
      end

      # Czytnik dla Tasks/workspace: wyłącznie tożsamość realnego konta,
      # bez alertu z workera. Zmiana pozostaje zapamiętana także po powrocie
      # starego konta w callbacku alertu; nil blokuje istniejące workspaces.
      def current
        value = Publication::Data.account(@user.call)
        @changed = true unless value.downcase == @owner
        @changed ? nil : value
      rescue Publication::Invalid
        @changed = true
        nil
      end

      def check
        current
        return true unless @changed
        @alert.call(GameRoomContent.utf8(_("The account changed. Close this window and reopen local tournament tests.")))
        false
      end

      private

      def account
        Publication::Data.account(@user.call).downcase.freeze
      rescue Publication::Invalid
        nil
      end
    end

    class Window
      using GameRoomLocalization::Translations

      class Form < GameRoomUI::Form
        attr_writer :hub_interaction
        def show_game_room_help
          @hub_interaction.call { super }
        end

        private

        def restore_game_room_help_focus(_field)
          # interaction odtworzy pole/kursory przed jedynym Form#focus pod busy.
          nil
        end
      end
      private_constant :Form

      def run
        return @result if @running || @finished
        @running = true
        begin
          interaction { build_form }
          @form.wait_without_announcement if @form && !@finished
          @result
        ensure
          @running = false
          @finished = true
        end
      end

      private

      def make_form(fields, cancel:)
        @form = Form.new(fields, program: @program, quiet: true)
        @form.hub_interaction = method(:interaction)
        @form.cancel_button = cancel
        cancel.on(:press) { interaction { finish } }
        @form
      end

      def interaction(restore: true)
        return if @busy || @finished
        @busy = true
        previous = @form&.index
        positions = @form ? @form.fields.filter_map do |field|
          if field.is_a?(ListBox)
            [field, field.index, nil]
          elsif field.is_a?(EditBox)
            [field, field.index, field.check]
          end
        end : []
        begin
          yield
        ensure
          begin
            unless @finished || !@form
              if restore
                positions.each do |field, index, check|
                  field.index = index
                  field.check = check if field.is_a?(EditBox)
                end
                @form.index = previous unless previous.nil?
              end
              @form.focus
            end
          ensure
            @busy = false
          end
        end
      end

      def finish(result = nil)
        @result = result
        @finished = true
        @form.resume
      end

      def readonly(header, value)
        EditBox.new(text(header), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
          text: text(value), quiet: true)
      end

      def button(label, &action)
        Button.new(text(label)).tap { |control| control.on(:press) { interaction(&action) } if action }
      end

      def text(value)
        GameRoomContent.utf8(value)
      end
    end

    class DraftPicker < Window
      using GameRoomLocalization::Translations

      def initialize(program:, registry:, rows:, owner:, alert:, context:, publish:)
        @program, @registry, @rows, @owner, @alert = program, registry, rows, owner, alert
        @context, @publish = context, publish
      end

      private

      def build_form
        @list = ListBox.new([], header: text(_("Choose a local draft")), quiet: true)
        @list.update_options(@rows.map { |row| text(row.fetch('name')) }, keys: @rows.map { |row| row.fetch('id') })
        details = readonly(_("Local test publication"), [@context,
          text(_("Enter on the list only views the draft. Use Publish to open publication settings.")),
          text(_("Each draft revision is a separate publication intent. Editing a draft creates a new revision; reopening the same revision does not send again."))].join("\r\n"))
        view = button(_("View")) { preview if @owner.check }
        publish = button(_("Publish")) { @publish.call(selected) if selected && @owner.check }
        cancel = button(_("Cancel"))
        make_form([@list, details, view, publish, cancel], cancel: cancel)
        @form.accept_button = view
        @form.game_room_general_help_tips = [details.text]
      end

      def selected
        @rows[@list.index]
      end

      def preview
        return unless selected
        DraftPreview.new(program: @program, registry: @registry, draft: selected, alert: @alert).wait
        @owner.check
      end
    end

    class Participant < Window
      using GameRoomLocalization::Translations

      def initialize(program:, owner:, alert:)
        @program, @owner, @alert = program, owner, alert
      end

      private

      def build_form
        summary = readonly(_("Choose a test participant"),
          _("Local test — data on this computer only. A test participant name does not authenticate a network account."))
        @name = EditBox.new(text(_("Test participant name")), text: '', quiet: true)
        use = button(_("Use test participant"))
        cancel = button(_("Cancel"))
        make_form([summary, @name, use, cancel], cancel: cancel)
        use.on(:press) { interaction(restore: false) { choose } }
        @form.game_room_general_help_tips = @form.game_room_text_help_tips = [summary.text]
      end

      def choose
        return unless @owner.check
        actor = Publication::Data.account(@name.text).freeze
        finish(actor)
      rescue Publication::Invalid
        @alert.call(text(_("Enter a test participant name (1-64 characters, no leading or trailing whitespace or control characters).")))
        @form.index = @form.fields.index(@name)
      end
    end
  end
end

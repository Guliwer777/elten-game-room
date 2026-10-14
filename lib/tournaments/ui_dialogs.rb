# encoding: UTF-8
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative 'publication'

module GameRoomTournaments
  # Wspólny lifecycle tylko nowych okien huba. Pomoc i klawisze pozostają
  # własnością GameRoomUI; otoczka chroni także modal, resume i powrót fokusu.
  module Dialogs
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
        @alert.call(GameRoomContent.utf8(_("The account changed. Close tournaments and reopen them.")))
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

  end
end

# encoding: UTF-8
require_relative 'local_test_dialogs'
require_relative 'match_entry_screen'
require_relative 'game_selection'
module GameRoomTournaments
  class MatchEntryScreen
    class GameChoice < LocalTestDialogs::Window
      include LeaseWindow
      using GameRoomLocalization::Translations
      def initialize(program:, spec:, guard:, context:, lease:)
        @program, @spec, @guard, @context, @lease = program, spec, guard, context, lease
      end
      private
      def build_form
        require_relative '../game_surfaces'
        @surface = GameSurfaces.build(@spec)
        @surface.action_guard = @guard
        @surface.on_action do |action|
          next unless @guard.call
          if action.kind.to_s == 'surface' && action.name.to_s == 'refresh'
            @form.replace_fields(@surface.fields + [@back])
            @form.index = 0
            @form.focus
          else
            finish(GameSelection.encode(action.to_h))
          end
        end
        @back = button(_("Back"))
        make_form(@surface.fields + [@back], cancel: @back)
      end
    end
  end
end

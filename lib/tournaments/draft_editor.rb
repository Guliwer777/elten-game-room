# encoding: UTF-8
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative 'draft_details_editor'
require_relative 'group_advancement'

module GameRoomTournaments
  class DraftEditor
    using GameRoomLocalization::Translations

    def initialize(program:, registry:, configure:, save:, alert:, draft: nil)
      @program, @registry, @configure, @save, @alert = program, registry, configure, save, alert
      @draft = draft
    end

    def wait
      @ids = @registry.ids
      @result = nil
      @options_by_game = {}
      @details = copy(DraftDetails::DEFAULTS.merge(@draft || {}).slice(*DraftDetails::DEFAULTS.keys))
      if @draft
        @options_by_game[@draft.fetch('game_id')] = copy(@draft.fetch('game_options'))
      end
      initialize_game_options
      @name = EditBox.new(text(_("Tournament name")), text: @draft ? text(@draft.fetch('name')) : '', max_length: 120, quiet: true)
      @games = ListBox.new([text(_("Select a game"))] + @ids.map { |id| text(@registry.name(id)) },
        header: text(_("Game")), index: @draft ? (@ids.index(@draft['game_id']) || -1) + 1 : 0, quiet: true)
      @format = ListBox.new(format_labels.map { |value| text(value) },
        header: text(_("Tournament format")), index: format_values.index(@draft ? @draft['format'] : 'round_robin') || 0, quiet: true)
      @rematch = ListBox.new(rematch_labels.map { |value| text(value) },
        header: text(_("Return matches")), index: rematch_values.index(@draft ? @draft['rematch'] : false) || 0, quiet: true)
      @group_count = ListBox.new([text(_("To be decided"))] + (2..128).map { |n| text(n) },
        header: text(_("Number of groups")), index: [nil, *(2..128)].index(@details['group_count']) || 0, quiet: true)
      @group_places = ListBox.new([text(_("To be decided"))] + (1..255).map { |n| text(n) },
        header: text(_("Qualifying places per group")), index: [nil, *(1..255)].index(@details['places_per_group']) || 0, quiet: true)
      @advancement = ListBox.new([text(_("Automatic cross-group qualification")), text(_("Manual group configuration"))],
        header: text(_("Qualification policy")), index: !@draft || GroupAdvancement.automatic?(@details['group_advancement']) ? 0 : 1, quiet: true)
      settings = Button.new(text(_("Game settings")))
      details = Button.new(text(_("Participants and playing windows")))
      save = Button.new(text(save_label))
      cancel = Button.new(text(_("Cancel")))
      fields = setup_fields([@name, @games, settings, @format, @rematch, @advancement, @group_count, @group_places, details, save, cancel])
      @form = GameRoomUI::Form.new(fields, program: @program, quiet: true)
      @form.accept_button, @form.cancel_button = save, cancel
      @format.on(:move) { interaction { update_group_fields } }
      @advancement.on(:move) { interaction { update_group_fields } }
      update_group_fields
      initialize_form_state
      settings.on(:press) { interaction { configure_settings } }
      details.on(:press) { interaction { configure_details } }
      save.on(:press) { interaction { submit } }
      cancel.on(:press) { interaction { finish } }
      @form.wait
      @result
    end

    private

    def save_label; _("Save draft"); end
    def initialize_game_options; end
    def initialize_form_state; end
    def format_values; [nil,'round_robin','groups_knockout']; end
    def format_labels; [_("To be decided"),_("Round robin"),_("Groups and knockout")]; end
    def rematch_values; [nil,false,true]; end
    def rematch_labels; [_("To be decided"),_("No"),_("Yes")]; end
    def groups_selected?; format_values[@format.index]=='groups_knockout'; end
    def setup_fields(fields); fields; end

    def interaction
      return if @busy || @finished
      @busy = true
      begin
        yield
      ensure
        @busy = false
      end
    end

    def finish
      @finished = true
      @form.resume
    end

    def configure_settings
      game = selected_game
      return unless game
      configured = @configure.call(game, copy(options_for(game)))
      @options_by_game[game.id] = copy(configured) if configured
    end

    def update_group_fields
      groups_selected? ? @form.show(@advancement) : @form.hide(@advancement)
      [@group_count, @group_places].each do |field|
        groups_selected? && @advancement.index == 1 ? @form.show(field) : @form.hide(field)
      end
    end

    def configure_details
      previous_index = @form.index
      configured = DraftDetailsEditor.new(program: @program, details: @details, alert: @alert).wait
      @details = copy(configured) if configured
      @form.index = previous_index if @form.index != previous_index
      @form.focus
    end

    def submit
      name = text(@name.text).strip
      if name.empty? || name.length > 120 || name.match?(/[\x00-\x1f\x7f]/)
        @alert.call(text(_("Enter a tournament name (1-120 characters, one line).")))
        return
      end
      game = selected_game
      unless game
        @alert.call(text(_("Select a game.")))
        return
      end
      @result = @save.call(copy(@details).merge('name' => name, 'game_id' => game.id,
        'game_options' => copy(options_for(game)), 'format' => format_values[@format.index],
        'group_advancement' => groups_selected? && @advancement.index == 0 ? GroupAdvancement::COMPACT : nil,
        'group_count' => groups_selected? && @advancement.index == 0 ? nil : [nil, *(2..128)][@group_count.index],
        'places_per_group' => groups_selected? && @advancement.index == 0 ? nil : [nil, *(1..255)][@group_places.index],
        'rematch' => rematch_values[@rematch.index]))
      finish if @result
    end

    def selected_game
      @registry.build(@ids[@games.index - 1]) if @games.index.positive?
    end

    def options_for(game)
      @options_by_game.fetch(game.id) { game.default_options }
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end

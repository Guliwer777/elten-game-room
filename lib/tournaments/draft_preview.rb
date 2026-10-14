# encoding: UTF-8
require_relative '../game_room_ui'
require_relative '../game_content'
require_relative '../game_room_localization'
require_relative 'draft_details'
require_relative 'league_plan'
require_relative 'match_order'
require_relative 'group_plan'

module GameRoomTournaments
  class DraftPreview
    using GameRoomLocalization::Translations

    def initialize(program:, registry:, draft:, alert:)
      @program, @registry, @alert = program, registry, alert
      @draft = JSON.parse(JSON.generate(DraftDetails::DEFAULTS.merge(draft)))
    end

    def wait
      details = GameRoomUI::HelpText.new(text(_("Tournament settings")), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
        text: description, quiet: true)
      plan = Button.new(text(_("Match plan")))
      back = Button.new(text(_("Back")))
      @form = GameRoomUI::Form.new([details, plan, back], program: @program, quiet: true)
      @form.accept_button, @form.cancel_button = plan, back
      plan.on(:press) { interaction { show_plan } }
      back.on(:press) { interaction { @finished = true; @form.resume } }
      @form.wait
    end

    private

    def direct_final?
      @draft['format'] == 'groups_knockout' && ['automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(@draft['group_advancement']) && @draft['participants'].size == 2
    end

    def interaction
      return if @busy || @finished
      @busy = true
      begin
        yield
      ensure
        @busy = false
      end
    end

    def show_plan
      previous_index = @form.index
      error = planning_error
      if error
        @alert.call(text(error))
        return
      end
      begin
        rows, summary, keys = EltenAPI::Tasks.run(title: text(_("Match plan")), ui: :none, cancellable: false) do
          direct = direct_final?
          if @draft['format'] == 'groups_knockout' && !direct
            plan = GroupPlan.build(participants: @draft['participants'], group_count: @draft['group_count'],
              places_per_group: @draft['places_per_group'], players_per_match: @draft['players_per_match'],
              pairing: @draft['pairing'], rematch: @draft['rematch'], advancement: @draft['group_advancement'])
            group_plan_text(plan)
          else
            matches = LeaguePlan.build(participants: @draft['participants'], players_per_match: @draft['players_per_match'],
              pairing: @draft['pairing'], rematch: direct ? false : @draft['rematch'])
            plan_text(matches)
          end
        end
      rescue LeaguePlan::Invalid => error
        @alert.call(text(plan_error(error)))
        return
      end
      list = ListBox.new([], header: text(_("Matches")), quiet: true)
      list.update_options(rows, keys: keys)
      details = GameRoomUI::HelpText.new(text(_("Plan summary")), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
        text: summary, quiet: true)
      back = Button.new(text(_("Back")))
      form = GameRoomUI::Form.new([list, details, back], program: @program, quiet: true)
      form.cancel_button = back
      finished = false
      back.on(:press) do
        next if finished
        finished = true
        form.resume
      end
      form.wait
    ensure
      @form.index = previous_index if @form.index != previous_index
      @form.focus
    end

    def planning_error
      return _("Choose the tournament format before building a match plan.") unless %w[round_robin groups_knockout].include?(@draft['format'])
      game = @registry.build(@draft['game_id'])
      return _("Choose an available game before building a match plan.") unless game
      players = @draft['players_per_match']
      if players.is_a?(Integer) && !players.between?(game.minimum_players, game.maximum_players)
        return text(_("This game requires %{minimum} to %{maximum} players per match.")) % {
          minimum: game.minimum_players, maximum: game.maximum_players }
      end
      options = game.normalize_options(JSON.parse(JSON.generate(@draft.fetch('game_options'))))
      game.validation_error(options, player_count: players)
    end

    def plan_error(error)
      case error.code
      when :invalid_group_configuration
        _("Choose the number of groups and qualifying places. Each group must have enough players for a match and fewer qualifying places than participants.")
      when :too_many_group_matches
        _("A group exceeds 256 matches. Add more groups, change multiplayer pairings or disable return matches.")
      when :too_many_matches
        _("This plan exceeds 5000 matches. Reduce participants, change multiplayer pairings or disable return matches.")
      when :invalid_rematch
        _("Choose Yes or No for return matches before building a match plan.")
      when :missing_rematch
        _("Choose whether to include return matches before building a match plan.")
      when :invalid_pairing
        _("Choose valid multiplayer pairings before building a match plan.")
      when :missing_pairing
        _("Choose multiplayer pairings before building a match plan.")
      when :invalid_participants
        _("Add 2 to 256 distinct local participants before building a match plan.")
      when :invalid_players_per_match
        _("Choose the number of players per match (2 to 8), not exceeding the participant count.")
      else
        raise error
      end
    end

    def group_plan_text(plan)
      rows, keys = [], []
      lines = [text(_("Local plan only. Nothing is saved or published.")),
        text(_("These local names are not confirmed registrations. Invitations and matches are not active.")),
        text(_("Groups follow the participant list in rotation. This is not a draw or ranking-based seeding.")),
        text(_("Only group matches are planned here. Knockout matches require confirmed group results and resolved qualification ties.")),
        text(_("Matches: %{count}")) % {count: plan['match_count']}]
      plan['groups'].each_with_index do |group, index|
        label = text(_("Group %{number}")) % {number: index + 1}
        lines << label + ': ' + group['units'].map { |unit| text(unit) }.join(', ')
        lines << text(_("Qualifying places per group")) + ': ' + group['places'].to_s
        group['matches'].each_with_index do |match, number|
          rows << (text(_("Group %{group}; match %{number}; %{players}")) % {
            group: index + 1, number: number + 1,
            players: match['participants'].map { |unit| text(unit) }.join(', ')})
          keys << match['id']
        end
      end
      [rows, lines.join("\r\n\r\n"), keys]
    end

    def plan_text(matches)
      counts = @draft['participants'].to_h { |name| [name, 0] }
      rows = matches.map do |match|
        match['players'].each { |name| counts[name] += 1 }
        text(_("Match %{number}; leg %{leg}; %{players}")) % { number: match['number'], leg: match['leg'],
          players: MatchOrder.players(matches, match).map { |name| text(name) }.join(', ') }
      end
      lines = [text(_("Local plan only. Nothing is saved or published.")),
        text(_("These local names are not confirmed registrations. Invitations and matches are not active.")),
        text(_("The plan specifies compositions and return matches only; no fixed start times, seats or roles are assigned.")),
        text(_("Matches: %{count}")) % { count: matches.length }, text(_("Appearances per participant"))]
      counts.each { |name, count| lines << (text(_("%{name}: %{count}")) % { name: text(name), count: count }) }
      [rows, lines.join("\r\n\r\n"), matches.map { |match| "match:#{match['number']}" }]
    end

    def description
      game = @registry.build(@draft.fetch('game_id'))
      lines = [text(_("Tournament name")) + ': ' + text(@draft.fetch('name')),
        text(_("Game")) + ': ' + text(game ? game.name : @draft.fetch('game_id'))]
      format = { 'round_robin' => _("Round robin"), 'groups_knockout' => _("Groups and knockout") }[@draft['format']] || _("To be decided")
      rematch = @draft['rematch'].nil? ? _("To be decided") : (@draft['rematch'] ? _("Yes") : _("No"))
      rematch = _("No") if direct_final?
      lines << text(_("Tournament format")) + ': ' + text(format)
      lines << text(_("Return matches")) + ': ' + text(rematch)
      if @draft['format'] == 'groups_knockout' && ['automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(@draft['group_advancement'])
        if direct_final?
          lines << text(_("Two participants play a direct final, without groups or a return match."))
        elsif @draft['group_advancement'] == 'automatic_compact_groups_v2'
          lines << text(_("Groups of three or four; four preferred. Extra qualifying places compare results without matches against the last player of a larger group."))
        else
          lines << text(_("Automatic qualification: two groups through 16 participants, four above 16; the largest power of two advances. Cross-pair first with last."))
        end
      elsif @draft['format'] == 'groups_knockout'
        lines << text(_("Number of groups")) + ': ' + text(@draft['group_count'] || _("To be decided"))
        lines << text(_("Qualifying places per group")) + ': ' + text(@draft['places_per_group'] || _("To be decided"))
      end
      pairing = { 'all_combinations' => _("All possible compositions"), 'balanced_cycle' => _("Rotating compositions; equal appearances") }[@draft['pairing']] || _("To be decided")
      lines << text(_("Players per match")) + ': ' + text(@draft['players_per_match'] || _("To be decided"))
      lines << text(_("Multiplayer pairings")) + ': ' + text(pairing)
      participants = @draft.fetch('participants')
      lines << (text(_("Local participants: %{count}")) % { count: participants.length })
      lines.concat(participants.map { |name| text(name) })
      lines << text(_("These local names are not confirmed registrations. Invitations and matches are not active."))
      lines << text(_("Playing windows"))
      lines << text(_("Organizer dates and times, without time zone conversion."))
      lines << text(_("No playing windows.")) if @draft.fetch('windows').empty?
      @draft.fetch('windows').each do |window|
        lines << (text(_("%{start_date} %{start_time} to %{end_date} %{end_time}")) % {
          start_date: text(window['date']), start_time: text(window['start']),
          end_date: text(window['end_date']), end_time: text(window['end']) })
      end
      if game
        options = game.normalize_options(JSON.parse(JSON.generate(@draft.fetch('game_options'))))
        settings = game.effective_option_definitions(options).filter_map do |definition|
          next unless game.option_visible?(definition, options, normalize: false)
          label = text(definition.summary_label || definition.label)
          label + ': ' + option_value(definition, options[definition.key.to_s])
        end
        lines << text(_("Game settings")) + ":\r\n" + settings.join("\r\n")
      end
      lines.join("\r\n\r\n")
    end

    def option_value(definition, value)
      case definition.kind.to_sym
      when :boolean
        text(value ? _("Yes") : _("No"))
      when :choice
        choice = definition.choices.to_a.find { |item| item.value.to_s == value.to_s }
        text(choice ? choice.label : value)
      when :multiple_choice
        selected = definition.choices.to_a.each_with_index.filter_map do |choice, index|
          text(choice.label) if (value.to_i & (1 << index)) != 0
        end
        selected.empty? ? text(_("None")) : selected.join(', ')
      else
        definition.summary_unit == :seconds ? (text(_("%{seconds} seconds")) % { seconds: text(value) }) : text(value)
      end
    end

    def text(value)
      GameRoomContent.utf8(value)
    end
  end
end

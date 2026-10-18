# encoding: UTF-8
require_relative "../lib/game_room_localization"

module GameRoomGames
  using GameRoomLocalization::Translations
  class Taboo
    def surface_spec(replay, viewer)
      state = replay.state
      master = master?(state,viewer)
      lines = card_lines(state,viewer)
      action = if state[:phase] == :ready && same_user?(viewer,state[:current_player])
        "start"
      elsif state[:phase] == :describing && same_user?(viewer,state[:current_player])
        "correct"
      end
      review = state[:phase] == :review ? state[:review].map do |entry|
        card = cards(state)[entry[:card]]
        { word: card["word"], forbidden: card["forbidden"], result: entry[:result], label: result_label(entry[:result]) }
      end : []
      GameSurfaces::TabooSpec.new(token: token(state), phase: state[:phase], lines: lines,
        status: role_text(state,viewer), action: action, master: master, review: review,
        results: RESULTS.map { |r| [r,result_label(r)] },
        opponent: card_visible?(state,viewer) && !same_user?(viewer,state[:current_player]))
    end
    def custom_game_shortcuts(replay, viewer)
      state = replay.state
      result = [surface_shortcut(key: "r", label: _("remaining time"), command: "taboo_time",
        payload: { "deadline" => state[:deadline], "offset" => state[:clock_offset].to_i, "frozen" => state[:frozen_at], "epoch" => state[:clock_epoch_offset].to_i }),
        announcement_shortcut(key: "s", label: _("team scores"), message: score_announcement_order([0, 1], state[:scores]).map { |team| _("Team %{number}: %{score}") % { number: team + 1, score: state[:scores][team] } }.join("; "))]
      lines = card_lines(state,viewer)
      unless lines.empty?
        result << announcement_shortcut(key: "c", label: _("read the entire card"), message: lines.join(", "))
        lines.each_with_index do |text, i|
          result << announcement_shortcut(key: (i+1).to_s, label: i == 0 ? _("read the target") : _("read forbidden word %{number}") % { number: i }, message: text)
        end
        if same_user?(viewer,state[:current_player])
          result << surface_shortcut(key: "p", label: _("skip this card"), command: "taboo_skipped")
        else
          result << surface_shortcut(key: "b", label: _("buzz this card"), command: "taboo_buzzed")
        end
      end
      result
    end
    def turn_announcement(replay, viewer); role_text(replay.state,viewer); end
    def result_text(replay)
      return nil unless replay.winner
      _("Team %{team} wins Taboo.") % { team: replay.winner.delete_prefix("team:").to_i + 1 }
    end
    def turn_marker(replay)
      [replay.state[:turn], replay.state[:phase]]
    end
    def result_label(result)
      { "correct" => _("Guessed"), "skipped" => _("Skipped"), "buzzed" => _("Rule violation"), "neutral" => _("No points") }.fetch(result)
    end
    def role_text(state,viewer)
      return _("Preparing Taboo.") if state[:phase] == :awaiting_deal
      return _("Taboo is finished.") if state[:phase] == :finished
      text = _("%{player} describes for team %{team}.") % { player: participant_name(state[:current_player]), team: state[:team]+1 }
      suffix = case state[:phase]
      when :ready then same_user?(viewer,state[:current_player]) ? _("Press Enter when everyone is ready.") : _("Waiting for the describing player.")
      when :preparing then _("Three-second preparation.")
      when :review then _("Review this turn. The table master must approve it.")
      else
        if same_user?(viewer,state[:current_player])
          _("Describe the target without the forbidden words.")
        elsif team_of(state,viewer) == state[:team]
          _("Guess aloud. The card is hidden.")
        elsif team_of(state,viewer)
          _("Monitor the description. Press B for a violation.")
        else
          _("You are observing. The card is hidden.")
        end
      end
      text + " " + suffix
    end
    def rule_sections
      generated_rule_sections
    end
  end
end

require_relative 'generated/rulebooks/taboo'

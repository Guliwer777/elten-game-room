# encoding: UTF-8
require_relative 'local_fixed_team_execution_screen'
require_relative 'local_individual_entry'
require_relative 'local_game_choice_dialog'
require_relative 'local_realtime_game_dialog'
module GameRoomTournaments
  class LocalIndividualExecutionScreen < LocalFixedTeamExecutionScreen
    using GameRoomLocalization::Translations
    private
    def game_surface_available?; true; end
    def controller_class; LocalIndividualEntry; end
    def plan_header; text(_("Accepted individual plans")); end
    def match_header; text(_("My individual matches")); end
    def status_header; text(_("Individual execution status")); end
    def connection_policy; LocalIndividualConnection::POLICY; end
    def empty_text; text(_("No accepted individual plan.")); end
    def loading_text; text(_("Use Check status to read accepted individual plans.")); end
    def damaged_text; text(_("The accepted plan storage is damaged or incompatible. The last valid view is retained; no data was replaced.")); end
    def outcome_text(summary)
      summary['draw'] ? text(_("Draw")) : text(_("Winner: %{players}"))%{players:summary['winners'].map { |winner| text(winner) }.join(', ')}
    end
    def summary_text(summary)
      outcome_text(summary)
    end
    def saved_result_text(result)
      text(_("Saved match %{match}, leg %{leg}; result: %{result}")) % {
        match: match_number(result), leg: result['leg'], result: outcome_text(result['summary'])}
    end
    def standings_row_text(row)
      content = group_row_prefix(row) + (text(_("Place %{place}. ")) % {place: row['place']}) + text(_("Player %{player}: tournament points %{points}, played %{played}, wins %{wins}, draws %{draws}, losses %{losses}")) % {
        player: row['unit'], points: row['points'], played: row['played'], wins: row['wins'], draws: row['draws'], losses: row['losses']}
      if row['score_for']
        content += ' ' + text(_("Game points for %{for}, game points against %{against}.")) % {for: row['score_for'], against: row['score_against']}
      else
        content += ' ' + text(_("No numeric small points recorded."))
      end
      content + small_score_order_text(row)
    end
    def boundary_text
      [text(_("Ready is not consent or entry. Each test participant must consent and confirm entry separately.")),
        text(_("The creator can start one local game after every participant confirms entry.")),
        text(_("Local entry and Start do not open a network game.")),
        text(_("The realtime game view must use your signed-in account.")),
        text(_("The running local dispatcher renews your availability. It expires 60 seconds after renewal stops; online presence is not connected yet."))].join("\r\n")
    end
    def status_text
      value = super
      if @controller.reason == :realtime_execution_required
        value += "\r\n" + text(_("This game needs its realtime client, which is not connected to local tournament execution yet."))
      end
      value
    end
  end
end

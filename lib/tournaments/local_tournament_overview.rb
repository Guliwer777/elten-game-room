# encoding: UTF-8
require_relative 'local_fixed_team_plan_screen'
require_relative 'local_individual_execution_screen'
require_relative 'local_organizer_decision_screen'
require_relative 'local_match_labels'

module GameRoomTournaments
  class LocalTournamentOverview < LocalFixedTeamPlanScreen
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:)
      super(program: program, workspace: workspace, owner: owner)
      @publication = publication
    end
    private
    def build_form
      @details = readonly(_("Matches, groups and standings"), '')
      refresh = button(_("Refresh")) { refresh_overview }
      play = button(_("Individual matches — local execution")) do
        settings = JSON.parse(@publication['settings_json'])
        pairs = @workspace.registry.build(@publication['game']).team_size(settings['game_options'], player_count: settings['players_per_match']) == 2
        screen = pairs ? LocalFixedTeamExecutionScreen : LocalIndividualExecutionScreen
        screen.new(program: @program, workspace: @workspace, owner: @owner).run if current?
        refresh_overview if current?
      end
      play.header = text(_("Play tournament matches"))
      back = button(_("Back"))
      fields = [@details, refresh, play]
      if @publication['__insertion_user'].downcase == @workspace.actor.downcase
        fields << button(_("Organizer decisions — forfeits")) do
          LocalOrganizerDecisionScreen.new(program: @program, workspace: @workspace, owner: @owner,
            rows: @overview_rows || []).run if current?
          refresh_overview if current?
        end
      end
      make_form(fields + [back], cancel: back)
      refresh_overview
    end
    def refresh_overview
      return unless current?
      ref = {'author' => @publication['__insertion_user'], 'publication_key' => @publication['publication_key']}
      result = @workspace.tournament_overview(publication_ref: ref, context: @context, lease: @lease, session: @session)
      return unless result && current?
      unless result[:state] == :confirmed
        if result[:reason] == :registration_open
          @details.set_text(text(_("Registration is still open. Matches and groups will be created after it closes.")))
        elsif result[:reason] == :incomplete_pairs
          @details.set_text(text(_("Some participants still need partners. Complete the pairs before creating matches.")))
        else
          @details.set_text(text(_("Plan operation blocked: %{reason}")) % {reason: result[:reason] || result[:state]})
        end
        return
      end
      lines = [@publication['title']]
      @overview_rows = result[:rows]
      windows = result[:rows].flat_map { |item| item['record']['evidence']['plan']['matches'].flat_map { |match| match['windows'] } }
      if !windows.empty? && windows.all? { |window| window['closes'] <= result.fetch(:observed_at) }
        lines << text(_("The tournament time has ended. Unfinished matches receive no automatic result or points."))
      end
      if result[:rows].empty?
        lines << text(_("Matches are created after registration closes. Open the tournament as its test organizer to prepare them automatically."))
      end
      result[:rows].each do |item|
        record, progress = item.values_at('record', 'progress')
        lines << LocalMatchLabels.phase(record)
        results = progress['results'] || []
        groups = record['preview']['source']['candidate']['groups'] || []
        membership = record['preview']['source']['candidate']['membership']
        membership = record.dig('preview','source','candidate','knockout','qualification','snapshot','membership') || membership
        units = membership ? membership['units'].to_h { |unit| [unit['unit_id'], unit['accounts'].join(' — ')] } : {}
        if record.dig('preview', 'source', 'candidate', 'knockout', 'qualification')
          lines << text(_("Additional games decide group qualification. Their points do not change the original group table."))
        end
        if progress['champion']
          lines << text(_("Tournament winner: %{player}")) % {player: units.fetch(progress['champion'], progress['champion'])}
        elsif progress['complete'] && record['preview']['source']['candidate']['format'] == 'round_robin'
          lines << text(_("All tournament matches have been completed."))
        end
        groups.each { |group| lines << "#{text(_("Group"))} #{group['id']}: #{group['units'].map { |unit| units.fetch(unit, unit) }.join(', ')}" }
        lines.concat(standings_lines(progress,units))
        record['evidence']['plan']['matches'].each_with_index do |match, index|
          outcome = results.find { |row| row['match_id'] == match['match_id'] && row['leg'] == match['leg'] }
          names = match['players'].map { |person| person['username'] }.join(' — ')
          group = groups.find { |item| item['matches'].include?(match['match_id']) }
          label = match['leg'] == 2 ? _("Match %{number}, return match: %{players}") : _("Match %{number}: %{players}")
          lines << (group ? "#{text(_("Group"))} #{group['id']}: " : '') + text(label) % {number: index + 1, players: names}
          if outcome
            if outcome['kind'] == 'forfeit'
              lines << text(_("Forfeit — organizer decision: %{reason}")) % {reason: outcome['reason']}
            end
            summary = outcome['summary']
            winners = summary['winners'] || [summary.fetch('winner')]
            value = summary['draw'] ? text(_("Draw")) : winners.map { |winner| units.fetch(winner, winner) }.join(', ')
            lines << (summary['draw'] ? value : text(_("Winner: %{players}"))%{players:value})
            lines << summary['scores'].map { |player, score| "#{units.fetch(player, player)}: #{score}" }.join('; ') if summary['scores']
          else
            stage = (progress['matches'] || []).find { |row| row['match_id'] == match['match_id'] && row['leg'] == match['leg'] }
            expired = match['windows'].all? { |window| window['closes'] <= result.fetch(:observed_at) }
            label = if stage && stage['stage'] == 'awaiting_result'
              _("Finished game awaiting result registration")
            elsif expired
              _("Match unfinished after its deadline")
            elsif stage && stage['stage'] == 'playing'
              _("Match in progress")
            else
              _("Match awaiting play")
            end
            lines << text(label)
          end
        end
        if progress.dig('cross_seeding', 'state') == 'ready'
          lines << text(_("Qualified players: %{players}")) % {
            players: progress.fetch('qualified').map { |unit| units.fetch(unit, unit) }.join(', ')}
        end
        (progress.dig('cross_seeding', 'comparison') || []).each do |row|
          lines << text(_("Cross-group comparison: %{player}, points %{points}, counted matches %{played}")) % {
            player: units.fetch(row['unit'], row['unit']), points: row['points'], played: row['played']}
          if row['excluded']
            lines << text(_("Excluded from this comparison: matches against %{player}")) % {
              player: units.fetch(row['excluded'], row['excluded'])}
          end
        end
      end
      @details.set_text(lines.join("\r\n"))
    end
    def standings_lines(progress,units)
      lines=[]
      (progress['standings'] || []).each do |row|
        group = row['group'] ? "#{text(_("Group"))} #{row['group']}: " : ''
        lines << group + text(_("Player %{player}: tournament points %{points}, played %{played}, wins %{wins}, draws %{draws}, losses %{losses}")) % {
          player: units.fetch(row['unit'] || row['team'], row['unit'] || row['team']), points: row['points'], played: row['played'], wins: row['wins'], draws: row['draws'], losses: row['losses']}
        lines << text(_("Place: %{place}")) % {place: row['place']} if row['place']
        unless row['score_for'].nil? || row['score_against'].nil?
          lines << text(_("Small points: scored %{scored}, conceded %{conceded}, difference %{difference}")) % {
            scored: row['score_for'], conceded: row['score_against'], difference: row['score_for'] - row['score_against']}
        end
      end
      lines
    end
  end
end

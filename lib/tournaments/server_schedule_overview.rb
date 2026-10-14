# encoding: UTF-8
require_relative 'tournament_window'
require_relative 'match_order'
require_relative 'server_forfeit_screen'

module GameRoomTournaments
  # Shared schedule and explicit ordinary-table entry for the selected fixture.
  class ServerScheduleOverview < TournamentWindow
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:)
      super(program: program, workspace: workspace, owner: owner)
      @publication = publication
    end
    private
    def build_form
      @details = readonly(_("Matches, groups and standings"), '')
      refresh = button(_("Refresh")) { refresh_schedule }
      @match_list = ListBox.new([],header:text(_("Tournament match")),quiet:true)
      play = button(_("Create or join table for this match")) do
        next unless current? && @candidate && @matches && (match=@matches[@match_list.index])
        @program.open_ordinary_tournament_match(@publication,match) if @program.respond_to?(:open_ordinary_tournament_match)
        refresh_schedule if current?
      end
      back = button(_("Back"))
      fields=[@details,@match_list,refresh]
      fields << play if @program.respond_to?(:open_ordinary_tournament_match)
      if @program.respond_to?(:award_ordinary_tournament_forfeit)
        @forfeit=button(_("Award forfeit")) do
          next unless current? && forfeit_available?
          match=@matches[@match_list.index]
          schedule_id=@candidate['schedule_id']
          units=match['unit_ids'] || match['players']
          teams=(@candidate.dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
          winner=ServerForfeitScreen.new(program:@program,names:units.map{|unit|teams.fetch(unit,unit)}).run
          next if winner.nil? || !current?
          @program.award_ordinary_tournament_forfeit(@publication,match,units.fetch(winner),schedule_id)
          refresh_schedule if current?
        end
        fields << @forfeit
        @cancel_forfeit=button(_("Cancel tournament match and award forfeit")) do
          next unless current? && cancel_forfeit_available?
          match=@matches[@match_list.index]
          schedule_id=@candidate['schedule_id']
          units=match['unit_ids'] || match['players']
          teams=(@candidate.dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
          winner=ServerForfeitScreen.new(program:@program,names:units.map{|unit|teams.fetch(unit,unit)},cancellation:true).run
          next if winner.nil? || !current?
          @program.award_ordinary_tournament_forfeit(@publication,match,units.fetch(winner),schedule_id,cancel_started:true)
          refresh_schedule if current?
        end
        fields << @cancel_forfeit
        @match_list.on(:move){interaction(restore:false){update_forfeit}}
      end
      if @workspace.respond_to?(:advance_phase)
        @advance=button(experimental_ui? ? _("Prepare the next tournament phase (server test)") : _("Prepare the next tournament phase")) do
          next unless current? && @candidate
          result=@workspace.advance_phase(publication_ref:{'author'=>@publication['__insertion_user'],'publication_key'=>@publication['publication_key']},
            expected_schedule_id:@candidate['schedule_id'],context:@context,lease:@lease)
          next unless current?
          if result && result[:reason]
            message=case result[:reason]
            when :phase_results_incomplete then _("Finish all matches in this phase before preparing the next one.")
            when :group_tie_requires_resolution then _("Group qualification is tied. No participants were advanced automatically.")
            when :tournament_completed then _("The final has been completed. There is no next round.")
            else _("Plan operation blocked: %{reason}")
            end
            alert(text(message)%{reason:result[:reason]})
          end
          refresh_schedule
        end
        fields << @advance
      end
      if experimental_ui? && @workspace.respond_to?(:shared_proposal)
        fields << button(_("Shared match proposal (server test)")) do
          next unless current? && @candidate && @matches && (match=@matches[@match_list.index])
          ServerProposalScreen.new(program:@program,workspace:@workspace,owner:@owner,publication:@publication,match:match).run
          refresh_schedule if current?
        end
      end
      if experimental_ui? && @workspace.respond_to?(:shared_readiness)
        @ready_details=readonly(_("Shared player readiness"),'')
        @shared_ready=button(_("I am ready to play")){refresh_readiness(true)}
        @shared_unavailable=button(_("Disable my availability for automatic matches")){refresh_readiness(false)}
        fields += [@ready_details,@shared_ready,@shared_unavailable]
      end
      make_form(fields+[back], cancel: back)
      refresh_schedule
    end

    def refresh_schedule
      return unless current?
      @ready_details&.set_text('')
      if @shared_ready
        @form.hide(@shared_ready)
        @form.hide(@shared_unavailable)
      end
      reference = {'author' => @publication['__insertion_user'], 'publication_key' => @publication['publication_key']}
      @form.hide(@advance) if @advance
      @form.hide(@forfeit) if @forfeit
      @form.hide(@cancel_forfeit) if @cancel_forfeit
      @result_view=nil
      result = @workspace.shared_schedule(publication_ref: reference, context: @context, lease: @lease)
      return unless current?
      # Clear an old plan after a failed refresh; it must not look current.
      unless result
        @candidate=nil
        @match_list.update_options([],keys:[])
        @details.set_text(text(_("Tournament access failed. Check Operations before repeating a write.")))
        return
      end
      if result[:reason]
        @candidate=nil
        @match_list.update_options([],keys:[])
        message = case result[:reason]
        when :registration_open then _("Registration is still open. Matches and groups will be created after it closes.")
        when :incomplete_pairs then _("Some participants still need partners. Complete the pairs before creating matches.")
        else _("Plan operation blocked: %{reason}")
        end
        @details.set_text(text(message) % {reason: result[:reason]})
        return
      end
      storage = result.fetch('storage')
      history=result['phase_history'] || []
      result = result.fetch('candidate')
      @candidate=result
      if @advance
        available=@publication['__insertion_user'].downcase==@workspace.actor.downcase && %w[groups_knockout knockout].include?(@candidate['format'])
        available ? @form.show(@advance) : @form.hide(@advance)
      end
      if @shared_ready && (@candidate['roster'] || []).include?(@workspace.actor.downcase)
        @form.show(@shared_ready)
        @form.show(@shared_unavailable)
      end
      ordered=ordered_matches(result.fetch('matches'))
      organizer=@workspace.respond_to?(:shared_proposal) && @publication['__insertion_user'].downcase==@workspace.actor.downcase
      @matches=organizer ? ordered : ordered.select{|m|m['players'].include?(@workspace.actor.downcase)}
      @match_list.update_options(@matches.map{|m|match_label(m)},keys:@matches.map{|m|[m['match_id'],m['leg']]})
      status = storage == 'confirmed' ? _("Match plan read from the server. Select your match to create or join its ordinary table. Results are saved automatically for supported individual and team matches.") : _("The organizer must open this tournament to save its match plan on the server. The list below is only a preview.")
      lines = [@publication['title'], text(status)]
      if @candidate.dig('knockout','qualification')
        lines << text(_("Additional matches to resolve group qualification"))
      elsif @candidate['knockout']
        lines << text(_("Knockout round: %{round}"))%{round:@candidate['knockout']['round']}
      end
      groups = result['groups'] || []
      teams = (result.dig('membership', 'units') || []).to_h { |unit| [unit['unit_id'], unit['accounts'].join(' + ')] }
      groups.each { |group| lines << "#{text(_("Group"))} #{group['id']}: #{group['units'].map { |unit| teams.fetch(unit, unit) }.join(', ')}" }
      view=@program.ordinary_tournament_results(@publication) if @program.respond_to?(:ordinary_tournament_results)
      @result_view=view
      if view && view['schedule_id'] && view['schedule_id']!=@candidate['schedule_id']
        @candidate=nil
        @match_list.update_options([],keys:[])
        @form.hide(@advance) if @advance
        @details.set_text(text(_("The tournament phase changed. Refresh the match list.")))
        return
      end
      if view
        view['standings'].each{|row|lines << (row['group'] ? "#{text(_("Group"))} #{row['group']}: " : '')+text(_("%{player}: %{points} tournament points"))%{player:teams.fetch(row['unit'],row['unit']),points:row['points']}}
        if view['champion']
          lines << text(_("Tournament winner: %{player}"))%{player:teams.fetch(view['champion'],view['champion'])}
          @form.hide(@advance) if @advance
        end
      end
      ordered.each_with_index do |match, index|
        group = groups.find { |item| item['matches'].include?(match['match_id']) }
        label = match['leg'] == 2 ? _("Match %{number}, return match: %{players}") : _("Match %{number}: %{players}")
        names = match['unit_ids'] ? MatchOrder.players(ordered, match, key: 'unit_ids').map { |unit| teams.fetch(unit) }.join(' — ') : MatchOrder.players(@candidate['matches'], match).join(' — ')
        lines << (group ? "#{text(_("Group"))} #{group['id']}: " : '') + text(label) % {number: index + 1, players: names}
        receipt=view && view['results'].find{|r|r['match_id']==match['match_id'] && r['leg']==match['leg']}
        lines << text(_("Forfeit")) if receipt && %w[ordinary-match-forfeit-v1 ordinary-match-cancel-forfeit-v1].include?(receipt['kind'])
        lines << text(_("The started match was cancelled in the tournament. Its game history is preserved.")) if receipt && receipt['kind']=='ordinary-match-cancel-forfeit-v1'
        lines << result_label(receipt['summary'],teams) if receipt
      end
      history.each{|phase|lines.concat(previous_phase_lines(phase))}
      @details.set_text(lines.join("\n"))
      update_forfeit
      refresh_readiness if @ready_details
    end

    def forfeit_available?
      match=@matches && @matches[@match_list.index]
      @candidate && @result_view && match && @publication['__insertion_user'].downcase==@workspace.actor.downcase &&
        (@result_view['forfeitable_matches'] || []).any?{|row|row['match_id']==match['match_id'] && row['leg']==match['leg']} &&
        !@result_view['results'].any?{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
    end
    def experimental_ui?;@workspace.respond_to?(:experimental_ui?) && @workspace.experimental_ui?;end
    def update_forfeit
      return unless @forfeit
      forfeit_available? ? @form.show(@forfeit) : @form.hide(@forfeit)
      cancel_forfeit_available? ? @form.show(@cancel_forfeit) : @form.hide(@cancel_forfeit) if @cancel_forfeit
    end
    def cancel_forfeit_available?
      match=@matches && @matches[@match_list.index]
      @candidate && @result_view && match && @publication['__insertion_user'].downcase==@workspace.actor.downcase &&
        (@result_view['cancellable_matches'] || []).any?{|row|row['match_id']==match['match_id'] && row['leg']==match['leg']} &&
        !@result_view['results'].any?{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
    end
    def refresh_readiness(available=nil)
      return unless current? && @candidate && @ready_details
      reference={'author'=>@publication['__insertion_user'],'publication_key'=>@publication['publication_key']}
      result=@workspace.shared_readiness(publication_ref:reference,available:available,
        intent_id:available.nil? ? nil : SecureRandom.uuid,context:@context,lease:@lease)
      return unless current?
      # A failed read never leaves an old ready list looking current.
      @ready_details.set_text('')
      return unless result
      lines=[text(_("Shared readiness test: availability expires after 60 seconds. This does not reserve players or send invitations."))]
      result['participants'].each do |row|
        label=row['state']=='ready' ? _("Availability enabled") : row['state']=='not_ready' ? _("Availability disabled") : _("Confirmation pending")
        lines << "#{row['account']}: #{text(label)}"
      end
      @ready_details.set_text(lines.join("\n"))
    end

    def ordered_matches(matches)
      matches.group_by{|match|[match['players'].sort,match['unit_ids']&.sort]}.values.flat_map{|pair|pair.sort_by{|match|match['leg']}}
    end

    def match_label(match)
      label=match['leg']==2 ? _("Match %{number}, return match: %{players}") : _("Match %{number}: %{players}")
      text(label)%{number:match['number'],players:MatchOrder.players(@candidate['matches'], match).join(' — ')}
    end

    def result_label(summary,teams={})
      outcome=summary['draw'] ? text(_("Draw")) : text(_("Winner: %{players}"))%{players:summary.fetch('winners').map{|unit|teams.fetch(unit,unit)}.join(', ')}
      scores=summary['scores']
      score=scores && !scores.empty? ? summary.fetch('participants').map{|player|"#{teams.fetch(player,player)}: #{scores.fetch(player)}"}.join('; ') : text(_("This game does not provide a numeric score."))
      outcome+"\n"+text(_("Game score: %{score}"))%{score:score}
    end
    def previous_phase_lines(phase)
      candidate=phase.fetch('candidate')
      view=phase.fetch('view')
      teams=(candidate.dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
      lines=[text(_("Previous tournament phase results"))]
      if candidate.dig('knockout','qualification')
        lines << text(_("Additional matches to resolve group qualification"))
      elsif candidate['knockout']
        lines << text(_("Knockout round: %{round}"))%{round:candidate['knockout']['round']}
      end
      view['standings'].each do |row|
        prefix=row['group'] ? "#{text(_("Group"))} #{row['group']}: " : ''
        lines << prefix+text(_("%{player}: %{points} tournament points"))%{player:teams.fetch(row['unit'],row['unit']),points:row['points']}
      end
      candidate['matches'].each do |match|
        names=match['unit_ids'] ? MatchOrder.players(candidate['matches'],match,key:'unit_ids').map{|unit|teams.fetch(unit)} : MatchOrder.players(candidate['matches'],match)
        label=match['leg']==2 ? _("Match %{number}, return match: %{players}") : _("Match %{number}: %{players}")
        lines << text(label)%{number:match['number'],players:names.join(' — ')}
        result=view['results'].find{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
        lines << text(_("Forfeit")) if result && %w[ordinary-match-forfeit-v1 ordinary-match-cancel-forfeit-v1].include?(result['kind'])
        lines << result_label(result['summary'],teams) if result
      end
      lines
    end
  end
end

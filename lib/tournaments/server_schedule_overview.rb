# encoding: UTF-8
require_relative 'tournament_window'
require_relative 'match_order'
require_relative 'server_forfeit_screen'
require_relative 'view_refresh'
require_relative 'phase_description'

module GameRoomTournaments
  # Shared schedule and explicit ordinary-table entry for the selected fixture.
  class ServerScheduleOverview < TournamentWindow
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, publication:,mode: :matches,initial_phase_id:nil)
      super(program: program, workspace: workspace, owner: owner)
      @publication = publication
      @mode=mode
      @initial_phase_id=initial_phase_id
    end
    private
    def build_form
      @details = readonly(_("Information"), '')
      refresh = button(_("Refresh")) { refresh_schedule }
      @match_list = ListBox.new([],header:text(_("Tournament matches")),quiet:true)
      @standings_list=ListBox.new([],header:text(_("Standings")),quiet:true)
      @phases=ListBox.new([],header:text(_("Tournament phase")),quiet:true)
      @phases.on(:move){interaction(restore:false,focus:false){render_phase}}
      @play = button(_("Play")) do
        next unless current? && @candidate && @matches && (match=@matches[@match_list.index])
        next unless @candidate['schedule_id']==@current_schedule_id && @program.respond_to?(:open_ordinary_tournament_match) &&
          match['players'].include?(@workspace.actor.downcase) && !completed_match?(match)
        identity=[@candidate['schedule_id'],match['match_id'],match['leg']]
        next unless @program.send(:confirm,text(_("Do you want to play this match?"))) && current?
        selected=@matches && @matches[@match_list.index]
        next unless selected && @candidate && @candidate['schedule_id']==@current_schedule_id &&
          identity==[@candidate['schedule_id'],selected['match_id'],selected['leg']] && !completed_match?(selected)
        @program.open_ordinary_tournament_match(@publication,match)
        refresh_schedule if current?
      end
      back = button(_("Back"))
      fields=@mode==:results ? [@standings_list,@phases,@details,refresh] : [@match_list,@phases,@details,refresh]
      if @mode!=:results && @program.respond_to?(:award_ordinary_tournament_forfeit)
        @forfeit=button(_("Award forfeit")) do
          next unless current? && forfeit_available?
          match=@matches[@match_list.index]
          schedule_id=@candidate['schedule_id']
          units=match['unit_ids'] || match['players']
          teams=(@candidate.dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
          loser=ServerForfeitScreen.new(program:@program,names:units.map{|unit|teams.fetch(unit,unit)}).run
          next if loser.nil? || !current?
          selected=@matches && @matches[@match_list.index]
          next unless selected && @candidate['schedule_id']==schedule_id && selected['match_id']==match['match_id'] && selected['leg']==match['leg']
          @program.award_ordinary_tournament_forfeit(@publication,match,units.fetch(loser),schedule_id,names:teams)
          refresh_schedule if current?
        end
      end
      if @mode!=:results && experimental_ui? && @workspace.respond_to?(:advance_phase)
        @advance=button(experimental_ui? ? _("Prepare the next tournament phase (server test)") : _("Prepare the next tournament phase")) do
          next unless current? && @candidate && @candidate['schedule_id']==@current_schedule_id
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
            @owner.notify(text(message)%{reason:result[:reason]})
          end
          refresh_schedule
        end
        fields << @advance
      end
      make_form(fields+[back], cancel: back)
      @form.hide(back)
      @match_list.on(:select) do
        if completed_match_selected?
          interaction{@owner.notify(text(_("This match has already been played.")))}
        else
          @play.press
        end
      end
      @match_list.bind_context{|menu|match_context(menu)}
      @form.game_room_invitation_context_field = @match_list if @mode != :results
      reference={'author'=>@publication['__insertion_user'].downcase,'publication_key'=>@publication['publication_key']}
      @view_refresh=ViewRefresh.new(@program,reference:reference){interaction(focus:false){refresh_schedule(automatic:true)}}
      @form.hub_update=-> {@view_refresh.tick unless @busy || @finished || !@context.current?(@lease)}
      refresh_schedule
    end

    def refresh_schedule(automatic:false)
      return unless current?
      @view_refresh&.acknowledge
      @form.hide(@advance) if @advance
      @form.show(@details)
      @result_view=nil
      result = automatic && coordinated_view
      result ||= @program.ordinary_tournament_overview(@publication, workspace:@workspace, context:@context, lease:@lease,
        match_controls:@mode!=:results)
      return unless current?
      # Clear an old plan after a failed refresh; it must not look current.
      unless result
        @candidate=nil
        @result_phases=nil
        @phases.update_options([],keys:[])
        @match_list.update_options([],keys:[])
        @standings_list.update_options([],keys:[])
        @details.set_text(text(_("Tournament access failed. Check Operations before repeating a write.")))
        return
      end
      if result[:reason]
        @candidate=nil
        @result_phases=nil
        @phases.update_options([],keys:[])
        @match_list.update_options([],keys:[])
        @standings_list.update_options([],keys:[])
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
      view=result.fetch('results')
      result = result.fetch('candidate')
      @candidate=result
      present_schedule(result, storage, history, view)
    end

    def coordinated_view
      return nil unless %w[confirmed observed].include?(@storage) && @current_schedule_id && @program.class.respond_to?(:tournament_view_snapshot)
      # Organizer match controls include fresh native-table checks; a shared
      # standings observation cannot replace those. New phases read their plan.
      return nil if @mode!=:results && @publication['__insertion_user'].downcase==@workspace.actor.downcase
      reference={'author'=>@publication['__insertion_user'].downcase,'publication_key'=>@publication['publication_key']}
      value=@program.class.tournament_view_snapshot(reference)
      return nil unless value && value.dig('candidate','schedule_id')==@current_schedule_id
      value.merge('storage'=>'observed')
    end

    def present_schedule(result, storage, history, view)
      @result_view=view
      if view && view['schedule_id'] && view['schedule_id']!=@candidate['schedule_id']
        @candidate=nil
        @result_phases=nil
        @phases.update_options([],keys:[])
        @match_list.update_options([],keys:[])
        @standings_list.update_options([],keys:[])
        @form.hide(@advance) if @advance
        @details.set_text(text(_("The tournament phase changed. Refresh the match list.")))
        return
      end
      was_current=!@result_phases || @phases.index==@result_phases.size-1
      @storage=storage
      @current_schedule_id=result['schedule_id']
      @result_phases=history+[{'candidate'=>result,'view'=>view || {'standings'=>[],'results'=>[]}}]
      @phases.update_options(@result_phases.map{|phase|phase_label(phase['candidate'])},
        keys:@result_phases.map{|phase|phase['candidate']['schedule_id']})
      @phases.index=@result_phases.size-1 if was_current
      if @initial_phase_id
        requested=@result_phases.index{|phase|phase['candidate']['schedule_id']==@initial_phase_id}
        @phases.index=requested if requested
        @initial_phase_id=nil
      end
      render_phase
    end

    def render_match_status
      label=if @result_view && @result_view['completed']
        _("Completed — all required matches have been resolved")
      elsif @candidate['schedule_id']!=@current_schedule_id
        _("Previous tournament phase")
      elsif %w[confirmed observed].include?(@storage)
        _("Choose a match and press Enter to play. Results are recorded automatically.")
      else
        _("The match plan has not been confirmed yet. Refresh before playing.")
      end
      lines=[@publication['title'],text(label)]
      lines<<text(_("Tournament winner: %{player}"))%{player:team_names.fetch(@result_view['champion'],@result_view['champion'])} if @result_view && @result_view['champion']
      lines.concat(forfeit_diagnostics(@result_view))
      @details.set_text(lines.join("\n"))
    end

    def render_matches
      return unless @candidate && @ordered
      unfinished,completed_matches=@ordered.partition{|match|!completed_match?(match)}
      own,others=unfinished.partition{|match|match['players'].include?(@workspace.actor.downcase)}
      visible=own+others+completed_matches
      # The first row describes the phase, not a fixture. Keep its nil mapping so
      # Enter and context actions cannot accidentally target the first match.
      @matches=[nil,*visible]
      completed=@ordered.count{|match|completed_match?(match)}
      summary=text(_("Matches — %{phase}; completed: %{done}/%{total}"))%{phase:phase_label(@candidate),done:completed,total:@ordered.size}
      @match_list.update_options([summary,*visible.map{|match|match_label(match)}],
        keys:[:phase_summary,*visible.map{|match|[match['match_id'],match['leg']]}])
      @match_list.index=0 if @shown_schedule_id!=@candidate['schedule_id']
      @shown_schedule_id=@candidate['schedule_id']
    end

    def render_results
      phase=@result_phases && @result_phases[@phases.index]
      return unless phase
      teams=(phase['candidate'].dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
      rows=phase['view']['standings'] || []
      @standings_list.header=text(_("Standings — %{phase}"))%{phase:phase_label(phase['candidate'])}
      @standings_list.update_options(rows.map{|row|standings_row_label(row,teams)},keys:rows.map{|row|[row['group'],row['unit']]})
      lines=[]
      if (winner=phase['view']['champion'])
        lines << text(_("Tournament winner: %{player}"))%{player:teams.fetch(winner,winner)}
      end
      lines.concat(forfeit_diagnostics(phase['view']))
      @details.set_text(lines.join("\n"))
      lines.empty? ? @form.hide(@details) : @form.show(@details)
    end

    def standings_row_label(row,teams)
      prefix=row['group'] ? text(_("Group"))+" #{row['group']}; " : ''
      label=prefix+(text(_("%{place}. %{player}; points: %{points}; played: %{played}"))%{
        place:row.fetch('place'),player:teams.fetch(row['unit'],row['unit']),points:row['points'],played:row['played']})
      if row['score_for'] && row['score_against'] && row['played'].positive? && row['scored_matches']==row['played']
        label+='; '+(text(_("Small points: scored %{scored}, conceded %{conceded}, difference %{difference}"))%{
          scored:row['score_for'],conceded:row['score_against'],difference:row['score_for']-row['score_against']})
      end
      label
    end

    def render_phase
      phase=@result_phases && @result_phases[@phases.index]
      return unless phase
      @candidate,@result_view=phase.values_at('candidate','view')
      @ordered=ordered_matches(@candidate.fetch('matches'))
      if @mode==:results
        render_results
      else
        render_matches
        render_match_status
      end
      if @advance
        available=@candidate['schedule_id']==@current_schedule_id && !@result_view['champion'] &&
          (@candidate['roster'] + [@publication['__insertion_user'].downcase]).include?(@workspace.actor.downcase) &&
          %w[groups_knockout knockout].include?(@candidate['format'])
        available ? @form.show(@advance) : @form.hide(@advance)
      end
    end

    def team_names
      (@candidate.dig('membership','units') || []).to_h{|unit|[unit['unit_id'],unit['accounts'].join(' + ')]}
    end

    def completed_match?(match)
      @result_view && @result_view['results'].any?{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
    end

    def forfeit_available?
      match=@matches && @matches[@match_list.index]
      @candidate && @candidate['schedule_id']==@current_schedule_id && @result_view && match && @publication['__insertion_user'].downcase==@workspace.actor.downcase &&
        ((@result_view['forfeitable_matches'] || [])+(@result_view['cancellable_matches'] || [])).any?{|row|row['match_id']==match['match_id'] && row['leg']==match['leg']} &&
        !@result_view['results'].any?{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
    end
    def experimental_ui?;@workspace.respond_to?(:experimental_ui?) && @workspace.experimental_ui?;end
    def completed_match_selected?
      match=@matches && @matches[@match_list.index]
      match && completed_match?(match)
    end

    def show_match_result
      return unless current? && completed_match_selected?
      match=@matches[@match_list.index]
      receipt=@result_view['results'].find{|row|row['match_id']==match['match_id'] && row['leg']==match['leg']}
      value=result_label(receipt.fetch('summary'),team_names)
      if receipt['kind']=='ordinary-match-forfeit-v2'
        loser=receipt.fetch('decision').fetch('loser')
        value += "\n"+text(_("%{player} loses by forfeit. Organizer: %{organizer}."))%{
          player:team_names.fetch(loser,loser),organizer:receipt.fetch('organizer')}
        explanation=ServerForfeitScreen.explanation(receipt)
        value += "\n"+text(explanation) if explanation
      end
      details=readonly(_("Result details"),value)
      back=Button.new(text(_("Back")))
      form=GameRoomUI::Form.new([details,back],program:@program,quiet:true)
      form.hide(back)
      form.cancel_button=back
      back.on(:press){form.resume}
      form.wait
    end

    def forfeit_diagnostics(view)
      lines=[]
      if view && !view.fetch('forfeit_conflicts',[]).empty?
        lines << text(_("Conflicting match results were recorded. The first complete result remains in effect."))
      end
      if view && !view.fetch('forfeit_unavailable_matches',[]).empty?
        lines << text(_("To decide a match in progress, join its table as an observer. A match with unavailable history cannot be decided here."))
      end
      lines
    end

    def match_context(menu)
      selected_match_context_actions(menu)
      @form.append_game_room_invitation(menu)
    end

    def selected_match_context_actions(menu)
      match=@matches && @matches[@match_list.index]
      return unless @candidate && match
      identity=[@candidate['schedule_id'],match['match_id'],match['leg']]
      actions=[]
      if completed_match?(match)
        actions << [_("Result details"),'w',-> {interaction{show_match_result}}]
        if return_match_for(match)
          actions << [_("Play return match"),'g',-> {
            following=return_match_for(match)
            if following
              @match_list.index=@matches.index(following)
              @play.press
            end
          }]
        end
      elsif @candidate['schedule_id']==@current_schedule_id
        actions << [_("Play"),'g',-> {@play.press}] if match['players'].include?(@workspace.actor.downcase)
        actions << [_("Award forfeit"),'f',-> {@forfeit.press}] if @forfeit && forfeit_available?
      end
      actions.each do |label,key,action|
        menu.option(text(label),nil,key) do
          selected=@matches && @matches[@match_list.index]
          action.call if current? && selected && identity==[@candidate&.fetch('schedule_id'),selected['match_id'],selected['leg']]
        end
      end
    end

    def return_match_for(match)
      return unless @candidate['schedule_id']==@current_schedule_id && match['players'].include?(@workspace.actor.downcase)
      @matches.compact.find do |following|
        following['leg']>match['leg'] && following['players'].sort==match['players'].sort &&
          following['unit_ids']&.sort==match['unit_ids']&.sort && !completed_match?(following)
      end
    end
    def ordered_matches(matches)
      matches.group_by{|match|[match['players'].sort,match['unit_ids']&.sort]}.values.flat_map{|pair|pair.sort_by{|match|match['leg']}}
    end

    def phase_label(candidate)
      PhaseDescription.label(candidate)
    end

    def match_label(match)
      names=match['unit_ids'] ? MatchOrder.players(@candidate['matches'],match,key:'unit_ids').map{|id|team_names.fetch(id)} : MatchOrder.players(@candidate['matches'],match)
      result=@result_view && @result_view['results'].find{|receipt|receipt['match_id']==match['match_id'] && receipt['leg']==match['leg']}
      status=result ? result_label(result['summary'],team_names).lines.map(&:strip).join('; ') : text(_("To be played"))
      status=text(_("Forfeit"))+"; "+status if result && %w[ordinary-match-forfeit-v1 ordinary-match-cancel-forfeit-v1 ordinary-match-forfeit-v2].include?(result['kind'])
      label=names.join(' — ')
      label+="; "+text(_("Return match")) if match['leg']==2
      label+"; "+status
    end

    def result_label(summary,teams={})
      outcome=summary['draw'] ? text(_("Draw")) : text(_("Winner: %{players}"))%{players:summary.fetch('winners').map{|unit|teams.fetch(unit,unit)}.join(', ')}
      if summary['places']
        place=1
        outcome=summary['places'].map do |group|
          line="#{place}. "+group.map { |unit| teams.fetch(unit,unit) }.join(', ')
          place+=group.size
          line
        end.join("\n")
      end
      scores=summary['scores']
      return outcome unless scores && !scores.empty?
      score=summary.fetch('participants').map{|player|"#{teams.fetch(player,player)}: #{scores.fetch(player)}"}.join('; ')
      outcome+"\n"+text(_("Game score: %{score}"))%{score:score}
    end
  end
end

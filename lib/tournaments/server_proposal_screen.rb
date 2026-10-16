# encoding: UTF-8
require_relative 'tournament_window'
require_relative 'server_workspace'
require_relative '../game_room_background'

module GameRoomTournaments
  # One Play action followed by a cancellable wait. Consent is scoped to a
  # specific invitation, never to another fixture or a reopened screen.
  class ServerProposalScreen < TournamentWindow
    using GameRoomLocalization::Translations
    def initialize(program:,workspace:,owner:,publication:,match:,clock:-> {GameRoomClock.now.to_i},play:false,accepted_token:nil,expected_token:nil,invitation_proof:nil)
      super(program:program,workspace:workspace,owner:owner)
      @publication,@match=publication,Publication::Data.freeze_tree(Publication::Data.copy(match))
      @clock,@initial_play,@accepted_token=clock,play,accepted_token
      @expected_token=expected_token
      @invitation_proof=invitation_proof && Publication::Data.freeze_tree(Publication::Data.copy(invitation_proof))
      @read_generation=0
      @reference={'author'=>publication['__insertion_user'].downcase,'publication_key'=>publication['publication_key']}.freeze
    end
    def run
      super
    ensure
      @refresh_work&.close
    end
    private
    def build_form
      @details=readonly(_("Tournament match"),'')
      @play=button(_("Play")){play_match}
      @cancel=Button.new(text(_("Cancel invitation")))
      refresh=button(_("Refresh")){perform('read')}
      back=button(_("Back"))
      make_form([@details,@play,@cancel,refresh,back],cancel:back)
      # Cancel and Escape withdraw only this pending consent, not tournament
      # membership. Do not leave a promise to open some later match.
      @cancel.on(:press){interaction{cancel_invitation}}
      back.on(:press){interaction{cancel_invitation}}
      @form.hide(back)
      @form.cancel_button=@cancel
      @form.accept_button=@play
      @form.hub_update=method(:update_invitation)
      if @workspace.respond_to?(:proposal_view_on_worker) && @program.class.respond_to?(:tournament_view_revision)
        @refresh_work=GameRoomBackground::Work.new(runtime:@program.class.app_runtime)
        @view_revision=view_revision
      end
      initial=invitation_view
      initial ? render(initial) : perform('read')
      if @expected_token && @observed && (@observed['token']!=@expected_token ||
          !%w[awaiting_consent consented].include?(@observed['state']) && !@observed['table_available'])
        @owner.notify(text(_("This match invitation is no longer available.")))
        return finish
      end
      play_match if @initial_play && @observed
    end

    # Opening a notification has just verified its sender and current proposal
    # on a worker. Use that observation for the initial display only. Accept
    # still goes through shared_proposal with the exact token and a fresh read;
    # neither this observation nor a notification grants native table entry.
    def invitation_view
      proof,@invitation_proof=@invitation_proof,nil
      return unless proof && @initial_play
      notice=proof.fetch('metadata')
      unless proof['status']=='confirmed' && notice['publication_ref']==@reference &&
          notice['match_id']==@match['match_id'] && notice['leg']==@match['leg'] &&
          notice['token']==@expected_token && notice['recipient']==@workspace.actor.downcase
        raise ArgumentError,'Invitation observation belongs to another match or account'
      end
      # Already accepted invitations may refer to an existing table. Read its
      # binding normally instead of inferring one from a notification proof.
      return if proof.fetch('accepted').include?(@workspace.actor.downcase)
      return unless proof.dig('window','opens')<=@clock.call && @clock.call<proof.dig('window','closes')
      proof.slice('players','accepted','window').merge('token'=>notice['token'],
        'state'=>'awaiting_consent','table_available'=>false)
    end

    def play_match
      return unless current? && @observed
      if @observed['table_available']
        @open_requested=true
      elsif %w[missing expired declined].include?(@observed['state'])
        perform('propose')
      elsif %w[awaiting_consent consented].include?(@observed['state'])
        if @observed['accepted'].include?(@workspace.actor.downcase)
          @accepted_token=@observed['token']
          render(@observed)
        else
          perform('accept')
        end
      end
    end

    def cancel_invitation
      if current? && @observed && @accepted_token==@observed['token'] &&
          %w[awaiting_consent consented].include?(@observed['state']) && !@observed['table_available']
        perform('decline')
      end
      @accepted_token=nil
      finish
    end

    def perform(action)
      return unless current?
      token=@observed && @observed['token']
      @read_generation+=1
      @view_revision=view_revision
      @observed=nil
      @form.hide(@play)
      result=@workspace.shared_proposal(publication_ref:@reference,match_id:@match['match_id'],leg:@match['leg'],action:action,token:token,
        intent_id:action=='read' ? nil : SecureRandom.uuid,context:@context,lease:@lease)
      return unless current?
      unless result
        @details.set_text(text(_("The invitation could not be checked. Refresh before trying again.")))
        return
      end
      @accepted_token=result['token'] if %w[accept propose].include?(action) && result['accepted'].include?(@workspace.actor.downcase)
      @accepted_token=nil if action=='decline'
      render(result)
    end

    def render(result)
      @observed=result
      actor=@workspace.actor.downcase
      waiting=result['players']-result['accepted']
      label=case result['state']
      when 'missing' then _("Choose Play to invite the other players.")
      when 'awaiting_consent' then text(_("Waiting for: %{players}"))%{players:waiting.join(', ')}
      when 'consented' then _("All players accepted. Opening the match table.")
      when 'declined' then _("The invitation was declined. You can arrange another time to play.")
      when 'expired' then _("This invitation expired. Choose Play to send a new one.")
      when 'completed' then _("This match has already finished.")
      else raise ArgumentError,'Unknown match invitation status'
      end
      label=_("The match table is open.") if result['table_available']
      value=[result['players'].join(' — '),text(label)].join("\n")
      if @details.text!=value
        index,check=@details.index,@details.check
        @details.set_text(value)
        @details.index,@details.check=index,check
      end
      available=result['players'].include?(actor) && result['state']!='completed' &&
        (@accepted_token!=result['token'] || !%w[awaiting_consent consented].include?(result['state']))
      available ? @form.show(@play) : @form.hide(@play)
      if @accepted_token==result['token'] && result['accepted'].include?(actor)
        @open_requested=true if result['table_available'] || result['state']=='consented' && actor==result['players'].first
      end
    end

    def view_revision
      @program.class.tournament_view_revision(@reference) if @program.class.respond_to?(:tournament_view_revision)
    end

    def update_invitation
      return if @busy || @finished || !@context.current?(@lease)
      if @open_requested
        @open_requested=false
        interaction do
          @program.open_ordinary_tournament_match(@publication,@match)
          finish
        end
        return
      end
      if (done=@refresh_work&.take)
        value,error=done
        if @refresh_generation==@read_generation
          if error
            raise error unless ServerWorkspace::ERRORS.any?{|kind|error.is_a?(kind)} || GameRoomNetworkErrors.expected?(error)
            @observed=nil
            @form.hide(@play)
            @details.set_text(text(_("The invitation could not be checked. Refresh before trying again.")))
            Log.warning("Tournament invitation refresh: #{error.class}: #{error.message}") if defined?(Log)
          elsif @refresh_revision==view_revision
            render(value)
          end
        end
      end
      if @observed && %w[awaiting_consent consented].include?(@observed['state']) && !@observed['table_available'] &&
          @observed.dig('window','closes') && @clock.call>=@observed['window']['closes']
        @accepted_token=nil
        render(@observed.merge('state'=>'expired'))
      end
      return unless @refresh_work && !@refresh_work.busy?
      revision=view_revision
      return if revision==@view_revision
      @view_revision=@refresh_revision=revision
      @refresh_generation=@read_generation
      # Reuse the just-delivered presentation for this exact fixture. Play,
      # Accept, Refresh and native entry still validate through the workspace.
      if @program.class.respond_to?(:tournament_proposal_snapshot)
        value=@program.class.tournament_proposal_snapshot(@reference,match_id:@match['match_id'],leg:@match['leg'])
        if value
          render(value)
          return
        end
      end
      @refresh_work.start do
        @workspace.proposal_view_on_worker(publication_ref:@reference,match_id:@match['match_id'],leg:@match['leg'],guard:-> {@context.current?(@lease)})
      end
    end
  end
end

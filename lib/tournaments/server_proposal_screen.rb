# encoding: UTF-8
require_relative 'local_fixed_team_plan_screen'

module GameRoomTournaments
  class ServerProposalScreen < LocalFixedTeamPlanScreen
    using GameRoomLocalization::Translations
    def initialize(program:,workspace:,owner:,publication:,match:)
      super(program:program,workspace:workspace,owner:owner)
      @publication,@match=publication,Publication::Data.freeze_tree(Publication::Data.copy(match))
    end
    private
    def build_form
      @details=readonly(_("Shared match proposal (server test)"),'')
      @propose=button(_("Propose this match (organizer)")){perform('propose')}
      @play=button(@match['leg']==2 ? _("Return match") : _("Play")){perform('accept')}
      @decline=button(_("Not now")){perform('decline')}
      refresh=button(_("Refresh")){perform('read')}
      back=button(_("Back"))
      make_form([@details,@propose,@play,@decline,refresh,back],cancel:back)
      perform('read')
    end

    def perform(action)
      return unless current?
      token=@observed && @observed['token']
      @observed=nil
      [@propose,@play,@decline].each{|button|@form.hide(button)}
      @details.set_text('')
      result=@workspace.shared_proposal(publication_ref:{'author'=>@publication['__insertion_user'],'publication_key'=>@publication['publication_key']},
        match_id:@match['match_id'],leg:@match['leg'],action:action,token:token,
        intent_id:action=='read' ? nil : SecureRandom.uuid,context:@context,lease:@lease)
      return unless current? && result
      @observed=result
      label=case result['state']
      when 'missing' then _("No shared match proposal yet.")
      when 'awaiting_consent' then _("Waiting for all players to accept.")
      when 'consented' then _("All players accepted this proposal.")
      when 'declined' then _("The proposal was declined. The match remains pending.")
      when 'expired' then _("The proposal expired or player readiness changed.")
      else raise ArgumentError,'Unknown pilot proposal status'
      end
      @details.set_text([text(_("Server proposal test: no automatic invitations, player reservations or table creation.")),
        result['players'].join(' — '),text(label),text(_("Accepted: %{players}"))%{players:result['accepted'].join(', ')}].join("\n"))
      actor=@workspace.actor.downcase
      if actor==@publication['__insertion_user'].downcase && %w[missing expired declined].include?(result['state'])
        @form.show(@propose)
      end
      if result['players'].include?(actor) && %w[awaiting_consent consented].include?(result['state'])
        @form.show(@play) unless result['accepted'].include?(actor)
        @form.show(@decline)
      end
    end
  end
end

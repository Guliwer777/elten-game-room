module GameRoomTournaments
  module LocalDispatchScreen
    using GameRoomLocalization::Translations
    private
    def additional_game_fields
      @execution_table_limit = EditBox.new(text(_("Maximum simultaneous tables")), text: '3', quiet: true)
      super + [@execution_table_limit, button(_("Set tournament table limit")) do
        raw = @execution_table_limit.text.strip
        if raw.match?(/\A[0-9]{1,2}\z/) && raw.to_i.between?(1, 32)
          start_fixed(:dispatch_configure, max_tables: raw.to_i)
        else
          @status.set_text(text(_("Enter a table limit from 1 to 32.")))
        end
      end, @dispatch_ready=button(_("I am ready to play")) { start_fixed(:dispatch_enable) },
        @dispatch_withdraw=button(_("Disable my availability for automatic matches")) { start_fixed(:dispatch_disable) },
        @dispatch_play=button(_("Play")) { start_fixed(:dispatch_accept) },
        @dispatch_decline=button(_("Not now")) { start_fixed(:dispatch_decline) },
        @dispatch_return=button(_("Return match")) { start_fixed(:dispatch_rematch) },
        @dispatch_not_now=button(_("Not now")) { start_fixed(:dispatch_not_now) },
        @dispatch_renew=button(_("Renew an expired tournament invitation")) { start_fixed(:dispatch_renew) }]
    end
    def start_fixed(action,**options)
      if %i[dispatch_accept dispatch_decline dispatch_rematch dispatch_not_now].include?(action)
        options=options.merge(proposal_token:@displayed_proposal_token)
      end
      super(action,**options)
    end
    def drain_fixed
      if !@busy && !@readiness_pending && current?
        effect = @controller.dispatch_update
        if effect
          @dispatch_status = effect
          @status.set_text(status_text)
        end
      end
      super
      effect = @controller.view[:dispatch]
      if effect && !effect.equal?(@last_dispatch_view)
        @last_dispatch_view = effect
        @dispatch_status = effect
        @status.set_text(status_text)
      end
    end
    def status_text
      value = super
      update_dispatch_controls
      if @dispatch_status
        value += "\r\n" + text(_("Automatic matches: %{state}; reason: %{reason}")) % {
          state: @dispatch_status[:reason] == :matches_completed ? text(_("Completed")) : dispatch_state_text(@dispatch_status[:state]),
          reason: dispatch_reason_text(@dispatch_status[:reason])}
        status = @dispatch_status[:status]
        if status
          value += "\r\n" + text(_("Active tournament tables: %{active} of %{maximum}")) % {active: status['active'].size, maximum: status['max_tables']}
          proposal=status['proposal']
          value += "\r\n" + text(_("Proposed match: %{players}"))%{players:proposal['players'].join(' — ')} if proposal
        end
      end
      value
    end
    def update_dispatch_controls
      return unless @form && @dispatch_play
      snapshot=@dispatch_status && @dispatch_status[:status]
      if snapshot && @controller && snapshot['intent_id']!=@controller.view[:selected_id]
        @dispatch_status=nil
        snapshot=nil
      end
      actor=@workspace.actor.downcase
      proposal=snapshot && snapshot['proposal']
      @displayed_proposal_token=proposal && proposal['token']
      active=snapshot && snapshot['active'].find{|row|row['players'].include?(actor)}
      ready=snapshot && snapshot['own_ready']
      rematch=proposal && proposal['leg']==2
      accepted=proposal && proposal['accepted'].include?(actor)
      visible={@dispatch_ready=>!ready && !active,@dispatch_withdraw=>!!ready,
        @dispatch_play=>(proposal && !rematch && !accepted) || (active && active['bound'] && !active['started']),
        @dispatch_decline=>proposal && !rematch,@dispatch_return=>rematch && !accepted,
        @dispatch_not_now=>!!rematch,@dispatch_renew=>@dispatch_status && @dispatch_status[:state]==:invited}
      visible.each{|field,show|show ? @form.show(field) : @form.hide(field)}
    end
    def boundary_text
      super + "\r\n" + text(_("The running local dispatcher renews your availability. It expires 60 seconds after renewal stops; online presence is not connected yet."))
    end
    def dispatch_state_text(state)
      label = case state
      when :enabled then _("Availability enabled")
      when :disabled then _("Availability disabled")
      when :waiting then _("Waiting for the next match")
      when :awaiting_invitation then _("Waiting for an invitation")
      when :invited then _("Waiting for participants to accept")
      when :confirmed then _("Confirmed")
      when :awaiting_consent then _("Waiting for all participants to accept the match")
      when :awaiting_rematch then _("Return match available. All participants must accept; Not now keeps it pending.")
      when :declined then _("Match declined. Choose I am ready to play to receive another proposal.")
      when :blocked then _("Action unavailable")
      when :uncertain then _("Confirmation pending")
      else state.to_s
      end
      text(label)
    end
    def dispatch_reason_text(reason)
      label = case reason
      when nil then '-'
      when :not_coordinator then _("Only the match coordinator can perform this action.")
      when :participants_unavailable then _("At least one participant is unavailable.")
      when :not_all_ready then _("Waiting for every participant to be ready.")
      when :invitation_required then _("The invitation is missing or has expired.")
      when :no_expired_invitation then _("There is no expired invitation to renew.")
      when :invitation_changed then _("The invitation changed. Check the current match.")
      when :invitation_not_expired then _("The invitation has not expired yet.")
      when :already_entered then _("The participant has already entered the match.")
      when :already_started then _("The game has already started.")
      when :table_limit then _("The tournament table limit has been reached.")
      when :participants_busy then _("A participant is already assigned to another match.")
      when :match_window_not_open then _("The scheduled match time has not started yet.")
      when :match_window_closed then _("The scheduled match time has ended. No result was awarded.")
      when :previous_match_pending then _("The first match must finish before the return match can start.")
      when :matches_completed then _("All your matches in this phase are completed.")
      when :availability_changed then _("Your availability changed in another client. Enable it again if you want to participate.")
      when :proposal_changed then _("This match proposal changed. Refresh before responding; no new opponent was accepted.")
      when :execution_interrupted then _("The match was interrupted because its authorization changed or its time limit expired. Automatic dispatch stopped; saved history and player reservations are retained. No result was awarded.")
      else reason.to_s
      end
      text(label)
    end
  end
end

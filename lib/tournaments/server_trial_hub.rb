# encoding: UTF-8
require_relative 'local_test_hub'
require_relative 'server_trial_workspace'
require_relative 'server_schedule_overview'
require_relative 'server_proposal_screen'

module GameRoomTournaments
  # Separate server test UI. No virtual actors or execution adapters.
  class ServerTrialHub < LocalTestHub
    using GameRoomLocalization::Translations
    private

    def setup_publish_label; _("Publish in server test"); end

    def use_participant(actor)
      return unless @owner.check && actor && actor.downcase == @owner.current.downcase
      @workspace = ServerTrialWorkspace.new(program: @program, registry: @registry,
        user: @owner.method(:current), alert: @alert, clock: @clock)
    end

    def context
      [@workspace.mode_label, text(_("Current identity: %{actor}")) % {actor: @workspace.actor},
        text(_("The separate server test shares tournaments and supports automatic results for matches between two individual players at ordinary public tables. Automatic invitations are not available yet."))].join("\n")
    end

    def build_form
      return unless use_participant(@owner.current)
      @summary = readonly(_("Server tournament test"), context)
      browse_button = button(_("Tournament list")) { browse if @owner.check }
      create = button(_("Create and publish tournament")) { create_tournament if @owner.check }
      operations = button(_("Operations")) { show_operations if @owner.check }
      back = button(_("Back"))
      make_form([@summary, browse_button, create, operations, back], cancel: back)
      @form.game_room_general_help_tips = [context]
    end

    def browse
      PublicScreen.new(program: @program, registry: @registry, load: @workspace.method(:load),
        join: @workspace.method(:join), withdraw: @workspace.method(:withdraw), alert: @alert,
        mode_label: @workspace.mode_label, actor: @workspace.actor, clock: @clock,
        edit_tournament: method(:edit_tournament), delete_tournament: method(:delete_tournament), overview: method(:show_server_schedule),
        manage_participants: method(:manage_server_participants), set_partner: @workspace.method(:set_partner)).run
      @owner.check
    end

    def show_server_schedule(row)
      ServerScheduleOverview.new(program: @program, workspace: @workspace, owner: @owner,
        publication: row).run if @owner.check
    end

    def manage_server_participants(row)
      LocalParticipantManager.new(program: @program, workspace: @workspace, owner: @owner,
        publication: row, confirm: @confirm, alert: @alert).run if @owner.check
    end
  end
end

# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'server_workspace'
require_relative 'public_screen'
require_relative 'operations_screen'
require_relative 'tournament_setup_editor'
require_relative 'participant_manager'
require_relative 'server_schedule_overview'
require_relative '../game_option_editor'
module GameRoomTournaments
  class SharedHub < Dialogs::Window
    using GameRoomLocalization::Translations
    def initialize(program:,registry:,user:,alert:,confirm:,clock:-> {GameRoomClock.now.to_i},workspace_factory:nil,mine:false)
      @program,@registry,@user,@alert,@confirm,@clock=program,registry,user,alert,confirm,clock
      @owner=Dialogs::Owner.new(user,alert)
      @mine=mine
      @workspace_factory=workspace_factory || -> {ServerWorkspace.new(program:@program,registry:@registry,user:@owner.method(:current),alert:@alert,clock:@clock,
        backend_uuid:@program.class.server_app_uuid)}
    end
    private
    def build_form
      return unless @owner.check
      @workspace=@workspace_factory.call
      browse_tournaments
    end
    def configure(game,options)
      GameRoomOptionEditor.new(program:@program,defaults:->(model,_definitions){model.default_options},remember:->(*){},alert:@alert).
        edit(game,initial_options:options,submit_label:_("Next"),require_confirmation:true)
    end
    def create_tournament
      intent='setup:'+SecureRandom.uuid
      publish=->(**values){@workspace.publish(intent_id:intent,**values) if @owner.check}
      TournamentSetupEditor.new(program:@program,registry:@registry,configure:method(:configure),publish:publish,
        alert:@alert,clock:@clock,publish_label:_("Publish tournament")).wait
    end
    def browse_tournaments
      PublicScreen.new(program:@program,registry:@registry,load:@workspace.method(:load),join:@workspace.method(:join),
        withdraw:@workspace.method(:withdraw),alert:@alert,mode_label:@workspace.mode_label,actor:@workspace.actor,
        overview:method(:show_schedule),results:->(row){show_schedule(row,mode: :results)},
        phase:method(:change_phase),manage_participants:method(:manage_participants),set_partner:@workspace.method(:set_partner),
        edit_tournament:method(:edit_tournament),delete_tournament:method(:delete_tournament),
        create:-> {create_tournament if @owner.check},recover:-> {show_operations if @owner.check},mine:@mine,clock:@clock).run
    end
    def show_schedule(row,mode: :matches)
      ServerScheduleOverview.new(program:@program,workspace:@workspace,owner:@owner,publication:row,mode:mode).run if @owner.check
    end
    def change_phase(row,action)
      return unless @owner.check
      @phase_intents ||= {}
      generation=RegistrationProjection.publication_generation(row)
      intent=@phase_intents[[row['__id'],generation,action]] ||= SecureRandom.uuid
      result=@workspace.change_phase(tournament_id:row['__id'],action:action,intent_id:intent,expected_generation:generation)
      @alert.call(text(result && result['status']=='confirmed' ? _("Tournament updated.") : _("The change could not be confirmed. Refresh to check its status.")))
    end
    def manage_participants(row)
      ParticipantManager.new(program:@program,workspace:@workspace,owner:@owner,publication:row,confirm:@confirm,alert:@alert).run if @owner.check
    end
    def edit_tournament(row)
      intent='edit:'+SecureRandom.uuid
      publish=->(**values){@workspace.edit_tournament(tournament_id:row['__id'],intent_id:intent,
        expected_generation:RegistrationProjection.publication_generation(row),**values) if @owner.check}
      TournamentSetupEditor.new(program:@program,registry:@registry,configure:method(:configure),publish:publish,
        alert:@alert,clock:@clock,publication:row).wait
    end
    def delete_tournament(row)
      return unless @owner.check && @confirm.call(text(_("Cancel tournament %{title}?"))%{title:row['title']}) && @owner.check
      @deletion_intents ||= {}
      intent=@deletion_intents[row['__id']] ||= 'delete:'+SecureRandom.uuid
      result=@workspace.delete_tournament(row['__id'],intent,RegistrationProjection.publication_generation(row))
      @alert.call(text(result && result['status']=='confirmed' ? _("Tournament cancelled.") : _("The change could not be confirmed. Refresh to check its status.")))
    end
    def show_operations
      OperationsScreen.new(program:@program,load:@workspace.method(:operations),reconcile:@workspace.method(:reconcile),
        alert:@alert,mode_label:@workspace.mode_label,actor:@workspace.actor).run
    end
  end
end

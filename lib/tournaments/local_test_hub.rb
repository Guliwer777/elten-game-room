# encoding: UTF-8
require_relative 'local_test_dialogs'
require_relative 'local_workspace'
require_relative 'draft_workspace'
require_relative 'public_screen'
require_relative 'operations_screen'
require_relative 'publication_editor'
require_relative 'local_registration_time'
require_relative 'match_entry_screen'
require_relative 'local_fixed_team_execution_screen'
require_relative 'local_fixed_team_plan_screen'
require_relative 'local_individual_execution_screen'
require_relative 'local_individual_plan_screen'
require_relative 'local_tournament_overview'
require_relative 'tournament_setup_editor'
require_relative 'local_participant_manager'

module GameRoomTournaments
  class LocalTestHub < LocalTestDialogs::Window
    using GameRoomLocalization::Translations

    def initialize(program:, registry:, user:, alert:, confirm:, clock: -> { Time.now.to_i }, open_setup: false, open_browse: false)
      @program, @registry, @user, @alert, @confirm = program, registry, user, alert, confirm
      @owner = LocalTestDialogs::Owner.new(user, alert)
      @clock = clock
      @open_setup = open_setup
      @open_browse = open_browse
      @readiness_session = LocalReadinessSession.new
    end

    def run
      return if @running || @finished
      begin
        super
      ensure
        @readiness_session.close
      end
    end

    private

    def build_form
      unless use_participant(@owner.current)
        @finished = true
        return
      end
      @summary = readonly(_("Local tournament tests"), context)
      browse_button = button(_("Browse local test tournaments")) { browse if @owner.check }
      operations = button(_("Operations")) { show_operations if @owner.check }
      publish = button(_("Publish a draft in local test")) { choose_draft if @owner.check }
      create = button(_("Create and publish tournament")) { create_tournament if @owner.check }
      change = button(_("Change test participant")) do
        if change_participant
          @summary.set_text(context)
          @form.game_room_general_help_tips = [context]
        end
      end
      back = button(_("Back"))
      matches = button(_("My matches — readiness and coordination")) { show_matches if @owner.check }
      fixed = button(_("Fixed teams — local execution")) { show_fixed_team_matches if @owner.check }
      individual = button(_("Individual matches — local execution")) do
        @individual_entry = LocalIndividualExecutionScreen.new(program: @program, workspace: @workspace, owner: @owner)
        begin
          @individual_entry.run if @owner.check
        ensure
          @individual_entry = nil
        end
      end
      individual_plan = button(_("Individual matches — create a plan")) do
        LocalIndividualPlanScreen.new(program: @program, workspace: @workspace, owner: @owner).run if @owner.check
      end
      plan = button(_("Fixed teams — create a plan")) do
        LocalFixedTeamPlanScreen.new(program: @program, workspace: @workspace, owner: @owner).run if @owner.check
      end
      advanced_fields = [change, operations, publish, matches, plan, fixed, individual_plan, individual]
      advanced = button(_("Advanced local test tools")) do
        @advanced_open = !@advanced_open
        advanced_fields.each { |field| @advanced_open ? @form.show(field) : @form.hide(field) }
      end
      make_form([@summary, create, browse_button, advanced, *advanced_fields, back], cancel: back)
      advanced_fields.each { |field| @form.hide(field) }
      @form.game_room_general_help_tips = [context]
      create_tournament if @open_setup && @owner.check
      browse if @open_browse && @owner.check
    end

    def change_participant
      return unless @owner.check
      actor = LocalTestDialogs::Participant.new(program: @program, owner: @owner, alert: @alert).run
      valid_owner = actor ? @owner.check : @owner.current
      return unless actor && valid_owner
      use_participant(actor)
    end

    def use_participant(actor)
      return unless actor && @owner.check
      actor = Publication::Data.account(actor)
      @readiness_session.choose_actor(actor)
      @workspace = LocalWorkspace.new(program: @program, registry: @registry,
        user: @owner.method(:current), actor: actor, alert: @alert, clock: @clock,
        readiness_session: @readiness_session)
    rescue Publication::Invalid
      @alert.call(text(_("The local test account or participant is invalid. Close this window and reopen local tournament tests.")))
      nil
    end

    def create_tournament
      # Simulation actors never become the organizer of a newly created tournament.
      return unless use_participant(@owner.current)
      @summary.set_text(context)
      @form.game_room_general_help_tips = [context]
      drafts = DraftWorkspace.new(program: @program, registry: @registry, user: @owner.method(:current), alert: @alert, confirm: @confirm)
      workspace = @workspace
      intent = 'setup:' + SecureRandom.uuid
      publish = ->(**values) { workspace.publish(intent_id: intent, **values) if @owner.check }
      TournamentSetupEditor.new(program: @program, registry: @registry, configure: drafts.method(:configure),
        publish: publish, alert: @alert, clock: @clock, publish_label: setup_publish_label).wait
    end

    def setup_publish_label; nil; end

    def browse
      PublicScreen.new(program: @program, registry: @registry, load: @workspace.method(:load),
        join: @workspace.method(:join), alert: @alert, mode_label: @workspace.mode_label, actor: @workspace.actor,clock:@clock,
        join_virtual: method(:join_virtual), overview: method(:show_tournament), withdraw: @workspace.method(:withdraw), manage_participants: method(:manage_participants), set_partner: method(:set_partner), edit_tournament: method(:edit_tournament), delete_tournament: method(:delete_tournament)).run
      @owner.check
    end

    def join_virtual(tournament_id, name)
      return unless @owner.check
      actor = Publication::Data.account(name)
      workspace = LocalWorkspace.new(program: @program, registry: @registry,
        user: @owner.method(:current), actor: actor, alert: @alert, clock: @clock)
      workspace.join(tournament_id)
    rescue Publication::Invalid
      @alert.call(text(_("The local test account or participant is invalid. Close this window and reopen local tournament tests.")))
      nil
    end

    def manage_participants(publication)
      return unless @owner.check
      LocalParticipantManager.new(program: @program, workspace: @workspace, owner: @owner,
        publication: publication, confirm: @confirm, alert: @alert).run
    end

    def set_partner(id, actor, partner, intent)
      return unless @owner.check
      LocalWorkspace.new(program: @program, registry: @registry, user: @owner.method(:current),
        actor: actor, alert: @alert, clock: @clock).set_partner(id, actor, partner, intent)
    end

    def edit_tournament(publication)
      return unless @owner.check
      drafts = DraftWorkspace.new(program: @program, registry: @registry, user: @owner.method(:current), alert: @alert, confirm: @confirm)
      intent = 'edit:' + SecureRandom.uuid
      callback = ->(**attributes) { @workspace.edit_tournament(tournament_id: publication['__id'], intent_id: intent, expected_generation: RegistrationProjection.publication_generation(publication), **attributes) if @owner.check }
      TournamentSetupEditor.new(program: @program, registry: @registry, configure: drafts.method(:configure), publish: callback,
        alert: @alert, clock: @clock, publication: publication).wait
    end

    def delete_tournament(publication)
      return unless @owner.check
      return unless @confirm.call(text(_("Delete tournament %{title}?")) % {title: publication['title']}) && @owner.check
      @deletion_intents ||= {}
      intent = @deletion_intents[publication['__id']] ||= 'delete:' + SecureRandom.uuid
      result = @workspace.delete_tournament(publication['__id'], intent, RegistrationProjection.publication_generation(publication))
      @alert.call(text(result && result['status'] == 'confirmed' ? _("Tournament deleted.") : _("Tournament deletion not confirmed. Check Operations.")))
    end

    def show_tournament(row)
      LocalTournamentOverview.new(program: @program, workspace: @workspace, owner: @owner,
        publication: row).run if @owner.check
    end

    def show_matches
      @match_entry = MatchEntryScreen.new(program: @program, workspace: @workspace, owner: @owner)
      @match_entry.run
      @owner.check
    ensure
      @match_entry = nil
    end

    def show_fixed_team_matches
      @fixed_team_entry = LocalFixedTeamExecutionScreen.new(program: @program, workspace: @workspace, owner: @owner)
      @fixed_team_entry.run
      @owner.check
    ensure
      @fixed_team_entry = nil
    end

    def show_operations
      OperationsScreen.new(program: @program, load: @workspace.method(:operations),
        reconcile: @workspace.method(:reconcile), alert: @alert,
        mode_label: @workspace.mode_label, actor: @workspace.actor).run
      @owner.check
    end

    def choose_draft
      rows = DraftWorkspace.new(program: @program, registry: @registry, user: @owner.method(:current),
        alert: @alert, confirm: @confirm).load
      return unless rows && @owner.check
      if rows.empty?
        @alert.call(text(_("No local drafts. Create a draft in Local tournament drafts in the previous menu first.")))
        return
      end
      LocalTestDialogs::DraftPicker.new(program: @program, registry: @registry, rows: rows,
        owner: @owner, alert: @alert, context: context, publish: method(:publish_draft)).run
      @owner.check
    end

    def publication_snapshot(row)
      data = Publication::Data
      draft = data.freeze_tree(data.copy(row))
      unless data.text?(draft['id']) && Drafts::UUID.match?(draft['id']) && data.integer?(draft['revision'], 1)
        raise Publication::Invalid, :invalid_draft_identity
      end
      intent = "draft:#{draft['id']}:revision:#{draft['revision']}"
      # Dziennik przyjmuje do 256 bajtów zamiaru, nigdy tytuł ani losowy klucz UI.
      data.text!(intent, bytes: 256)
      [draft, intent.freeze]
    rescue Publication::Invalid
      @alert.call(text(_("The draft identity, revision or data is invalid. Reopen local tournament drafts.")))
      nil
    end

    def publish_draft(row)
      return unless @owner.check
      snapshot = publication_snapshot(row)
      return unless snapshot
      draft, intent = snapshot
      workspace = @workspace
      operations = workspace.operations
      return unless operations && @owner.check
      if operations.any? { |record| record.fetch('kind') == 'publication' && record.fetch('intent_id') == intent }
        @alert.call(text(_("A publication operation for this draft revision already exists. Use Operations to check it; no new publication will be sent.")))
        show_operations if @owner.check
        return
      end
      save = lambda do |**values|
        next unless @owner.check
        result = workspace.publish(draft: draft, intent_id: intent, **values)
        @owner.check ? result : nil
      end
      PublicationEditor.new(program: @program, draft: draft, registry: @registry, mode_label: workspace.mode_label,
        actor: workspace.actor, timezone: workspace.timezone, convert_time: method(:convert_time),
        save: save, alert: @alert, clock: @clock).wait
      @owner.check
    end

    def convert_time(date, time)
      LocalRegistrationTime.convert(date, time)
    rescue LocalRegistrationTime::Invalid => error
      code = case error.code
      when :invalid_date, :invalid_time, :nonexistent_time, :invalid_timestamp then :invalid_time
      when :ambiguous_time, :unsupported_time then error.code
      else
        raise ArgumentError, "Unknown registration time error: #{error.code}"
      end
      raise PublicationEditor::InvalidTime, code
    end

    def context
      [@workspace.mode_label, text(_("Test actor: %{actor}")) % {actor: @workspace.actor},
        text(_("Data stays on this computer. Test names do not authenticate network accounts. No invitations or matches are started."))].join("\r\n")
    end
  end
end

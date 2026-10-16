# encoding: UTF-8
require 'securerandom'
require_relative 'local_fixed_team_plan_screen'
require_relative 'local_match_labels'

module GameRoomTournaments
  class LocalOrganizerDecisionScreen < LocalFixedTeamPlanScreen
    using GameRoomLocalization::Translations
    def initialize(program:, workspace:, owner:, rows:)
      super(program: program, workspace: workspace, owner: owner)
      @entries = rows.flat_map do |item|
        record = item['record']
        next [] unless record['preview']['source']['candidate']['publication_ref']['author'].downcase == workspace.actor.downcase
        record['evidence']['plan']['matches'].each_with_index.map { |match, index| [record, match, index + 1] }
      end
    end
    private
    def build_form
      @matches = ListBox.new(@entries.map { |record, match, _number|
        "#{LocalMatchLabels.phase(record)}: #{LocalMatchLabels.match(record, match)}" },
        header: text(_("Match for organizer decision")), quiet: true)
      @winner = ListBox.new([], header: text(_("Winner by forfeit")), quiet: true)
      @reason = EditBox.new(text(_("Reason for organizer decision")), type: EditBox::Flags::MultiLine, text: '', quiet: true)
      @status = readonly(_("Decision status"), '')
      @matches.on(:move) { interaction(restore: false) { load_status } }
      check = button(_("Check decision")) { load_status }
      award = button(_("Confirm forfeit: 2 points to winner, 0 to loser, no small points")) { award_forfeit }
      back = button(_("Back"))
      make_form([@matches, @winner, @reason, @status, check, award, back], cancel: back)
      load_status
    end
    def call_operation(action, input)
      record = @entries[@matches.index]&.first
      return unless record && current?
      method = record['evidence']['version'] == 1 ? :individual_plan : :fixed_team_plan
      result = @workspace.public_send(method, action: action, input: input,
        context: @context, lease: @lease, session: @session)
      result && result[:state] == :confirmed ? result[:value] : result
    end
    def selectors
      record, match = @entries.fetch(@matches.index)
      {'intent_id' => record['preview']['intent_id'], 'match_id' => match['match_id'],
        'leg' => match['leg'], 'window_id' => match['windows'].first['id']}
    end
    def load_status
      return if @entries.empty?
      # An uncertain write remains attached to its original match.
      @matches.index = @pending_index if @pending
      record, match = @entries.fetch(@matches.index)
      @units = match['players'].group_by { |p| record['evidence']['version'] == 2 ? p['team'] : p['account'] }
      @winner.update_options(@units.values.map { |people| people.map { |p| p['username'] }.join(' — ') }, keys: @units.keys)
      value = call_operation(:organizer_result_status, {'selectors' => selectors})
      @revision = value && value[:state] == :confirmed ? value[:revision] : nil
      unless value && value[:state] == :confirmed
        @status.set_text(text(_("Plan operation blocked: %{reason}")) % {reason: value && (value[:reason] || value[:state]) || 'read_failed'})
        return
      end
      receipt = value && value[:result]
      if receipt
        @status.set_text(text(_("Result already recorded. It cannot be overwritten.")) + "\r\n" + GameRoomContent.utf8(receipt['reason'] || ''))
        @pending = nil if @pending && receipt['id'] == @pending['operation_id']
        @revision = nil
      else
        @status.set_text(text(@pending ? _("Decision unconfirmed. Check decision before any further action.") : _("Choose the winner and enter the reason. No result is awarded automatically.")))
      end
    end
    def award_forfeit
      return if @pending || !@revision || @entries.empty? || !current?
      if @reason.text.strip.empty?
        @status.set_text(text(_("Enter the reason for this decision.")))
        return
      end
      @pending_index = @matches.index
      @pending = {'selectors' => selectors, 'operation_id' => SecureRandom.uuid, 'winner' => @units.keys.fetch(@winner.index),
        'reason' => GameRoomContent.utf8(@reason.text), 'expected_revision' => @revision}
      outcome = call_operation(:organizer_forfeit, @pending)
      if outcome && outcome[:state] == :confirmed
        @pending = nil
        load_status
      elsif outcome && outcome[:state] == :blocked
        @pending = nil
        @revision = nil
        @status.set_text(text(_("Plan operation blocked: %{reason}")) % {reason: outcome[:reason]})
      else
        @status.set_text(text(_("Decision unconfirmed. Check decision before any further action.")))
      end
    end
  end
end

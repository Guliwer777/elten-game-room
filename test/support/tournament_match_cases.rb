# encoding: UTF-8
require_relative 'tournament_match_invitation'
require 'timeout'

module TournamentMatchCases
  module_function

  def rejected(scenario, stage)
    outcome = scenario.join
    assert(!outcome.result.is_a?(LobbyRepository::JoinResult), "#{stage}: nie odmówiono")
    assert(scenario.old_present? && scenario.calls[:leave] == 0 && scenario.calls[:complete] == 0, "#{stage}: skutek po odmowie")
    outcome
  end

  def dialog_changes
    mutations = {
      'kolejność' => ->(data) { data['players'].reverse! },
      'konto' => ->(data) { data['players'][1]['account'] = 'carol' },
      'rola' => ->(data) { data['players'][0]['role'] = 'observer' },
      'miejsce' => ->(data) { data['players'][0]['seat'] = 1 },
      'drużyna' => ->(data) { data['players'][0]['team'] = 'other' },
      'opcja bool/int' => ->(data) { data['options']['draw_responses'] = 1 },
      'generacja' => ->(data) { data['execution_generation'] = 'other' },
      'native UUID' => ->(data) { data['native_uuid'] = 'other' },
      'gotowość' => ->(data) { data['reservation']['ready_versions']['bob'] = 'other' }
    }
    mutations.each do |label, mutation|
      scenario = TournamentMatchScenario.new
      scenario.alice.define_singleton_method(:confirm) { |_text| scenario.change_target(&mutation); true }
      assert(scenario.alice.confirm('Zgoda na dokładny cel'), 'Fixture nie zakończył dialogu')
      rejected(scenario, "dialog #{label}")
      assert(scenario.membership.establish_count == 0, "#{label}: establish przed odrzuceniem")
    end
  end

  def context_changes
    %w[account backend runtime cancel epoch].each do |kind|
      [false, true].each do |during|
        scenario = TournamentMatchScenario.new
        change = lambda do
          case kind
          when 'account' then scenario.context['account'] = 'bob'
          when 'backend' then scenario.context['scope'] = scenario.context['scope'].merge('backend_identity' => 'other')
          when 'runtime' then scenario.context['runtime_id'] = 'new-runtime'
          when 'cancel' then scenario.context['cancelled'] = true
          when 'epoch' then scenario.context['epoch'] += 2
          end
        end
        during ? scenario.port.during_read = change : change.call
        rejected(scenario, "kontekst #{kind}/#{during}")
        assert(scenario.membership.establish_count == 0, 'Kontekst nie zablokował establish')
      end
    end
  end

  def readback_failures
    %w[pending unknown conflict unsupported refused absent_final].each do |state|
      scenario = TournamentMatchScenario.new
      scenario.port.response['status'] = state
      rejected(scenario, state)
      assert(scenario.membership.establish_count == 0, 'Niepotwierdzony odczyt użyty jak ordinary')
    end
    scenario = TournamentMatchScenario.new
    scenario.acceptance.instance_variable_set(:@bound_membership, nil)
    result = rejected(scenario, 'Brak bezpiecznego cleanup')
    assert(result.result == :membership_ownership_unavailable && scenario.membership.establish_count == 0, 'Stary cleanup użyty dla bound')
    scenario = TournamentMatchScenario.new
    scenario.port.response['capabilities'] = {}
    rejected(scenario, 'Brak capability')
    assert(scenario.membership.establish_count == 0, 'Brak capability nie zablokował skutku')
  end

  def program_errors
    [1, 3].each do |read_number|
      scenario = TournamentMatchScenario.new
      direct = ArgumentError.new('pierwotna przyczyna')
      program_error = begin
        raise ProgramError.new('błąd programu'), cause: direct
      rescue ProgramError => error
        error
      end
      scenario.port.during_read = -> { raise program_error if scenario.port.calls.size == read_number }
      caught = begin
        scenario.join
        nil
      rescue ProgramError => error
        error
      end
      assert(caught.equal?(program_error) && caught.cause.equal?(direct), 'Zamaskowano ProgramError/directcause')
      assert(scenario.old_present? && scenario.calls[:complete] == 0, 'Skutek po ProgramError')
      assert(scenario.membership.release_count == (read_number == 3 ? 1 : 0), 'Zła własność cleanup po wyjątku')
    end
    scenario = TournamentMatchScenario.new
    timeout = Timeout::Error.new('czas odczytu')
    scenario.port.during_read = -> { raise timeout }
    caught = begin; scenario.join; rescue Timeout::Error => error; error; end
    assert(caught.equal?(timeout) && scenario.membership.establish_count == 0 && scenario.old_present?, 'Timeout stał się ordinary')
  end

  class ProgramError < StandardError; end

  def ownership
    scenario = TournamentMatchScenario.new
    scenario.membership.after_establish = lambda do
      core = scenario.broker.cores.fetch(scenario.target['__live_session_id'])
      core.participants['alice'] = NativeLiveSessionsBroker::Participant.new(id: 'replacement-generation', user: 'Alice')
      scenario.change_target { |data| data['plan_revision'] = 'other' }
    end
    rejected(scenario, 'Zastąpiona membership')
    person = scenario.broker.cores.fetch(scenario.target['__live_session_id']).participants.fetch('alice')
    assert(person.id == 'replacement-generation' && scenario.membership.release_count == 1, 'Usunięto cudzą generację')

    scenario = TournamentMatchScenario.new
    scenario.alice.send(:establish_invited_table_transport, scenario.invitation.table)
    scenario.membership.after_establish = -> { scenario.change_target { |data| data['plan_revision'] = 'other' } }
    rejected(scenario, 'Already here')
    assert(scenario.target_present? && scenario.membership.release_count == 0, 'Usunięto already_here')

    scenario = TournamentMatchScenario.new
    scenario.membership.after_establish = -> { scenario.context['epoch'] += 1 }
    scenario.membership.release_result = :unknown
    caught = begin; scenario.join; rescue GameRoomUseCases::AcceptInvitation::CleanupUnconfirmed => error; error; end
    assert(caught.is_a?(GameRoomUseCases::AcceptInvitation::CleanupUnconfirmed) && scenario.old_present?, 'Niepewny cleanup udaje sukces')
  end
end

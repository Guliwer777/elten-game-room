# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja cold FT2B'); super(value, message); end
F = TournamentFT2B1
T = F::T
phase, variant, name = ARGV
raise 'Nieznany etap' unless %w[A B].include?(phase) && %w[healthy lost_target lost_ready].include?(variant) && name.match?(/\Ac[1-3]\z/)
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', name)
transfer = File.join(directory, 'transfer.json')
assert_equal(false, EltenAPI::ServerClock.synchronized?)
assert_equal(nil, EltenAPI::ServerClock.now)
clock_calls = []
trap = TracePoint.new(:call) do |event|
  if event.defined_class == EltenAPI::ServerClock.singleton_class
    clock_calls << event.method_id
    raise 'Lokalna ścieżka używa ServerClock' unless phase == 'ordinary'
  end
  raise 'Niedozwolona sieć' if %i[e_json_request json_request request_sample].include?(event.method_id)
end
trap.enable(target_thread: nil)
counters = Hash.new(0)
trace = TracePoint.new(:call) do |event|
  key = [event.defined_class.to_s, event.method_id.to_s].join('#')
  owners = %w[GameRoomTournaments::LocalFixedTeamPlanBackend GameRoomTournaments::LocalFixedTeamReadinessPort GameRoomTournaments::LocalFixedTeamCoordinationPort GameRoomTransport GameRoomLiveSessionStore GameRoomTournaments::LocalFixedTeamNativeEndpoint GameRoomTournaments::LocalFixedTeamNativeEndpoint::View]
  counters[key] += 1 if owners.include?(event.defined_class.to_s) && %i[accept store reserve create_bind create_room create stack_push].include?(event.method_id)
end
trace.enable(target_thread: nil)
if phase == 'A'
  fixture = F.fixture(directory)
  if variant != 'lost_ready'
    %w[Anna Bartek Beata].each do |actor|
      F.with_execution(fixture, actor) do |execution|
        F.select_execution(execution, fixture[:record])
        assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
      end
    end
  end
else
  saved = JSON.parse(File.binread(transfer))
  assert(Process.pid != saved['pid'], 'B nie jest zimnym procesem')
  fixture = {program: TournamentEntryContextTest::Program.new(directory), now: saved['now'], plans: saved['plans']}
end
state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
plan_path = File.join(fixture[:plans], 'fixed-teams-v1', 'sandbox-k02.json')
plan_before = File.binread(plan_path)
if phase == 'A' && variant == 'lost_target'
  T::LocalFixedTeamNativeProvider.prepend(Module.new do
    def committed(receipt:)
      super
      raise T::CoordinationContract::PortUnavailable, 'Kontrolowana utrata odpowiedzi PO commit core+receipt'
    end
  end)
elsif phase == 'A' && variant == 'lost_ready'
  T::LocalFixedTeamReadinessPort.prepend(Module.new do
    def store(operation:)
      result = super
      raise T::ReadinessContract::PortUnavailable, 'Kontrolowana utrata odpowiedzi PO commit własnej deklaracji'
    end
  end)
end
begin
  GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
  driver = TournamentNativeDriver.new
  hub = T::LocalTestHub.new(**F.args(fixture))
  screen = -> { hub.instance_variable_get(:@fixed_team_entry) }
  complete = lambda do |form|
    2.times do
      work = screen.call.instance_variable_get(:@readiness_work)
      wait_background_work(work, timeout: 30) if work&.busy?
      form.update
    end
  end
  F.actor(driver, 'Ala')
  driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press; complete.call(form)
    if phase == 'A'
      F.button(form, 'Ready').press; complete.call(form)
      expected = variant == 'lost_ready' ? :unknown : :confirmed
      assert_equal(expected, screen.call.controller.view[:operation][:state])
      if variant != 'lost_ready'
        F.button(form, 'Choose technical deadline').press
      end
    else
      selection = screen.call.send(:selectors).transform_keys(&:to_s)
      assert_equal(saved['selection'], selection, 'Cold zmienił accepted/match/leg/window')
      if variant == 'lost_ready'
        rows = screen.call.controller.view[:records]
        assert_equal([saved['ready_uuid']], rows.map { |r| r['operation']['operation_id'] })
        F.button(form, 'Check uncertain operation').press; complete.call(form)
        result = screen.call.controller.view[:operation]
        assert_equal(:confirmed, result[:state]); assert_equal(saved['ready_uuid'], result[:operation_id])
        assert_equal(1, screen.call.controller.view[:current]['ready_revision'])
      else
        2.times do
          F.button(form, 'Check original coordination').press; complete.call(form)
          result = screen.call.controller.view[:coordination]
          assert_equal(:bound, result[:state]); assert_equal(saved['target']['receipt']['operation_id'], result[:operation_id])
          assert_equal(saved['target'], result[:target].to_h, 'Cold zmienił exact target/receipt/native')
          assert(F.field(form, 'Fixed-team execution status').text.include?(result[:operation_id]))
        end
      end
    end
  end
  if phase == 'A' && variant != 'lost_ready'
    driver.step('Technical local trial deadline', [13]) do |form|
      date = Time.at(fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
      [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
        field = F.field(form, "End: #{part}")
        field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)); field.trigger(:move)
      end
      form.index = form.fields.index(F.button(form, 'Use technical deadline'))
    end
    driver.step('Accepted fixed-team plans') do |form|
      F.button(form, 'Prepare local target').press; complete.call(form)
      result = screen.call.controller.view[:coordination]
      assert_equal(variant == 'lost_target' ? :unknown : :bound, result[:state])
      assert(result[:operation_id], 'Utracono pierwotny UUID')
    end
  end
  if phase == 'A'
    driver.step('Accepted fixed-team plans') do |_form|
      state = JSON.parse(File.binread(state_path))
      target = state['executions'].values.first&.fetch('target')
      result = screen.call.controller.view[:coordination]
      if variant != 'lost_ready'
        assert_equal(1, state['native']['creates'].size)
        assert_equal(1, state['native']['cores'].size)
        core = state['native']['cores'].first
        assert_equal(false, core['closed']); assert_equal({}, core['invitations'])
        assert_equal(1, core['participants'].size); assert_equal(1, core['entries'].size)
        assert_equal('room_created', core['entries'].first['packet']['kind'])
        assert_equal(target['receipt']['operation_id'], result[:operation_id])
        assert_equal(target, result[:target].to_h) if variant == 'healthy'
      end
      File.binwrite(transfer, JSON.pretty_generate({pid: Process.pid, now: fixture[:now], plans: fixture[:plans],
        selection: screen.call.send(:selectors), ready_uuid: screen.call.controller.view[:records].first['operation']['operation_id'],
        target: target, native: state['native'], executions: state['executions'], readiness: state['readiness']}))
    end
  end
  driver.step('Accepted fixed-team plans', [27]); driver.step('Local tournament tests', [27])
  hub.run; driver.finish
  assert_equal(plan_before, File.binread(plan_path), 'Konsument zmienił FT1')
  assert_equal(0, fixture[:program].managed_resources.size)
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  if phase == 'B'
    state = JSON.parse(File.binread(state_path))
    %w[native executions readiness].each { |key| assert_equal(saved[key], state[key], "Cold zmienił #{key}") }
    assert_equal({}, counters, 'Cold wykonał accept/store/reserve/create zamiast odczytu')
  else
    assert_equal(1, counters['GameRoomTournaments::LocalFixedTeamPlanBackend#accept'])
    expected = variant == 'lost_ready' ? 0 : 1
    assert_equal(expected, counters['GameRoomTransport#create_room'])
    assert_equal(expected, counters['GameRoomLiveSessionStore#create_room'])
    assert_equal(expected, counters['GameRoomTournaments::LocalFixedTeamNativeEndpoint#create'])
  end
  assert_equal([], clock_calls)
  File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'), 'cold-result.json'), JSON.pretty_generate({phase: phase, variant: variant, pid: Process.pid, counters: counters, clock_calls: clock_calls, state: JSON.parse(File.binread(state_path))}))
  puts "PASS #{phase}/#{variant}: native UI, realny commit/UUID, host bez synchronizacji, cold bez create"
ensure
  trace.disable; trap.disable
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end

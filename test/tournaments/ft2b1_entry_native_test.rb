# encoding: UTF-8
require_relative '../support/tournament_ft2b1_entry'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja własnego pionu FT2')
  super(value, message)
end
F = TournamentFT2B1
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
directory = File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE')))
fixture = F.fixture(directory)
program = fixture.fetch(:program)
plan_file = File.join(fixture[:plans], 'fixed-teams-v1', 'sandbox-k02.json')
plan_before = File.binread(plan_file)
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  finish_work = lambda do |form|
    screen = hub.instance_variable_get(:@fixed_team_entry)
    2.times do
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work) if work && work.busy?
      form.update
    end
  end
  F.actor(driver, 'Ala')
  driver.step('Local tournament tests', [13]) do |form|
    control = form.fields.grep(Button).find { |item| item.label == F::ACTION }
    assert(control, 'Zdrowy Hub nie udostępnia wejścia zaakceptowanego FT1')
    form.index = form.fields.index(control)
  end
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Check status').press
    finish_work.call(form)
    assert_equal(1, form.fields.first.options.size)
    assert_equal(4, F.field(form, 'My fixed-team matches').options.size)
    assert(F.field(form, 'Fixed-team execution status').text.include?('Own readiness: unknown'))
    F.button(form, 'Ready').press
    finish_work.call(form)
    assert(F.field(form, 'Fixed-team execution status').text.include?('Own readiness: ready'))
    F.button(form, 'Withdraw readiness').press
    finish_work.call(form)
    assert(F.field(form, 'Fixed-team execution status').text.include?('Own readiness: withdrawn'))
    assert_equal(2, F.field(form, 'Readiness operations').options.size)
    F.button(form, 'Check uncertain operation').press
    finish_work.call(form)
    screen = hub.instance_variable_get(:@fixed_team_entry)
    view = screen.controller.view
    assert_equal('plan-ft2b1', view[:selected_id])
    assert(view[:records].all? { |record| record['operation']['account'] == 'ala' }, 'Cudza gotowość')
    assert(view[:records].all? { |record| record['operation']['operation_id'].match?(/\A[0-9a-f-]{36}\z/) })
    assert_equal(2, view[:current]['ready_revision'])
  end
  driver.step('Accepted fixed-team plans', [13])
  driver.step('Match details', [27])
  driver.step('Accepted fixed-team plans', [27])
  driver.step('Local tournament tests', [27])
  hub.run
  driver.finish
  assert_equal(plan_before, File.binread(plan_file), 'Odczyt lub Ready zmieniły FT1')
  assert_equal(0, program.managed_resources.size)
  assert_equal(0, program.class.app_runtime.managed_resources.size)
  puts 'PASS Hub → accepted FT1 → własne Ready/Withdraw CAS → UUID/historia/reconcile, native kontrolki i worker'
ensure
  program.finalize
  program.class.app_runtime.close
end

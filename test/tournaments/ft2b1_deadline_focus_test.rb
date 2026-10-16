# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja deadline/focus'); super(value, message); end
F = TournamentFT2B1
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
begin
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  parent = selected = nil
  resumed = 0
  driver.on_resume = lambda do |form|
    next unless form.fields.first.header == 'Technical local trial deadline'
    resumed += 1
    screen = hub.instance_variable_get(:@fixed_team_entry)
    assert(screen.instance_variable_get(:@busy), 'Guard zwolniony przed resume')
    F.field(parent, 'My fixed-team matches').index = 1
    F.button(parent, 'Prepare local target').press
    F.button(parent, 'Back').press
    assert_equal(nil, screen.instance_variable_get(:@readiness_pending), 'Reentrant target uruchomił worker')
  end
  F.actor(driver, 'Ala')
  driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
  driver.step('Accepted fixed-team plans') do |form|
    parent = form
    F.button(form, 'Check status').press
    2.times do
      work = hub.instance_variable_get(:@fixed_team_entry).instance_variable_get(:@readiness_work)
      wait_background_work(work) if work&.busy?
      form.update
    end
    screen = hub.instance_variable_get(:@fixed_team_entry)
    selected = screen.send(:selectors)
    form.index = form.fields.index(F.button(form, 'Choose technical deadline'))
    F.button(form, 'Choose technical deadline').press
  end
  driver.step('Technical local trial deadline', [27])
  driver.step('Accepted fixed-team plans') do |form|
    screen = hub.instance_variable_get(:@fixed_team_entry)
    assert_equal(selected, screen.send(:selectors), 'Cancel przestawił cel')
    assert_equal(nil, screen.instance_variable_get(:@deadline))
    assert_equal('Choose technical deadline', form.fields[form.index].label)
    F.button(form, 'Choose technical deadline').press
  end
  driver.step('Technical local trial deadline', [13]) do |form|
    date = Time.at(fixture[:record]['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
    [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
      field = F.field(form, "End: #{part}")
      field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value)); field.trigger(:move)
    end
    form.index = form.fields.index(F.button(form, 'Use technical deadline'))
  end
  driver.step('Accepted fixed-team plans') do |form|
    screen = hub.instance_variable_get(:@fixed_team_entry)
    assert_equal(selected, screen.send(:selectors), 'Akceptacja przestawiła cel')
    assert_equal(selected, screen.instance_variable_get(:@deadline)[:selectors])
    assert(F.field(form, 'Fixed-team execution status').text.include?('Technical deadline:'), 'Status po resume nie opisuje przywróconego celu')
    assert_equal('Choose technical deadline', form.fields[form.index].label)
    assert_equal(2, resumed)
  end
  driver.step('Accepted fixed-team plans', [27]); driver.step('Local tournament tests', [27])
  hub.run; driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS Cancel/accept deadline: oryginalny cel, natywny fokus, busy w resume, zero reentrant target'
ensure
  fixture[:program].finalize; fixture[:program].class.app_runtime.close
end

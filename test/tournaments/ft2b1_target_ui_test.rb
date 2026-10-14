# encoding: UTF-8
require_relative '../support/tournament_ft2b1_execution'
include GameRoomTest::Assertions
def self.assert(value, message = 'Asercja celu FT2B'); super(value, message); end
F = TournamentFT2B1
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
fixture = F.fixture(File.join(ENV.fetch('FT2_SCRATCH'), 'shared', File.basename(ENV.fetch('ENTRY_EVIDENCE'))))
record = fixture[:record]
begin
  %w[Anna Bartek Beata].each do |actor|
    F.with_execution(fixture, actor) do |execution|
      F.select_execution(execution, record)
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  driver = TournamentNativeDriver.new
  hub = F::T::LocalTestHub.new(**F.args(fixture))
  complete = lambda do |form|
    2.times do
      screen = hub.instance_variable_get(:@fixed_team_entry)
      work = screen.instance_variable_get(:@readiness_work)
      wait_background_work(work) if work && work.busy?
      form.update
    end
  end
  F.actor(driver, 'Ala')
  driver.step('Local tournament tests', [13]) { |form| form.index = form.fields.index(F.button(form, F::ACTION)) }
  driver.step('Accepted fixed-team plans') do |form|
    assert(form.fields.grep(Button).any? { |b| b.label == 'Prepare local target' }, 'Brak użytkowej drogi do produkcyjnego targetu')
    F.button(form, 'Check status').press; complete.call(form)
    F.button(form, 'Ready').press; complete.call(form)
    F.button(form, 'Prepare local target').press; complete.call(form)
    assert(F.field(form, 'Fixed-team execution status').text.include?('Choose a technical deadline'), 'Brak terminu nie ma czytelnej odmowy')
    F.button(form, 'Choose technical deadline').press
  end
  driver.step('Technical local trial deadline', [13]) do |form|
    date = Time.at(record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60).getlocal
    [date.year, date.month, date.day, date.hour, date.min].zip(%w[year month day hour minute]).each do |value, part|
      field = F.field(form, "End: #{part}")
      field.index = field.options.index(format(part == 'year' ? '%04d' : '%02d', value))
      field.trigger(:move)
    end
    form.index = form.fields.index(F.button(form, 'Use technical deadline'))
  end
  driver.step('Accepted fixed-team plans') do |form|
    F.button(form, 'Prepare local target').press; complete.call(form)
    view = hub.instance_variable_get(:@fixed_team_entry).controller.view
    assert_equal(:bound, view.fetch(:coordination).fetch(:state))
    target = view[:coordination][:target].to_h
    text = F.field(form, 'Fixed-team execution status').text
    assert(text.include?(target['binding']['native_uuid']), 'Status nie pokazuje exact UUID')
    assert(text.include?(target['receipt']['native_digest']), 'Status nie pokazuje native digest')
    %w[Ala Anna Bartek Beata].each { |name| assert(text.include?(name), 'Brak planowanej osoby') }
    assert(text.include?('not consent'), 'Zatarto granicę zgody')
    F.button(form, 'Check original coordination').press; complete.call(form)
    assert_equal(target, hub.instance_variable_get(:@fixed_team_entry).controller.view[:coordination][:target].to_h)
  end
  driver.step('Accepted fixed-team plans', [27])
  driver.step('Local tournament tests', [27])
  hub.run
  driver.finish
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  puts 'PASS natywny Hub → osobisty Ready → jawny termin wybierakiem → bound/exact target → reconcile'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end

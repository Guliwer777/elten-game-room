# encoding: UTF-8
require_relative 'durable_save_fixture'
module DurableSaveCases
  include DurableSaveFixture
  Intent = GameRoomSavedGameSaveIntent
  class ProgramError < StandardError; end
  def scenario(name)
    root = GameRoomTest::TemporaryDirectory.create('durable-save-case-')
    h = DurableSaveFixture.room
    h.as('Alice') do
      store = DurableSaveFixture.intent(root)
      service = DurableSaveFixture::Resources.new(root)
      service.intent = store
      archive = AccountSavedGames.new(DurableSaveFixture.program, owner: 'Alice', resources: service)
      command = DurableSaveFixture.use_case(h, archive)
      yield root, h, store, service, archive, command
    end
    puts "PASS #{name}"
  end
  def caught
    yield
    nil
  rescue StandardError => error
    error
  end
  def save(command, h, store)
    caught { command.call(**DurableSaveFixture.arguments(h), intent: store) }
  end
  def frozen?(h)
    h.repositories['Alice'].snapshot_for(h.session, force_events: true).session['__frozen'] == true
  end
  def lost(command, h, store, service)
    service.lost_reply = service.read_failure = true
    error = save(command, h, store)
    assert(error.is_a?(Intent::Uncertain), "Brak niepewności: #{error.inspect}")
    service.lost_reply = service.read_failure = false
    store.list.fetch(0)
  end
end

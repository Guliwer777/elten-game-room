# encoding: UTF-8
require 'tmpdir'
require_relative '../../lib/saved_game_save_intent'

def assert(condition, message)
  raise message unless condition
end

root = Dir.mktmpdir('save-long-lock-')
directory = File.join(root, 'parent-' + 'a' * 110, 'child-' + 'b' * 80)
account = 'Alice'
build = -> do
  GameRoomSavedGameSaveIntent.new(directory: directory, owner: 'Alice',
    backend_identity: 'isolated-long-path', account: -> { account })
end
first, second = build.call, build.call
native = GameRoomTournaments::LocalFilesystem
assert(first.path.length > 300, 'The lock path did not cross the Windows path boundary')
assert(first.list.empty?, 'The journal could not be read at the long path')
entered = 0
first.with_save_attempt do
  entered += 1
  assert(File.file?(native.native(first.path + '.save.lock')), 'The native save lock was not created')
  error = begin
    second.with_save_attempt { raise 'The competing save entered the locked section' }
    nil
  rescue GameRoomSavedGameSaveIntent::Pending => failure
    failure
  end
  assert(error.is_a?(GameRoomSavedGameSaveIntent::Pending), 'The long-path lock did not reject a concurrent save')
  assert(second.list.empty?, 'The save lock prevented an independent reconciliation read')
end
second.with_save_attempt { entered += 1 }
assert(entered == 2, 'The lock did not release after the first attempt')
failure = IOError.new('isolated save failure')
begin
  first.with_save_attempt { raise failure }
rescue IOError => error
  assert(error.equal?(failure), 'The save lock replaced the original operation error')
end
second.with_save_attempt { entered += 1 }
account = 'Bob'
begin
  first.with_save_attempt { raise 'A foreign account entered the save attempt' }
  raise 'The changed account was accepted'
rescue GameRoomSavedGameSaveIntent::ContextChanged
end
assert(entered == 3, 'The save attempt did not release its lock after a failure')
puts 'Durable save long-path lock passed (native I/O, competing owner, recovery read, exception, account)'

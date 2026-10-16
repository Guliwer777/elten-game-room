# encoding: UTF-8
require 'open3'
require 'rbconfig'
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('Atomowy claim w dwóch prawdziwych procesach uprawnia dokładnie jeden upload') do |root,h,store,service,_archive,command|
  puts "Izolowane dane konkurencji: #{root}"
  store.singleton_class.prepend(Module.new do
    define_method(:prepare_archive) do |**args|
      DurableSaveFixture.dump(File.join(root, 'archive.json'), args.fetch(:row))
      super(**args)
    end
    def claim(_id); raise Intent::Pending, 'Przerwano przed claim'; end
  end)
  assert(save(command,h,store).is_a?(Intent::Pending), 'Nie przygotowano punktu wyścigu')
  operation = store.list.fetch(0)
  assert(operation['status'] == 'prepared' && service.state['uploads'] == 0, 'Niepoprawny punkt początkowy')
  worker = File.expand_path('../support/durable_save_claim_process.rb', __dir__)
  children = %w[A B].map { |label| [label, *Open3.popen3(RbConfig.ruby, worker, root, label, operation['id'])] }
  children.each do |_label,_input,output,_error,_waiter|
    assert(output.gets.start_with?('ready '), 'Dziecko nie osiągnęło bariery')
  end
  children.each { |_label,input,*_| input.puts('start'); input.close }
  children.each do |label,_input,output,error,waiter|
    raw = output.read + error.read
    File.binwrite(File.join(root, "claim-#{label}-raw.bin"), raw)
    assert(waiter.value.success?, "Błąd procesu claim: #{raw}")
  end
  rows = %w[A B].map { |label| DurableSaveFixture.read(File.join(root,"claim-#{label}.json")) }
  assert(rows.map { |r| r['pid'] }.uniq.length == 2 && rows.none? { |r| r['pid'] == Process.pid }, 'Nie były to dwa procesy')
  assert(rows.count { |r| r['won'] } == 1 && service.state['uploads'] == 1, 'Claim udzielił więcej niż jednego prawa wysyłki')
  assert(store.fetch(operation['id'])['status'] == 'attempted', 'Nie utrwalono wygranej')
  assert(save(command,h,store).is_a?(Intent::Pending) && service.state['uploads'] == 1, 'Retry dostało upload')
  puts JSON.generate('claim_processes'=>rows)
end

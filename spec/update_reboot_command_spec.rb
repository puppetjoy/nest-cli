# frozen_string_literal: true

require 'nest/update_transaction'

RSpec.describe Nest::UpdateReboot, 'native command boundary' do
  let(:transaction) { Nest::UpdateTransaction.new }

  it 'uses one exact argv spawn and an observed integer exit without shell or output' do
    expect(Process).to receive(:spawn).with(
      'systemctl', '--no-block', 'reboot', out: File::NULL, err: File::NULL
    ).once.and_return(123)
    expect(Process).to receive(:waitpid2).with(123, Process::WNOHANG).and_return([123, double(exitstatus: 23)])
    expect(Process).not_to receive(:kill)
    expect(transaction.send(:reboot_command)).to eq(23)
  end

  it 'bounds a stuck client, kills/reaps only that client and never launches a fallback' do
    expect(Process).to receive(:spawn).once.and_return(123)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0, 11)
    expect(Process).to receive(:waitpid2).with(123, Process::WNOHANG).and_return(nil)
    expect(Process).to receive(:kill).with('KILL', 123).once
    expect(Process).to receive(:waitpid).with(123).once
    expect { transaction.send(:reboot_command) }.to raise_error(/timed out/)
  end

  it 'does not turn a signaled native client into an integer success' do
    expect(Process).to receive(:spawn).once.and_return(123)
    expect(Process).to receive(:waitpid2).and_return([123, double(exitstatus: nil)])
    expect(Process).not_to receive(:kill)
    expect(transaction.send(:reboot_command)).to be_nil
  end

  it 'propagates launch failure without a fallback or fabricated result' do
    expect(Process).to receive(:spawn).once.and_raise(Errno::ENOENT)
    expect(Process).not_to receive(:waitpid2)
    expect { transaction.send(:reboot_command) }.to raise_error(Errno::ENOENT)
  end
end

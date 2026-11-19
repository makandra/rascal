require 'open3'

describe 'rascal --version' do

  it 'prints the version' do
    output, status = Open3.capture2(RbConfig.ruby, File.expand_path('../../exe/rascal', __dir__), '--version')

    expect(status).to be_success
    expect(output).to eq "Rascal version #{Rascal::VERSION}.\n"
  end

end

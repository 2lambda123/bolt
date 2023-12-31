# frozen_string_literal: true

require 'spec_helper'

require 'bolt/inventory'
require 'bolt/transport/local'
require 'bolt/util'

require 'bolt_spec/files'
require 'bolt_spec/integration'
require 'bolt_spec/pal'
require 'bolt_spec/project'
require 'bolt_spec/transport'

require 'shared_examples/transport'

describe Bolt::Transport::Local do
  include BoltSpec::PAL
  include BoltSpec::Transport

  let(:transport)     { :local }
  let(:host_and_port) { 'localhost' }
  let(:safe_name)     { host_and_port }
  let(:user)          { 'runner' }
  let(:password)      { 'runner' }
  let(:os_context)    { Bolt::Util.windows? ? windows_context : posix_context }
  let(:transport_config) { {} }
  let(:config)        { make_config({ local: transport_config }) }
  let(:plugins)       { make_plugins(config) }
  let(:inventory)     { Bolt::Inventory::Inventory.new({}, config.transport, config.transports, plugins) }
  let(:target)        { make_target }

  def make_target
    inventory.get_target(host_and_port)
  end

  it 'is always connected' do
    expect(runner.connected?(target)).to eq(true)
  end

  include_examples 'transport api'

  it "can run a command with pipes" do
    command, expected = os_context[:pipe_command]
    result = runner.run_command(target, command, catch_errors: true)
    expect(result.value['exit_code']).to eq(0)
    expect(result.value['stdout']).to match(expected)
  end

  context 'running as another user', sudo: true do
    include_examples 'with sudo'

    context "overriding with '_run_as'" do
      let(:transport_config) do
        {
          'sudo-password' => password,
          'run-as'        => 'root'
        }
      end

      it "can override run_as for command via an option" do
        expect(runner.run_command(target, 'whoami', run_as: user)['stdout']).to eq("#{user}\n")
      end

      it "can override run_as for script via an option" do
        contents = "#!/bin/sh\nwhoami"
        with_tempfile_containing('script test', contents) do |file|
          expect(runner.run_script(target, file.path, [], run_as: user)['stdout']).to eq("#{user}\n")
        end
      end

      it "can override run_as for task via an option" do
        contents = "#!/bin/sh\nwhoami"
        with_task_containing('tasks_test', contents, 'environment') do |task|
          expect(runner.run_task(target, task, {}, run_as: user).message).to eq("#{user}\n")
        end
      end

      it "can override run_as for file upload via an option" do
        contents = "upload file test as root content"
        dest = '/tmp/root-file-upload-test'
        with_tempfile_containing('tasks test upload as root', contents) do |file|
          expect(runner.upload(target, file.path, dest, run_as: user).message).to match(/Uploaded/)
          expect(runner.run_command(target, "cat #{dest}", run_as: user)['stdout']).to eq(contents)
          expect(runner.run_command(target, "stat -c %U #{dest}", run_as:  user)['stdout'].chomp).to eq(user)
          expect(runner.run_command(target, "stat -c %G #{dest}", run_as:  user)['stdout'].chomp).to eq('docker')
        end

        runner.run_command(target, "rm #{dest}", sudoable: true, run_as: user)
      end
    end

    context "as user with no password" do
      let(:transport_config) do
        {
          'run-as' => 'root'
        }
      end

      it "returns a failed result when a temporary directory is created" do
        contents = "#!/bin/sh\nwhoami"
        with_tempfile_containing('script test', contents) do |file|
          expect {
            runner.run_script(target, file.path, [])
          }.to raise_error(Bolt::Node::EscalateError,
                           "Sudo password for user #{user} was not provided for #{host_and_port}")
        end
      end
    end
  end

  context 'with large input and output' do
    let(:file_size) { 1011 }
    let(:str) { (0...1024).map { rand(65..90).chr }.join }
    let(:arguments) { { 'input' => str * file_size } }
    let(:ruby_task) do
      <<~TASK
      #!/usr/bin/env ruby
      input = STDIN.read
      STDERR.print input
      STDOUT.print input
      TASK
    end

    it "runs with large input and captures large output" do
      with_task_containing('big_kahuna', ruby_task, 'stdin', '.rb') do |task|
        result = runner.run_task(target, task, arguments).value
        expect(result['input'].bytesize).to eq(file_size * 1024)
        # Ensure the strings are the same
        expect(result['input'][-1024..-1]).to eq(str)
      end
    end

    context 'with run-as', sudo: true do
      let(:transport_config) do
        {
          'sudo-password' => password,
          'run-as'        => 'root'
        }
      end

      it "runs with large input and output" do
        with_task_containing('big_kahuna', ruby_task, 'stdin', '.rb') do |task|
          result = runner.run_task(target, task, arguments).value
          expect(result['input'].bytesize).to eq(file_size * 1024)
          expect(result['input'][-1024..-1]).to eq(str)
        end
      end
    end

    context 'with slow input' do
      let(:file_size) { 10 }
      let(:ruby_task) do
        <<~TASK
        #!/usr/bin/env ruby
        while true
          begin
            input = STDIN.readpartial(1024)
            sleep(0.2)
            STDERR.print input
            STDOUT.print input
          rescue EOFError
            break
          end
        end
        TASK
      end

      it "runs with large input and captures large output" do
        with_task_containing('slow_and_steady', ruby_task, 'stdin', '.rb') do |task|
          result = runner.run_task(target, task, arguments).value
          expect(result['input'].bytesize).to eq(file_size * 1024)
          # Ensure the strings are the same
          expect(result['input'][-1024..-1]).to eq(str)
        end
      end
    end
  end

  context 'file extensions', windows: true do
    include BoltSpec::Files
    include BoltSpec::Integration
    include BoltSpec::Project

    let(:config) { { 'modulepath' => fixtures_path('modules') } }

    around(:each) do |example|
      in_project(config: config, inventory: inventory) do |project|
        @project = project
        example.run
      end
    end

    context 'with an unspecified extension' do
      let(:inventory) { {} }

      it 'errors' do
        results = run_cli_json(%w[task run sample::python -t localhost], project: @project)
        result  = results['items'][0]

        expect(result['status']).to eq('failure')
        expect(result.dig('value', '_error', 'msg')).to match(/File extension .py is not enabled/)
      end
    end

    context 'with a specified extension' do
      let(:inventory) do
        {
          'config' => {
            'local' => {
              'extensions' => ['.py']
            }
          }
        }
      end

      it 'runs the task' do
        results = run_cli_json(%w[task run sample::python -t localhost], project: @project)
        result  = results['items'][0]

        expect(result['status']).to eq('success')
      end
    end
  end
end

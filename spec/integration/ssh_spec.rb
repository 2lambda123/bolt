# frozen_string_literal: true

require 'spec_helper'
require 'bolt_spec/conn'
require 'bolt_spec/files'
require 'bolt_spec/integration'

describe "when runnning over the ssh transport", ssh: true do
  include BoltSpec::Conn
  include BoltSpec::Files
  include BoltSpec::Integration

  let(:whoami) { "whoami" }
  let(:modulepath) { File.join(__dir__, '../fixtures/modules') }
  let(:stdin_task) { "sample::stdin" }
  let(:uri) { conn_uri('ssh') }
  let(:user) { conn_info('ssh')[:user] }
  let(:password) { conn_info('ssh')[:password] }

  after(:each) { Puppet.settings.send(:clear_everything_for_tests) }

  context 'when using CLI options' do
    let(:config_flags) {
      %W[--targets #{uri} --no-host-key-check --format json --modulepath #{modulepath} --password #{password}]
    }

    it 'runs a command' do
      result = run_one_node(%W[command run #{whoami}] + config_flags)
      expect(result['stdout'].strip).to eq(user)
    end

    it 'reports errors when command fails' do
      result = run_failed_node(%w[command run boop] + config_flags)
      expect(result['_error']['kind']).to eq('puppetlabs.tasks/command-error')
      expect(result['_error']['msg']).to eq('The command failed with exit code 127')
    end

    context 'wrong port' do
      let(:uri) { conn_uri('ssh', override_port: 62223) }

      it 'reports errors when node is unreachable' do
        result = run_failed_node(%W[command run #{whoami}] + config_flags)
        expect(result['_error']['kind']).to eq('puppetlabs.tasks/connect-error')
        expect(result['_error']['msg']).to match(
          /Failed to connect to #{uri}: Connection refused/
        )
      end
    end

    it 'runs a task', :reset_puppet_settings do
      result = run_one_node(%W[task run #{stdin_task} message=somemessage] + config_flags)
      expect(result['message'].strip).to eq("somemessage")
    end

    it 'reports errors when task fails', :reset_puppet_settings do
      result = run_failed_node(%w[task run results fail=true] + config_flags)
      expect(result['_error']['kind']).to eq('puppetlabs.tasks/task-error')
      expect(result['_error']['msg']).to eq("The task failed with exit code 1:\n")
    end

    it 'passes noop to a task that supports noop', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::noop message=somemessage --noop] + config_flags)
      expect(result['_output'].strip).to eq("somemessage with noop true")
    end

    it 'passes noop to a plan that runs a task with noop', :reset_puppet_settings do
      result = run_cli_json(%w[plan run sample::noop] + config_flags)[0]['result']
      expect(result['_output'].strip).to eq("This works with noop true")
    end

    it 'does not pass noop to a task by default', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::noop message=somemessage] + config_flags)
      expect(result['_output'].strip).to eq("somemessage with noop")
    end

    it 'escalates privileges when passed --run-as' do
      result = run_one_node(%W[command run #{whoami} --run-as root --sudo-password #{password}] + config_flags)
      expect(result['stdout'].strip).to eq("root")
      result = run_one_node(%W[command run #{whoami} --run-as #{user} --sudo-password #{password}] + config_flags)
      expect(result['stdout'].strip).to eq(user)
    end
  end

  context 'when using a configfile' do
    let(:config) do
      { 'format' => 'json',
        'modulepath' => modulepath,
        'ssh' => {
          'user' => user,
          'password' => password,
          'host-key-check' => false
        } }
    end

    let(:uri) { (1..2).map { |i| "#{conn_uri('ssh')}?id=#{i}" }.join(',') }
    let(:config_flags) { %W[--targets #{uri}] }
    let(:single_target_conf) { %W[--targets #{conn_uri('ssh')}] }
    let(:interpreter_task) { 'sample::interpreter' }
    let(:interpreter_ext) do
      { 'interpreters' => {
        '.py' => '/usr/bin/python3'
      } }
    end
    let(:interpreter_no_ext) do
      { 'interpreters' => {
        'py' => '/usr/bin/python3'
      } }
    end

    it 'runs multiple commands' do
      with_tempfile_containing('conf', YAML.dump(config)) do |conf|
        result = run_nodes(%W[command run #{whoami} --configfile #{conf.path}] + config_flags)
        expect(result.map { |r| r['stdout'].strip }).to eq([user, user])
      end
    end

    it 'runs multiple tasks', :reset_puppet_settings do
      with_tempfile_containing('conf', YAML.dump(config)) do |conf|
        result = run_nodes(%W[task run #{stdin_task} message=somemessage --configfile #{conf.path}] + config_flags)
        expect(result.map { |r| r['message'].strip }).to eq(%w[somemessage somemessage])
      end
    end

    it 'runs multiple tasks as a specified user', :reset_puppet_settings do
      config['ssh']['run-as'] = user

      with_tempfile_containing('conf', YAML.dump(config)) do |conf|
        result = run_nodes(%W[command run #{whoami} --configfile #{conf.path}
                              --sudo-password #{password}] + config_flags)
        expect(result.map { |r| r['stdout'].strip }).to eq([user, user])
      end
    end

    it 'runs task with specified interpreter key py', :reset_puppet_settings do
      ssh_conf = { 'ssh' => config['ssh'].merge(interpreter_no_ext) }
      with_tempfile_containing('conf', YAML.dump(config.merge(ssh_conf))) do |conf|
        result =
          run_nodes(%W[task run #{interpreter_task} message=somemessage
                       --configfile #{conf.path}] + config_flags)
        expect(result.map { |r| r['env'].strip }).to eq(%w[somemessage somemessage])
        expect(result.map { |r| r['stdin'].strip }).to eq(%w[somemessage somemessage])
      end
    end

    it 'runs task with specified interpreter that with run-as set', :reset_puppet_settings do
      ssh_conf = { 'ssh' => config['ssh'].merge(interpreter_no_ext) }
      with_tempfile_containing('conf', YAML.dump(config.merge(ssh_conf))) do |conf|
        result =
          run_nodes(%W[task run #{interpreter_task} message=somemessage
                       --configfile #{conf.path} --run-as root --sudo-password #{password}] + config_flags)
        expect(result.map { |r| r['env'].strip }).to eq(%w[somemessage somemessage])
        expect(result.map { |r| r['stdin'].strip }).to eq(%w[somemessage somemessage])
      end
    end

    it 'runs task with interpreter key .py', :reset_puppet_settings do
      ssh_conf = { 'ssh' => config['ssh'].merge(interpreter_ext) }
      with_tempfile_containing('conf', YAML.dump(config.merge(ssh_conf))) do |conf|
        result = run_nodes(%W[task run #{interpreter_task} message=somemessage
                              --configfile #{conf.path}] + config_flags)
        expect(result.map { |r| r['env'].strip }).to eq(%w[somemessage somemessage])
        expect(result.map { |r| r['stdin'].strip }).to eq(%w[somemessage somemessage])
      end
    end

    it 'task fails when bad shebang is not overriden', :reset_puppet_settings do
      with_tempfile_containing('conf', YAML.dump(config)) do |conf|
        result = run_failed_node(%W[task run #{interpreter_task} message=somemessage
                                    --configfile #{conf.path}] + single_target_conf)
        expect(result['_error']['msg']).to match(/interpreter.py: not found/)
      end
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'bolt_spec/files'
require 'bolt_spec/integration'
require 'bolt_spec/project'

describe "when running over the local transport" do
  include BoltSpec::Files
  include BoltSpec::Integration
  include BoltSpec::Project

  let(:modulepath) { fixtures_path('modules') }
  let(:uri) { 'localhost,local://foo' }
  let(:user) { ENV['USER'] }
  let(:sudo_user) { 'root' }
  let(:sudo_password) { 'runner' }
  let(:stdin_task) { "sample::stdin" }

  after(:each) { Puppet.settings.send(:clear_everything_for_tests) }

  context 'when using CLI options' do
    let(:echo) { "echo hi" }
    let(:config_flags) {
      %W[--targets localhost --format json --modulepath #{modulepath}]
    }

    it 'runs multiple commands' do
      result = run_nodes(%W[command run #{echo} --targets #{uri} --format json])
      expect(result.map { |r| r['stdout'].strip }).to eq(%w[hi hi])
    end

    it 'reports errors when command fails' do
      result = run_failed_nodes(%W[command run boop --targets #{uri} --format json])
      expect(result[0]['_error']).to be
    end

    it 'returns correct exit code', :reset_puppet_settings do
      cmd = "puppet apply --trace --detailed-exitcodes -e 'notify {foo:}'"
      result = run_failed_nodes(%W[command run #{cmd} -t localhost]).first
      expect(result['_error']['msg']).to eq('The command failed with exit code 2')
      expect(result['_error']['details']['exit_code']).to eq(2)
    end

    it 'runs a ruby task using bolt ruby', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::bolt_ruby message=somemessage] + config_flags)
      expect(result['env']).to match(/somemessage/)
      expect(result['stdin']).to match(/somemessage/)
    end

    context 'with bundled-ruby false' do
      around :each do |example|
        inv = { 'config' => { 'local' => { 'bundled-ruby' => false } } }
        with_project(inventory: inv) do |project|
          @project = project
          example.run
        end
      end

      it 'restores original Ruby environment variables' do
        cmd = %W[task run env_var::ruby_env --project #{@project.path}]
        result = run_one_node(cmd + config_flags)
        env = Bundler.with_unbundled_env do
          ENV['GEM_HOME']
        end
        expect(result['_output'].strip).to eq(env.to_s)
      end
    end

    context 'specifying transport on the CLI' do
      let(:config_flags) { %W[--targets 127.0.0.1 -m #{modulepath} --transport local] }

      it "applies bundled-ruby config" do
        data = { 'config' => { 'local' => { 'bundled-ruby' => true } } }
        with_tempfile_containing('inv', data.to_yaml) do |inv|
          cmd = %W[task run sample::bolt_ruby message=somemessage --inventoryfile #{inv.path}]
          result = run_one_node(cmd + config_flags)
          expect(result['env']).to match(/somemessage/)
          expect(result['stdin']).to match(/somemessage/)
        end
      end
    end
  end

  context 'when using CLI options on POSIX OS', bash: true do
    let(:config_flags) {
      %W[--targets #{uri} --format json --modulepath #{modulepath}]
    }

    it 'runs script with parameter', :reset_puppet_settings do
      with_tempfile_containing('script', "#!/usr/bin/env bash \n echo $1", '.sh') do |script|
        results = run_cli_json(%W[script run #{script.path} param --targets localhost])
        results['items'].each do |result|
          expect(result['status']).to eq('success')
          expect(result['value']).to eq(
            "stdout"        => "param\n",
            "stderr"        => "",
            "merged_output" => "param\n",
            "exit_code"     => 0
          )
        end
      end
    end

    it 'runs multiple tasks', :reset_puppet_settings do
      result = run_nodes(%W[task run #{stdin_task} message=somemessage] + config_flags)
      expect(result.map { |r| r['message'].strip }).to eq(%w[somemessage somemessage])
    end

    it 'reports errors when task fails', :reset_puppet_settings do
      result = run_failed_nodes(%w[task run results fail=true] + config_flags)
      expect(result[0]['_error']).to be
    end

    context 'with environment variables set' do
      before(:each) { ENV['test_var'] = "testing this" }
      after(:each) { ENV.delete('test_var') }
      # Only works with localhost's default configuration
      let(:uri) { 'localhost' }

      it 'exposes environment variables to the task' do
        result = run_one_node(%w[task run env_var::get_var] + config_flags)
        output = result['_output'].strip
        expect(output).to eq("testing this")
      end

      it 'exposes environment variables during apply' do
        result = run_cli_json(%w[plan run env_var::get_var] + config_flags)
        expect(result).not_to include('kind')
        event = result.first['value']['report']['resource_statuses']['Notify[gettingvar]']['events'].first
        expect(event).to include('message' => "defined 'message' as 'testing this'")
      end
    end
  end

  context 'runs as an escalated user', sudo: true do
    let(:config_flags) {
      %W[--targets #{uri} --format json --modulepath #{modulepath}] +
        %W[--run-as #{sudo_user} --sudo-password #{sudo_password}]
    }

    it 'runs a command', :reset_puppet_settings do
      result = run_nodes(%w[command run whoami] + config_flags)
      expect(result.map { |r| r['stdout'].strip }).to eq(%w[root root])
    end

    it 'returns merged output', :reset_puppet_settings do
      result = run_nodes(["command", "run", ">&2 echo Hello $USER && whoami"] + config_flags)
      expect(result.map { |r| r['merged_output'].strip }).to eq(["Hello root\nroot", "Hello root\nroot"])
    end

    it 'with script with parameters', :reset_puppet_settings do
      with_tempfile_containing('script', "#!/usr/bin/env bash \n echo $1", '.sh') do |script|
        results = run_cli_json(%W[script run #{script.path} hello] + config_flags)
        results['items'].each do |result|
          expect(result['status']).to eq('success')
          expect(result['value']).to eq(
            "stdout"        => "hello\n",
            "stderr"        => "",
            "merged_output" => "hello\n",
            "exit_code"     => 0
          )
        end
      end
    end
  end

  context 'when using CLI options on Windows OS', windows: true do
    let(:config_flags) {
      %W[--targets localhost --format json --modulepath #{modulepath}]
    }

    it 'runs powershell script with parameter', :reset_puppet_settings do
      with_tempfile_containing('script', "Write-Host $args", '.ps1') do |script|
        results = run_cli_json(%W[script run #{script.path} param --targets localhost])
        results['items'].each do |result|
          expect(result['status']).to eq('success')
          expect(result['value']).to eq(
            "stdout"        => "param\n",
            "stderr"        => "",
            "merged_output" => "param\n",
            "exit_code"     => 0
          )
        end
      end
    end

    it 'runs ruby script with parameter', :reset_puppet_settings do
      ruby_script = "puts 'Ruby' \n ARGV.each {|a| puts a}"
      with_tempfile_containing('script', ruby_script, '.rb') do |script|
        results = run_cli_json(%W[script run #{script.path} param --targets localhost])
        results['items'].each do |result|
          expect(result['status']).to eq('success')
          expect(result['value']).to eq(
            "stdout"        => "Ruby\r\nparam\r\n",
            "stderr"        => "",
            "merged_output" => "Ruby\r\nparam\r\n",
            "exit_code"     => 0
          )
        end
      end
    end

    it 'runs a task reading from stdin', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::winstdin message=somemessage] + config_flags)
      output = result['_output'].strip
      expect(output).to match(/STDIN: {"message":"somemessage"/)
    end

    it 'runs a task reading from $input', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::wininput message=somemessage] + config_flags)
      output = result['_output'].strip
      expect(output).to match(/INPUT: {"message":"somemessage"/)
    end

    it 'runs a task with parameters', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::winparams message=µsomemessage] + config_flags)
      output = result['_output'].strip
      expect(output).to match(/Message: µsomemessage/)
    end

    it 'runs a task reading from environment variables', :reset_puppet_settings do
      result = run_one_node(%w[task run sample::winenv message=somemessage] + config_flags)
      output = result['_output'].strip
      expect(output).to match(/ENV: somemessage/)
    end

    it 'runs a task with complex parameters', :reset_puppet_settings do
      complex_input_file = fixtures_path('complex_params', 'input.json')
      expected = File.open(fixtures_path('complex_params', 'output'), 'rb', &:read)
      result = run_one_node(%W[task run sample::complex_params --params @#{complex_input_file}] + config_flags)
      expect(result['_output']).to eq(expected)
    end
  end
end

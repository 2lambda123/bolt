# frozen_string_literal: true

require 'spec_helper'

describe 'puppetdb_fact' do
  include PuppetlabsSpec::Fixtures

  let(:pdb_client) { mock('pdb_client') }

  around(:each) do |example|
    Puppet[:tasks] = true
    Puppet.override(bolt_pdb_client: pdb_client) do
      example.run
    end
  end

  context 'it calls puppetdb_facts' do
    let(:facts)    { { 'a.com' => {}, 'b.com' => {} } }
    let(:instance) { 'instance' }

    it 'with list of targets' do
      pdb_client.expects(:facts_for_node).with(facts.keys).returns(facts)

      is_expected.to run.with_params(facts.keys).and_return(facts)
    end

    it 'with a named instance' do
      pdb_client.expects(:facts_for_node).with(facts.keys, instance).returns(facts)

      is_expected.to run.with_params(facts.keys, instance).and_return(facts)
    end
  end
end

# frozen_string_literal: true

require_relative '../../bolt/task'
require_relative '../../bolt/transport/base'

module Bolt
  module Transport
    class Remote < Base
      # TODO: this should have access to inventory so target doesn't have to
      def initialize(executor)
        super()

        @executor = executor
      end

      def get_proxy(target)
        inventory = target.inventory
        raise "Target was created without inventory? Not get_targets?" unless inventory
        proxy = inventory.get_targets(target.options['run-on'] || 'localhost').first

        if proxy.transport == 'remote'
          msg = "#{proxy.name} is not a valid run-on target for #{target.name} since is also remote."
          raise Bolt::Error.new(msg, 'bolt/invalid-remote-target')
        end
        proxy
      end

      # Cannot batch because arugments differ
      def run_task(target, task, arguments, options = {}, position = [])
        proxy_target = get_proxy(target)
        transport = @executor.transport(proxy_target.transport)
        arguments = arguments.merge('_target' => target.to_h.compact)

        remote_task = task.remote_instance

        result = transport.run_task(proxy_target, remote_task, arguments, options, position)
        Bolt::Result.new(target, value: result.value, action: 'task', object: task.name)
      end
    end
  end
end

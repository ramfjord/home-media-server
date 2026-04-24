require 'erb'
require_relative 'config'

module Mediaserver
  class Renderer
    def initialize(config)
      @config = config
    end

    def render(template_string, service_name: nil)
      template = ERB.new(template_string, trim_mode: '%<>')
      template.result(binding_for(service_name))
    end

    private

    def binding_for(service_name)
      services = @config.services
      service = service_name ? @config.find(service_name) : nil
      install_base = @config.globals['install_base']
      media_path = @config.globals['media_path']
      hostname = @config.globals['hostname']
      compose_file = @config.globals['compose_file']
      config_yaml = @config.raw
      binding
    end
  end
end

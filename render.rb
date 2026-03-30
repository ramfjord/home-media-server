#!/usr/bin/env ruby

require 'erb'
require 'yaml'

# Just read from stdin
text = ARGF.read
template = ERB.new(text, trim_mode: '%<>')

config_yaml = YAML.load(File.read('services.yml'))

# Load local config overrides if present
if File.exist?('config.local.yml')
  local_config = YAML.load(File.read('config.local.yml'))
  config_yaml.merge!(local_config) if local_config
end

services = config_yaml['services']
install_base = config_yaml['install_base'] || '/opt/mediaserver'
media_path = config_yaml['media_path'] || '/data'
hostname = config_yaml['hostname'] || 'localhost'
compose_file = "#{install_base}/docker-compose.yml"

# Expand variables in volume paths
services.each do |svc|
  if svc['volumes']
    svc['volumes'] = svc['volumes'].map do |v|
      v.gsub('${install_base}', install_base)
       .gsub('${media_path}', media_path)
    end
  end
end

# If SERVICE_NAME is set, expose the specific service for single-service templates
service_name = ENV['SERVICE_NAME']
service = services.find { |s| s['name'] == service_name } if service_name

# Helper: get all services that use VPN
vpn_services = services.select { |s| s['uses_vpn'] }

# Helper: get the VPN gateway service
vpn_gateway = services.find { |s| s['is_vpn_gateway'] }

puts template.result

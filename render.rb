#!/usr/bin/env ruby

require 'erb'
require 'yaml'

class ProjectService
  def initialize(definition)
    @definition = definition
  end

  def name
    @definition['name']
  end

  def dockerized?
    @definition.key?('docker_config')
  end

  def unit
    @definition['unit']
  end

  def partof
    @definition['partof']
  end

  def desc
    @definition['desc']
  end

  def port
    @definition['port']
  end

  def healthz
    @definition['healthz']
  end

  def docker_config
    @definition['docker_config'] || {}
  end

  def has_unit?
    @definition.key?('unit')
  end

  def uid
    @definition['uid']
  end

  # Access raw definition for backward compatibility if needed
  def [](key)
    @definition[key]
  end

  def has_key?(key)
    @definition.has_key?(key)
  end
end

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

# Expand variables in all service definitions (including docker_config)
def expand_vars(obj, install_base, media_path, hostname)
  case obj
  when Hash
    obj.each { |k, v| obj[k] = expand_vars(v, install_base, media_path, hostname) }
  when Array
    obj.map! { |v| expand_vars(v, install_base, media_path, hostname) }
  when String
    obj.gsub('${install_base}', install_base)
       .gsub('${media_path}', media_path)
       .gsub('${hostname}', hostname)
  else
    obj
  end
end

services.each do |svc|
  expand_vars(svc, install_base, media_path, hostname)
end

# Wrap services in ProjectService class
services = services.map { |s| ProjectService.new(s) }

# If SERVICE_NAME is set, expose the specific service for single-service templates
service_name = ENV['SERVICE_NAME']
service = services.find { |s| s.name == service_name } if service_name

puts template.result

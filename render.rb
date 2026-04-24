#!/usr/bin/env ruby

require 'erb'
require 'yaml'

def get_group_id(group_name)
  `getent group #{group_name} 2>/dev/null | cut -d: -f3`.strip
end

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

  def user_id
    # Wireguard needs to run as root to set up network interfaces
    return nil if name == 'wireguard'
    @user_id ||= `id -u #{name} 2>/dev/null`.strip
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

  def groups
    @definition['groups'] || []
  end

  def group_ids
    groups.map { |g| get_group_id(g) }.compact
  end

  def has_unit?
    @definition.key?('unit')
  end

  # Access raw definition for backward compatibility if needed
  def [](key)
    @definition[key]
  end

  def has_key?(key)
    @definition.has_key?(key)
  end

  def use_vpn?
    @definition['use_vpn'] == true
  end

  def sighup_reload?
    @definition['sighup_reload'] == true
  end
end

# Just read from stdin
text = ARGF.read
template = ERB.new(text, trim_mode: '%<>')

config_yaml = YAML.load(File.read('services.yml'))

# Minimal deep merge — not worth pulling in the deep_merge gem for one function.
# Array handling (union) adapted from:
# https://github.com/danielsdeleo/deep_merge/blob/master/lib/deep_merge/core.rb
def deep_merge!(base, overrides)
  overrides.each do |key, value|
    if value.is_a?(Hash) && base[key].is_a?(Hash)
      deep_merge!(base[key], value)
    elsif value.is_a?(Array) && base[key].is_a?(Array)
      base[key] = (base[key] | value)
    else
      base[key] = value
    end
  end
  base
end

# Load local config overrides if present
if File.exist?('config.local.yml')
  local_config = YAML.load(File.read('config.local.yml'))
  if local_config
    service_overrides = local_config.delete('service_overrides') || {}
    config_yaml.merge!(local_config)

    # Apply per-service overrides via deep merge
    service_overrides.each do |svc_name, overrides|
      svc_def = config_yaml['services'].find { |s| s['name'] == svc_name }
      next unless svc_def
      deep_merge!(svc_def, overrides)
    end
  end
end

services = config_yaml['services']
install_base = config_yaml['install_base'] || '/opt/mediaserver'
media_path = config_yaml['media_path'] || '/data'
hostname = config_yaml['hostname'] || 'localhost'
compose_file = "#{install_base}/config/docker-compose.yml"

# Expand variables in all service definitions (including docker_config)
def expand_vars(obj, vars)
  case obj
  when Hash
    obj.each { |k, v| obj[k] = expand_vars(v, vars) }
  when Array
    obj.map! { |v| expand_vars(v, vars) }
  when String
    result = obj
    vars.each { |k, v| result = result.gsub("${#{k}}", v.to_s) if v }
    result
  else
    obj
  end
end

services.each do |svc|
  expand_vars(svc, config_yaml)
end

# Wrap services in ProjectService class
services = services.map { |s| ProjectService.new(s) }

# If SERVICE_NAME is set, expose the specific service for single-service templates
service_name = ENV['SERVICE_NAME']
service = services.find { |s| s.name == service_name } if service_name

puts template.result

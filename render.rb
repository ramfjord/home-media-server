#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'mediaserver/renderer'

config = Mediaserver::Config.load(root: __dir__)
renderer = Mediaserver::Renderer.new(config)
puts renderer.render(ARGF.read, service_name: ENV['SERVICE_NAME'])

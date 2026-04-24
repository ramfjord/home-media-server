require 'minitest/autorun'
require 'mediaserver/renderer'

class RendererTest < Minitest::Test
  def build_config
    svc_a = Mediaserver::ProjectService.new('name' => 'a', 'port' => 8080, 'docker_config' => { 'image' => 'a:1' })
    svc_b = Mediaserver::ProjectService.new('name' => 'b', 'port' => 9090)
    globals = {
      'install_base' => '/opt/x',
      'media_path' => '/data',
      'hostname' => 'host.local',
      'compose_file' => '/opt/x/config/docker-compose.yml',
    }
    Mediaserver::Config.new(services: [svc_a, svc_b], globals: globals, raw: { 'snmp_host' => 'box' })
  end

  def test_globals_exposed
    r = Mediaserver::Renderer.new(build_config)
    out = r.render('<%= install_base %>|<%= media_path %>|<%= hostname %>|<%= compose_file %>')
    assert_equal '/opt/x|/data|host.local|/opt/x/config/docker-compose.yml', out
  end

  def test_services_iterable
    r = Mediaserver::Renderer.new(build_config)
    out = r.render('<% services.each do |s| %><%= s.name %>:<%= s.port %>,<% end %>')
    assert_equal 'a:8080,b:9090,', out
  end

  def test_service_selected_by_name
    r = Mediaserver::Renderer.new(build_config)
    out = r.render('<%= service.name %>', service_name: 'b')
    assert_equal 'b', out
  end

  def test_service_nil_when_not_requested
    r = Mediaserver::Renderer.new(build_config)
    out = r.render('<%= service.nil? %>')
    assert_equal 'true', out
  end

  def test_config_yaml_exposed
    r = Mediaserver::Renderer.new(build_config)
    out = r.render('<%= config_yaml["snmp_host"] %>')
    assert_equal 'box', out
  end
end

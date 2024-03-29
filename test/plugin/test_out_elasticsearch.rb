require 'helper'
require 'date'
require 'json'
require 'flexmock/test_unit'

class ElasticsearchOutput < Test::Unit::TestCase
  include FlexMock::TestCase

  attr_accessor :index_cmds, :index_command_counts

  def setup
    Fluent::Test.setup
    require 'fluent/plugin/out_elasticsearch'
    @driver = nil
    log = Fluent::Engine.log
    log.out.logs.slice!(0, log.out.logs.length)
  end

  def driver(tag='test', conf='')
    @driver ||= Fluent::Test::BufferedOutputTestDriver.new(Fluent::ElasticsearchOutput, tag) {
      # v0.12's test driver assume format definition. This simulates ObjectBufferedOutput format
      if !defined?(Fluent::Plugin::Output)
        def format(tag, time, record)
          [time, record].to_msgpack
        end
      end
    }.configure(conf)
  end

  def sample_record(content={})
      {'age' => 26, 'request_id' => '42', 'parent_id' => 'parent', 'routing_id' => 'routing'}.merge(content)
  end

  def stub_elastic_ping(url="http://localhost:9200")
    stub_request(:head, url).to_return(:status => 200, :body => "", :headers => {})
  end

  def stub_elastic(url="http://localhost:9200/_bulk")
    stub_request(:post, url).with do |req|
        @index_cmds = req.body.split("\n").map {|r| JSON.parse(r) }
    end
  end

  def stub_elastic_unavailable(url="http://localhost:9200/_bulk")
    stub_request(:post, url).to_return(:status => [503, "Service Unavailable"])
  end

  def stub_elastic_with_store_index_command_counts(url="http://localhost:9200/_bulk")
    if @index_command_counts == nil
       @index_command_counts = {}
       @index_command_counts.default = 0
    end

    stub_request(:post, url).with do |req|
      index_cmds = req.body.split("\n").map {|r| JSON.parse(r) }
      @index_command_counts[url] += index_cmds.size
    end
  end

  def make_response_body(req, error_el = nil, error_status = nil, error = nil)
    req_index_cmds = req.body.split("\n").map { |r| JSON.parse(r) }
    items = []
    count = 0
    ids = 1
    op = nil
    index = nil
    type = nil
    id = nil
    req_index_cmds.each do |cmd|
      if count.even?
        op = cmd.keys[0]
        index = cmd[op]['_index']
        type = cmd[op]['_type']
        if cmd[op].has_key?('_id')
          id = cmd[op]['_id']
        else
          # Note: this appears to be an undocumented feature of Elasticsearch
          # https://www.elastic.co/guide/en/elasticsearch/reference/2.4/docs-bulk.html
          # When you submit an "index" write_operation, with no "_id" field in the
          # metadata header, Elasticsearch will turn this into a "create"
          # operation in the response.
          if "index" == op
            op = "create"
          end
          id = ids
          ids += 1
        end
      else
        item = {
          op => {
            '_index' => index, '_type' => type, '_id' => id, '_version' => 1,
            '_shards' => { 'total' => 1, 'successful' => 1, 'failed' => 0 },
            'status' => op == 'create' ? 201 : 200
          }
        }
        items.push(item)
      end
      count += 1
    end
    if !error_el.nil? && !error_status.nil? && !error.nil?
      op = items[error_el].keys[0]
      items[error_el][op].delete('_version')
      items[error_el][op].delete('_shards')
      items[error_el][op]['error'] = error
      items[error_el][op]['status'] = error_status
      errors = true
    else
      errors = false
    end
    @index_cmds = items
    body = { 'took' => 6, 'errors' => errors, 'items' => items }
    return body.to_json
  end

  def stub_elastic_bad_argument(url="http://localhost:9200/_bulk")
    error = {
      "type" => "mapper_parsing_exception",
      "reason" => "failed to parse [...]",
      "caused_by" => {
        "type" => "illegal_argument_exception",
        "reason" => "Invalid format: \"...\""
      }
    }
    stub_request(:post, url).to_return(lambda { |req| { :status => 200, :body => make_response_body(req, 1, 400, error), :headers => { 'Content-Type' => 'json' } } })
  end

  def stub_elastic_bulk_error(url="http://localhost:9200/_bulk")
    error = {
      "type" => "some-unrecognized-error",
      "reason" => "some message printed here ...",
    }
    stub_request(:post, url).to_return(lambda { |req| { :status => 200, :body => make_response_body(req, 1, 500, error), :headers => { 'Content-Type' => 'json' } } })
  end

  def stub_elastic_bulk_rejected(url="http://localhost:9200/_bulk")
    error = {
      "status" => 500,
      "type" => "es_rejected_execution_exception",
      "reason" => "rejected execution of org.elasticsearch.transport.TransportService$4@1a34d37a on EsThreadPoolExecutor[bulk, queue capacity = 50, org.elasticsearch.common.util.concurrent.EsThreadPoolExecutor@312a2162[Running, pool size = 32, active threads = 32, queued tasks = 50, completed tasks = 327053]]"
    }
    stub_request(:post, url).to_return(lambda { |req| { :status => 200, :body => make_response_body(req, 1, 429, error), :headers => { 'Content-Type' => 'json' } } })
  end

  def stub_elastic_out_of_memory(url="http://localhost:9200/_bulk")
    error = {
      "status" => 500,
      "type" => "out_of_memory_error",
      "reason" => "Java heap space"
    }
    stub_request(:post, url).to_return(lambda { |req| { :status => 200, :body => make_response_body(req, 1, 500, error), :headers => { 'Content-Type' => 'json' } } })
  end

  def stub_elastic_unexpected_response_op(url="http://localhost:9200/_bulk")
    error = {
      "category" => "some-other-type",
      "reason" => "some-other-reason"
    }
    stub_request(:post, url).to_return(lambda { |req| bodystr = make_response_body(req, 0, 500, error); body = JSON.parse(bodystr); body['items'][0]['unknown'] = body['items'][0].delete('create'); { :status => 200, :body => body.to_json, :headers => { 'Content-Type' => 'json' } } })
  end

  def assert_logs_include(logs, msg, exp_matches=1)
    matches = logs.grep /#{msg}/
    assert_equal(exp_matches, matches.length, "Logs do not contain '#{msg}' '#{logs}'")
  end

  def test_configure
    config = %{
      host     logs.google.com
      port     777
      scheme   https
      path     /es/
      user     john
      password doe
    }
    instance = driver('test', config).instance

    assert_equal 'logs.google.com', instance.host
    assert_equal 777, instance.port
    assert_equal :https, instance.scheme
    assert_equal '/es/', instance.path
    assert_equal 'john', instance.user
    assert_equal 'doe', instance.password
    assert_equal :TLSv1, instance.ssl_version
    assert_nil instance.client_key
    assert_nil instance.client_cert
    assert_nil instance.client_key_pass
    assert_false instance.with_transporter_log
  end

  def test_template_already_present
    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      template_name   logstash
      template_file   /abc123
    }

    # connection start
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
    # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_not_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash")
  end

  def test_template_create
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')

    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      template_name   logstash
      template_file   #{template_file}
    }

    # connection start
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
    # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 404, :body => "", :headers => {})
    # creation
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash", times: 1)
  end

  def test_template_overwrite
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')

    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      template_name   logstash
      template_file   #{template_file}
      template_overwrite true
    }

    # connection start
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
    # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 200, :body => "", :headers => {})
    # creation
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash", times: 1)
  end


  def test_template_create_invalid_filename
    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      template_name   logstash
      template_file   /abc123
    }

    # connection start
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
    # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 404, :body => "", :headers => {})

    assert_raise(RuntimeError) {
      driver('test', config)
    }
  end

  def test_templates_create
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')
    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      templates       {"logstash1":"#{template_file}", "logstash2":"#{template_file}","logstash3":"#{template_file}" }
    }

    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
     # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 404, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 404, :body => "", :headers => {})

    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash3").
      to_return(:status => 200, :body => "", :headers => {}) #exists

    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash3").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_requested( :put, "https://john:doe@logs.google.com:777/es//_template/logstash1", times: 1)
    assert_requested( :put, "https://john:doe@logs.google.com:777/es//_template/logstash2", times: 1)
    assert_not_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash3") #exists
  end

  def test_templates_overwrite
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')
    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      templates       {"logstash1":"#{template_file}", "logstash2":"#{template_file}","logstash3":"#{template_file}" }
      template_overwrite true
    }

    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
     # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash3").
      to_return(:status => 200, :body => "", :headers => {}) #exists

    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash3").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1", times: 1)
    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2", times: 1)
    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash3", times: 1)
  end

  def test_templates_not_used
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')

    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      template_name   logstash
      template_file   #{template_file}
      templates       {"logstash1":"#{template_file}", "logstash2":"#{template_file}" }
    }
    # connection start
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
    # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 404, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 404, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 404, :body => "", :headers => {})
    #creation
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 200, :body => "", :headers => {})

    driver('test', config)

    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash", times: 1)

    assert_not_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1")
    assert_not_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2")
  end

  def test_templates_can_be_partially_created_if_error_occurs
    cwd = File.dirname(__FILE__)
    template_file = File.join(cwd, 'test_template.json')
    config = %{
      host            logs.google.com
      port            777
      scheme          https
      path            /es/
      user            john
      password        doe
      templates       {"logstash1":"#{template_file}", "logstash2":"/abc" }
    }
    stub_request(:head, "https://john:doe@logs.google.com:777/es//").
      to_return(:status => 200, :body => "", :headers => {})
     # check if template exists
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 404, :body => "", :headers => {})
    stub_request(:get, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 404, :body => "", :headers => {})

    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1").
      to_return(:status => 200, :body => "", :headers => {})
    stub_request(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2").
      to_return(:status => 200, :body => "", :headers => {})

    assert_raise(RuntimeError) {
      driver('test', config)
    }

    assert_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash1", times: 1)
    assert_not_requested(:put, "https://john:doe@logs.google.com:777/es//_template/logstash2")
  end

  def test_legacy_hosts_list
    config = %{
      hosts    host1:50,host2:100,host3
      scheme   https
      path     /es/
      port     123
    }
    instance = driver('test', config).instance

    assert_equal 3, instance.get_connection_options[:hosts].length
    host1, host2, host3 = instance.get_connection_options[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 50, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal '/es/', host2[:path]
    assert_equal 'host3', host3[:host]
    assert_equal 123, host3[:port]
    assert_equal 'https', host3[:scheme]
    assert_equal '/es/', host3[:path]
  end

  def test_hosts_list
    config = %{
      hosts    https://john:password@host1:443/elastic/,http://host2
      path     /default_path
      user     default_user
      password default_password
    }
    instance = driver('test', config).instance

    assert_equal 2, instance.get_connection_options[:hosts].length
    host1, host2 = instance.get_connection_options[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 443, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal 'john', host1[:user]
    assert_equal 'password', host1[:password]
    assert_equal '/elastic/', host1[:path]

    assert_equal 'host2', host2[:host]
    assert_equal 'http', host2[:scheme]
    assert_equal 'default_user', host2[:user]
    assert_equal 'default_password', host2[:password]
    assert_equal '/default_path', host2[:path]
  end

  def test_hosts_list_with_escape_placeholders
    config = %{
      hosts    https://%{j+hn}:%{passw@rd}@host1:443/elastic/,http://host2
      path     /default_path
      user     default_user
      password default_password
    }
    instance = driver('test', config).instance

    assert_equal 2, instance.get_connection_options[:hosts].length
    host1, host2 = instance.get_connection_options[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 443, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal 'j%2Bhn', host1[:user]
    assert_equal 'passw%40rd', host1[:password]
    assert_equal '/elastic/', host1[:path]

    assert_equal 'host2', host2[:host]
    assert_equal 'http', host2[:scheme]
    assert_equal 'default_user', host2[:user]
    assert_equal 'default_password', host2[:password]
    assert_equal '/default_path', host2[:path]
  end

  def test_single_host_params_and_defaults
    config = %{
      host     logs.google.com
      user     john
      password doe
    }
    instance = driver('test', config).instance

    assert_equal 1, instance.get_connection_options[:hosts].length
    host1 = instance.get_connection_options[:hosts][0]

    assert_equal 'logs.google.com', host1[:host]
    assert_equal 9200, host1[:port]
    assert_equal 'http', host1[:scheme]
    assert_equal 'john', host1[:user]
    assert_equal 'doe', host1[:password]
    assert_equal nil, host1[:path]
  end

  def test_single_host_params_and_defaults_with_escape_placeholders
    config = %{
      host     logs.google.com
      user     %{j+hn}
      password %{d@e}
    }
    instance = driver('test', config).instance

    assert_equal 1, instance.get_connection_options[:hosts].length
    host1 = instance.get_connection_options[:hosts][0]

    assert_equal 'logs.google.com', host1[:host]
    assert_equal 9200, host1[:port]
    assert_equal 'http', host1[:scheme]
    assert_equal 'j%2Bhn', host1[:user]
    assert_equal 'd%40e', host1[:password]
    assert_equal nil, host1[:path]
  end

  def test_content_type_header
    stub_request(:head, "http://localhost:9200/").
      to_return(:status => 200, :body => "", :headers => {})
    if Elasticsearch::VERSION >= "6.0.2"
      elastic_request = stub_request(:post, "http://localhost:9200/_bulk").
                          with(headers: { "Content-Type" => "application/x-ndjson" })
    else
      elastic_request = stub_request(:post, "http://localhost:9200/_bulk").
                          with(headers: { "Content-Type" => "application/json" })
    end
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_write_message_with_bad_chunk
    driver.configure("target_index_key bad_value\n")
    log = driver.instance.router.emit_error_handler.log
    stub_elastic_ping
    stub_elastic
    driver.emit({'bad_value'=>"\255"})
    driver.run
    assert_logs_include(log.out.logs, /(input string invalid)|(invalid byte sequence in UTF-8)/)
  end

  def test_writes_to_default_index
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_index'])
  end

  def test_writes_to_default_type
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_type'])
  end

  def test_writes_to_speficied_index
    driver.configure("index_name myindex\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('myindex', index_cmds.first['index']['_index'])
  end

  def test_writes_to_speficied_index_uppercase
    driver.configure("index_name MyIndex\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    # Allthough index_name has upper-case characters,
    # it should be set as lower-case when sent to elasticsearch.
    assert_equal('myindex', index_cmds.first['index']['_index'])
  end

  def test_writes_to_target_index_key
    driver.configure("target_index_key @target_index\n")
    stub_elastic_ping
    stub_elastic
    record = sample_record.clone
    driver.emit(sample_record.merge('@target_index' => 'local-override'))
    driver.run
    assert_equal('local-override', index_cmds.first['index']['_index'])
    assert_nil(index_cmds[1]['@target_index'])
  end

  def test_writes_to_target_index_key_logstash
    driver.configure("target_index_key @target_index
                      logstash_format true")
    time = Time.parse Date.today.iso8601
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('@target_index' => 'local-override'), time.to_i)
    driver.run
    assert_equal('local-override', index_cmds.first['index']['_index'])
  end

   def test_writes_to_target_index_key_logstash_uppercase
    driver.configure("target_index_key @target_index
                      logstash_format true")
    time = Time.parse Date.today.iso8601
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('@target_index' => 'Local-Override'), time.to_i)
    driver.run
    # Allthough @target_index has upper-case characters,
    # it should be set as lower-case when sent to elasticsearch.
    assert_equal('local-override', index_cmds.first['index']['_index'])
  end

  def test_writes_to_default_index_with_pipeline
    pipeline = "fluentd"
    driver.configure("pipeline #{pipeline}")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(pipeline, index_cmds.first['index']['pipeline'])
  end

  def test_writes_to_target_index_key_fallack
    driver.configure("target_index_key @target_index\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_index'])
  end

  def test_writes_to_target_index_key_fallack_logstash
    driver.configure("target_index_key @target_index\n
                      logstash_format true")
    time = Time.parse Date.today.iso8601
    logstash_index = "logstash-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_speficied_type
    driver.configure("type_name mytype\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('mytype', index_cmds.first['index']['_type'])
  end

  def test_writes_to_target_type_key
    driver.configure("target_type_key @target_type\n")
    stub_elastic_ping
    stub_elastic
    record = sample_record.clone
    driver.emit(sample_record.merge('@target_type' => 'local-override'))
    driver.run
    assert_equal('local-override', index_cmds.first['index']['_type'])
    assert_nil(index_cmds[1]['@target_type'])
  end

  def test_writes_to_target_type_key_fallack_to_default
    driver.configure("target_type_key @target_type\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_type'])
  end

  def test_writes_to_target_type_key_fallack_to_type_name
    driver.configure("target_type_key @target_type
                      type_name mytype")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('mytype', index_cmds.first['index']['_type'])
  end

  def test_writes_to_target_type_key_nested
    driver.configure("target_type_key kubernetes.labels.log_type\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('kubernetes' => {
      'labels' => {
        'log_type' => 'local-override'
      }
    }))
    driver.run
    assert_equal('local-override', index_cmds.first['index']['_type'])
    assert_nil(index_cmds[1]['kubernetes']['labels']['log_type'])
  end

  def test_writes_to_target_type_key_fallack_to_default_nested
    driver.configure("target_type_key kubernetes.labels.log_type\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('kubernetes' => {
      'labels' => {
        'other_labels' => 'test'
      }
    }))
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_type'])
  end

  def test_writes_to_speficied_host
    driver.configure("host 192.168.33.50\n")
    stub_elastic_ping("http://192.168.33.50:9200")
    elastic_request = stub_elastic("http://192.168.33.50:9200/_bulk")
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_writes_to_speficied_port
    driver.configure("port 9201\n")
    stub_elastic_ping("http://localhost:9201")
    elastic_request = stub_elastic("http://localhost:9201/_bulk")
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_writes_to_multi_hosts
    hosts = [['192.168.33.50', 9201], ['192.168.33.51', 9201], ['192.168.33.52', 9201]]
    hosts_string = hosts.map {|x| "#{x[0]}:#{x[1]}"}.compact.join(',')

    driver.configure("hosts #{hosts_string}")

    hosts.each do |host_info|
      host, port = host_info
      stub_elastic_ping("http://#{host}:#{port}")
      stub_elastic_with_store_index_command_counts("http://#{host}:#{port}/_bulk")
    end

    1000.times do
      driver.emit(sample_record.merge('age'=>rand(100)))
    end

    driver.run

    # @note: we cannot make multi chunks with options (flush_interval, buffer_chunk_limit)
    # it's Fluentd test driver's constraint
    # so @index_command_counts.size is always 1

    assert(@index_command_counts.size > 0, "not working with hosts options")

    total = 0
    @index_command_counts.each do |url, count|
      total += count
    end
    assert_equal(2000, total)
  end

  def test_nested_record_with_flattening_on
    driver.configure("flatten_hashes true
                      flatten_hashes_separator |")

    original_hash =  {"foo" => {"bar" => "baz"}, "people" => [
      {"age" => "25", "height" => "1ft"},
      {"age" => "30", "height" => "2ft"}
    ]}

    expected_output = {"foo|bar"=>"baz", "people" => [
      {"age" => "25", "height" => "1ft"},
      {"age" => "30", "height" => "2ft"}
    ]}

    stub_elastic_ping
    stub_elastic
    driver.emit(original_hash)
    driver.run
    assert_equal expected_output, index_cmds[1]
  end

  def test_nested_record_with_flattening_off
    # flattening off by default

    original_hash =  {"foo" => {"bar" => "baz"}}
    expected_output = {"foo" => {"bar" => "baz"}}

    stub_elastic_ping
    stub_elastic
    driver.emit(original_hash)
    driver.run
    assert_equal expected_output, index_cmds[1]
  end

  def test_makes_bulk_request
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.emit(sample_record.merge('age' => 27))
    driver.run
    assert_equal(4, index_cmds.count)
  end

  def test_all_records_are_preserved_in_bulk
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.emit(sample_record.merge('age' => 27))
    driver.run
    assert_equal(26, index_cmds[1]['age'])
    assert_equal(27, index_cmds[3]['age'])
  end

  def test_writes_to_logstash_index
    driver.configure("logstash_format true\n")
    #
    # This is 1 second past midnight in BST, so the UTC index should be the day before
    dt = DateTime.new(2015, 6, 1, 0, 0, 1, "+01:00")
    logstash_index = "logstash-2015.05.31"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, dt.to_time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_non_utc_index
    driver.configure("logstash_format true
                      utc_index false")
    # When using `utc_index false` the index time will be the local day of
    # ingestion time
    time = Date.today.to_time
    index = "logstash-#{time.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix
    driver.configure("logstash_format true
                      logstash_prefix myprefix")
    time = Time.parse Date.today.iso8601
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix_and_separator
    separator = '_'
    driver.configure("logstash_format true
                      logstash_prefix_separator #{separator}
                      logstash_prefix myprefix")
    time = Time.parse Date.today.iso8601
    logstash_index = "myprefix#{separator}#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix_uppercase
    driver.configure("logstash_format true
                      logstash_prefix MyPrefix")
    time = Time.parse Date.today.iso8601
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    # Allthough logstash_prefix has upper-case characters,
    # it should be set as lower-case when sent to elasticsearch.
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

    def test_writes_to_logstash_index_with_specified_dateformat
    driver.configure("logstash_format true
                      logstash_dateformat %Y.%m")
    time = Time.parse Date.today.iso8601
    logstash_index = "logstash-#{time.getutc.strftime("%Y.%m")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix_and_dateformat
    driver.configure("logstash_format true
                      logstash_prefix myprefix
                      logstash_dateformat %Y.%m")
    time = Time.parse Date.today.iso8601
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_doesnt_add_logstash_timestamp_by_default
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds[1]['@timestamp'])
  end

  def test_adds_timestamp_when_logstash
    driver.configure("logstash_format true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.now.iso8601
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_adds_timestamp_when_include_timestamp
    driver.configure("include_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.now
    time = ts.to_time
    driver.emit(sample_record, time)
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts.iso8601)
  end

  def test_uses_custom_timestamp_when_included_in_record
    driver.configure("logstash_format true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).iso8601
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_timestamp_when_included_in_record_without_logstash
    driver.configure("include_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).iso8601
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key
    driver.configure("logstash_format true
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).iso8601
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key_with_format
    driver.configure("logstash_format true
                      time_key_format %Y-%m-%d %H:%M:%S.%N%z
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = "2001-02-03 13:14:01.673+02:00"
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
    assert_equal("logstash-2001.02.03", index_cmds[0]['index']['_index'])
  end

  def test_uses_custom_time_key_with_format_without_logstash
    driver.configure("include_timestamp true
                      index_name test
                      time_key_format %Y-%m-%d %H:%M:%S.%N%z
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = "2001-02-03 13:14:01.673+02:00"
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
    assert_equal("test", index_cmds[0]['index']['_index'])
  end

  def test_uses_custom_time_key_exclude_timekey
    driver.configure("logstash_format true
                      time_key vtm
                      time_key_exclude_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).iso8601
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(!index_cmds[1].key?('@timestamp'), '@timestamp should be messing')
  end

  def test_uses_custom_time_key_format
    driver.configure("logstash_format true
                      time_key_format %Y-%m-%dT%H:%M:%S.%N%z\n")
    stub_elastic_ping
    stub_elastic
    ts = "2001-02-03T13:14:01.673+02:00"
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert_equal("logstash-2001.02.03", index_cmds[0]['index']['_index'])
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key_format_without_logstash
    driver.configure("include_timestamp true
                      index_name test
                      time_key_format %Y-%m-%dT%H:%M:%S.%N%z\n")
    stub_elastic_ping
    stub_elastic
    ts = "2001-02-03T13:14:01.673+02:00"
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert_equal("test", index_cmds[0]['index']['_index'])
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  data(:default => nil,
       :custom_tag => 'es_plugin.output.time.error')
  def test_uses_custom_time_key_format_logs_an_error(tag_for_error)
    tag_config = tag_for_error ? "time_parse_error_tag #{tag_for_error}" : ''
    tag_for_error = 'Fluent::ElasticsearchOutput::TimeParser.error' if tag_for_error.nil?
    driver.configure("logstash_format true
                      time_key_format %Y-%m-%dT%H:%M:%S.%N%z\n#{tag_config}\n")
    stub_elastic_ping
    stub_elastic

    ts = "2001/02/03 13:14:01,673+02:00"
    index = "logstash-#{Date.today.strftime("%Y.%m.%d")}"

    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run

    log = driver.instance.router.emit_error_handler.log
    errors = log.out.logs.grep /tag="#{tag_for_error}"/
    assert_equal(1, errors.length, "Error was logged for timestamp parse failure")

    assert_equal(index, index_cmds[0]['index']['_index'])
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end


  def test_uses_custom_time_key_format_obscure_format
    driver.configure("logstash_format true
                      time_key_format %a %b %d %H:%M:%S %Z %Y\n")
    stub_elastic_ping
    stub_elastic
    ts = "Thu Nov 29 14:33:20 GMT 2001"
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert_equal("logstash-2001.11.29", index_cmds[0]['index']['_index'])
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_no_subsecond_precision_by_default
    driver.configure("logstash_format true\n")
    stub_elastic_ping
    stub_elastic
    begin
      time = Fluent::EventTime.new(Time.now.to_i, 000000000)
    rescue
      time = Fluent::Engine.now
    end
    driver.emit(sample_record, time)
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], Time.at(time).iso8601)
  end

  def test_uses_subsecond_precision_when_configured
    driver.configure("logstash_format true
                      time_precision 3\n")
    stub_elastic_ping
    stub_elastic
    begin
    time = Fluent::EventTime.new(Time.now.to_i, 000000000)
    rescue
      time = Fluent::Engine.now
    end
    driver.emit(sample_record, time)
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], Time.at(time).iso8601(3))
  end

  def test_doesnt_add_tag_key_by_default
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds[1]['tag'])
  end

  def test_adds_tag_key_when_configured
    driver('mytag').configure("include_tag_key true\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1].has_key?('tag'))
    assert_equal(index_cmds[1]['tag'], 'mytag')
  end

  def test_adds_id_key_when_configured
    driver.configure("id_key request_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_id'], '42')
  end

  def test_doesnt_add_id_key_if_missing_when_configured
    driver.configure("id_key another_request_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_adds_id_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_adds_parent_key_when_configured
    driver.configure("parent_key parent_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_parent'], 'parent')
  end

  def test_doesnt_add_parent_key_if_missing_when_configured
    driver.configure("parent_key another_parent_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_parent'))
  end

  def test_adds_parent_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_parent'))
  end

  def test_adds_routing_key_when_configured
    driver.configure("routing_key routing_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_routing'], 'routing')
  end

  def test_doesnt_add_routing_key_if_missing_when_configured
    driver.configure("routing_key another_routing_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_routing'))
  end

  def test_adds_routing_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_routing'))
  end

  def test_remove_one_key
    driver.configure("remove_keys key1\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('key1' => 'v1', 'key2' => 'v2'))
    driver.run
    assert(!index_cmds[1].has_key?('key1'))
    assert(index_cmds[1].has_key?('key2'))
  end

  def test_remove_multi_keys
    driver.configure("remove_keys key1, key2\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('key1' => 'v1', 'key2' => 'v2'))
    driver.run
    assert(!index_cmds[1].has_key?('key1'))
    assert(!index_cmds[1].has_key?('key2'))
  end

  def test_request_error
    stub_elastic_ping
    stub_elastic_unavailable
    driver.emit(sample_record)
    assert_raise(Elasticsearch::Transport::Transport::Errors::ServiceUnavailable) {
      driver.run
    }
  end

  def test_garbage_record_error
    stub_elastic_ping
    stub_elastic
    driver.emit("some garbage string")
    driver.run
  end

  def test_connection_failed_retry
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise Faraday::ConnectionFailed, "Test message"
    end

    driver.emit(sample_record)

    assert_raise(Fluent::ElasticsearchOutput::ConnectionFailure) {
      driver.run
    }
    assert_equal(connection_resets, 3)
  end

  def test_reconnect_on_error_enabled
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise ZeroDivisionError, "any not host_unreachable_exceptions exception"
    end

    driver.configure("reconnect_on_error true\n")
    driver.emit(sample_record)

    assert_raise(ZeroDivisionError) {
      driver.run
    }

    assert_raise(ZeroDivisionError) {
      driver.run
    }
    assert_equal(connection_resets, 2)
  end

  def test_reconnect_on_error_disabled
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise ZeroDivisionError, "any not host_unreachable_exceptions exception"
    end

    driver.configure("reconnect_on_error false\n")
    driver.emit(sample_record)

    assert_raise(ZeroDivisionError) {
      driver.run
    }

    assert_raise(ZeroDivisionError) {
      driver.run
    }
    assert_equal(connection_resets, 1)
  end

  def test_bulk_error_retags_when_configured
    driver.configure("retry_tag retry\n")
    stub_elastic_ping
    stub_request(:post, 'http://localhost:9200/_bulk')
        .to_return(lambda do |req|
      { :status => 200,
        :headers => { 'Content-Type' => 'json' },
        :body => %({
          "took" : 1,
          "errors" : true,
          "items" : [
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc",
                "status" : 500,
                "error" : {
                  "type" : "some unrecognized type",
                  "reason":"some error to cause version mismatch"
                }
              }
            }
           ]
        })
     }
    end)
    driver.emit(sample_record, 1)

    driver.expect_emit('retry', 1, sample_record)
    driver.run
  end

  def test_create_should_write_records_with_ids_and_skip_those_without
    driver.configure("write_operation create\nid_key my_id\nlog_level debug")
    log = driver.instance.router.emit_error_handler.log
    stub_elastic_ping
    stub_request(:post, 'http://localhost:9200/_bulk')
        .to_return(lambda do |req|
      { :status => 200,
        :headers => { 'Content-Type' => 'json' },
        :body => %({
          "took" : 1,
          "errors" : true,
          "items" : [
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc"
              }
            },
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "xyz",
                "status" : 500,
                "error" : {
                  "type" : "some unrecognized type",
                  "reason":"some error to cause version mismatch"
                }
              }
            }
           ]
        })
     }
    end)
    sample_record1 = sample_record('my_id' => 'abc')
    sample_record4 = sample_record('my_id' => 'xyz')
    driver.emit(sample_record1, 1)
    driver.emit(sample_record, 2)
    driver.emit(sample_record, 3)
    driver.emit(sample_record4, 4)

    # one record succeeded while the other should be 'retried'
    driver.expect_emit('test', 4, sample_record4)
    driver.run
    assert_logs_include(log.out.logs, /(Dropping record)/, 2)
  end

  def test_create_should_write_records_with_ids_and_emit_those_without
    driver.configure("write_operation create\nid_key my_id\nemit_error_for_missing_id true")
    log = driver.instance.router.emit_error_handler.log
    stub_elastic_ping
    stub_request(:post, 'http://localhost:9200/_bulk')
        .to_return(lambda do |req|
      { :status => 200,
        :headers => { 'Content-Type' => 'json' },
        :body => %({
          "took" : 1,
          "errors" : true,
          "items" : [
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc"
              }
            },
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "xyz",
                "status" : 500,
                "error" : {
                  "type" : "some unrecognized type",
                  "reason":"some error to cause version mismatch"
                }
              }
            }
           ]
        })
     }
    end)
    sample_record1 = sample_record('my_id' => 'abc')
    sample_record4 = sample_record('my_id' => 'xyz')
    driver.emit(sample_record1, 1)
    driver.emit(sample_record, 2)
    driver.emit(sample_record, 3)
    driver.emit(sample_record4, 4)

    # one record succeeded while the other should be 'retried'
    driver.expect_emit('test', 4, sample_record4)
    driver.run
    assert_logs_include(log.out.logs, /(Missing '_id' field)/, 2)
  end

  def test_bulk_error
    stub_elastic_ping
    stub_request(:post, 'http://localhost:9200/_bulk')
        .to_return(lambda do |req|
      { :status => 200,
        :headers => { 'Content-Type' => 'json' },
        :body => %({
          "took" : 1,
          "errors" : true,
          "items" : [
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc",
                "status" : 500,
                "error" : {
                  "type" : "some unrecognized type",
                  "reason":"some error to cause version mismatch"
                }
              }
            },
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc",
                "status" : 201
              }
            },
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc",
                "status" : 500,
                "error" : {
                  "type" : "some unrecognized type",
                  "reason":"some error to cause version mismatch"
                }
              }
            },
            {
              "create" : {
                "_index" : "foo",
                "_type"  : "bar",
                "_id" : "abc",
                "_id" : "abc",
                "status" : 409
              }
            }
           ]
        })
     }
    end)

    driver.emit(sample_record, 1)
    driver.emit(sample_record, 2)
    driver.emit(sample_record, 3)
    driver.emit(sample_record, 4)

    driver.expect_emit('test', 1, sample_record)
    driver.expect_emit('test', 3, sample_record)
    driver.run
  end

  def test_update_should_not_write_if_theres_no_id
    driver.configure("write_operation update\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_upsert_should_not_write_if_theres_no_id
    driver.configure("write_operation upsert\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_create_should_not_write_if_theres_no_id
    driver.configure("write_operation create\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_update_should_write_update_op_and_doc_as_upsert_is_false
    driver.configure("write_operation update
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("update"))
    assert(!index_cmds[1]["doc_as_upsert"])
    assert(!index_cmds[1]["upsert"])
  end

  def test_update_should_remove_keys_from_doc_when_keys_are_skipped
    driver.configure("write_operation update
                      id_key request_id
                      remove_keys_on_update parent_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1]["doc"])
    assert(!index_cmds[1]["doc"]["parent_id"])
  end

  def test_upsert_should_write_update_op_and_doc_as_upsert_is_true
    driver.configure("write_operation upsert
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("update"))
    assert(index_cmds[1]["doc_as_upsert"])
    assert(!index_cmds[1]["upsert"])
  end

  def test_upsert_should_write_update_op_upsert_and_doc_when_keys_are_skipped
    driver.configure("write_operation upsert
                      id_key request_id
                      remove_keys_on_update parent_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("update"))
    assert(!index_cmds[1]["doc_as_upsert"])
    assert(index_cmds[1]["upsert"])
    assert(index_cmds[1]["doc"])
  end

  def test_upsert_should_remove_keys_from_doc_when_keys_are_skipped
    driver.configure("write_operation upsert
                      id_key request_id
                      remove_keys_on_update parent_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1]["upsert"] != index_cmds[1]["doc"])
    assert(!index_cmds[1]["doc"]["parent_id"])
    assert(index_cmds[1]["upsert"]["parent_id"])
  end

  def test_upsert_should_remove_multiple_keys_when_keys_are_skipped
    driver.configure("write_operation upsert
                      id_key id
                      remove_keys_on_update foo,baz")
    stub_elastic_ping
    stub_elastic
    driver.emit("id" => 1, "foo" => "bar", "baz" => "quix", "zip" => "zam")
    driver.run
    assert(
      index_cmds[1]["doc"] == {
        "id" => 1,
        "zip" => "zam",
      }
    )
    assert(
      index_cmds[1]["upsert"] == {
        "id" => 1,
        "foo" => "bar",
        "baz" => "quix",
        "zip" => "zam",
      }
    )
  end

  def test_upsert_should_remove_keys_from_when_the_keys_are_in_the_record
    driver.configure("write_operation upsert
                      id_key id
                      remove_keys_on_update_key keys_to_skip")
    stub_elastic_ping
    stub_elastic
    driver.emit("id" => 1, "foo" => "bar", "baz" => "quix", "keys_to_skip" => ["baz"])
    driver.run
    assert(
      index_cmds[1]["doc"] == {
        "id" => 1,
        "foo" => "bar",
      }
    )
    assert(
      index_cmds[1]["upsert"] == {
        "id" => 1,
        "foo" => "bar",
        "baz" => "quix",
      }
    )
  end

  def test_upsert_should_remove_keys_from_key_on_record_has_higher_presedence_than_config
    driver.configure("write_operation upsert
                      id_key id
                      remove_keys_on_update foo,bar
                      remove_keys_on_update_key keys_to_skip")
    stub_elastic_ping
    stub_elastic
    driver.emit("id" => 1, "foo" => "bar", "baz" => "quix", "keys_to_skip" => ["baz"])
    driver.run
    assert(
      index_cmds[1]["doc"] == {
        "id" => 1,
        # we only expect baz to be stripped here, if the config was more important
        # foo would be stripped too.
        "foo" => "bar",
      }
    )
    assert(
      index_cmds[1]["upsert"] == {
        "id" => 1,
        "foo" => "bar",
        "baz" => "quix",
      }
    )
  end

  def test_create_should_write_create_op
    driver.configure("write_operation create
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("create"))
  end

  def test_use_simple_sniffer
    require 'fluent/plugin/elasticsearch_simple_sniffer'
    driver.configure("sniffer_class_name Fluent::ElasticsearchSimpleSniffer
                      log_level debug
                      with_transporter_log true
                      reload_connections true
                      reload_after 1")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    log = driver.instance.router.emit_error_handler.log
    # 2 - one for the ping, one for the _bulk
    assert_logs_include(log.out.logs, /In Fluent::ElasticsearchSimpleSniffer hosts/, 2)
  end

  def test_suppress_doc_wrap
    driver.configure('write_operation update
                      id_key id
                      remove_keys id
                      suppress_doc_wrap true')
    stub_elastic_ping
    stub_elastic
    doc_body = {'field' => 'value'}
    doc_record = {'id' => 1, 'doc' => doc_body}
    script_body = {'source' => 'ctx._source.counter += params.param1',
                   'lang' => 'painless',
                   'params' => {'param1' => 1}}
    upsert_body = {'counter' => 1}
    script_record = {'id' => 2, 'script' => script_body, 'upsert' => upsert_body}
    driver.emit(doc_record, 1)
    driver.emit(script_record, 2)
    driver.run
    assert(
      index_cmds[1] == {'doc' => doc_body}
    )
    assert(
      index_cmds[3] == {
        'script' => script_body,
        'upsert' => upsert_body
      }
    )
  end

  def test_suppress_doc_wrap_should_handle_record_as_is_at_upsert
    driver.configure('write_operation upsert
                      id_key id
                      remove_keys id
                      suppress_doc_wrap true')
    stub_elastic_ping
    stub_elastic
    doc_body = {'field' => 'value'}
    doc_record = {'id' => 1, 'doc' => doc_body, 'doc_as_upsert' => true}
    script_body = {'source' => 'ctx._source.counter += params.param1',
                   'lang' => 'painless',
                   'params' => {'param1' => 1}}
    upsert_body = {'counter' => 1}
    script_record = {'id' => 2, 'script' => script_body, 'upsert' => upsert_body}
    driver.emit(doc_record, 1)
    driver.emit(script_record, 2)
    driver.run
    assert(
      index_cmds[1] == {
        'doc' => doc_body,
        'doc_as_upsert' => true
      }
    )
    assert(
      index_cmds[3] == {
        'script' => script_body,
        'upsert' => upsert_body
      }
    )
  end

end

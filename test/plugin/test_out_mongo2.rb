# coding: utf-8
require "helper"

class Mongo2OutputTest < ::Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    setup_mongod
  end

  def teardown
    teardown_mongod
  end

  def collection_name
    'test'
  end

  def database_name
    'fluent_test'
  end

  def port
    27017
  end

  def default_config
    %[
      type mongo
      database #{database_name}
      collection #{collection_name}
      include_time_key true
    ]
  end

  def setup_mongod
    options = {}
    options[:database] = database_name
    @client = ::Mongo::Client.new(["localhost:#{port}"], options)
  end

  def teardown_mongod
    @client[collection_name].drop
  end

  def create_driver(conf=default_config, tag='test')
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::Mongo2Output, tag).configure(conf)
  end

  def test_configure
    d = create_driver(%[
      type mongo
      database fluent_test
      collection test_collection

      capped
      capped_size 100
    ])

    assert_equal('fluent_test', d.instance.database)
    assert_equal('test_collection', d.instance.collection)
    assert_equal('localhost', d.instance.host)
    assert_equal(port, d.instance.port)
    assert_equal({capped: true, size: 100}, d.instance.collection_options)
    assert_equal({ssl: false, write: {j: false}}, d.instance.client_options)
  end

  def test_configure_with_ssl
    conf = default_config + %[
      ssl true
    ]
    d = create_driver(conf)
    expected = {
      write: {
        j: false,
      },
      ssl: true,
      ssl_cert: nil,
      ssl_key: nil,
      ssl_key_pass_phrase: nil,
      ssl_verify: false,
      ssl_ca_cert: nil,
    }
    assert_equal(expected, d.instance.client_options)
  end

  def test_configure_with_write_concern
    d = create_driver(default_config + %[
      write_concern 2
    ])

    expected = {
      w: 2,
      ssl: false,
      write: {
        j: false,
      },
    }
    assert_equal(expected, d.instance.client_options)
  end

  def test_configure_with_journaled
    d = create_driver(default_config + %[
      journaled true
    ])

    expected = {
      ssl: false,
      write: {
        j: true,
      },
    }
    assert_equal(expected, d.instance.client_options)
  end

  def test_configure_with_logger_conf
    d = create_driver(default_config + %[
      mongo_log_level fatal
    ])

    expected = "fatal"
    assert_equal(expected, d.instance.mongo_log_level)
  end

  def get_documents
    @client[collection_name].find.to_a.map {|e| e.delete('_id'); e}
  end

  def emit_documents(d)
    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({'a' => 1}, time)
    d.emit({'a' => 2}, time)
    time
  end

  def test_format
    d = create_driver

    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({'a' => 1}, time)
    d.emit({'a' => 2}, time)
    d.expect_format([time, {'a' => 1, d.instance.time_key => time}].to_msgpack)
    d.expect_format([time, {'a' => 2, d.instance.time_key => time}].to_msgpack)
    d.run

    documents = get_documents
    assert_equal(2, documents.size)
  end

  def test_write
    d = create_driver
    t = emit_documents(d)

    d.run
    actual_documents = get_documents
    time = Time.parse("2011-01-02 13:14:15 UTC")
    expected = [{'a' => 1, d.instance.time_key => time},
                {'a' => 2, d.instance.time_key => time}]
    assert_equal(expected, actual_documents)
  end

  def test_write_at_enable_tag
    d = create_driver(default_config + %[
      include_tag_key true
      include_time_key false
    ])
    t = emit_documents(d)

    d.run
    actual_documents = get_documents
    expected = [{'a' => 1, d.instance.tag_key => 'test'},
                {'a' => 2, d.instance.tag_key => 'test'}]
    assert_equal(expected, actual_documents)
  end

  def emit_invalid_documents(d)
    time = Time.parse("2011-01-02 13:14:15 UTC").to_i
    d.emit({'a' => 3, 'b' => "c", '$last' => '石動'}, time)
    d.emit({'a' => 4, 'b' => "d", 'first' => '菖蒲'.encode('EUC-JP').force_encoding('UTF-8')}, time)
    time
  end

  def test_write_with_invalid_recoreds_with_exclude_one_broken_fields_mongodb_3_2_or_later
    omit("Use MongoDB 3.2 or later.") unless ENV['MONGODB'].to_f >= 3.2

    d = create_driver(default_config + %[
      exclude_broken_fields a
    ])
    t = emit_documents(d)
    t = emit_invalid_documents(d)

    d.run
    documents = get_documents
    assert_equal(4, documents.size)
    assert_equal(4, documents.select { |e| e.has_key?(d.instance.broken_bulk_inserted_sequence_key) }.size)
    assert_equal([1, 2, 3, 4], documents.select { |e| e.has_key?('a') }.map { |e| e['a'] }.sort)
    assert_equal(0, documents.select { |e| e.has_key?('b') }.size)
  end

  def test_write_with_invalid_recoreds_with_keys_containing_dot_and_dollar
    d = create_driver(default_config + %[
      replace_dot_in_key_with _dot_
      replace_dollar_in_key_with _dollar_
    ])

    original_time = "2016-02-01 13:14:15 UTC"
    time = Time.parse(original_time).to_i
    d.emit({
      "foo.bar1" => {
        "$foo$bar" => "baz"
      },
      "foo.bar2" => [
        {
          "$foo$bar" => "baz"
        }
      ],
    }, time)
    d.run

    documents = get_documents
    expected = {"foo_dot_bar1" => {
                  "_dollar_foo$bar"=>"baz"
                },
                "foo_dot_bar2" => [
                  {
                    "_dollar_foo$bar"=>"baz"
                  },
                ], "time" => Time.parse(original_time)
               }
    assert_equal(1, documents.size)
    assert_equal(expected, documents[0])
    assert_equal(0, documents.select { |e| e.has_key?(d.instance.broken_bulk_inserted_sequence_key)}.size)
  end

  class WithAuthenticateTest < self
    def setup_mongod
      options = {}
      options[:database] = database_name
      @client = ::Mongo::Client.new(["localhost:#{port}"], options)
      @client.database.users.create('fluent', password: 'password',
                                    roles: [Mongo::Auth::Roles::READ_WRITE])
    end

    def teardown_mongod
      @client[collection_name].drop
      @client.database.users.remove('fluent')
    end

    def test_write_with_authenticate
      d = create_driver(default_config + %[
        user fluent
        password password
      ])
      t = emit_documents(d)

      d.run
      actual_documents = get_documents
      time = Time.parse("2011-01-02 13:14:15 UTC")
      expected = [{'a' => 1, d.instance.time_key => time},
                  {'a' => 2, d.instance.time_key => time}]
      assert_equal(expected, actual_documents)
    end
  end

  class MongoAuthenticateTest < self
    require 'fluent/plugin/mongo_auth'
    include ::Fluent::MongoAuth

    def setup_mongod
      options = {}
      options[:database] = database_name
      @client = ::Mongo::Client.new(["localhost:#{port}"], options)
      @client.database.users.create('fluent', password: 'password',
                                    roles: [Mongo::Auth::Roles::READ_WRITE])
    end

    def teardown_mongod
      @client[collection_name].drop
      @client.database.users.remove('fluent')
    end

    def test_authenticate
      d = create_driver(default_config + %[
        user fluent
        password password
      ])

      assert authenticate(@client)
    end
  end
end

# encoding: UTF-8

require File.expand_path("helper", File.dirname(__FILE__))

class SentinelTest < Test::Unit::TestCase

  include Helper::Client

  def test_sentinel_connection
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    handler = lambda do |id|
      {
        :sentinel => lambda do |command, *args|
          commands[id] << [command, *args]
          ["127.0.0.1", "6381"]
        end
      }
    end

    RedisMock.start(handler.call(:s1)) do |s1_port|
      RedisMock.start(handler.call(:s2)) do |s2_port|
        sentinels[0][:port] = s1_port
        sentinels[1][:port] = s2_port
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], []
  end

  def test_sentinel_failover
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    s1 = {
      :sentinel => lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      :sentinel => lambda do |command, *args|
        commands[:s2] << [command, *args]
        ["127.0.0.1", "6381"]
      end
    }

    RedisMock.start(s1) do |s1_port|
      RedisMock.start(s2) do |s2_port|
        sentinels[0][:port] = s1_port
        sentinels[1][:port] = s2_port
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], [%w[get-master-addr-by-name master1]]
  end

  def test_sentinel_failover_prioritize_healthy_sentinel
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    commands = {
      :s1 => [],
      :s2 => [],
    }

    s1 = {
      :sentinel => lambda do |command, *args|
        commands[:s1] << [command, *args]
        "$-1" # Nil
      end
    }

    s2 = {
      :sentinel => lambda do |command, *args|
        commands[:s2] << [command, *args]
        ["127.0.0.1", "6381"]
      end
    }

    RedisMock.start(s1) do |s1_port|
      RedisMock.start(s2) do |s2_port|
        sentinels[0][:port] = s1_port
        sentinels[1][:port] = s2_port
        redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

        assert redis.ping

        redis.quit

        assert redis.ping
      end
    end

    assert_equal commands[:s1], [%w[get-master-addr-by-name master1]]
    assert_equal commands[:s2], [%w[get-master-addr-by-name master1], %w[get-master-addr-by-name master1]]
  end

  def test_sentinel_with_non_sentinel_options
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    commands = {
      :s1 => [],
      :m1 => []
    }

    sentinel = lambda do |port|
      {
        :auth => lambda do |pass|
          commands[:s1] << ["auth", pass]
          "-ERR unknown command 'auth'"
        end,
        :select => lambda do |db|
          commands[:s1] << ["select", db]
          "-ERR unknown command 'select'"
        end,
        :sentinel => lambda do |command, *args|
          commands[:s1] << [command, *args]
          ["127.0.0.1", port.to_s]
        end
      }
    end

    master = {
      :auth => lambda do |pass|
        commands[:m1] << ["auth", pass]
        "+OK"
      end,
      :role => lambda do
        commands[:m1] << ["role"]
        ["master"]
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(sentinel.call(master_port)) do |sen_port|
        sentinels[0][:port] = sen_port
        redis = Redis.new(:url => "redis://:foo@master1/15", :sentinels => sentinels, :role => :master)

        assert redis.ping
      end
    end

    assert_equal [%w[get-master-addr-by-name master1]], commands[:s1]
    assert_equal [%w[auth foo], %w[role]], commands[:m1]
  end

  def test_sentinel_role_mismatch
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    sentinel = lambda do |port|
      {
        :sentinel => lambda do |command, *args|
          ["127.0.0.1", port.to_s]
        end
      }
    end

    master = {
      :role => lambda do
        ["slave"]
      end
    }

    ex = assert_raise(Redis::ConnectionError) do
      RedisMock.start(master) do |master_port|
        RedisMock.start(sentinel.call(master_port)) do |sen_port|
          sentinels[0][:port] = sen_port
          redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master)

          assert redis.ping
        end
      end
    end

    assert_match(/Instance role mismatch/, ex.message)
  end

  def test_sentinel_retries
    sentinels = [{:host => "127.0.0.1", :port => 26381},
                 {:host => "127.0.0.1", :port => 26382}]

    connections = []

    handler = lambda do |id, port|
      {
        :sentinel => lambda do |command, *args|
          connections << id

          if connections.count(id) < 2
            :close
          else
            ["127.0.0.1", port.to_s]
          end
        end
      }
    end

    master = {
      :role => lambda do
        ["master"]
      end
    }

    RedisMock.start(master) do |master_port|
      RedisMock.start(handler.call(:s1, master_port)) do |s1_port|
        RedisMock.start(handler.call(:s2, master_port)) do |s2_port|
          sentinels[0][:port] = s1_port
          sentinels[1][:port] = s2_port
          redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master, :reconnect_attempts => 1)

          assert redis.ping
        end
      end
    end

    assert_equal [:s1, :s2, :s1], connections

    connections.clear

    ex = assert_raise(Redis::CannotConnectError) do
      RedisMock.start(master) do |master_port|
        RedisMock.start(handler.call(:s1, master_port)) do |s1_port|
          RedisMock.start(handler.call(:s2, master_port)) do |s2_port|
            redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :master, :reconnect_attempts => 0)

            assert redis.ping
          end
        end
      end
    end

    assert_match(/No sentinels available/, ex.message)
  end

  def test_sentinel_nearest
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    master = { :role => lambda { ["master"] }, :node_id => lambda { ["master"] }, :ping => lambda { ["OK"] } }
    s1     = { :role => lambda { ["slave"] }, :node_id => lambda { ["1"] }, :ping => lambda { sleep 0.1; ["OK"] } }
    s2     = { :role => lambda { ["slave"] }, :node_id => lambda { ["2"] }, :ping => lambda { sleep 0.2; ["OK"] } }
    s3     = { :role => lambda { ["slave"] }, :node_id => lambda { ["3"] }, :ping => lambda { sleep 0.3; ["OK"] } }

    5.times do
      RedisMock.start(master) do |master_port|
        RedisMock.start(s1) do |s1_port|
          RedisMock.start(s2) do |s2_port|
            RedisMock.start(s3) do |s3_port|

              sentinel = lambda do |port|
                {
                  :sentinel => lambda do |command, *args|
                    case command
                    when "master"
                      %W[role-reported master ip 127.0.0.1 port #{master_port}]
                    when "slaves"
                      [
                        %W[master-link-status down ip 127.0.0.1 port #{s1_port}],
                        %W[master-link-status ok ip 127.0.0.1 port #{s2_port}],
                        %W[master-link-status ok ip 127.0.0.1 port #{s3_port}]
                      ].shuffle
                    else
                      ["127.0.0.1", port.to_s]
                    end
                  end
                }
              end

              RedisMock.start(sentinel.call(master_port)) do |sen_port|
                sentinels[0][:port] = sen_port
                redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :nearest)
                assert_equal ["master"], redis.node_id
              end
            end
          end
        end
      end
    end
  end

  def test_sentinel_nearest_slave
    sentinels = [{:host => "127.0.0.1", :port => 26381}]

    master = { :role => lambda { ["master"] } }
    s1 = { :role => lambda { ["slave"] }, :node_id => lambda { ["1"] }, :ping => lambda { ["OK"] } }
    s2 = { :role => lambda { ["slave"] }, :node_id => lambda { ["2"] }, :ping => lambda { sleep 0.1; ["OK"] } }
    s3 = { :role => lambda { ["slave"] }, :node_id => lambda { ["3"] }, :ping => lambda { sleep 0.2; ["OK"] } }

    5.times do
      RedisMock.start(master) do |master_port|
        RedisMock.start(s1) do |s1_port|
          RedisMock.start(s2) do |s2_port|
            RedisMock.start(s3) do |s3_port|

              sentinel = lambda do |port|
                {
                  :sentinel => lambda do |command, *args|
                    case command
                    when "slaves"
                      [
                        %W[master-link-status down ip 127.0.0.1 port #{s1_port}],
                        %W[master-link-status ok ip 127.0.0.1 port #{s2_port}],
                        %W[master-link-status ok ip 127.0.0.1 port #{s3_port}]
                      ].shuffle
                    else
                      ["127.0.0.1", port.to_s]
                    end
                  end
                }
              end

              RedisMock.start(sentinel.call(master_port)) do |sen_port|
                sentinels[0][:port] = sen_port
                redis = Redis.new(:url => "redis://master1", :sentinels => sentinels, :role => :nearest_slave)
                assert_equal redis.node_id, ["2"]
              end
            end
          end
        end
      end
    end

  end
end

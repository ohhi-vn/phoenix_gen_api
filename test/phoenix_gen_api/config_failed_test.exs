defmodule PhoenixGenApi.ConfigFailedTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.ConfigFailed

  setup do
    ConfigFailed.clear()
    :ok
  end

  describe "record/4" do
    test "records a failed config with string reason" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "bad_action",
        service: "bad_service",
        nodes: :local,
        mfa: {BadMod, :bad_fn, []}
      }

      entry =
        ConfigFailed.record(config, "request_type must be a non-empty string", :pull, :node@host)

      assert entry.service == "bad_service"
      assert entry.request_type == "bad_action"
      assert entry.source == :pull
      assert entry.node == :node@host
      assert entry.reason == ["request_type must be a non-empty string"]
      assert is_map(entry.config)
      assert is_integer(entry.inserted_at_ms)
      assert is_integer(entry.expires_at_ms)
    end

    test "records a failed config with list of reasons" do
      config = %{
        request_type: "",
        service: nil,
        nodes: :local
      }

      reasons = ["service must not be nil", "request_type must be a non-empty string"]
      entry = ConfigFailed.record(config, reasons, :push, nil)

      assert entry.source == :push
      assert entry.node == nil
      assert entry.reason == reasons
    end

    test "records from push source" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "push_action",
        service: "push_service",
        nodes: :local,
        mfa: {BadMod, :bad_fn, []}
      }

      entry = ConfigFailed.record(config, "MFA not allowed", :push, :remote@host)
      assert entry.source == :push
      assert entry.node == :remote@host
    end
  end

  describe "list/1" do
    test "returns empty list when no entries" do
      assert ConfigFailed.list() == []
    end

    test "returns recorded entries" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config, "reason1", :pull, nil)
      ConfigFailed.record(config, "reason2", :push, nil)

      entries = ConfigFailed.list()
      assert length(entries) == 2
    end

    test "filters by source" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config, "reason1", :pull, nil)
      ConfigFailed.record(config, "reason2", :push, nil)

      pull_entries = ConfigFailed.list(source: :pull)
      assert length(pull_entries) == 1
      assert hd(pull_entries).source == :pull

      push_entries = ConfigFailed.list(source: :push)
      assert length(push_entries) == 1
      assert hd(push_entries).source == :push
    end

    test "filters by service" do
      config1 = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a1",
        service: "svc1",
        nodes: :local,
        mfa: {M, :f, []}
      }

      config2 = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a2",
        service: "svc2",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config1, "reason", :pull, nil)
      ConfigFailed.record(config2, "reason", :pull, nil)

      entries = ConfigFailed.list(service: "svc1")
      assert length(entries) == 1
      assert hd(entries).service == "svc1"
    end

    test "respects limit" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      for i <- 1..5, do: ConfigFailed.record(config, "reason#{i}", :pull, nil)

      assert length(ConfigFailed.list(limit: 3)) == 3
      assert length(ConfigFailed.list(limit: 10)) == 5
    end

    test "orders by newest first" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config, "oldest", :pull, nil)
      Process.sleep(10)
      ConfigFailed.record(config, "newest", :pull, nil)

      entries = ConfigFailed.list(order: :newest_first)
      assert hd(entries).reason == ["newest"]
    end
  end

  describe "count/0" do
    test "returns 0 when empty" do
      assert ConfigFailed.count() == 0
    end

    test "returns correct count" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      for i <- 1..3, do: ConfigFailed.record(config, "reason#{i}", :pull, nil)

      assert ConfigFailed.count() == 3
    end
  end

  describe "summary/0" do
    test "returns summary with counts" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config, "reason1", :pull, nil)
      ConfigFailed.record(config, "reason2", :push, nil)
      ConfigFailed.record(config, "reason3", :pull, nil)

      summary = ConfigFailed.summary()
      assert summary.total == 3
      assert summary.pull == 2
      assert summary.push == 1
      assert is_map(summary.by_service)
      assert summary.newest != nil
      assert summary.oldest != nil
    end
  end

  describe "cleanup/0" do
    test "removes expired entries" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      ConfigFailed.record(config, "reason", :pull, nil)
      assert ConfigFailed.count() == 1

      # Manually insert an expired entry
      :ets.insert(
        :phoenix_gen_api_config_failed,
        {999_999,
         %{
           id: 999_999,
           service: "expired_svc",
           request_type: "expired_action",
           version: nil,
           source: :pull,
           node: nil,
           reason: ["expired"],
           config: %{},
           inserted_at_ms: 0,
           expires_at_ms: 1
         }}
      )

      # Only the non-expired one should be counted
      assert ConfigFailed.count() == 1
      cleaned = ConfigFailed.cleanup()
      assert cleaned >= 1
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "a",
        service: "s",
        nodes: :local,
        mfa: {M, :f, []}
      }

      for i <- 1..5, do: ConfigFailed.record(config, "reason#{i}", :pull, nil)
      assert ConfigFailed.count() == 5

      ConfigFailed.clear()
      assert ConfigFailed.count() == 0
    end
  end
end

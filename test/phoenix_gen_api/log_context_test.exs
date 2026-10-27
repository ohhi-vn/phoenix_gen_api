defmodule PhoenixGenApi.LogContextTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.LogContext
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  describe "line/4 and event/3" do
    test "builds a documented event line with inline fields" do
      assert LogContext.line(
               "ConfigReceiver",
               :push_validation_failed,
               "PushConfig validation failed",
               service: "user_service",
               node: nil,
               request_type: "get_user"
             ) ==
               "[ConfigReceiver] event=push_validation_failed PushConfig validation failed " <>
                 "service=\"user_service\" node=unknown request_type=\"get_user\""
    end

    test "event/3 omits the message and keeps field order" do
      assert LogContext.event("Worker", :circuit_breaker_open, pool: :async_pool, node: :gw@host) ==
               "[Worker] event=circuit_breaker_open pool=:async_pool node=:gw@host"
    end

    test "nil message renders no double space" do
      assert LogContext.line("Executor", :test_event, nil, []) == "[Executor] event=test_event"
      assert LogContext.line("Executor", :test_event, "", []) == "[Executor] event=test_event"
    end

    test "nil values render as unknown when not normalized" do
      assert LogContext.line("Module", :event, "message", user_id: nil) ==
               "[Module] event=event message user_id=unknown"
    end
  end

  describe "request_context/2" do
    test "includes request identity, current node, and version" do
      request = %Request{
        request_id: "req_1",
        request_type: "get_user",
        service: "user_service",
        user_id: "user_1"
      }

      context = LogContext.request_context(request, %FunConfig{version: "1.2.3"})
      line = LogContext.line("Executor", :lookup, "message", context)

      assert line =~ "request_id=\"req_1\""
      assert line =~ "request_type=\"get_user\""
      assert line =~ "service=\"user_service\""
      assert line =~ "user_id=\"user_1\""
      assert line =~ "node=#{inspect(node())}"
      assert line =~ "version=\"1.2.3\""
    end

    test "marks missing request values as unknown" do
      line =
        LogContext.line(
          "Executor",
          :lookup,
          "message",
          LogContext.request_context(%Request{})
        )

      assert line =~ "request_id=unknown"
      assert line =~ "request_type=unknown"
      assert line =~ "service=unknown"
      assert line =~ "user_id=unknown"
      refute line =~ "version="
    end
  end

  describe "metadata installation" do
    setup do
      previous = Logger.metadata()
      on_exit(fn -> Logger.reset_metadata(previous) end)
      :ok
    end

    test "put/1 returns the previous metadata and installs new keys" do
      Logger.metadata(existing: :value)

      previous = LogContext.put(%{request_id: "req_1", service: "svc"})

      assert previous[:existing] == :value
      assert Logger.metadata()[:request_id] == "req_1"
      assert Logger.metadata()[:service] == "svc"

      Logger.reset_metadata(previous)
      assert Logger.metadata()[:request_id] == nil
      assert Logger.metadata()[:existing] == :value
    end

    test "with_context/2 restores metadata after normal return" do
      result =
        LogContext.with_context([request_id: "req_2"], fn -> Logger.metadata()[:request_id] end)

      assert result == "req_2"
      assert Logger.metadata()[:request_id] == nil
    end

    test "with_context/2 restores metadata after a raise" do
      assert_raise RuntimeError, fn ->
        LogContext.with_context([request_id: "req_3"], fn -> raise "boom" end)
      end

      assert Logger.metadata()[:request_id] == nil
    end

    test "nested contexts restore the outer context first" do
      LogContext.with_context([request_id: "outer"], fn ->
        assert Logger.metadata()[:request_id] == "outer"

        LogContext.with_context([request_id: "inner"], fn ->
          assert Logger.metadata()[:request_id] == "inner"
        end)

        assert Logger.metadata()[:request_id] == "outer"
      end)

      assert Logger.metadata()[:request_id] == nil
    end
  end

  describe "redaction and verbose payloads" do
    setup do
      previous = Application.get_env(:phoenix_gen_api, :log_verbose_payloads, false)

      on_exit(fn ->
        Application.put_env(:phoenix_gen_api, :log_verbose_payloads, previous)
      end)

      :ok
    end

    test "payload/1 is redacted by default" do
      Application.put_env(:phoenix_gen_api, :log_verbose_payloads, false)

      assert LogContext.payload(%{"secret" => "value"}) == :redacted
      refute LogContext.verbose_payloads?()
    end

    test "payload/1 returns the inspected payload when enabled" do
      Application.put_env(:phoenix_gen_api, :log_verbose_payloads, true)

      assert inspect(LogContext.payload(%{"token" => "abc"})) =~ "abc"
      assert LogContext.verbose_payloads?()
    end

    test "sensitive/1 always redacts" do
      assert LogContext.sensitive("secret") == "<redacted>"
    end

    test "payload_summary/1 never includes values" do
      summary = LogContext.payload_summary(%{"token" => "secret", "user" => "u1"})

      assert summary =~ "keys="
      refute summary =~ "secret"
    end

    test "payload_size/1 returns a non-negative integer" do
      assert LogContext.payload_size(%{a: 1}) > 0
      assert LogContext.payload_size(:atom) > 0
    end
  end
end

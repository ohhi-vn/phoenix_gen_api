defmodule PhoenixGenApi.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.Structs.Request

  setup do
    # RateLimiter is already started by the application supervisor.
    # Reset configuration and clear all rate limit data between tests.
    RateLimiter.update_config(%{global_limits: [], api_limits: []})
    RateLimiter.clear()
    :ok
  end

  describe "check_rate_limit/1 with global limits" do
    test "allows requests within limit" do
      # Configure a simple global limit
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 5, window_ms: 10_000}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_1",
        user_id: "user_123",
        service: "test_service",
        request_type: "test_api"
      }

      # Should allow 5 requests
      Enum.each(1..5, fn _ ->
        assert :ok == RateLimiter.check_rate_limit(request)
      end)

      # 6th request should be rate limited
      assert {:error, :rate_limited, details} = RateLimiter.check_rate_limit(request)
      assert details.max_requests == 5
      assert details.current_requests == 5
      assert details.retry_after_ms > 0
    end

    test "allows requests after window expires" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 2, window_ms: 100}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_2",
        user_id: "user_456",
        service: "test_service",
        request_type: "test_api"
      }

      assert :ok == RateLimiter.check_rate_limit(request)
      assert :ok == RateLimiter.check_rate_limit(request)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request)

      # Wait for window to expire
      Process.sleep(150)

      # Should be allowed again
      assert :ok == RateLimiter.check_rate_limit(request)
    end

    test "ignores requests with missing key values" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 1, window_ms: 10_000}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_3",
        user_id: nil,
        service: "test_service",
        request_type: "test_api"
      }

      # Should always allow since user_id is nil
      Enum.each(1..10, fn _ ->
        assert :ok == RateLimiter.check_rate_limit(request)
      end)
    end
  end

  describe "check_rate_limit/1 with API limits" do
    test "applies specific limits per API" do
      RateLimiter.update_config(%{
        global_limits: [],
        api_limits: [
          %{
            service: "expensive_service",
            request_type: "export",
            key: :user_id,
            max_requests: 2,
            window_ms: 10_000
          }
        ]
      })

      request = %Request{
        request_id: "req_4",
        user_id: "user_789",
        service: "expensive_service",
        request_type: "export"
      }

      assert :ok == RateLimiter.check_rate_limit(request)
      assert :ok == RateLimiter.check_rate_limit(request)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request)

      # Different API should not be affected
      other_request = %Request{
        request_id: "req_5",
        user_id: "user_789",
        service: "expensive_service",
        request_type: "import"
      }

      assert :ok == RateLimiter.check_rate_limit(other_request)
    end

    test "checks both global and API limits" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 10, window_ms: 10_000}
        ],
        api_limits: [
          %{
            service: "api_service",
            request_type: "fast_api",
            key: :user_id,
            max_requests: 3,
            window_ms: 10_000
          }
        ]
      })

      request = %Request{
        request_id: "req_6",
        user_id: "user_limit",
        service: "api_service",
        request_type: "fast_api"
      }

      # API limit should hit first
      Enum.each(1..3, fn _ -> assert :ok == RateLimiter.check_rate_limit(request) end)
      assert {:error, :rate_limited, details} = RateLimiter.check_rate_limit(request)
      assert details.scope == {"api_service", "fast_api"}
    end
  end

  describe "check_rate_limit/3 direct check" do
    test "checks global limit directly" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 2, window_ms: 10_000}
        ],
        api_limits: []
      })

      assert :ok == RateLimiter.check_rate_limit("user_direct_1", :global, :user_id)
      assert :ok == RateLimiter.check_rate_limit("user_direct_1", :global, :user_id)
      assert {:error, :rate_limited, details} = RateLimiter.check_rate_limit("user_direct_1", :global, :user_id)
      assert details.scope == :global
    end

    test "checks API limit directly" do
      RateLimiter.update_config(%{
        global_limits: [],
        api_limits: [
          %{
            service: "direct_service",
            request_type: "direct_api",
            key: :user_id,
            max_requests: 1,
            window_ms: 10_000
          }
        ]
      })

      scope = {"direct_service", "direct_api"}
      assert :ok == RateLimiter.check_rate_limit("user_direct_api_2", scope, :user_id)
      assert {:error, :rate_limited, details} = RateLimiter.check_rate_limit("user_direct_api_2", scope, :user_id)
      assert details.scope == scope
    end
  end

  describe "reset_rate_limit/3" do
    test "resets counters for a specific key" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 2, window_ms: 10_000}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_reset",
        user_id: "user_reset",
        service: "test",
        request_type: "test"
      }

      assert :ok == RateLimiter.check_rate_limit(request)
      assert :ok == RateLimiter.check_rate_limit(request)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request)

      # Reset the limit
      assert :ok == RateLimiter.reset_rate_limit("user_reset", :global, :user_id)

      # Should be allowed again
      assert :ok == RateLimiter.check_rate_limit(request)
    end
  end

  describe "get_rate_limit_status/3" do
    test "returns current usage information" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 10, window_ms: 60_000}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_status",
        user_id: "user_status",
        service: "test",
        request_type: "test"
      }

      # Make 3 requests
      Enum.each(1..3, fn _ -> RateLimiter.check_rate_limit(request) end)

      status = RateLimiter.get_rate_limit_status("user_status", :global, :user_id)
      assert is_list(status)
      assert length(status) == 1

      limit_info = hd(status)
      assert limit_info.max_requests == 10
      assert limit_info.current_requests == 3
      assert limit_info.remaining == 7
      assert limit_info.scope == :global
    end
  end

  describe "update_config/1" do
    test "updates global limits at runtime" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 5, window_ms: 10_000}
        ],
        api_limits: []
      })

      config = RateLimiter.get_configured_limits()
      assert length(config.global) == 1
      assert hd(config.global).max_requests == 5

      # Update to new limit
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 20, window_ms: 30_000}
        ]
      })

      config = RateLimiter.get_configured_limits()
      assert hd(config.global).max_requests == 20
      assert hd(config.global).window_ms == 30_000
    end

    test "updates API limits at runtime" do
      RateLimiter.update_config(%{
        global_limits: [],
        api_limits: [
          %{
            service: "svc",
            request_type: "api",
            key: :user_id,
            max_requests: 5,
            window_ms: 10_000
          }
        ]
      })

      config = RateLimiter.get_configured_limits()
      assert length(config.api) == 1
      assert hd(config.api).max_requests == 5
    end
  end

  describe "fail-open behavior" do
    test "allows requests when rate limiter is disabled" do
      # Note: In test environment, we can't easily disable the limiter
      # without restarting the process, but we can test the enabled?() logic
      # by checking that it respects configuration.
      # For now, we verify that normal operation works.
      RateLimiter.update_config(%{global_limits: [], api_limits: []})

      request = %Request{
        request_id: "req_disabled",
        user_id: "user_disabled",
        service: "test",
        request_type: "test"
      }

      # With no limits configured, should always pass
      Enum.each(1..100, fn _ ->
        assert :ok == RateLimiter.check_rate_limit(request)
      end)
    end
  end

  describe "concurrent access" do
    test "handles concurrent requests correctly" do
      RateLimiter.update_config(%{
        global_limits: [
          %{key: :user_id, max_requests: 50, window_ms: 10_000}
        ],
        api_limits: []
      })

      request = %Request{
        request_id: "req_concurrent",
        user_id: "user_concurrent",
        service: "test",
        request_type: "test"
      }

      # Spawn multiple processes to make requests concurrently
      parent = self()

      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            result = RateLimiter.check_rate_limit(%{request | request_id: "req_#{i}"})
            send(parent, {:result, result})
          end)
        end)

      # Collect results
      results =
        Enum.map(1..100, fn _ ->
          receive do
            {:result, result} -> result
          after
            5000 -> :timeout
          end
        end)

      # Wait for tasks to finish
      Enum.each(tasks, &Task.await(&1, 5000))

      # Count successes and failures
      successes = Enum.count(results, &(&1 == :ok))
      failures = Enum.count(results, fn
        {:error, :rate_limited, _} -> true
        _ -> false
      end)

      # Should have exactly 50 successes and 50 failures
      assert successes == 50
      assert failures == 50
    end
  end
end

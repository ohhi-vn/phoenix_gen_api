defmodule PhoenixGenApi.Errors.ClassifyTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Errors.Classify
  alias PhoenixGenApi.Errors.DecodeError
  alias PhoenixGenApi.Errors.InvalidType
  alias PhoenixGenApi.Permission.PermissionDenied

  describe "failure_classes/0" do
    test "lists every documented class" do
      assert Classify.failure_classes() == [
               :invalid_request,
               :permission_denied,
               :rate_limited,
               :unavailable,
               :timeout,
               :internal
             ]
    end
  end

  describe "classify/1" do
    test "successful results are not failures" do
      assert Classify.classify(:ok) == nil
      assert Classify.classify({:ok, :whatever}) == nil
      assert Classify.classify(nil) == nil
    end

    test "maps error tuples" do
      assert Classify.classify({:error, :rate_limited}) == :rate_limited
      assert Classify.classify({:error, :not_found}) == :invalid_request
      assert Classify.classify({:error, :timeout}) == :timeout
      assert Classify.classify({:error, :circuit_open}) == :unavailable
    end

    test "maps exit tuples" do
      assert Classify.classify({:exit, :timeout}) == :timeout
      assert Classify.classify({:exit, :noproc}) == :unavailable
    end

    test "maps exceptions" do
      assert Classify.classify(DecodeError.exception(:invalid_payload, "bad")) ==
               :invalid_request

      assert Classify.classify(InvalidType.exception("field")) == :invalid_request
      assert Classify.classify(%PermissionDenied{}) == :permission_denied
      assert Classify.classify(%ArgumentError{}) == :internal
    end

    test "unknown terms are internal" do
      assert Classify.classify(:something_else) == :internal
      assert Classify.classify("boom") == :internal
    end
  end

  describe "classify/2 with :error" do
    test "invalid requests" do
      assert Classify.classify(:error, :invalid_payload) == :invalid_request
      assert Classify.classify(:error, :missing_field) == :invalid_request
      assert Classify.classify(:error, :invalid_config) == :invalid_request
      assert Classify.classify(:error, :not_found) == :invalid_request
      assert Classify.classify(:error, {:mfa_not_allowed, {:os, :cmd, []}}) == :invalid_request
    end

    test "permission denied" do
      assert Classify.classify(:error, :permission_denied) == :permission_denied
      assert Classify.classify(:error, %PermissionDenied{}) == :permission_denied
    end

    test "rate limited" do
      assert Classify.classify(:error, :rate_limited) == :rate_limited
      assert Classify.classify(:error, {:rate_limited, %{retry_after_ms: 10}}) == :rate_limited
      assert Classify.classify(:error, :rate_limiter_error) == :rate_limited
    end

    test "timeouts" do
      assert Classify.classify(:error, :timeout) == :timeout
      assert Classify.classify(:error, {:timeout, 5_000}) == :timeout
    end

    test "unavailable" do
      for reason <- [
            :unavailable,
            :noproc,
            :circuit_open,
            :queue_full,
            :retry_exhausted,
            :rpc_exit,
            {:badrpc, :timeout},
            :shutdown,
            {:shutdown, :restart},
            :econnrefused,
            :closed
          ] do
        assert Classify.classify(:error, reason) == :unavailable,
               "expected #{inspect(reason)} to classify as :unavailable"
      end
    end

    test "everything else is internal" do
      assert Classify.classify(:error, :boom) == :internal
      assert Classify.classify(:error, {:unexpected, 1}) == :internal
    end
  end

  describe "classify/2 with :exit" do
    test "timeout exits" do
      assert Classify.classify(:exit, :timeout) == :timeout
      assert Classify.classify(:exit, {:timeout, {GenServer, :call, []}}) == :timeout
    end

    test "unavailable exits" do
      assert Classify.classify(:exit, :noproc) == :unavailable
      assert Classify.classify(:exit, :normal) == :unavailable
      assert Classify.classify(:exit, :shutdown) == :unavailable
      assert Classify.classify(:exit, {:shutdown, :tcp_closed}) == :unavailable
    end

    test "other exits are internal" do
      assert Classify.classify(:exit, :killed) == :internal
      assert Classify.classify(:exit, {:badmatch, 1}) == :internal
    end
  end

  describe "classify/2 with :throw" do
    test "throws are internal" do
      assert Classify.classify(:throw, :oops) == :internal
      assert Classify.classify(:throw, {:invalid, 1}) == :internal
    end
  end
end

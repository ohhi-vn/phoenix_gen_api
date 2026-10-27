defmodule PhoenixGenApi.Errors.Classify do
  @moduledoc """
  Maps an execution outcome to a stable failure class.

  The failure class is internal metadata used for telemetry and log-level
  selection. It is deliberately **not** part of `PhoenixGenApi.Structs.Response`:
  the public response shape is unchanged by classification.

  Classes:

    * `:invalid_request` — the caller sent something the library refuses
      (malformed payload, unsupported function, disallowed MFA, bad argument type)
    * `:permission_denied` — an authorization check failed
    * `:rate_limited` — a configured rate limit was exceeded
    * `:unavailable` — a dependency, node, pool, or store is not available
    * `:timeout` — an operation exceeded its deadline
    * `:internal` — anything else, including unexpected crashes

  ## Usage

      iex> PhoenixGenApi.Errors.Classify.classify({:error, :rate_limited})
      :rate_limited

      iex> PhoenixGenApi.Errors.Classify.classify(:exit, :timeout)
      :timeout

      iex> PhoenixGenApi.Errors.Classify.classify({:ok, :done})
      nil
  """

  alias PhoenixGenApi.Errors.DecodeError
  alias PhoenixGenApi.Errors.InvalidType
  alias PhoenixGenApi.Permission.PermissionDenied

  @type failure_class ::
          :invalid_request
          | :permission_denied
          | :rate_limited
          | :unavailable
          | :timeout
          | :internal

  @type outcome :: :error | :exit | :throw

  @doc """
  Returns the list of failure classes.
  """
  @spec failure_classes() :: [failure_class()]
  def failure_classes,
    do: [
      :invalid_request,
      :permission_denied,
      :rate_limited,
      :unavailable,
      :timeout,
      :internal
    ]

  @doc """
  Classifies a result term.

  Successful results (`:ok`, `{:ok, _}`) return `nil`.
  """
  @spec classify(term()) :: failure_class() | nil
  def classify(:ok), do: nil
  def classify({:ok, _}), do: nil
  def classify(nil), do: nil
  def classify({:error, reason}), do: classify(:error, reason)
  def classify({:exit, reason}), do: classify(:exit, reason)
  def classify({:throw, reason}), do: classify(:throw, reason)
  def classify(%{__struct__: _} = exception), do: classify(:error, exception)
  def classify(_other), do: :internal

  @doc """
  Classifies an outcome kind and reason.
  """
  @spec classify(outcome(), term()) :: failure_class()
  def classify(:exit, :timeout), do: :timeout
  def classify(:exit, {:timeout, _}), do: :timeout
  def classify(:exit, :noproc), do: :unavailable
  def classify(:exit, :normal), do: :unavailable
  def classify(:exit, :shutdown), do: :unavailable
  def classify(:exit, {:shutdown, _}), do: :unavailable
  def classify(:exit, _reason), do: :internal

  def classify(:throw, _reason), do: :internal

  def classify(:error, %DecodeError{}), do: :invalid_request
  def classify(:error, %InvalidType{}), do: :invalid_request
  def classify(:error, %PermissionDenied{}), do: :permission_denied
  def classify(:error, %ArgumentError{}), do: :internal

  def classify(:error, :invalid_payload), do: :invalid_request
  def classify(:error, :missing_field), do: :invalid_request
  def classify(:error, :invalid_config), do: :invalid_request
  def classify(:error, :not_found), do: :invalid_request
  def classify(:error, {:mfa_not_allowed, _}), do: :invalid_request
  def classify(:error, :mfa_not_allowed), do: :invalid_request

  def classify(:error, :permission_denied), do: :permission_denied

  def classify(:error, :rate_limited), do: :rate_limited
  def classify(:error, {:rate_limited, _}), do: :rate_limited
  def classify(:error, :rate_limiter_error), do: :rate_limited

  def classify(:error, :timeout), do: :timeout
  def classify(:error, {:timeout, _}), do: :timeout

  def classify(:error, :unavailable), do: :unavailable
  def classify(:error, :noproc), do: :unavailable
  def classify(:error, :circuit_open), do: :unavailable
  def classify(:error, :queue_full), do: :unavailable
  def classify(:error, :retry_exhausted), do: :unavailable
  def classify(:error, :rpc_exit), do: :unavailable
  def classify(:error, {:badrpc, _}), do: :unavailable
  def classify(:error, :shutdown), do: :unavailable
  def classify(:error, {:shutdown, _}), do: :unavailable
  def classify(:error, :econnrefused), do: :unavailable
  def classify(:error, :closed), do: :unavailable

  def classify(:error, _reason), do: :internal
end

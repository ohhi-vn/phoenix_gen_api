defmodule PhoenixGenApi.Security do
  @moduledoc """
  Provides security utilities for PhoenixGenApi.

  ## Features

  1. **Admin gate** — fail-closed authorization for dangerous runtime operations
     (toggling `detail_error`, updating rate limit config, pushing configs).

  2. **Push token validation** — constant-time comparison to authenticate
     push requests from remote nodes.

  3. **MFA allowlist validation** — restricts which `{module, function, args}`
     tuples can be registered as function configurations, preventing a
     compromised node from registering dangerous MFAs (e.g. `:os.cmd`).

  ## Configuration

  All checks are **opt-in and backward compatible**. If the relevant application
  environment variables are not set, the checks are skipped:

      config :phoenix_gen_api,
        # Admin actions allowlist (fail-closed: default denies everything)
        admin_actions: [:push_config],

        # Push token — when set, push requests must include a matching token
        push_token: "my-secret-token",

        # MFA allowlist — when set, only listed {module, function} pairs are allowed.
        # Module-level entries (just an atom) allow all functions in that module.
        mfa_allowlist: [
          MyApp.UserService,
          {MyApp.OrderService, :create_order}
        ]

  ## Hardcoded Denylist

  The following modules are **always blocked** unless explicitly allowed:
  `:os`, `:file`, `:code`, `:erlang`, `:net`, `:rpc`, `:global`, `:inet`.

  ## Environment Recommendations

  - **Development**: You may enable all admin actions for convenience.
  - **Production**: Enable only what's needed. Configure `push_token` and
    `mfa_allowlist` to restrict push sources and allowed function targets.
  """

  import Bitwise
  require Logger

  @type admin_action ::
          :change_detail_error
          | :update_rate_limit_config
          | :push_config
          | :enable_tracing
          | :disable_tracing

  # ---------------------------------------------------------------------------
  # Admin Gate
  # ---------------------------------------------------------------------------

  @doc """
  Checks whether a given admin action is currently permitted.

  Returns `true` if the action is in the configured allowlist, `false` otherwise.
  When denied, a warning is logged.

  ## Examples

      iex> PhoenixGenApi.Security.admin_action_allowed?(:update_rate_limit_config)
      false

      iex> PhoenixGenApi.Security.admin_action_allowed?(:change_detail_error)
      false
  """
  @spec admin_action_allowed?(admin_action()) :: boolean()
  def admin_action_allowed?(action)
      when action in [
             :change_detail_error,
             :update_rate_limit_config,
             :push_config,
             :enable_tracing,
             :disable_tracing
           ] do
    allowed = Application.get_env(:phoenix_gen_api, :admin_actions, [])

    if action in allowed do
      Logger.info("[Security] admin action allowed: #{action}")
      true
    else
      Logger.warning("[Security] admin action denied: #{action}, not in allowlist")
      false
    end
  end

  # ---------------------------------------------------------------------------
  # Push Token Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validates a push token using constant-time comparison.

  Returns `true` if:
    - No `:push_token` is configured (backward compatible — push allowed without token)
    - The provided token matches the configured token

  Returns `false` if a token is configured but the provided token doesn't match
  or is missing.

  Uses constant-time comparison to prevent timing attacks.
  """
  @spec valid_push_token?(nil | String.t() | binary()) :: boolean()
  def valid_push_token?(nil) do
    case Application.get_env(:phoenix_gen_api, :push_token) do
      nil -> true
      _configured -> false
    end
  end

  def valid_push_token?(token) when is_binary(token) do
    case Application.get_env(:phoenix_gen_api, :push_token) do
      nil ->
        true

      configured when is_binary(configured) ->
        constant_time_compare(token, configured)

      _ ->
        false
    end
  end

  def valid_push_token?(_), do: false

  # Constant-time binary comparison to prevent timing attacks.
  # Always does the full comparison regardless of length to avoid leaking
  # length info via timing.
  defp constant_time_compare(a, b) when is_binary(a) and is_binary(b) do
    size_eq = byte_size(a) == byte_size(b)
    result = constant_time_compare_bin(a, b, 0)
    size_eq and result == 0
  end

  defp constant_time_compare_bin(<<>>, <<>>, acc), do: acc

  defp constant_time_compare_bin(<<>>, _, acc) when acc != 0, do: acc
  defp constant_time_compare_bin(_, <<>>, acc) when acc != 0, do: acc
  defp constant_time_compare_bin(<<>>, _, _acc), do: 1
  defp constant_time_compare_bin(_, <<>>, _acc), do: 1

  defp constant_time_compare_bin(<<x, rest_a::binary>>, <<y, rest_b::binary>>, acc) do
    constant_time_compare_bin(rest_a, rest_b, acc ||| Bitwise.bxor(x, y))
  end

  # ---------------------------------------------------------------------------
  # MFA Allowlist Validation
  # ---------------------------------------------------------------------------

  @hardcoded_denylist [
    :os,
    :file,
    :code,
    :erlang,
    :net,
    :rpc,
    :global,
    :inet
  ]

  @doc """
  Validates that an MFA tuple is allowed by the configured allowlist and not
  in the hardcoded denylist.

  ## Parameters

    - `mfa` - A `{module, function, args}` tuple

  ## Returns

    - `:ok` if the MFA is allowed
    - `{:error, {:mfa_not_allowed, mfa}}` if the MFA is not allowed

  ## Behavior

    - If no `:mfa_allowlist` is configured, all MFAs pass the allowlist check
      (backward compatible) — but the hardcoded denylist is still enforced.
    - If `:mfa_allowlist` IS configured, the `{module, function}` pair must match
      an entry. Entries can be:
      - A module atom (e.g. `MyApp.UserService`) — allows all functions in that module
      - A `{module, function}` tuple (e.g. `{MyApp.OrderService, :create_order}`)
    - Modules in the hardcoded denylist (`:os`, `:file`, `:code`, `:erlang`,
      `:net`, `:rpc`, `:global`, `:inet`) are ALWAYS blocked unless the
      allowlist explicitly includes them.
  """
  @spec validate_mfa({module(), atom(), list()}) :: :ok | {:error, {:mfa_not_allowed, term()}}
  def validate_mfa({module, function, _args} = mfa) do
    # Check hardcoded denylist first — always enforced
    if module in @hardcoded_denylist do
      Logger.warning(
        "[Security] MFA denied by hardcoded denylist: module=#{inspect(module)}, function=#{inspect(function)}"
      )

      {:error, {:mfa_not_allowed, mfa}}
    else
      check_mfa_allowlist(mfa)
    end
  end

  def validate_mfa(invalid) do
    {:error, {:mfa_not_allowed, invalid}}
  end

  # MFA allowlist check
  defp check_mfa_allowlist(mfa = {module, function, _args}) do
    allowlist = Application.get_env(:phoenix_gen_api, :mfa_allowlist)

    if is_nil(allowlist) do
      # No allowlist configured — allow everything (backward compatible)
      :ok
    else
      if mfa_in_allowlist?({module, function}, allowlist) do
        :ok
      else
        Logger.warning(
          "[Security] MFA not in allowlist: module=#{inspect(module)}, function=#{inspect(function)}"
        )

        {:error, {:mfa_not_allowed, mfa}}
      end
    end
  end

  # Check if {module, function} matches an allowlist entry
  defp mfa_in_allowlist?({mod, fun}, allowlist) when is_list(allowlist) do
    Enum.any?(allowlist, fn
      # Module-level entry — allows all functions in that module
      ^mod -> true
      # Specific {module, function} entry
      {^mod, ^fun} -> true
      # No match
      _ -> false
    end)
  end

  defp mfa_in_allowlist?(_, _), do: false
end

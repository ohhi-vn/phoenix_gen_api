defmodule PhoenixGenApi.Permission do
  @moduledoc """
  Provides permission checking functionality for API requests.

  This module implements a flexible permission system that can verify whether a user
  has the right to execute a specific request. Permissions can be disabled, or configured
  to check that certain request arguments match the requesting user's identity.

  ## Permission Modes

  ### Disabled Permissions (`false`)
  When `check_permission: false` is set in the FunConfig, all permission checks pass.
  This is useful for public endpoints that don't require authentication or authorization.

  ### Any Authenticated (`:any_authenticated`)
  When `check_permission: :any_authenticated` is configured, the system verifies that
  the request has a valid `user_id`. Any authenticated user is allowed access.

  ### Argument-Based Permissions (`{:arg, arg_name}`)
  When `check_permission: {:arg, arg_name}` is configured, the system verifies that
  the value of the specified argument matches the request's `user_id`. This ensures
  users can only access their own data.

  For example, with `{:arg, "user_id"}`, a request from user "123" will only be
  allowed if `request.args["user_id"] == "123"`.

  When `arg_orders: :map`, the argument is first looked up at the top level of
  `request.args`, then searched one level deep inside map values.

  ### Role-Based Permissions (`{:role, allowed_roles}`)
  When `check_permission: {:role, allowed_roles}` is configured, the system verifies
  that the user has one of the allowed roles. Roles are checked against the
  `request.user_roles` field (must be a list of strings or atoms).

  For example, with `{:role, ["admin", "moderator"]}`, only users with those roles
  are allowed access.

  ### Custom Callback (`permission_callback`)
  When `permission_callback: {module, function, args}` is set,
  the callback takes precedence over `check_permission`. Called as
  `apply(module, function, [request | args])`. Must return `true` or `false`.
  Any other return value is treated as `false`. Exceptions are caught and treated
  as `false` for safety.

  ## Examples

      # Public endpoint - no permission check
      config = %FunConfig{
        request_type: "get_public_data",
        check_permission: false
      }

      request = %Request{user_id: "any_user"}
      Permission.check_permission(request, config)
      # => true

      # Any authenticated user
      config = %FunConfig{
        request_type: "get_profile",
        check_permission: :any_authenticated
      }

      request = %Request{user_id: "user_123"}
      Permission.check_permission(request, config)
      # => true

      request = %Request{user_id: nil}
      Permission.check_permission(request, config)
      # => false

      # User-specific endpoint - must match user_id
      config = %FunConfig{
        request_type: "get_user_profile",
        check_permission: {:arg, "user_id"}
      }

      # This passes - user accessing their own data
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_123"}
      }
      Permission.check_permission(request, config)
      # => true

      # This fails - user trying to access another user's data
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }
      Permission.check_permission(request, config)
      # => false

      # Role-based access
      config = %FunConfig{
        request_type: "delete_user",
        check_permission: {:role, ["admin"]}
      }

      request = %Request{
        user_id: "user_123",
        user_roles: ["admin"]
      }
      Permission.check_permission(request, config)
      # => true

  ## Security Considerations

  - Always use `check_permission!/2` in the execution path to raise on failures
  - The `check_permission/2` function is non-raising and returns a boolean
  - Missing arguments result in permission denial (returns `false`)
  - Permission checks happen before argument validation and function execution
  - All permission failures are logged for audit purposes
  - Use specific permission modes rather than `false` when possible

  ### Securing `{:arg, arg_name}` Against user_id Override

  When using `{:arg, arg_name}`, the `user_id` in `socket.assigns` **must** be set
  by a verified authentication step in `Phoenix.Socket.connect/3` — never from
  client payload. The `override_user_id` channel option (default `true`) only
  applies when `socket.assigns.user_id` is a verified non-empty string; it will
  **NOT** override with a client-supplied `user_id`.

  Use `require_verified_user_id: true` (the default) in your channel to reject
  unauthenticated requests **before** they reach permission checks. This prevents
  requests with no verified `user_id` from ever entering the execution pipeline.
  Set `require_verified_user_id: false` only for public endpoints that use
  `check_permission: false`.
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  require Logger

  @doc """
  Exception raised when a permission check fails.

  Contains details about the request and the permission mode that was denied.
  """
  defmodule PermissionDenied do
    @moduledoc false

    defexception [:message, :user_id, :request_id, :request_type, :permission_mode]

    @impl true
    def exception(opts) do
      user_id = Keyword.get(opts, :user_id)
      request_id = Keyword.get(opts, :request_id)
      request_type = Keyword.get(opts, :request_type)
      permission_mode = Keyword.get(opts, :permission_mode)

      message =
        "Permission denied for user: #{inspect(user_id)}, " <>
          "request: #{inspect(request_id)}, " <>
          "type: #{inspect(request_type)}, " <>
          "mode: #{inspect(permission_mode)}"

      %__MODULE__{
        message: message,
        user_id: user_id,
        request_id: request_id,
        request_type: request_type,
        permission_mode: permission_mode
      }
    end
  end

  # ──────────────────────────────────────────────
  # Custom permission callback (highest precedence)
  # ──────────────────────────────────────────────

  def check_permission(request, %FunConfig{permission_callback: {mod, fun, args}})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    execute_permission_callback(mod, fun, [request | args])
  end

  # ──────────────────────────────────────────────
  # Disabled — public endpoint
  # ──────────────────────────────────────────────

  def check_permission(%Request{}, %FunConfig{permission_callback: nil, check_permission: false}) do
    true
  end

  # ──────────────────────────────────────────────
  # :any_authenticated
  # ──────────────────────────────────────────────

  def check_permission(%Request{user_id: user_id}, %FunConfig{
        permission_callback: nil,
        check_permission: :any_authenticated
      })
      when is_binary(user_id) and byte_size(user_id) > 0 do
    true
  end

  def check_permission(%Request{user_id: user_id} = request, %FunConfig{
        permission_callback: nil,
        check_permission: :any_authenticated
      }) do
    log_permission_denied(request, ":any_authenticated", "user_id is #{inspect(user_id)}")
    false
  end

  # ──────────────────────────────────────────────
  # {:arg, arg_name} with arg_orders: :map
  # ──────────────────────────────────────────────

  def check_permission(
        request = %Request{user_id: user_id},
        %FunConfig{
          permission_callback: nil,
          check_permission: {:arg, arg_name},
          arg_orders: :map
        }
      )
      when is_binary(user_id) and byte_size(user_id) > 0 do
    arg_value = Map.get(request.args, arg_name) || find_in_map_args(request.args, arg_name)
    do_check_arg(request, arg_name, arg_value, user_id)
  end

  # ──────────────────────────────────────────────
  # {:arg, arg_name} standard (non-map)
  # ──────────────────────────────────────────────

  def check_permission(
        request = %Request{user_id: user_id},
        %FunConfig{permission_callback: nil, check_permission: {:arg, arg_name}}
      )
      when is_binary(user_id) and byte_size(user_id) > 0 do
    arg_value = Map.get(request.args, arg_name)
    do_check_arg(request, arg_name, arg_value, user_id)
  end

  # Fallback for {:arg, ...} when user_id is nil or empty
  def check_permission(%Request{user_id: user_id} = request, %FunConfig{
        permission_callback: nil,
        check_permission: {:arg, arg_name}
      }) do
    Logger.warning(
      "[Permission] {:arg, #{inspect(arg_name)}} check with nil/empty user_id - " <>
        "this usually means the socket was not authenticated. " <>
        "Consider using require_verified_user_id: true in your channel. " <>
        "user_id: #{inspect(user_id)}, request_id: #{inspect(request.request_id)}"
    )

    false
  end

  # ──────────────────────────────────────────────
  # {:role, allowed_roles}
  # ──────────────────────────────────────────────

  def check_permission(
        %Request{user_roles: user_roles} = request,
        %FunConfig{permission_callback: nil, check_permission: {:role, allowed_roles}}
      )
      when is_list(user_roles) and is_list(allowed_roles) do
    allowed_roles_set = MapSet.new(allowed_roles)
    user_roles_set = MapSet.new(user_roles)

    case MapSet.intersection(user_roles_set, allowed_roles_set) |> MapSet.size() do
      0 ->
        log_permission_denied(
          request,
          "role check",
          "user lacks required roles (required: #{inspect(allowed_roles)}, has: #{inspect(user_roles)})"
        )

        false

      _ ->
        true
    end
  end

  # Fallback for {:role, ...} when user_roles is not a list
  def check_permission(
        %Request{},
        %FunConfig{
          permission_callback: nil,
          check_permission: {:role, _allowed_roles}
        }
      ) do
    false
  end

  # ──────────────────────────────────────────────
  # Invalid check_permission mode (catch-all)
  # NOTE: This clause must remain BELOW the invalid permission_callback catch-all
  # so that invalid callbacks are handled first (they fall back to this via recursion).
  # ──────────────────────────────────────────────

  def check_permission(%Request{}, fun_config = %FunConfig{permission_callback: nil}) do
    Logger.error(
      "[Permission] invalid check_permission mode: #{inspect(fun_config.check_permission)}, request_type: #{inspect(fun_config.request_type)}"
    )

    false
  end

  # ──────────────────────────────────────────────
  # Invalid permission_callback format (catch-all)
  # Falls back to check_permission mode after logging the invalid callback.
  # ──────────────────────────────────────────────

  def check_permission(request = %Request{}, fun_config = %FunConfig{permission_callback: other}) do
    Logger.error(
      "[Permission] invalid permission_callback: #{inspect(other)}, falling back to check_permission: #{inspect(fun_config.check_permission)}"
    )

    check_permission(request, %FunConfig{fun_config | permission_callback: nil})
  end

  # ──────────────────────────────────────────────
  # Shared arg-checking logic (eliminates duplication between :map and standard)
  # ──────────────────────────────────────────────

  @doc false
  @spec do_check_arg(Request.t(), String.t(), any(), String.t()) :: boolean()
  defp do_check_arg(request, arg_name, arg_value, user_id) do
    case arg_value do
      nil ->
        log_permission_denied(
          request,
          "arg check",
          "missing argument #{inspect(arg_name)}"
        )

        false

      ^user_id ->
        true

      _other ->
        log_permission_denied(
          request,
          "arg check",
          "mismatch for #{inspect(arg_name)} (expected: #{inspect(user_id)}, got: #{inspect(arg_value)})"
        )

        false
    end
  end

  # ──────────────────────────────────────────────
  # find_in_map_args — searches one level deep in map values
  # ──────────────────────────────────────────────

  @doc false
  @spec find_in_map_args(map() | nil, String.t()) :: any()
  defp find_in_map_args(nil, _arg_name), do: nil

  defp find_in_map_args(args, arg_name) when is_map(args) do
    args
    |> Map.values()
    |> Enum.find_value(fn
      value when is_map(value) -> Map.get(value, arg_name)
      _ -> nil
    end)
  end

  # ──────────────────────────────────────────────
  # execute_permission_callback — runs the MFA callback with error handling
  # ──────────────────────────────────────────────

  @spec execute_permission_callback(module(), atom(), list()) :: boolean()
  defp execute_permission_callback(mod, fun, args) do
    try do
      case apply(mod, fun, args) do
        true ->
          true

        false ->
          Logger.warning(
            "[Permission] permission_callback {#{inspect(mod)}, #{inspect(fun)}} returned false"
          )

          false

        other ->
          Logger.warning(
            "[Permission] permission_callback {#{inspect(mod)}, #{inspect(fun)}} returned unexpected value: #{inspect(other)}"
          )

          false
      end
    rescue
      e ->
        Logger.error(
          "[Permission] permission_callback {#{inspect(mod)}, #{inspect(fun)}} raised: #{Exception.message(e)}"
        )

        false
    catch
      kind, reason ->
        Logger.error(
          "[Permission] permission_callback {#{inspect(mod)}, #{inspect(fun)}} caught #{inspect(kind)}: #{inspect(reason)}"
        )

        false
    end
  end

  # ──────────────────────────────────────────────
  # check_permission! — raising version
  # ──────────────────────────────────────────────

  @doc """
  Checks permission and raises an exception if the check fails.

  This is the raising version of `check_permission/2`. It should be used in the
  request execution pipeline where permission failures should halt processing.

  ## Parameters

    - `request` - The `Request` struct containing user information and arguments
    - `fun_config` - The `FunConfig` struct with permission settings

  ## Returns

    - `nil` - Permission check passed (function returns nothing on success)

  ## Raises

    - `PermissionDenied` - If the permission check fails

  ## Examples

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{check_permission: {:arg, "user_id"}}

      # This will raise because user_ids don't match
      Permission.check_permission!(request, config)
      # ** (PhoenixGenApi.Permission.PermissionDenied) Permission denied...

  ## Notes

  - Logs a warning with request details when permission is denied
  - Always called before request execution in the Executor module
  - Returns nothing on success (only side effect is potential exception)
  """
  def check_permission!(request = %Request{}, fun_config = %FunConfig{}) do
    if not check_permission(request, fun_config) do
      permission_mode = determine_permission_mode(fun_config)

      Logger.warning(
        "[Permission] denied: user_id: #{inspect(request.user_id)}, request_id: #{inspect(request.request_id)}, request_type: #{inspect(request.request_type)}, mode: #{inspect(permission_mode)}"
      )

      raise PermissionDenied,
        user_id: request.user_id,
        request_id: request.request_id,
        request_type: request.request_type,
        permission_mode: permission_mode
    end

    nil
  end

  # ──────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────

  defp determine_permission_mode(%FunConfig{permission_callback: {mod, fun, args}})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    {:callback, {mod, fun, args}}
  end

  defp determine_permission_mode(%FunConfig{check_permission: mode}), do: mode

  defp log_permission_denied(request, check_type, reason) do
    Logger.warning(
      "[Permission] #{check_type} denied: #{reason}, user_id: #{inspect(request.user_id)}, request_id: #{inspect(request.request_id)}"
    )
  end
end

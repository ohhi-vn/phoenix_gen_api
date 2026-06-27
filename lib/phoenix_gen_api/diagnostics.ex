defmodule PhoenixGenApi.Diagnostics do
  @moduledoc """
  Runtime diagnostics, monitoring, and debugging utilities for PhoenixGenApi.

  These helpers are intended for sysadmins and developers who need a safe
  runtime snapshot from IEx, remote shells, or custom admin tooling. They return
  structured maps rather than printing directly, so callers can expose them in
  dashboards or logs.

  ## Health checks

      PhoenixGenApi.Diagnostics.health_check()
      #=> %{status: :ok | :degraded | :error, checks: %{...}}

  ## Statistics

      PhoenixGenApi.Diagnostics.statistics()
      #=> %{vm: %{...}, phoenix_gen_api: %{...}}

  ## Debug reports

      PhoenixGenApi.Diagnostics.debug_report(process_limit: 10)

  ## Call flow inspection

  Trace how a request flows from the gateway to target nodes:

      PhoenixGenApi.Diagnostics.call_flow("user_service", "get_user")
      #=> %{config: %FunConfig{}, local?: true, nodes: [...], steps: [...]}

  View the full cluster topology as seen by this node:

      PhoenixGenApi.Diagnostics.cluster_view()
      #=> %{self: :node@host, connected: [...], registered: [...]}

  Inspect a specific request's execution path:

      PhoenixGenApi.Diagnostics.inspect_request(%Request{...})

  ## Tracing

  Tracing is gated behind admin actions because it can add overhead and expose
  runtime internals. Configure the actions before using it:

      config :phoenix_gen_api, :admin_actions, [
        :enable_tracing,
        :disable_tracing
      ]

      PhoenixGenApi.Diagnostics.trace_processes(:all,
        flags: [:call, :return_to, :procs],
        tracer: self()
      )

      PhoenixGenApi.Diagnostics.trace_functions({MyApp.Api, :get_user, 1},
        tracer: self()
      )

      PhoenixGenApi.Diagnostics.stop_trace(:all)
  """

  alias PhoenixGenApi.{ConfigDb, ConfigPuller, ConfigReceiver, RateLimiter}
  alias PhoenixGenApi.RelayServer

  require Logger

  @trace_process_targets [
    :all,
    :processes,
    :ports,
    :existing,
    :existing_processes,
    :existing_ports,
    :new,
    :new_processes,
    :new_ports
  ]

  @trace_flags [
    :call,
    :return_to,
    :return_trace,
    :procs,
    :ports,
    :timestamp,
    :cpu_timestamp,
    :arity,
    :silent
  ]

  @memory_types [
    :total,
    :processes,
    :processes_used,
    :system,
    :atom,
    :atom_used,
    :binary,
    :code,
    :ets
  ]

  @default_trace_flags [:call, :return_to, :procs]

  @type health_status :: :ok | :degraded | :error
  @type health_report :: %{
          required(:status) => health_status(),
          required(:node) => node(),
          required(:checked_at_ms) => integer(),
          required(:checks) => map()
        }

  # ──────────────────────────────────────────────────────────────────────
  # Health Check
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Returns a runtime health report for the VM, Erlang distribution, and
  PhoenixGenApi processes.

  Options:

    * `:max_memory_bytes` — if set and total memory exceeds it, the vm check
      is marked `:degraded`.

  The report is structured and non-destructive. It does not mutate the system.
  """
  @spec health_check(keyword()) :: health_report()
  def health_check(opts \\ []) do
    vm_check = vm_check(opts)
    node_check = node_check()
    phoenix_gen_api_check = phoenix_gen_api_check()

    checks = %{
      vm: vm_check,
      node: node_check,
      phoenix_gen_api: phoenix_gen_api_check
    }

    %{
      status: overall_status(checks),
      node: Node.self(),
      checked_at_ms: System.system_time(:millisecond),
      checks: checks
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Statistics
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Returns VM and PhoenixGenApi runtime statistics.

  The VM section contains process, memory, scheduler, reductions, runtime, and
  garbage collection counters. The PhoenixGenApi section contains status for the
  config cache, puller, receiver, rate limiter, worker pools, relay server, and
  telemetry event coverage.
  """
  @spec statistics(keyword()) :: map()
  def statistics(_opts \\ []) do
    %{
      node: Node.self(),
      collected_at_ms: System.system_time(:millisecond),
      vm: vm_statistics(),
      phoenix_gen_api: phoenix_gen_api_statistics()
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Debug Report
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Returns a debug-oriented snapshot for local runtime inspection.

  Options:

    * `:process_limit` — Maximum number of processes to include, sorted by
      memory usage. Defaults to `20`.
    * `:include_current_stacktrace` — Includes each process stacktrace when
      `true`. Defaults to `false`.

  The returned process summaries intentionally avoid full message queues and
  dictionaries by default.
  """
  @spec debug_report(keyword()) :: map()
  def debug_report(opts \\ []) do
    process_limit = Keyword.get(opts, :process_limit, 20)
    include_current_stacktrace? = Keyword.get(opts, :include_current_stacktrace, false)

    process_items =
      :erlang.processes()
      |> Enum.map(&process_summary(&1, include_current_stacktrace?))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&Map.get(&1, :memory, 0), :desc)
      |> Enum.take(process_limit)

    %{
      node: Node.self(),
      collected_at_ms: System.system_time(:millisecond),
      processes: process_items,
      ets_tables: phoenix_gen_api_ets_tables(),
      trace: trace_status()
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Call Flow Inspection
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Traces the call flow for a given service/request_type from the gateway node
  to its target node(s).

  Returns a map describing every step a request goes through:

    * `:config` — the resolved `%FunConfig{}` (or `nil` if not found)
    * `:local?` — whether execution is local (`:local`) or remote
    * `:nodes` — the list of target nodes after node selection
    * `:steps` — an ordered list of execution phases with descriptions
    * `:rate_limit` — which rate limiter scopes apply
    * `:permission` — the permission check strategy
    * `:hooks` — before/after hook configurations
    * `:retry` — retry configuration (if any)
    * `:cluster` — which of the target nodes are currently reachable

  ## Examples

      iex> PhoenixGenApi.Diagnostics.call_flow("user_service", "get_user")
      %{
        config: %FunConfig{request_type: "get_user", ...},
        local?: false,
        nodes: [:"service@host"],
        steps: [
          %{phase: :channel, desc: "WebSocket handle_in receives payload"},
          %{phase: :decode, desc: "Payload decoded into %Request{}"},
          %{phase: :config_lookup, desc: "ConfigDb.get(service, type, version)"},
          %{phase: :hooks_before, desc: "before_execute hooks (none configured)"},
          %{phase: :permission, desc: "Permission.check_permission!/2"},
          %{phase: :rate_limit, desc: "RateLimiter.check_rate_limit/1"},
          %{phase: :argument_validation, desc: "ArgumentHandler.convert_args!/2"},
          %{phase: :node_selection, desc: "NodeSelector picks :random from [node@host]"},
          %{phase: :execution, desc: "RPC to service@host"},
          %{phase: :hooks_after, desc: "after_execute hooks (none configured)"},
          %{phase: :response, desc: "Result pushed back to client via WebSocket"}
        ],
        ...
      }
  """
  @spec call_flow(String.t() | atom(), String.t(), String.t() | nil) :: map()
  def call_flow(service, request_type, version \\ nil) do
    config = resolve_config(service, request_type, version)
    build_call_flow(config, service, request_type)
  end

  @doc """
  Inspects a `%Request{}` struct and returns a detailed execution plan
  showing exactly what will happen when the request is executed.

  This is useful for debugging why a request succeeds, fails, or routes
  to a particular node.
  """
  @spec inspect_request(map() | PhoenixGenApi.Structs.Request.t()) :: map()
  def inspect_request(request) do
    service = Map.get(request, :service) || Map.get(request, "service")
    request_type = Map.get(request, :request_type) || Map.get(request, "request_type")
    version = Map.get(request, :version) || Map.get(request, "version")

    flow = call_flow(service, request_type, version)

    Map.merge(flow, %{
      request: %{
        service: service,
        request_type: request_type,
        version: version,
        user_id: Map.get(request, :user_id) || Map.get(request, "user_id"),
        device_id: Map.get(request, :device_id) || Map.get(request, "device_id"),
        request_id: Map.get(request, :request_id) || Map.get(request, "request_id")
      }
    })
  end

  @doc """
  Returns a cluster topology view from the perspective of this node.

  Shows connected nodes, registered processes, and which PhoenixGenApi
  services are reachable.
  """
  @spec cluster_view() :: map()
  def cluster_view do
    connected = Node.list()
    all_nodes = [Node.self() | connected]

    %{
      self: Node.self(),
      connected: connected,
      connected_count: length(connected),
      registered_processes: registered_processes(all_nodes),
      phoenix_gen_api_services: discover_phoenix_gen_api_services(connected),
      node_selection: %{
        strategies: [:random, :hash, :round_robin, :sticky],
        description: "Configure via FunConfig.choose_node_mode"
      }
    }
  end

  @doc """
  Returns a summary of all registered call flows across all services.

  Each entry shows the service, request_type, version, target nodes,
  and execution mode (local vs remote).
  """
  @spec list_call_flows(keyword()) :: [map()]
  def list_call_flows(opts \\ []) do
    services = ConfigDb.get_all_services()
    include_disabled = Keyword.get(opts, :include_disabled, false)

    for service <- services,
        {request_type, versions} <-
          Map.get(ConfigDb.get_functions_from_services(service), service, %{}),
        version <- versions,
        reduce: [] do
      acc ->
        case ConfigDb.get(service, request_type, version) do
          {:ok, fc} ->
            flow = build_call_flow({:ok, fc}, service, fc.request_type)
            [Map.put(flow, :disabled, Map.get(fc, :disabled, false)) | acc]

          {:error, :disabled} ->
            if include_disabled do
              [
                %{
                  service: service,
                  request_type: request_type,
                  version: version,
                  status: :disabled,
                  disabled: true
                }
                | acc
              ]
            else
              acc
            end

          _ ->
            acc
        end
    end
    |> Enum.reverse()
  end

  # ──────────────────────────────────────────────────────────────────────
  # Tracing (admin-gated)
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Enables legacy Erlang tracing for processes or ports.

  This operation requires the `:enable_tracing` admin action.

  Supported targets:

    * `:all`
    * `:processes`
    * `:ports`
    * `:existing`
    * `:existing_processes`
    * `:existing_ports`
    * `:new`
    * `:new_processes`
    * `:new_ports`
    * a PID or port
    * a list of the above

  Options:

    * `:flags` — Trace flags. Defaults to `[:call, :return_to, :procs]`.
    * `:tracer` — PID that receives trace messages. Defaults to `self()`.
  """
  @spec trace_processes(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace_processes(targets, opts \\ []) do
    with :ok <- admin_action_allowed?(:enable_tracing),
         {:ok, tracer} <- tracer(opts),
         {:ok, flags} <- trace_flags(opts),
         {:ok, normalized_targets} <- normalize_trace_targets(targets),
         :ok <- validate_trace_targets(normalized_targets) do
      trace_flags_with_tracer = [{:tracer, tracer} | flags]

      results =
        Enum.into(normalized_targets, %{}, fn target ->
          {inspect(target), :erlang.trace(target, true, trace_flags_with_tracer)}
        end)

      {:ok,
       %{
         tracer: tracer,
         flags: flags,
         targets: normalized_targets,
         results: results
       }}
    end
  end

  defp validate_trace_targets([:all]), do: :ok

  defp validate_trace_targets(targets) do
    invalid =
      Enum.reject(targets, fn
        t when is_pid(t) ->
          true

        t when is_port(t) ->
          true

        t when is_atom(t) ->
          if Code.ensure_loaded?(t) do
            true
          else
            Logger.warning("[Diagnostics] Trace target module not loaded: #{inspect(t)}")
            false
          end

        _ ->
          false
      end)

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_trace_target, invalid}}
    end
  end

  @doc """
  Enables call tracing for specific MFAs.

  This operation requires the `:enable_tracing` admin action.

  MFAs can be `{Module, Function}`, `{Module, Function, Arity}`, or `:all`.
  Arity may be a non-negative integer or `:_` for all arities.

  Options:

    * `:flags` — Process trace flags. Defaults to `[:call, :return_to, :procs]`.
    * `:match_spec` — Match specification passed to `:erlang.trace_pattern/3`.
      Defaults to `true`.
    * `:tracer` — PID that receives trace messages. Defaults to `self()`.
  """
  @spec trace_functions(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace_functions(mfas, opts \\ []) do
    with :ok <- admin_action_allowed?(:enable_tracing),
         {:ok, tracer} <- tracer(opts),
         {:ok, flags} <- trace_flags(opts),
         {:ok, match_spec} <- match_spec(opts),
         {:ok, normalized_mfas} <- normalize_mfas(mfas),
         :ok <- validate_mfa_modules(normalized_mfas) do
      {:ok, process_trace} = trace_processes(:all, Keyword.put(opts, :tracer, tracer))

      pattern_results =
        Enum.into(normalized_mfas, %{}, fn mfa ->
          {inspect(mfa), :erlang.trace_pattern(mfa, match_spec, [{:meta, tracer}])}
        end)

      {:ok,
       %{
         tracer: tracer,
         flags: flags,
         match_spec: match_spec,
         mfas: normalized_mfas,
         process_trace: process_trace,
         pattern_results: pattern_results
       }}
    end
  end

  defp validate_mfa_modules([{mod, _, _} | _] = mfas) when is_atom(mod) do
    invalid =
      Enum.reject(mfas, fn {mod, _, _} ->
        if Code.ensure_loaded?(mod) do
          true
        else
          Logger.warning("[Diagnostics] Trace MFA module not loaded: #{inspect(mod)}")
          false
        end
      end)

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_mfa, invalid}}
    end
  end

  defp validate_mfa_modules(_), do: :ok

  @doc """
  Disables legacy Erlang tracing for processes or ports.

  This operation requires the `:disable_tracing` admin action.
  """
  @spec stop_trace(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop_trace(targets \\ :all, opts \\ []) do
    with :ok <- admin_action_allowed?(:disable_tracing),
         {:ok, flags} <- trace_flags(opts),
         {:ok, normalized_targets} <- normalize_trace_targets(targets) do
      results =
        Enum.into(normalized_targets, %{}, fn target ->
          {inspect(target), :erlang.trace(target, false, flags)}
        end)

      {:ok,
       %{
         flags: flags,
         targets: normalized_targets,
         results: results
       }}
    end
  end

  @doc """
  Disables call tracing for specific MFAs.

  Passing `:all` disables all call trace patterns.
  """
  @spec stop_trace_functions(term()) :: {:ok, map()} | {:error, term()}
  def stop_trace_functions(mfas \\ :all) do
    with :ok <- admin_action_allowed?(:disable_tracing),
         {:ok, normalized_mfas} <- normalize_mfas(mfas) do
      results =
        Enum.into(normalized_mfas, %{}, fn mfa ->
          {inspect(mfa), :erlang.trace_pattern(mfa, false, [])}
        end)

      {:ok, %{mfas: normalized_mfas, results: results}}
    end
  end

  @doc """
  Returns a small trace status snapshot.
  """
  @spec trace_status() :: map()
  def trace_status do
    %{
      node: Node.self(),
      trace_control_word: :erlang.system_info(:trace_control_word)
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private — Call Flow Builder
  # ──────────────────────────────────────────────────────────────────────

  defp resolve_config(service, request_type, version) do
    v = if is_nil(version) or version == "0.0.0", do: nil, else: version

    case ConfigDb.get(service, request_type, v) do
      {:ok, config} -> {:ok, config}
      {:error, :not_found} -> ConfigDb.get_latest(service, request_type)
      error -> error
    end
  end

  defp build_call_flow({:ok, config}, service, request_type) do
    local? = PhoenixGenApi.Structs.FunConfig.local_service?(config)
    nodes = resolve_nodes(config)
    reachable = Enum.filter(nodes, &node_reachable?/1)

    rate_limit_scopes = build_rate_limit_scopes(service, request_type)

    %{
      service: service,
      request_type: request_type,
      version: Map.get(config, :version),
      config: config,
      local?: local?,
      nodes: nodes,
      reachable_nodes: reachable,
      unreachable_nodes: nodes -- reachable,
      response_type: config.response_type,
      choose_node_mode: config.choose_node_mode,
      timeout: config.timeout,
      rate_limit: rate_limit_scopes,
      permission: build_permission_info(config),
      hooks: build_hooks_info(config),
      retry: build_retry_info(config),
      mfa: config.mfa,
      steps: build_steps(config, local?, nodes, reachable)
    }
  end

  defp build_call_flow({:error, reason}, service, request_type) do
    %{
      service: service,
      request_type: request_type,
      config: nil,
      error: reason,
      steps: [
        %{
          phase: :config_lookup,
          desc: "ConfigDb.get(#{inspect(service)}, #{inspect(request_type)}) → #{inspect(reason)}"
        }
      ]
    }
  end

  defp resolve_nodes(config) do
    nodes = config.nodes

    if is_tuple(nodes) and tuple_size(nodes) == 3 do
      {mod, fun, args} = nodes

      if function_exported?(mod, fun, length(args)) do
        case apply(mod, fun, args) do
          list when is_list(list) -> list
          _ -> []
        end
      else
        []
      end
    else
      List.wrap(nodes)
    end
  end

  defp node_reachable?(node) when is_atom(node) do
    node == Node.self() || :net_adm.ping(node) == :pong
  end

  defp node_reachable?(_), do: false

  defp build_rate_limit_scopes(service, request_type) do
    configured = RateLimiter.get_configured_limits()

    global =
      Enum.map(configured.global, fn limit ->
        %{
          scope: :global,
          key: limit.key,
          max_requests: limit.max_requests,
          window_ms: limit.window_ms
        }
      end)

    api =
      Enum.filter(configured.api, fn limit ->
        limit.service == service and limit.request_type == request_type
      end)
      |> Enum.map(fn limit ->
        %{
          scope: :api,
          key: limit.key,
          max_requests: limit.max_requests,
          window_ms: limit.window_ms
        }
      end)

    %{global: global, api: api}
  end

  defp build_permission_info(config) do
    case config.check_permission do
      false ->
        %{strategy: :none, description: "No permission check"}

      true ->
        %{strategy: :authenticated, description: "Requires authenticated user_id"}

      {:arg, field} ->
        %{
          strategy: :arg_based,
          field: field,
          description: "Checks permission via request arg '#{field}'"
        }

      {:role, roles} ->
        %{
          strategy: :role_based,
          roles: roles,
          description: "Requires one of roles: #{inspect(roles)}"
        }

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        %{
          strategy: :custom_mfa,
          mfa: {mod, fun},
          description: "Custom permission check: #{mod}.#{fun}/2"
        }

      other ->
        %{
          strategy: :unknown,
          raw: other,
          description: "Unknown permission config: #{inspect(other)}"
        }
    end
  end

  defp build_hooks_info(config) do
    %{
      before_execute: format_hook(config.before_execute),
      after_execute: format_hook(config.after_execute)
    }
  end

  defp format_hook(nil), do: %{configured: false, description: "No hook configured"}

  defp format_hook({mod, fun}),
    do: %{
      configured: true,
      mfa: {mod, fun},
      args: 2,
      description: "#{mod}.#{fun}/2(request, fun_config)"
    }

  defp format_hook({mod, fun, extra_args}),
    do: %{
      configured: true,
      mfa: {mod, fun},
      args: 2 + length(extra_args),
      description: "#{mod}.#{fun}/#{2 + length(extra_args)}(request, fun_config, ...)"
    }

  defp format_hook(other), do: %{configured: true, raw: other, description: inspect(other)}

  defp build_retry_info(config) do
    case config.retry do
      nil ->
        %{configured: false, description: "No retry"}

      n when is_integer(n) ->
        %{
          configured: true,
          mode: :all_nodes,
          attempts: n,
          description: "Retry up to #{n} times across all nodes"
        }

      {:same_node, n} ->
        %{
          configured: true,
          mode: :same_node,
          attempts: n,
          description: "Retry up to #{n} times on the same node"
        }

      {:all_nodes, n} ->
        %{
          configured: true,
          mode: :all_nodes,
          attempts: n,
          description: "Retry up to #{n} times across all nodes"
        }
    end
  end

  defp build_steps(config, local?, nodes, reachable) do
    steps = [
      %{phase: :channel, desc: "WebSocket handle_in receives payload on channel"},
      %{phase: :decode, desc: "Payload decoded into %Request{} via Nestru"},
      %{
        phase: :config_lookup,
        desc: "ConfigDb.get(service, request_type, version) — direct ETS read"
      }
    ]

    steps =
      if config.before_execute do
        steps ++
          [
            %{
              phase: :hooks_before,
              desc: "before_execute hook: #{format_hook_short(config.before_execute)}"
            }
          ]
      else
        steps ++ [%{phase: :hooks_before, desc: "before_execute hooks (none configured)"}]
      end

    steps = steps ++ [%{phase: :permission, desc: "Permission.check_permission!/2"}]

    steps =
      steps ++
        [%{phase: :rate_limit, desc: "RateLimiter.check_rate_limit/1 — sliding window check"}]

    steps =
      if config.response_type in [:async, :none] do
        steps ++
          [
            %{
              phase: :argument_validation,
              desc: "ArgumentHandler.convert_args!/2 (deferred to worker pool)"
            }
          ]
      else
        steps ++ [%{phase: :argument_validation, desc: "ArgumentHandler.convert_args!/2"}]
      end

    steps =
      if local? do
        steps ++
          [
            %{
              phase: :execution,
              desc: "Local execution via Task.async (timeout: #{config.timeout}ms)"
            }
          ]
      else
        node_desc = Enum.map_join(nodes, ", ", &inspect/1)
        reach_desc = "#{length(reachable)}/#{length(nodes)} reachable"

        steps ++
          [
            %{
              phase: :node_selection,
              desc: "NodeSelector picks :#{config.choose_node_mode} from [#{node_desc}]"
            },
            %{phase: :execution, desc: "RPC to target node(s) — #{reach_desc}"}
          ]
      end

    steps =
      if config.retry do
        steps ++ [%{phase: :retry, desc: "Retry on failure: #{format_retry_short(config.retry)}"}]
      else
        steps
      end

    steps =
      if config.after_execute do
        steps ++
          [
            %{
              phase: :hooks_after,
              desc: "after_execute hook: #{format_hook_short(config.after_execute)}"
            }
          ]
      else
        steps ++ [%{phase: :hooks_after, desc: "after_execute hooks (none configured)"}]
      end

    response_desc =
      case config.response_type do
        :sync -> "Sync result pushed back to client via WebSocket"
        :async -> "Async result pushed to client when ready"
        :none -> "Fire-and-forget (no response to client)"
        :stream -> "Stream chunks pushed to client until complete"
        other -> "Response type: #{inspect(other)}"
      end

    steps ++ [%{phase: :response, desc: response_desc}]
  end

  defp format_hook_short({mod, fun}), do: "#{mod}.#{fun}/2"
  defp format_hook_short({mod, fun, extra}), do: "#{mod}.#{fun}/#{2 + length(extra)}"
  defp format_hook_short(other), do: inspect(other)

  defp format_retry_short(n) when is_integer(n), do: "#{n} attempts (all nodes)"
  defp format_retry_short({:same_node, n}), do: "#{n} attempts (same node)"
  defp format_retry_short({:all_nodes, n}), do: "#{n} attempts (all nodes)"
  defp format_retry_short(other), do: inspect(other)

  # ──────────────────────────────────────────────────────────────────────
  # Private — Cluster View
  # ──────────────────────────────────────────────────────────────────────

  defp registered_processes(nodes) do
    for node <- nodes do
      {node, :rpc.call(node, :erlang, :registered, [])}
    end
    |> Map.new()
  end

  defp discover_phoenix_gen_api_services(connected) do
    for node <- connected do
      services =
        :rpc.call(node, PhoenixGenApi.ConfigDb, :get_all_services, [])
        |> case do
          services when is_list(services) -> services
          _ -> []
        end

      {node, services}
    end
    |> Map.new()
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private — VM / Node checks
  # ──────────────────────────────────────────────────────────────────────

  defp vm_check(opts) do
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    mem = memory()
    max_memory_bytes = Keyword.get(opts, :max_memory_bytes)

    status =
      cond do
        process_limit > 0 and process_count >= trunc(process_limit * 0.9) ->
          :degraded

        is_integer(max_memory_bytes) and Map.get(mem, :total, 0) > max_memory_bytes ->
          :degraded

        true ->
          :ok
      end

    %{
      status: status,
      process_count: process_count,
      process_limit: process_limit,
      memory: mem,
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      uptime: :erlang.statistics(:wall_clock)
    }
  end

  defp vm_statistics do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      ets_count: :erlang.system_info(:ets_count),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      memory: memory(),
      reductions: :erlang.statistics(:reductions),
      exact_reductions: :erlang.statistics(:exact_reductions),
      runtime: :erlang.statistics(:runtime),
      garbage_collection: :erlang.statistics(:garbage_collection),
      context_switches: :erlang.statistics(:context_switches),
      scheduler_wall_time: :erlang.statistics(:scheduler_wall_time),
      uptime: :erlang.statistics(:wall_clock)
    }
  end

  defp node_check do
    alive? = Node.alive?()

    %{
      status: if(alive?, do: :ok, else: :error),
      node: Node.self(),
      alive?: alive?,
      connected_nodes: Node.list()
    }
  end

  defp phoenix_gen_api_check do
    client_mode = Application.get_env(:phoenix_gen_api, :client_mode, false)

    if client_mode do
      %{status: :ok, mode: :client}
    else
      checks = %{
        config_db: process_check(ConfigDb),
        config_puller: process_check(ConfigPuller),
        config_receiver: process_check(ConfigReceiver),
        relay_registry: process_check(PhoenixGenApi.RelayRegistry),
        relay_server: process_check(RelayServer),
        worker_pool_supervisor: process_check(PhoenixGenApi.WorkerPool.WorkerPoolSupervisor),
        async_pool: process_check(:async_pool),
        stream_pool: process_check(:stream_pool),
        rate_limiter_supervisor: process_check(:rate_limiter_supervisor),
        rate_limiter_instances: rate_limiter_health(),
        supervision_tree: supervision_tree_check()
      }

      %{status: overall_status(checks), mode: :gateway, checks: checks}
    end
  end

  defp phoenix_gen_api_statistics do
    %{
      client_mode: Application.get_env(:phoenix_gen_api, :client_mode, false),
      config_db: config_db_statistics(),
      config_puller: config_puller_statistics(),
      config_receiver: config_receiver_statistics(),
      rate_limiter: rate_limiter_statistics(),
      worker_pool: worker_pool_statistics(),
      relay: relay_statistics(),
      telemetry_events: PhoenixGenApi.Telemetry.list_events() |> length()
    }
  end

  defp config_db_statistics do
    if Process.whereis(ConfigDb) do
      %{
        status: :ok,
        count: ConfigDb.count(),
        services: ConfigDb.get_all_services(),
        ets: ets_table_info(ConfigDb)
      }
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp config_puller_statistics do
    if Process.whereis(ConfigPuller) do
      %{status: :ok, data: ConfigPuller.status()}
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp config_receiver_statistics do
    if Process.whereis(ConfigReceiver) do
      %{status: :ok, data: ConfigReceiver.status()}
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp rate_limiter_statistics do
    if Process.whereis(:rate_limiter_supervisor) do
      %{status: :ok, data: RateLimiter.status()}
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp worker_pool_statistics do
    %{
      async_pool: pool_statistics(:async_pool),
      stream_pool: pool_statistics(:stream_pool)
    }
  end

  defp pool_statistics(pool_name) do
    if Process.whereis(pool_name) do
      %{status: :ok, data: PhoenixGenApi.WorkerPool.status(pool_name)}
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp relay_statistics do
    if Process.whereis(RelayServer) do
      %{status: :ok, data: RelayServer.status()}
    else
      %{status: :error, reason: :not_started}
    end
  end

  defp rate_limiter_health do
    supervisor_name = :rate_limiter_supervisor

    case Process.whereis(supervisor_name) do
      nil ->
        %{status: :error, reason: :not_registered}

      _pid ->
        instance_count = RateLimiter.instance_count()

        if instance_count > 0 do
          alive_instances =
            0..(instance_count - 1)
            |> Enum.filter(fn i ->
              name = :"rate_limiter_instance_#{i}"
              Process.whereis(name) != nil && Process.alive?(Process.whereis(name))
            end)
            |> length()

          if alive_instances == instance_count do
            %{status: :ok, instance_count: instance_count, alive_instances: alive_instances}
          else
            %{
              status: :degraded,
              instance_count: instance_count,
              alive_instances: alive_instances,
              reason: :partial_failure
            }
          end
        else
          %{status: :ok, instance_count: 0, reason: :no_limits_configured}
        end
    end
  end

  defp process_check(name) do
    case Process.whereis(name) do
      nil ->
        %{status: :error, registered_name: inspect(name), pid: nil, reason: :not_registered}

      pid ->
        case :erlang.process_info(pid, :status) do
          :undefined ->
            %{
              status: :error,
              registered_name: inspect(name),
              pid: pid,
              reason: :not_alive
            }

          _ ->
            summary = process_summary(pid, false)

            if summary do
              %{
                status: :ok,
                registered_name: inspect(name),
                pid: pid,
                process: summary
              }
            else
              %{
                status: :error,
                registered_name: inspect(name),
                pid: pid,
                reason: :not_alive
              }
            end
        end
    end
  end

  defp supervision_tree_check do
    supervisor = PhoenixGenApi.Supervisor

    case Process.whereis(supervisor) do
      nil ->
        %{status: :error, reason: :supervisor_not_found}

      _pid ->
        children = Supervisor.which_children(supervisor)
        running = Enum.count(children, fn {_, pid, _, _} -> is_pid(pid) end)
        total = length(children)

        if running == total do
          %{status: :ok, children_count: total}
        else
          %{
            status: :degraded,
            children_count: total,
            running: running,
            reason: :partial_failure
          }
        end
    end
  end

  defp process_summary(pid, include_current_stacktrace?) do
    items =
      if include_current_stacktrace? do
        [
          :registered_name,
          :current_function,
          :current_stacktrace,
          :status,
          :message_queue_len,
          :memory,
          :total_heap_size,
          :reductions
        ]
      else
        [
          :registered_name,
          :current_function,
          :status,
          :message_queue_len,
          :memory,
          :total_heap_size,
          :reductions
        ]
      end

    case :erlang.process_info(pid, items) do
      :undefined ->
        nil

      infos ->
        infos
        |> Map.new()
        |> Map.put(:node, node(pid))
        |> Map.put(:pid, pid)
    end
  end

  defp memory do
    Enum.reduce(@memory_types, %{}, fn type, acc ->
      try do
        Map.put(acc, type, :erlang.memory(type))
      rescue
        ArgumentError -> acc
        ErlangError -> acc
      end
    end)
  end

  defp phoenix_gen_api_ets_tables do
    [
      ConfigDb,
      :rate_limiter_global,
      :rate_limiter_api,
      PhoenixGenApi.RelayRegistry,
      RelayServer.table()
    ]
    |> Enum.map(&{inspect(&1), ets_table_info(&1)})
    |> Map.new()
  end

  defp ets_table_info(table) do
    case :ets.info(table) do
      :undefined ->
        %{exists: false}

      info when is_list(info) ->
        info
        |> Map.new()
        |> Map.put(:exists, true)

      other ->
        %{exists: true, info: other}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private — Tracing helpers
  # ──────────────────────────────────────────────────────────────────────

  defp admin_action_allowed?(action) do
    if PhoenixGenApi.Security.admin_action_allowed?(action) do
      :ok
    else
      {:error, :admin_action_denied}
    end
  end

  defp tracer(opts) do
    tracer = Keyword.get(opts, :tracer, self())

    if is_pid(tracer) do
      {:ok, tracer}
    else
      {:error, :invalid_tracer}
    end
  end

  defp trace_flags(opts) do
    flags = Keyword.get(opts, :flags, @default_trace_flags)

    if is_list(flags) and Enum.all?(flags, &(&1 in @trace_flags)) do
      {:ok, flags}
    else
      {:error, :invalid_trace_flag}
    end
  end

  defp normalize_trace_targets(:all), do: {:ok, [:all]}

  defp normalize_trace_targets(targets) when is_list(targets) do
    if Enum.all?(targets, &valid_trace_target?/1) do
      {:ok, targets}
    else
      {:error, :invalid_trace_target}
    end
  end

  defp normalize_trace_targets(target) do
    if valid_trace_target?(target) do
      {:ok, [target]}
    else
      {:error, :invalid_trace_target}
    end
  end

  defp valid_trace_target?(target) when target in @trace_process_targets, do: true
  defp valid_trace_target?(pid) when is_pid(pid), do: true
  defp valid_trace_target?(port) when is_port(port), do: true
  defp valid_trace_target?(_), do: false

  defp normalize_mfas(:all), do: {:ok, [{:_, :_, :_}]}

  defp normalize_mfas(mfas) when is_list(mfas) do
    if Enum.all?(mfas, &valid_mfa?/1) do
      {:ok, Enum.map(mfas, &normalize_mfa/1)}
    else
      {:error, :invalid_mfa}
    end
  end

  defp normalize_mfas(mfa) do
    if valid_mfa?(mfa) do
      {:ok, [normalize_mfa(mfa)]}
    else
      {:error, :invalid_mfa}
    end
  end

  defp normalize_mfa({module, function}), do: {module, function, :_}
  defp normalize_mfa({module, function, arity}), do: {module, function, arity}
  defp normalize_mfa(:all), do: {:_, :_, :_}

  defp valid_mfa?(:all), do: true
  defp valid_mfa?({module, function}) when is_atom(module) and is_atom(function), do: true

  defp valid_mfa?({module, function, arity})
       when is_atom(module) and is_atom(function) and (is_integer(arity) or arity == :_),
       do: arity == :_ or arity >= 0

  defp valid_mfa?(_), do: false

  defp match_spec(opts) do
    match_spec = Keyword.get(opts, :match_spec, true)

    if is_boolean(match_spec) or is_list(match_spec) do
      {:ok, match_spec}
    else
      {:error, :invalid_match_spec}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Private — Status aggregation
  # ──────────────────────────────────────────────────────────────────────

  defp overall_status(%{status: status}), do: status

  defp overall_status(map) when is_map(map) do
    statuses = map |> Map.values() |> Enum.map(&overall_status/1)

    cond do
      :error in statuses -> :error
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  defp overall_status(list) when is_list(list) do
    statuses = Enum.map(list, &overall_status/1)

    cond do
      :error in statuses -> :error
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  defp overall_status(_), do: :ok
end

defmodule PhoenixGenApi.ImplHelper do
  @moduledoc """
  Macro to generate simple implementation of protocol.
  Support for easy to use with general encoder.

  Utility macro to generate implementation for struct.

  The target struct must have `encode!/2` function in module.

  Usage:

  ```Elixir
  use PhoenixGenApi.ImplHelper, encoder: JSON.Encoder, impl: [AModule1, AModule2, ...]
  ```

  Using macro without option in `use` keyword.
  Target module must have `encode!/2` function
  Generate implementation from struct for JSON.Encoder like this:

  ```Elixir
  require PhoenixGenApi.ImplHelper

  gen_impl JSON.Encoder, AModule
  ```
  """

  defmacro __using__(opts) do
    {opts, _} = Code.eval_quoted(opts, [], __CALLER__)

    encoder = Keyword.get(opts, :encoder)

    if encoder == nil, do: raise("missing encoder option")

    list_module = Keyword.get(opts, :impl, [])

    impl_asts =
      for module <- list_module do
        impl_quote(encoder, module)
      end

    {:__block__, [], impl_asts}
  end

  defmacro gen_impl(encoder, module) do
    encoder = Macro.expand(encoder, __CALLER__)
    module = Macro.expand(module, __CALLER__)

    impl_quote(encoder, module)
  end

  defp impl_quote(encoder, module) do
    quote do
      defimpl unquote(encoder), for: unquote(module) do
        def encode(data = %unquote(module){}, opts) do
          data
          |> unquote(module).encode!(opts)
          |> unquote(encoder).encode(opts)
        end
      end
    end
  end
end

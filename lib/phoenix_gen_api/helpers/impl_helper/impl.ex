defmodule PhoenixGenApi.ImplHelper do
  @doc """
  Macro to generate simple implementation of protocol.
  Support for easy to use with general encoder.

  Utility macro to generate implementation for struct.

  The target struct must have `encode!/2` function in module.

  Usage:

  ```Elixir
  use PhoenixGenApi.ImplHelper, encoder: ToonEx, impl: [AModule1, AModule2, ...]
  ```

  Using macro without option in `use` keyword.
  Target module must have `encode!/2` function
  Generate implementation from struct for JSON.Encoder like this:

  ```Elixir
  gen_impl JSON.Encoder, AModule
  ```
  """

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      list_module = Keyword.get(opts, :impl, [])
      encoder = Keyword.get(opts, :encoder)

      if (encoder == nil), do: raise "missing encoder option"

      for module <- list_module do
        PhoenixGenApi.ImplHelper.gen_impl(encoder, module)
      end
    end
  end

  defmacro gen_impl(encoder, module) do
    quote do
      defimpl unquote(encoder), for: unquote(module) do
        def encode(%unquote(module){} = data, opts) do
          data
          |> unquote(module).encode!(opts)
        end
      end
    end
  end
end

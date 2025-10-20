defmodule PhoenixGenApi.JasonImplHelper do
  @doc """
  Macro to generate simple implementation of protocol.
  Support for easy to use with Jason.Encoder.

  Utility macro to generate implementation for Jason.Encoder.

  The target struct must have `encode!` function in module.

  Usage:

  ```Elixir
  use PhoenixGenApi.JasonImplHelper, impl: [AModule1, AModule2, ...]
  ```

  Using macro without option in `use` keyword.
  Target module must have `encode!` function
  Generate implementation for Jason.Encoder like this:

  ```Elixir
  gen_impl AModule
  ```
  """

  # TO-DO: Improve this, avoid encode to many time.

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      import PhoenixGenApi.JasonImplHelper

      list_module = Keyword.get(opts, :impl, [])

      for mod <- list_module do
        gen_impl(mod)
      end
    end
  end

  defmacro gen_impl(mod) do
    quote do
      defimpl Jason.Encoder, for: unquote(mod) do
        def encode(%unquote(mod){} = data, _opts) do
          data
          |> unquote(mod).encode!()
          |> JSON.encode!()
        end
      end
    end
  end
end

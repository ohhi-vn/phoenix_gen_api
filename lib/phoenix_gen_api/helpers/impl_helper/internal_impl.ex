defmodule PhoenixGenApi.InternalImpl do
  @moduledoc false

  defmacro __using__(_opts) do
    quote location: :keep do
      use PhoenixGenApi.ImplHelper,
        encoder: Module.concat(Application.compile_env(:phoenix, :json_library, JSON), Encoder),
        impl: [
          PhoenixGenApi.Structs.Response
        ]
    end
  end
end

defmodule ChimeraRuntime.Repo do
  use Ecto.Repo,
    otp_app: :chimera_runtime,
    adapter: Ecto.Adapters.SQLite3
end

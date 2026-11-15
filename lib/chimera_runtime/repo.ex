defmodule ChimeraRuntime.Repo do
  use AshSqlite.Repo, otp_app: :chimera_runtime

  @impl true
  def installed_extensions, do: []

  @impl true
  def min_sqlite_version, do: %Version{major: 3, minor: 37, patch: 0}
end

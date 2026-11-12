defmodule ChimeraRuntimeWeb.PageController do
  use ChimeraRuntimeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

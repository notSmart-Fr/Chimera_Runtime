defmodule ChimeraRuntimeWeb.DashboardLiveTest do
  use ChimeraRuntimeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ChimeraRuntime.Chaos.Gate
  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  defp retry(fun, attempts \\ 20) do
    fun.()
  rescue
    e ->
      if attempts > 0 and Exception.message(e) =~ "database is locked" do
        Process.sleep(50)
        retry(fun, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp active_add_plugin! do
    plugin =
      retry(fn ->
        Sandbox.create_plugin!(%{
          name: "dash-add-#{System.unique_integer([:positive])}",
          wasm_binary: WasmFixtures.add(),
          timeout_ms: 5_000
        })
      end)

    plugin = retry(fn -> Sandbox.compile_plugin!(plugin) end)
    retry(fn -> Sandbox.activate_plugin!(plugin) end)
  end

  defp put_env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp reset_gate,
    do: :sys.replace_state(Gate, fn _ -> %{gate: Gate.new_state(), monitor: nil} end)

  setup do
    reset_gate()
    on_exit(&reset_gate/0)
    :ok
  end

  defp execution_payload(overrides) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        plugin_id: Ecto.UUID.generate(),
        status: :success,
        run_mode: :standard,
        duration_ms: 7,
        error_reason: nil,
        inserted_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp broadcast(payload) do
    Phoenix.PubSub.broadcast(
      ChimeraRuntime.PubSub,
      "sandbox:executions",
      %Phoenix.Socket.Broadcast{
        topic: "sandbox:executions",
        event: "execution_recorded",
        payload: payload
      }
    )
  end

  defp open_console(conn) do
    {:ok, lv, _html} = live(conn, "/control-room")
    render_async(lv, 5_000)
    lv
  end

  describe "mount" do
    test "GET /control-room returns 200 without credentials and shows the demo banner", %{
      conn: conn
    } do
      conn = get(conn, "/control-room")
      assert html_response(conn, 200) =~ "Demo mode: open access"
    end

    test "connected mount shows the three panels", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/control-room")
      assert has_element?(lv, "#demo-banner")
      assert has_element?(lv, "#registry-panel")
      assert has_element?(lv, "#console-panel")
      assert has_element?(lv, "#vitals-panel")
      assert has_element?(lv, "#chaos-chamber")
    end
  end

  describe "registry" do
    test "shows seeded plugins and never renders wasm_binary or source_code", %{conn: conn} do
      plugin = active_add_plugin!()
      {:ok, lv, _} = live(conn, "/control-room")
      html = render_async(lv, 5_000)

      assert html =~ plugin.name
      refute html =~ "wasm_binary"
      refute html =~ "source_code"
      assert html =~ "Failure rate"
    end
  end

  describe "console" do
    test "running an active add plugin shows output and wall time", %{conn: conn} do
      plugin = active_add_plugin!()
      lv = open_console(conn)

      lv
      |> form("#console-form",
        console: %{plugin_id: plugin.id, function_name: "add", args: "[2, 3]"}
      )
      |> render_submit()

      html = render_async(lv, 5_000)
      assert has_element?(lv, "#console-output", "5")
      assert has_element?(lv, "#console-wall-time", "Wall time")
      refute html =~ "wasm_binary"
    end

    test "invalid JSON args show an error and run nothing", %{conn: conn} do
      plugin = active_add_plugin!()
      lv = open_console(conn)

      html =
        lv
        |> form("#console-form",
          console: %{plugin_id: plugin.id, function_name: "add", args: "[1, "}
        )
        |> render_submit()

      assert html =~ "not valid JSON"
      refute has_element?(lv, "#console-result")
    end

    test "busy rejection when capacity is exhausted", %{conn: conn} do
      plugin = active_add_plugin!()
      put_env(:chimera_runtime, ChimeraRuntime.RunGuard, max_workers: 0)
      lv = open_console(conn)

      lv
      |> form("#console-form",
        console: %{plugin_id: plugin.id, function_name: "add", args: "[1, 2]"}
      )
      |> render_submit()

      render_async(lv, 5_000)
      assert has_element?(lv, "#console-rejected", "busy")
    end
  end

  describe "pubsub" do
    test "an execution event adds a log entry", %{conn: conn} do
      lv = open_console(conn)
      payload = execution_payload(%{duration_ms: 4242})
      broadcast(payload)

      assert render(lv) =~ "4242 ms"
      assert has_element?(lv, "#execution-log li", "success")
    end

    test "a malformed execution event is ignored", %{conn: conn} do
      lv = open_console(conn)
      broadcast(%{id: 1, bogus: true})
      html = render(lv)
      assert html =~ "No executions yet"
      assert Process.alive?(lv.pid)
    end
  end

  describe "chaos" do
    test "injection is contained and the LiveView process is unchanged; next click hits cooldown",
         %{conn: conn} do
      put_env(:chimera_runtime, :chaos, deadline_ms: 50, cooldown_ms: 60_000)
      lv = open_console(conn)
      pid = lv.pid

      lv |> element("#inject-chaos") |> render_click()
      render_async(lv, 15_000)

      assert has_element?(lv, "#chaos-result", "contained")
      assert has_element?(lv, "#chaos-liveview", "LiveView process unchanged")
      assert lv.pid == pid
      assert Process.alive?(pid)

      lv |> element("#inject-chaos") |> render_click()
      render_async(lv, 15_000)

      assert has_element?(lv, "#chaos-rejected", "cooldown")
      assert Process.alive?(pid)
    end
  end
end

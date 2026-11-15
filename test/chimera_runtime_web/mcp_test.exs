defmodule ChimeraRuntimeWeb.McpTest do
  use ChimeraRuntimeWeb.ConnCase, async: false

  alias ChimeraRuntime.Sandbox
  alias ChimeraRuntime.WasmFixtures

  @token String.duplicate("t", 32)

  # -- helpers ---------------------------------------------------------------

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

  defp mcp_env(overrides) do
    base = Application.get_env(:chimera_runtime, :mcp, [])
    put_env(:chimera_runtime, :mcp, Keyword.merge(base, overrides))
  end

  defp create_plugin!(attrs \\ %{}) do
    retry(fn ->
      Sandbox.create_plugin!(
        Map.merge(
          %{
            name: "mcp-#{System.unique_integer([:positive])}",
            wasm_binary: WasmFixtures.add(),
            timeout_ms: 5_000
          },
          attrs
        )
      )
    end)
  end

  defp active_add_plugin!(attrs \\ %{}) do
    plugin = create_plugin!(attrs)
    plugin = retry(fn -> Sandbox.compile_plugin!(plugin) end)
    retry(fn -> Sandbox.activate_plugin!(plugin) end)
  end

  defp rpc_conn(conn, method, params, headers \\ []) do
    body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    post_raw(conn, body, headers)
  end

  defp post_raw(conn, body, headers \\ []) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    post(conn, "/mcp", body)
  end

  defp rpc(conn, method, params, headers \\ []) do
    conn = rpc_conn(conn, method, params, headers)
    assert conn.status == 200
    json_response(conn, 200)
  end

  defp call_tool(conn, name, arguments, headers \\ []) do
    rpc(conn, "tools/call", %{"name" => name, "arguments" => arguments}, headers)
  end

  # Returns {is_error?, decoded_text_or_raw}
  defp tool_result(%{"result" => result}) do
    text =
      result
      |> Map.get("content", [])
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    decoded =
      case Jason.decode(text) do
        {:ok, v} -> v
        _ -> text
      end

    {Map.get(result, "isError", false) == true, decoded, result}
  end

  # -- protocol --------------------------------------------------------------

  describe "protocol" do
    test "initialize succeeds", %{conn: conn} do
      resp =
        rpc(conn, "initialize", %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })

      assert %{"result" => %{"serverInfo" => _, "capabilities" => %{"tools" => _}}} = resp
    end

    test "tools/list returns exactly the four tools with no Wasm or source in schemas", %{
      conn: conn
    } do
      %{"result" => %{"tools" => tools}} = rpc(conn, "tools/list", %{})

      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() ==
               ["inspect_execution_metrics", "list_plugins", "quarantine_plugin", "run_plugin"]

      encoded = Jason.encode!(tools)
      refute encoded =~ "wasm_binary"
      refute encoded =~ "source_code"
    end
  end

  # -- list_plugins ----------------------------------------------------------

  describe "list_plugins" do
    test "returns health fields and never wasm_binary or source_code", %{conn: conn} do
      plugin = active_add_plugin!()
      {error?, data, _} = conn |> call_tool("list_plugins", %{}) |> tool_result()

      refute error?
      list = if is_map(data), do: data["results"] || data["data"] || [], else: data
      assert is_list(list)
      entry = Enum.find(list, &(&1["id"] == plugin.id))
      assert entry
      assert entry["name"] == plugin.name
      assert Map.has_key?(entry, "state")

      # avg_duration_ms is nil (omitted) for a plugin with no runs.
      for key <- ["total_runs", "failure_rate"],
          do: assert(Map.has_key?(entry, key), "missing #{key}")

      encoded = Jason.encode!(data)
      refute encoded =~ "wasm_binary"
      refute encoded =~ "source_code"
    end

    test "clamps limit to 100", %{conn: conn} do
      for _ <- 1..3, do: create_plugin!()

      {error?, data, _} =
        conn |> call_tool("list_plugins", %{"limit" => 100_000}) |> tool_result()

      refute error?
      list = if is_map(data), do: data["results"] || data["data"] || [], else: data
      assert is_list(list)
      assert length(list) <= 100

      # The plug rewrites the argument itself.
      clamped =
        ChimeraRuntimeWeb.Plugs.McpLimits.clamp_limit(%{
          "method" => "tools/call",
          "params" => %{"name" => "list_plugins", "arguments" => %{"limit" => 100_000}}
        })

      assert clamped["params"]["arguments"]["limit"] == 100
    end
  end

  # -- inspect_execution_metrics --------------------------------------------

  describe "inspect_execution_metrics" do
    test "returns metrics for one plugin", %{conn: conn} do
      plugin = active_add_plugin!()

      {error?, data, _} =
        conn |> call_tool("inspect_execution_metrics", %{"id" => plugin.id}) |> tool_result()

      refute error?
      entry = if is_list(data), do: List.first(data), else: data
      entry = if is_map(entry) and is_map(entry["data"]), do: entry["data"], else: entry
      assert entry["id"] == plugin.id
      assert entry["name"] == plugin.name

      for key <- ["state", "total_runs", "failure_rate"],
          do: assert(Map.has_key?(entry, key), "missing #{key}")

      refute Jason.encode!(data) =~ "wasm_binary"
    end
  end

  # -- run_plugin ------------------------------------------------------------

  describe "run_plugin" do
    test "success on an active add plugin", %{conn: conn} do
      plugin = active_add_plugin!()

      {error?, data, _} =
        conn
        |> call_tool("run_plugin", %{
          "input" => %{"id" => plugin.id, "function_name" => "add", "args" => [2, 3]}
        })
        |> tool_result()

      refute error?
      assert %{"status" => "success", "output" => [5], "wall_time_us" => us} = data
      assert is_integer(us)
    end

    test "non-active plugin returns a tool-level error", %{conn: conn} do
      plugin = create_plugin!()

      {error?, data, _} =
        conn
        |> call_tool("run_plugin", %{
          "input" => %{"id" => plugin.id, "function_name" => "add", "args" => [2, 3]}
        })
        |> tool_result()

      assert error?
      refute is_map(data) and Map.has_key?(data, "status")
      refute is_map(data) and Map.has_key?(data, "output")
    end

    test "plugin whose timeout exceeds the MCP maximum is rejected", %{conn: conn} do
      plugin = active_add_plugin!()
      mcp_env(mcp_max_timeout_ms: plugin.timeout_ms - 1)

      {error?, data, _} =
        conn
        |> call_tool("run_plugin", %{
          "input" => %{"id" => plugin.id, "function_name" => "add", "args" => [2, 3]}
        })
        |> tool_result()

      assert error?
      refute is_map(data) and Map.has_key?(data, "output")
    end

    test "returns busy when run capacity is exhausted", %{conn: conn} do
      plugin = active_add_plugin!()
      put_env(:chimera_runtime, ChimeraRuntime.RunGuard, max_workers: 0)

      {error?, data, _} =
        conn
        |> call_tool("run_plugin", %{
          "input" => %{"id" => plugin.id, "function_name" => "add", "args" => [2, 3]}
        })
        |> tool_result()

      assert error?
      refute is_map(data) and Map.has_key?(data, "output")
    end
  end

  # Requirements 14.7 and 14.8: the message names the failure category.
  describe "run_plugin error categories" do
    test "messages name the category", %{conn: conn} do
      inactive = create_plugin!()
      args = fn id -> %{"input" => %{"id" => id, "function_name" => "add", "args" => [1, 2]}} end

      {true, data, _} = conn |> call_tool("run_plugin", args.(inactive.id)) |> tool_result()
      assert Jason.encode!(data) =~ "not_active"

      active = active_add_plugin!()
      put_env(:chimera_runtime, ChimeraRuntime.RunGuard, max_workers: 0)
      {true, data, _} = conn |> call_tool("run_plugin", args.(active.id)) |> tool_result()
      assert Jason.encode!(data) =~ "busy"
    end
  end

  # -- quarantine_plugin -----------------------------------------------------

  describe "quarantine_plugin" do
    test "quarantines, broadcasts a plugin_changed event, then fails the second time", %{
      conn: conn
    } do
      plugin = active_add_plugin!()
      ChimeraRuntimeWeb.Endpoint.subscribe("sandbox:plugins")

      {error?, _data, _} =
        conn |> call_tool("quarantine_plugin", %{"id" => plugin.id}) |> tool_result()

      refute error?
      assert {:ok, %{state: :quarantined}} = retry(fn -> Sandbox.get_plugin(plugin.id) end)

      assert_receive %Phoenix.Socket.Broadcast{event: "plugin_changed", payload: payload}, 2_000
      assert payload[:id] == plugin.id or payload["id"] == plugin.id

      {error2?, _, _} =
        conn |> call_tool("quarantine_plugin", %{"id" => plugin.id}) |> tool_result()

      assert error2?
    end
  end

  # -- guard -----------------------------------------------------------------

  describe "guard" do
    test "bad Origin returns 403", %{conn: conn} do
      conn = rpc_conn(conn, "tools/list", %{}, [{"origin", "http://evil.example"}])
      assert conn.status == 403
    end

    test "oversize valid JSON body returns 413", %{conn: conn} do
      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list",
          params: %{"pad" => String.duplicate("a", 70_000)}
        })

      assert byte_size(body) > 65_536
      conn = post_raw(conn, body)
      assert conn.status == 413
    end

    test "loopback is admitted without a token in test config", %{conn: conn} do
      conn = rpc_conn(conn, "tools/list", %{})
      assert conn.status == 200
    end

    test "with a token and loopback disabled: 401 without, 401 wrong, 200 with", %{conn: conn} do
      mcp_env(token: @token, allow_loopback_without_token?: false)

      assert rpc_conn(conn, "tools/list", %{}).status == 401

      assert rpc_conn(conn, "tools/list", %{}, [{"authorization", "Bearer wrong"}]).status ==
               401

      ok = rpc_conn(conn, "tools/list", %{}, [{"authorization", "Bearer " <> @token}])
      assert ok.status == 200
    end

    test "no token configured and loopback disabled returns 503", %{conn: conn} do
      base = Application.get_env(:chimera_runtime, :mcp, [])

      put_env(
        :chimera_runtime,
        :mcp,
        base |> Keyword.delete(:token) |> Keyword.put(:allow_loopback_without_token?, false)
      )

      assert rpc_conn(conn, "tools/list", %{}).status == 503
    end
  end
end

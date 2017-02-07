defmodule Bypass.Instance do
  use GenServer

  import Bypass.Utils

  # This is used to override the default behaviour of ranch_tcp
  # and limit the range of interfaces it will listen on to just
  # the loopback interface.
  @listen_ip {127, 0, 0, 1}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [opts])
  end

  def call(pid, request) do
    debug_log "call(#{inspect pid}, #{inspect request})"
    result = GenServer.call(pid, request, :infinity)
    debug_log "#{inspect pid} -> #{inspect result}"
    result
  end

  def cast(pid, request) do
    GenServer.cast(pid, request)
  end

  # GenServer callbacks

  def init([opts]) do
    # Get a free port from the OS
    case :ranch_tcp.listen(ip: @listen_ip, port: Keyword.get(opts, :port, 0)) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :erlang.port_close(socket)

        ref = make_ref()
        socket = do_up(port, ref)

        state = %{
          expect: %{},
          port: port,
          ref: ref,
          request_result: :ok,
          socket: socket,
          retained_plug: nil,
          caller_awaiting_down: nil,
          compile_routes: true,
          plug: nil
        }

        {:ok, state}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call(request, from, state) do
    debug_log [inspect(self()), " called ", inspect(request), " with state ", inspect(state)]
    do_handle_call(request, from, state)
  end

  def handle_cast({:retain_plug_process, caller_pid}, state) do
    debug_log [
      inspect(self()), " retain_plug_process ", inspect(caller_pid),
      ", retained_plug: ", inspect(state.retained_plug)
    ]
    {:noreply, Map.update!(state, :retained_plug, fn nil -> caller_pid end)}
  end

  defp do_handle_call(:port, _, %{port: port} = state) do
    {:reply, port, state}
  end

  defp do_handle_call(:up, _from, %{port: port, ref: ref, socket: nil} = state) do
    socket = do_up(port, ref)
    {:reply, :ok, %{state | socket: socket}}
  end
  defp do_handle_call(:up, _from, state) do
    {:reply, {:error, :already_up}, state}
  end

  defp do_handle_call(:down, _from, %{socket: nil} = state) do
    {:reply, {:error, :already_down}, state}
  end
  defp do_handle_call(:down, from, %{socket: socket, ref: ref} = state) when not is_nil(socket) do
    nil = state.caller_awaiting_down  # assertion
    if state.retained_plug != nil do
      # wait for the plug to finish
      {:noreply, %{state | caller_awaiting_down: from}}
    else
      do_down(ref, socket)
      {:reply, :ok, %{state | socket: nil}}
    end
  end

  defp do_handle_call({:plug, conn}, _from, state) do
    state = compile_routes(state)
    {:reply, state.plug, %{state | compile_routes: false}}
  end

  defp compile_routes(%{compile_routes: false} = state), do: state
  defp compile_routes(%{} = state) do
    nil
  end

  #defp do_handle_call({:expect, fun}, _from, state) when is_function(fun) do
  #  expectations = add_routes("<ANY>", "<ANY>", fun)
  #  state = Map.update!(state, :expect, &(Map.put(&1, :any, fun)))
  #  {:reply, expectations, %{state | compile_routes: true}}
  #end
  #defp do_handle_call({:expect, _}, _from, state) do
  #  expectations = add_routes("<ANY>", "<ANY>", nil)
  #  state = Map.update!(state, :expect, &(Map.put(&1, :any, nil)))
  #  {:reply, expectations, %{state | compile_routes: true}}
  #end
  defp do_handle_call({:expect, methods, paths, fun}, from, state) do
    macros = add_routes(methods, paths, fun)
    {:reply, Keyword.get_values(macros, :expectation), %{state | compile_routes: true}}
  end

  defp add_routes(methods, paths, fun) when not is_list(methods) do
    add_routes([methods], paths, fun)
  end
  defp add_routes(methods, paths, fun) when not is_list(paths) do
    add_routes(methods, [paths], fun)
  end
  defp add_routes(methods, paths, fun) do
    add_routes(methods, paths, fun, [])
  end
  defp add_routes([], [], fun, macros), do: macros
  defp add_routes([method | rest], paths, fun, macros) when length(rest) > 0 do
    add_routes([method], paths, fun, macros ++ add_routes(rest, paths, fun))
  end
  defp add_routes(method, [path | rest], fun, macros) when length(rest) > 0 do
    add_routes(method, [path], fun, macros ++ add_routes(method, rest, fun))
  end
  defp add_routes([method], [path], fun, macros) do
    expectation = quote bind_quoted: [method: method, path: path] do
      IO.puts "Call #{method} #{path} at least once"
      assert method == "YOURMOM"
      assert path == "ELIXIR"
    end

    route = quote bind_quoted: [method: method, path: path] do
      def call(%{method: method, request_path: path} = conn, pid) do
        fun.(conn)
      end 
    end

    #route = case method do
    #  #"<any"> ->
    #  #  quote match _, do: fun
    #  method ->
    #    quote unquote(method) "unquote(route)", do: fun
    add_routes([], [], fun, macros ++ [{:expectation, expectation}, {:route, route}])
  end

  defp do_handle_call({:put_expect_result, result}, _from, state) do
    updated_state =
      %{state | request_result: result}
      |> Map.put(:retained_plug, nil)
      |> dispatch_awaiting_caller()
    {:reply, :ok, updated_state}
  end

  defp do_handle_call(:on_exit, _from, state) do
    updated_state =
      case state do
        %{socket: nil} -> state
        %{socket: socket, ref: ref} ->
          do_down(ref, socket)
          %{state | socket: nil}
      end
    {:stop, :normal, state.request_result, updated_state}
  end

  defp do_up(port, ref) do
    plug_opts = [self()]
    {:ok, socket} = :ranch_tcp.listen(ip: @listen_ip, port: port)
    cowboy_opts = [ref: ref, acceptors: 5, port: port, socket: socket]
    {:ok, _pid} = Plug.Adapters.Cowboy.http(Bypass.Plug, plug_opts, cowboy_opts)
    socket
  end

  defp do_down(ref, socket) do
    :ok = Plug.Adapters.Cowboy.shutdown(ref)

    # `port_close` is synchronous, so after it has returned we _know_ that the socket has been
    # closed. If we'd rely on ranch's supervisor shutting down the acceptor processes and thereby
    # killing the socket we would run into race conditions where the socket port hasn't yet gotten
    # the EXIT signal and would still be open, thereby breaking tests that rely on a closed socket.
    case :erlang.port_info(socket, :name) do
      :undefined -> :ok
      _ -> :erlang.port_close(socket)
    end
  end

  defp dispatch_awaiting_caller(
    %{retained_plug: retained_plug, caller_awaiting_down: caller, socket: socket, ref: ref} = state)
  do
    if retained_plug == nil and caller != nil do
      do_down(ref, socket)
      GenServer.reply(caller, :ok)
      %{state | socket: nil, caller_awaiting_down: nil}
    else
      state
    end
  end
end

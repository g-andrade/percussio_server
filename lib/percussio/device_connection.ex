defmodule Percussio.DeviceConnection do
  use GenServer
  require Logger
  require Record

  @behaviour :ranch_protocol

  ## ------------------------------------------------------------------
  ## Macro-like Attribute Definitions
  ## ------------------------------------------------------------------

  @max_inbound_unconsumed_data_messages 10

  ## ------------------------------------------------------------------
  ## Type and Record Definitions
  ## ------------------------------------------------------------------

  Record.defrecord(:state,
    id: nil,
    transport: nil,
    tags: nil,
    socket: nil,
    in_buf: <<>>,
    device_id: nil,
    role: nil,
    march_pid: nil
  )

  Record.defrecord(:socket_tags,
    data: nil,
    passive: nil,
    closed: nil,
    error: nil
  )

  ## ------------------------------------------------------------------
  ## :ranch_protocol Function Definitions
  ## ------------------------------------------------------------------

  @impl true
  def start_link(accept_ref, _listen_socket, transport, protocol_opts) do
    init_args = %{
      accept_ref: accept_ref,
      transport: transport,
      protocol_opts: protocol_opts
    }
    :proc_lib.start_link(__MODULE__, :proc_lib_init, [init_args])
  end

  def proc_lib_init(args) do
    Process.flag(:trap_exit, true) # always call :terminate/2
    %{accept_ref: accept_ref} = args
    :proc_lib.init_ack({:ok, self()})

    {:ok, socket} = :ranch.handshake(accept_ref)
    state = initial_state(args, socket)

    case maybe_update_state_id(state) do
      {:ok, state} ->
        Logger.info("[#{id(state)}] Connected")
        set_socket_opts(state, [packet: :line])
        make_socket_active(state)
        :gen_server.enter_loop(__MODULE__, [], state)
      {:error, :closed} ->
        exit(:normal)
    end
  end

  ## ------------------------------------------------------------------
  ## GenServer Function Definitions
  ## ------------------------------------------------------------------

  @impl true
  def init(_never_called) do
    :erlang.error(:notsup)
  end

  @impl true
  def handle_call(call, from, state) do
    {:stop, {:unexpected_call, from, call}, state}
  end

  @impl true
  def handle_cast(cast, state) do
    {:stop, {:unexpected_cast, cast}, state}
  end

  @impl true
  def handle_info({:play_beat, duration}, state) do
    send_message_to_peer("BEAT #{duration}", state)
    {:noreply, state}
  end

  def handle_info({tag, socket, data}, state(tags: socket_tags(data: tag), socket: socket) = state) do
    handle_inbound_data(data, state)
  end

  def handle_info({tag, socket}, state(tags: socket_tags(passive: tag), socket: socket) = state) do
    handle_socket_passivity(state)
  end

  def handle_info({tag, socket}, state(tags: socket_tags(closed: tag), socket: socket) = state) do
    handle_socket_closure(state)
  end

  def handle_info({tag, socket, reason}, state(tags: socket_tags(error: tag), socket: socket) = state) do
    handle_socket_error(reason, state)
  end

  def handle_info(info, state) do
    {:stop, {:unexpected_info, info}, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("[#{id(state)}] Disconnected")
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Initialization and Socket Management
  ## ------------------------------------------------------------------

  defp initial_state(args, socket) do
    %{transport: transport} = args
    tags = socket_message_tags(transport)
    state(
      transport: transport,
      tags: tags,
      socket: socket)
  end

  defp socket_message_tags(transport) do
    case transport do
      :ranch_tcp ->
        socket_tags(
          data: :tcp,
          passive: :tcp_passive,
          closed: :tcp_closed,
          error: :tcp_error)
      :ranch_ssl ->
        socket_tags(
          data: :ssl,
          passive: :ssl_passive,
          closed: :ssl_closed,
          error: :ssl_error)
    end
  end

  defp maybe_update_state_id(state(id: nil, device_id: nil) = state) do
    state(transport: transport, socket: socket) = state
    case transport.peername(socket) do
      {:ok, {remote_ip_address, remote_port}} ->
        scheme = id_scheme(transport)
        remote_ip_address_charlist = :inet.ntoa(remote_ip_address)
        remote_ip_address_str = List.to_string(remote_ip_address_charlist)
        id = "#{scheme}://#{remote_ip_address_str}:#{remote_port}"
        {:ok, state(state, id: id)}
      {:error, _} = error ->
        error
    end
  end

  defp maybe_update_state_id(state(id: _, device_id: <<device_id :: bytes>>) = state) do
    state(role: role) = state
    id = "#{Percussio.Util.logger_safe_string(role)}|#{Percussio.Util.logger_safe_string(device_id)}"
    state(state, id: id)
  end

  defp maybe_update_state_id(state) do
    state
  end

  defp id_scheme(transport) do
    case transport do
      :ranch_tcp ->
        "redis"
      :ranch_ssl ->
        "rediss"
    end
  end

  defp make_socket_active(state) do
    socket_opts = [active: @max_inbound_unconsumed_data_messages]
    set_socket_opts(state, socket_opts)
  end

  defp set_socket_opts(state, opts) do
    state(transport: transport, socket: socket) = state
    case transport.setopts(socket, opts) do
      :ok -> :ok
      {:error, :closed} ->
        # we'll be notified of this asynchronously
        :ok
    end
  end

  defp id(state(id: id)) do
    id
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Inbound Socket Events
  ## ------------------------------------------------------------------

  defp handle_inbound_data(data, state) do
    Logger.debug("[#{id(state)}] Received #{byte_size(data)} inbound byte(s)")
    command_size = byte_size(data) - 1
    <<command :: bytes-size(command_size), ?\n>> = data
    handle_inbound_command(command, state)
  end

  defp handle_inbound_command(command, state) do
    case :binary.split(command, " ", [:global, :trim_all]) do
      ["REGISTER", device_id, role] ->
        handle_register_command(device_id, role, state)
      ["PLAY"] ->
        handle_play_command(state)
      ["STOP"] ->
        handle_stop_command(state)
      invalid_command ->
        Logger.error("[#{id(state)}] Received invalid command: #{inspect invalid_command}")
        {:stop, :normal, state}
    end
  end

  defp handle_socket_passivity(state) do
    make_socket_active(state)
    {:noreply, state}
  end

  defp handle_socket_closure(state) do
    {:stop, :normal, state}
  end

  defp handle_socket_error(reason, state) do
    Logger.info("[#{id(state)}] Connection error: #{inspect reason}")
    {:stop, :normal, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Register Command
  ## ------------------------------------------------------------------

  defp handle_register_command(device_id, role, state(device_id: nil) = state) do
    case Percussio.Util.validate_and_normalize_nonempty_strings([device_id: device_id, role: role]) do
      [device_id: device_id, role: role] ->
        state = state(state, device_id: device_id, role: role)
        Logger.info("[#{id(state)}] Device #{inspect device_id} registered for role #{inspect role}")
        state = maybe_update_state_id(state)
        {:ok, _, march_pid} = Percussio.March.register_output(role)
        state = state(state, march_pid: march_pid)
        {:noreply, state}

      {:error, :device_id} ->
        Logger.error("[#{id(state)}] Invalid device id: #{inspect device_id}")
        {:stop, :normal, state}
      {:error, :role} ->
        Logger.error("[#{id(state)}] Invalid role: #{inspect role}")
        {:stop, :normal, state}
    end
  end

  defp handle_register_command(device_id, _role, state) do
    Logger.error("[#{id(state)}] Unexpected device re-registration: #{inspect device_id}")
    {:stop, :normal, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Play Command
  ## ------------------------------------------------------------------

  defp handle_play_command(state(march_pid: march_pid) = state)
  when march_pid !== nil do
    Logger.info("[#{id(state)}] Device wants for the march to be played")
    case Percussio.March.play(march_pid) do
      :ok ->
        {:noreply, state}
      {:error, :already_playing} ->
        Logger.warn("[#{id(state)}] March is already playing")
        {:noreply, state}
    end
  end

  defp handle_play_command(state) do
    Logger.error("[#{id(state)}] Device wants for the march to be played but it hasn't registered yet")
    {:stop, :normal, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Stop Command
  ## ------------------------------------------------------------------

  defp handle_stop_command(state(march_pid: march_pid) = state)
  when march_pid !== nil do
    Logger.info("[#{id(state)}] Device wants for the march to be stopped")
    case Percussio.March.stop(march_pid) do
      :ok ->
        {:noreply, state}
      {:error, :already_stopped} ->
        Logger.warn("[#{id(state)}] March is already stopped")
        {:noreply, state}
    end
  end

  defp handle_stop_command(state) do
    Logger.error("[#{id(state)}] Device wants for the march to be stopped but it hasn't registered yet")
    {:stop, :normal, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Outbound Messages
  ## ------------------------------------------------------------------

  defp send_message_to_peer(data, state) do
    state(transport: transport, socket: socket) = state
    data = [data, ?\n]
    case transport.send(socket, data) do
      :ok -> 
        :ok
      {:error, :closed} ->
        # we'll be notified of this asynchronously
        :ok
    end
  end
end

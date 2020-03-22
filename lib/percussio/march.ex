defmodule Percussio.March do
  use GenServer
  require Logger
  require Record

  ## ------------------------------------------------------------------
  ## Macro-like Attribute Definitions
  ## ------------------------------------------------------------------

  @server __MODULE__
  @march_filename "march001.txt"

  ## ------------------------------------------------------------------
  ## Type and Record Definitions
  ## ------------------------------------------------------------------

  Record.defrecord(:state,
    global_params: nil,
    next_bars: nil,
    played_bars: [], # accumulated in reverse order
    outputs: %{}, # keyed by their monitors
    outputs_per_role: %{},
    playing: false,
    current_bar_timers: [],
    next_bar_timer: nil
  )

  Record.defrecord(:bar_definition,
    beats: []
  )

  Record.defrecord(:beat_definition,
    start_after: nil,
    duration: nil,
    role: nil
  )

  Record.defrecord(:output,
    pid: nil,
    role: nil
  )

  ## ------------------------------------------------------------------
  ## API Function Definitions
  ## ------------------------------------------------------------------

  def child_spec() do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: @server)
  end

  def register_output(role) do
    GenServer.call(@server, {:register_output, role}, :infinity)
  end

  def play(pid) do
    GenServer.call(pid, :play, :infinity)
  end

  def stop(pid) do
    GenServer.call(pid, :stop, :infinity)
  end

  ## ------------------------------------------------------------------
  ## GenServer Function Definitions
  ## ------------------------------------------------------------------

  @impl true
  def init([]) do
    state = initial_state()
    {:ok, state}
  end

  @impl true
  def handle_call({:register_output, role}, {pid, _}, state) do
    handle_output_registration(role, pid, state)
  end

  def handle_call(:play, _, state) do
    handle_play_call(state)
  end

  def handle_call(:stop, _, state) do
    handle_stop_call(state)
  end

  def handle_call(call, from, state) do
    {:stop, {:unexpected_call, from, call}, state}
  end

  @impl true
  def handle_cast(cast, state) do
    {:stop, {:unexpected_cast, cast}, state}
  end

  @impl true
  def handle_info({:play_bar, timestamp, bar_duration_in_millis}, state) do
    state = maybe_play_bar(timestamp, bar_duration_in_millis, state)
    {:noreply, state}
  end

  def handle_info({:"DOWN", ref, :process, _, _}, state) do
    handle_monitored_process_death(ref, state)
  end

  def handle_info(info, state) do
    {:stop, {:unexpected_info, info}, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Initialization
  ## ------------------------------------------------------------------

  defp initial_state() do
    march_filename = @march_filename
    Logger.info("Loading march from #{inspect march_filename}...")
    {global_params, bar_definitions} = parse_march_definition(march_filename)

    %{tempo: tempo} = global_params
    bar_duration_in_secs = 60 / tempo
    rounded_march_duration_in_secs = round(bar_duration_in_secs * length(bar_definitions))
    displayed_march_duration_minutes = div(rounded_march_duration_in_secs, 60)
    displayed_march_duration_seconds = rem(rounded_march_duration_in_secs, 60)
    Logger.info(
      "March loaded: #{tempo}bpm, #{length(bar_definitions)} bars"
      <> ", #{displayed_march_duration_minutes}m#{displayed_march_duration_seconds}s")

    state(global_params: global_params, next_bars: bar_definitions)
  end

  defp parse_march_definition(filename) do
    bin_definition = File.read!(filename)
    lines = :binary.split(bin_definition, ["\n", "\r"], [:global, :trim_all])
    lines = Enum.filter(lines, fn line -> String.length(line) > 0 end)
    {global_params, lines} = parse_march_definition_global_params(lines)
    {bar_definitions, trailing_lines} = parse_march_definition_bars(lines, global_params)
    trailing_lines == [] or exit({:unparsed_lines, trailing_lines})
    {global_params, bar_definitions}
  end

  ## March Definition: Global Parameters

  defp parse_march_definition_global_params(lines) do
    default_global_params = %{tempo: 60}
    parse_march_definition_global_params_recur(lines, default_global_params)
  end

  defp parse_march_definition_global_params_recur([line | next] = lines, acc) do
    case line do
      "tempo=" <> bin_tempo ->
        {tempo, ""} = Integer.parse(bin_tempo)
        parse_march_definition_global_params_recur(next, %{acc | tempo: tempo})
      "*" <> _ ->
        {acc, lines}
      end
  end

  defp parse_march_definition_global_params_recur([], acc) do
    {acc, []}
  end

  ## march Definition: Bars

  defp parse_march_definition_bars(lines, global_params) do
    parse_march_definition_bars_recur(lines, global_params, [])
  end

  defp parse_march_definition_bars_recur(["*bar" <> bin_opts | next], global_params, acc) do
    split_bin_opts = :binary.split(bin_opts, " ", [:global, :trim_all])
    opts = Enum.map(split_bin_opts, fn bin_opt -> :binary.split(bin_opt, "=", [:global, :trim_all]) end)
    times =
      case opts do # TODO support generic list of options
        [["x" <> bin_repeat]] ->
          {repeat, ""} = Integer.parse(bin_repeat)
          (repeat >= 0) or exit({:repeat_less_than_zero, bin_opts})
          1 + repeat
        [] ->
          1
      end

    {beat_definitions, next} = parse_march_definition_bar_beats(next, global_params)
    bar_definition = bar_definition(beats: beat_definitions)
    bar_definitions = List.duplicate(bar_definition, times)
    acc = bar_definitions ++ acc
    parse_march_definition_bars_recur(next, global_params, acc)
  end

  defp parse_march_definition_bars_recur(lines, _global_params, acc) do
    bars = Enum.reverse(acc)
    {bars, lines}
  end

  ## March Definition: Beats

  defp parse_march_definition_bar_beats(lines, global_params) do
    parse_march_definition_bar_beats_recur(lines, global_params, [])
  end

  defp parse_march_definition_bar_beats_recur([<<first_char, _ :: bytes>> = line | next], global_params, acc)
  when first_char != ?*
  do
    [role, bin_beats] = :binary.split(line, ":", [:global, :trim_all])
    split_bin_beats = :binary.split(bin_beats, [",", " "], [:global, :trim_all])
    beat_definitions = Enum.map(split_bin_beats, &parse_march_definition_bar_beat(role, &1, global_params))
    beats_overlap?(beat_definitions) and exit({:beats_overlap, split_bin_beats})
    acc = beat_definitions ++ acc
    parse_march_definition_bar_beats_recur(next, global_params, acc)
  end

  defp parse_march_definition_bar_beats_recur(lines, _global_params, acc) do
    beat_definitions = Enum.sort(acc)
    {beat_definitions, lines}
  end

  ## March Definition: Beat Definition

  defp parse_march_definition_bar_beat(role, bin_beat, global_params) do
    [bin_fraction | bin_attributes] = :binary.split(bin_beat, "-", [:global, :trim_all])
    stacatto = Enum.member?(bin_attributes, "s")

    [bin_numerator, bin_denominator] = :binary.split(bin_fraction, "/", [:global, :trim_all])
    {numerator, ""} = Integer.parse(bin_numerator)
    {denominator, ""} = Integer.parse(bin_denominator)
    (numerator >= 0) or exit({:numerator_less_than_zero, bin_fraction})
    (denominator > 0) or exit({:denominator_less_than_one, bin_fraction})

    default_duration_ratio = 1 / denominator
    duration_ratio =
      cond do
        stacatto ->
          default_duration_ratio * 0.5
        not stacatto ->
          default_duration_ratio
      end

    start_ratio = numerator / denominator
    (start_ratio <= 1) or exit({:beat_start_overtakes_bar_termination, bin_fraction})
    (start_ratio + duration_ratio <= 1)
    or exit({:beat_finish_overtakes_bar_termination, bin_fraction <> " + " <> Float.to_string(duration_ratio)})

    %{tempo: tempo} = global_params
    bar_duration_in_millis = 1000 * 60 / tempo
    start_after = trunc(start_ratio * bar_duration_in_millis)
    duration = trunc(duration_ratio * bar_duration_in_millis)
    beat_definition(role: role, start_after: start_after, duration: duration)
  end

  defp beats_overlap?(sorted_beat_definitions) do
    case sorted_beat_definitions do
      [beat_definition(start_after: prev_start_after, duration: prev_duration)
        | [beat_definition(start_after: next_start_after) | _] = next
      ] ->
        (prev_start_after + prev_duration) > next_start_after or beats_overlap?(next)
      [beat_definition()] ->
        false
      [] ->
        false
    end
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Output Registration and Unregistration
  ## ------------------------------------------------------------------

  defp handle_output_registration(role, pid, state) do
    state(outputs: outputs, outputs_per_role: outputs_per_role) = state
    mon = Process.monitor(pid)
    new_output = output(pid: pid, role: role)
    Logger.info("Output registered for role #{inspect role} (pid: #{inspect pid})")

    outputs = Map.put(outputs, mon, new_output)
    outputs_for_same_role = Map.get(outputs_per_role, role, [])
    outputs_for_same_role = [mon | outputs_for_same_role]
    outputs_per_role = Map.put(outputs_per_role, role, outputs_for_same_role)
    state = state(state, outputs: outputs, outputs_per_role: outputs_per_role)
    {:reply, {:ok, mon, self()}, state}
  end

  defp handle_monitored_process_death(ref, state) do
    state(outputs: outputs, outputs_per_role: outputs_per_role) = state
    {output, outputs} = Map.pop(outputs, ref)
    output(pid: pid, role: role) = output
    Logger.info("Output unregistered for role #{inspect role} (pid: #{inspect pid})")

    outputs_per_role =
      case Map.fetch!(outputs_per_role, role) do
        [^ref] ->
          Map.delete(outputs_per_role, role)
        [_,_|_] = outputs_for_same_role ->
          outputs_for_same_role = List.delete(outputs_for_same_role, ref)
          Map.replace!(outputs_per_role, role, outputs_for_same_role)
      end
    state = state(state, outputs: outputs, outputs_per_role: outputs_per_role)
    {:noreply, state}
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Play
  ## ------------------------------------------------------------------

  defp handle_play_call(state) do
    state(playing: playing) = state
    case playing do
      false ->
        handle_valid_play_call(state)
      true ->
        {:reply, {:error, :already_playing}, state}
    end
  end

  defp handle_valid_play_call(state) do
    state(global_params: global_params) = state
    %{tempo: tempo} = global_params
    bar_duration_in_millis = trunc(1000 * 60 / tempo)
    now_ts = System.monotonic_time(:millisecond)
    Logger.info("Started playing")

    next_bar_timer = Process.send_after(self(), {:play_bar, now_ts, bar_duration_in_millis}, 0)
    state = state(state, playing: true, next_bar_timer: next_bar_timer)
    {:reply, :ok, state}
  end

  defp maybe_play_bar(timestamp, bar_duration_in_millis, state) do
    state(next_bars: next_bars) = state
    case next_bars do
      [current_bar | next_bars] ->
        play_bar(timestamp, bar_duration_in_millis, current_bar, next_bars, state)
      [] ->
        Logger.info("Finished playing")
        state(played_bars: played_bars) = state
        state(state,
          next_bars: Enum.reverse(played_bars),
          played_bars: [],
          playing: false, current_bar_timers: [], next_bar_timer: nil)
    end
  end

  defp play_bar(timestamp, bar_duration_in_millis, current_bar, next_bars, state) do
    state(played_bars: played_bars, outputs: outputs, outputs_per_role: outputs_per_role) = state
    Logger.info("Playing bar ##{length(played_bars) + 1}")

    bar_definition(beats: beats) = current_bar
    Enum.each(beats,
      fn beat_definition(start_after: start_after, duration: duration, role: role) ->
        output_refs = Map.get(outputs_per_role, role, [])
        output_states = Map.values( Map.take(outputs, output_refs) )
        output_pids = for output(pid: pid) <- output_states, do: pid
        Enum.each(output_pids,
          fn pid ->
            Process.send_after(pid, {:play_beat, duration}, start_after)
          end)
      end)

    next_bar_ts = timestamp + bar_duration_in_millis
    next_bar_timer = Process.send_after(
      self(), {:play_bar, next_bar_ts, bar_duration_in_millis},
      next_bar_ts, [abs: true])

    played_bars = [current_bar | played_bars]
    state(state, next_bars: next_bars, played_bars: played_bars, next_bar_timer: next_bar_timer)
  end

  ## ------------------------------------------------------------------
  ## Private Function Definitions - Stop
  ## ------------------------------------------------------------------

  defp handle_stop_call(state) do
    state(playing: playing) = state
    case playing do
      true ->
        handle_valid_stop_call(state)
      false ->
        {:reply, {:error, :already_stopped}, state}
    end
  end

  defp handle_valid_stop_call(state) do
    state(
      next_bars: next_bars,
      played_bars: played_bars,
      current_bar_timers: current_bar_timers,
      next_bar_timer: next_bar_timer) = state

    Enum.each(current_bar_timers, &Process.cancel_timer/1)
    :true = cancel_next_bar_timer_or_flush_its_message(next_bar_timer)
    Logger.info("Stopped playing")

    next_bars = Enum.reverse(played_bars, next_bars)
    state = state(state,
      next_bars: next_bars,
      played_bars: [],
      playing: false,
      current_bar_timers: [],
      next_bar_timer: nil)

    {:reply, :ok, state}
  end

  defp cancel_next_bar_timer_or_flush_its_message(next_bar_timer) do
    is_integer( Process.cancel_timer(next_bar_timer) )
    or receive do
      {:play_bar, _, _} ->
        true
    after
      0 -> false
    end
  end
end

defmodule SMPPEX.Time.Mock do
  @server __MODULE__
  @behaviour :gen_statem

  alias __MODULE__, as: Data

  defmodule TimerMsg do
    defstruct [:pid, :time, :message, :ref]
  end

  defstruct time: 0,
            unfreeze_time: 0,
            timer_messages: [],
            timer_message_history: []

  def start_link() do
    start_link(:running)
  end

  def start_link(state) do
    :gen_statem.start_link({:local, @server}, __MODULE__, [state], [])
  end

  # Time functions

  def monotonic_time(unit) do
    :erlang.convert_time_unit(monotonic_time(), :native, unit)
  end

  def monotonic_time() do
    :gen_statem.call(@server, :monotonic_time)
  end

  def send_after(pid, time, message) do
    :gen_statem.call(@server, {:send_after, pid, time, message})
  end

  def cancel_timer(ref) do
    :gen_statem.call(@server, {:cancel_timer, ref})
  end

  # Mock functions

  def warp_by(timer_interval) do
    warp_by(timer_interval, :millisecond)
  end

  def warp_by(timer_interval, unit) do
    :gen_statem.call(@server, {:warp_by, timer_interval, unit})
  end

  def freeze() do
    :gen_statem.call(@server, :freeze)
  end

  def unfreeze() do
    :gen_statem.call(@server, :unfreeze)
  end

  # :gen_statem callbacks

  def callback_mode(), do: :state_functions

  def init([:frozen]) do
    time = :erlang.monotonic_time()

    {:ok, :frozen,
     %Data{
       time: time
     }}
  end

  def init([:running]) do
    time = :erlang.monotonic_time()

    {:ok, :running,
     %Data{
       time: time,
       unfreeze_time: time
     }}
  end

  # States: Running, Frozen, Rescheduling

  ## Frosen state

  def frozen({:call, from}, :monotonic_time, data) do
    {:keep_state_and_data, [{:reply, from, mocked_monotonic_time(:frozen, data)}]}
  end

  def frozen({:call, from}, :freeze, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def frozen({:call, from}, :unfreeze, data) do
    new_data = %Data{
      data
      | unfreeze_time: :erlang.monotonic_time()
    }

    {:next_state, :rescheduling, new_data,
     [{:reply, from, :ok}, {:next_event, :internal, :reschedule}]}
  end

  def frozen({:call, from}, {:send_after, pid, interval, message}, data) do
    msg = make_timer_msg(:frozen, data, pid, interval, message)

    new_data = %Data{
      data
      | timer_messages: insert_msg(msg, data.timer_messages)
    }

    {:keep_state, new_data, [{:reply, from, msg.ref}]}
  end

  def frozen({:call, from}, {:warp_by, timer_interval, unit}, data) do
    new_data = warp_by(:frozen, data, timer_interval, unit)
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  ## Running state

  def running({:call, from}, {:cancel_timer, ref}, data) do
    {_msg, new_messages} = take_msg(ref, data.timer_messages)

    new_data = %Data{
      data
      | timer_messages: new_messages
    }

    {:next_state, :rescheduling, new_data,
     [{:reply, from, :ok}, {:next_event, :internal, :reschedule}]}
  end

  def running({:call, from}, :monotonic_time, data) do
    {:keep_state_and_data, [{:reply, from, mocked_monotonic_time(:running, data)}]}
  end

  def running({:call, from}, :freeze, data) do
    new_data = %Data{
      data
      | time: mocked_monotonic_time(:running, data),
        unfreeze_time: nil
    }

    {:next_state, :frozen, new_data, [{:reply, from, :ok}]}
  end

  def running({:call, from}, :unfreeze, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def running({:call, from}, {:send_after, pid, interval, message}, data) do
    msg = make_timer_msg(:running, data, pid, interval, message)

    new_data = %Data{
      data
      | timer_messages: insert_msg(msg, data.timer_messages)
    }

    {:next_state, :rescheduling, new_data,
     [{:reply, from, msg.ref}, {:next_event, :internal, :reschedule}]}
  end

  def running(:state_timeout, {:send_msg, ref}, data) do
    new_data = send_msg(data, ref)
    {:next_state, :running, new_data, next_event_timer(new_data)}
  end

  def running({:call, from}, {:warp_by, timer_interval, unit}, data) do
    new_data = warp_by(:running, data, timer_interval, unit)

    {:next_state, :rescheduling, new_data,
     [{:reply, from, :ok}, {:next_event, :internal, :reschedule}]}
  end

  ## Rescheduling state

  def rescheduling(:internal, :reschedule, data) do
    {:next_state, :running, data, next_event_timer(data)}
  end

  # Private functions

  defp warp_by(state, data, timer_interval, unit) do
    timer_interval = :erlang.convert_time_unit(timer_interval, unit, :native)
    real_monotonic_time = :erlang.monotonic_time()
    new_time = mocked_monotonic_time(state, data, real_monotonic_time) + timer_interval

    msgs = Enum.filter(data.timer_messages, fn msg -> msg.time <= new_time end)

    new_data =
      List.foldl(msgs, data, fn msg, data_acc ->
        send_msg(data_acc, msg.ref)
      end)

    %Data{
      new_data
      | time: new_time,
        unfreeze_time: real_monotonic_time
    }
  end

  def send_msg(data, ref) do
    {msg, new_messages} = take_msg(ref, data.timer_messages)

    timer_message_history =
      if msg do
        send(msg.pid, msg.message)
        [msg | data.timer_message_history]
      else
        data.timer_message_history
      end

    %Data{data | timer_messages: new_messages, timer_message_history: timer_message_history}
  end

  defp make_timer_msg(state, data, pid, time_interval, message) do
    ref = :erlang.make_ref()

    time =
      mocked_monotonic_time(state, data) +
        :erlang.convert_time_unit(time_interval, :millisecond, :native)

    %TimerMsg{
      pid: pid,
      time: time,
      message: message,
      ref: ref
    }
  end

  defp mocked_monotonic_time(state, data) do
    mocked_monotonic_time(state, data, :erlang.monotonic_time())
  end

  defp mocked_monotonic_time(:frozen, data, _real_monotonic_time) do
    data.time
  end

  defp mocked_monotonic_time(:running, data, real_monotonic_time) do
    real_monotonic_time - data.unfreeze_time + data.time
  end

  defp next_event_timer(%Data{timer_messages: []}) do
    []
  end

  defp next_event_timer(%Data{timer_messages: [msg | _]} = data) do
    interval =
      (msg.time - mocked_monotonic_time(:running, data))
      |> to_non_negative()
      |> :erlang.convert_time_unit(:native, :millisecond)

    [{:state_timeout, interval, {:send_msg, msg.ref}}]
  end

  defp insert_msg(new_msg, []) do
    [new_msg]
  end

  defp insert_msg(new_msg, [msg | rest]) do
    if new_msg.time < msg.time do
      [new_msg | [msg | rest]]
    else
      [msg | insert_msg(new_msg, rest)]
    end
  end

  defp take_msg(ref, msgs) do
    case Enum.split_with(msgs, fn msg -> msg.ref == ref end) do
      {[], msgs} -> {nil, msgs}
      {[msg], msgs} -> {msg, msgs}
    end
  end

  defp to_non_negative(number) do
    if number < 0 do
      0
    else
      number
    end
  end
end

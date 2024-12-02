defmodule PylonEmu do
  require Logger

  defmodule BatState do
    defstruct  [:can_port,                          # pid to CAN process
                watchdog_counter: 0,
                temperature_max_dC: 0,              # INT16   in deci °C
                temperature_min_dC: 0,              # INT16   in deci °C
                voltage_dV: 0,                      # UINT16  in deci volt
                current_dA: 0,                      # INT16   in deci ampere
                reported_soc: 0,                    # UINT16  integer-percent x 100. 9550 = 95.50%
                soh_pptt: 9550,                     # UINT16  integer-percent x 100. 9550 = 95.50%
                max_charge_current_dA: 0,           # UINT16  in deci ampere
                max_discharge_current_dA: 0,        # UINT16  in deci ampere
                max_cell_voltage_mV: 0,             # UINT16  in milli volt
                min_cell_voltage_mV: 0,             # UINT16  in milli volt
                bms_status: 0,                      # UINT8   0x00 = SLEEP/FAULT 0x01 = Charge 0x02 = Discharge 0x03 = Idle
                disable_chg_dischg: <<0x00, 0x00,0x00, 0x00>>,      # Set to <<0xAA, 0xAA, 0xAA, 0xAA>> to disable battery, else <<0x00, 0x00, 0x00, 0x00>>
                msg_4260: <<0x00, 0x02, 0x00, 0x03, 0x27, 0x74, 0xC7, 0xAC>>, # ??
                msg_4290: <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>, # ??
                msg_7310: <<0x00, 0x00, 0x01, 0x01, 0x01, 0x02, 0x00, 0x01>>, # ??
                ## Bellow are Constants that should be chnaged
                max_design_voltage_dV: 5000,           # UINT16  in deci volt
                min_design_voltage_dV: 2500,           # UINT16  in deci volt
                max_cell_voltage_lim_mV: 4300,         # UINT16  in milli volt
                min_cell_voltage_lim_mV: 2700,         # UINT16  in milli volt
                max_cell_voltage_deviation_mV: 500,    # UINT16  in milli volt
                total_cell_amount: 120,                # UINT16
                modules_in_series: 4,                  # UINT8
                cells_per_module: 30,                  # UINT8
                voltage_level: 384,                    # UINT8
                ah_capacity: 37                        # UINT8
              ]
  end

  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(can_if) do
    {:ok, can_port} = Ng.Can.start_link
    Ng.Can.open(can_port, can_if, sndbuf: 1024, rcvbuf: 106496)
    Ng.Can.await_read(can_port)
    Process.send_after(self(), :send100, 100)
    Process.send_after(self(), :send1000, 1000)

    {:ok, %BatState{can_port: can_port}}
  end

  @impl true
  def handle_info({:can_frames, _interface_name, recvd_frames}, state) do
    state = parse_msg(state, recvd_frames)
    Ng.Can.await_read(state.can_port)
    {:noreply, state}
  end

  def handle_info(:send100, state) do
    ## Write every 100 ms here
    state = cond do
      state.disable_chg_dischg != <<0xAA, 0xAA, 0xAA, 0xAA>> ->
        %{state | bms_status: 0}
      state.current_dA < 0 ->
        %{state | bms_status: 1}
      state.current_dA > 0 ->
        %{state | bms_status: 2}
      state.current_dA == 0 ->
        %{state | bms_status: 3}
    end

    build100frames(state)
    Process.send_after(self(), :send100, 100)
    {:noreply, state}
  end

  def handle_info(:send1000, state) do
    ## Write every 1000 ms here
    Logger.info("#{inspect state}")
    <<int::unsigned-integer-size(16)>>=<<(state.watchdog_counter + 1)::unsigned-integer-size(16)>>
    state = %{state | watchdog_counter: int}
    build1000frames(state)
    Process.send_after(self(), :send1000, 1000)
    {:noreply, state}
  end

  def parse_msg(state, []), do: state

  def parse_msg(state, [recvd_frame | t]) do
    {id, data} = recvd_frame
    <<extended::size(1), _rtr::size(1), id::size(30)>> = <<id::integer-size(32)>>
    new_state = case {extended, id}  do
      {1, 0x4200} ->
        <<val::size(8), _::binary>> = data
        case val do
          0x00 ->
            Logger.info("Sending response to inverter after reciving #{inspect val}")
            response00(state)
          0x02 ->
            Logger.info("Sending response to inverter after reciving #{inspect val}")
            response02(state)
          _ ->
            Logger.info("No Resonse to inverter sent, recived #{inspect val}")
        end

      {0, x} when x in 0x100..0x199 ->
        Logger.info("Message 0x1XX recived")
        parse1xx(state, data)

      {0, x} when x in 0x200..0x299 ->
        Logger.info("Message 0x2XX recived")
        parse2xx(state, data)

      {0, x} when x in 0x300..0x399 ->
        Logger.info("Message 0x3XX recived")
        parse3xx(state, data)

      {0, x} when x in 0x400..0x499 ->
        Logger.info("Message 0x4XX recived")
        parse4xx(state, data)

      {0, x} when x in 0x500..0x599 ->
        Logger.info("Message 0x5XX recived")
        parse5xx(state, data)

      _ ->
        if extended == 1 do
          Logger.info("Unexpected Extended CAN ID recived: #{inspect id}")
        else
          Logger.info("Unexpected CAN ID recived: #{inspect id}")
        end
    end
    parse_msg(new_state, t)
  end

  defp response00(state) do
    ### All voltages and temperatures should be sent as little endian ??!
    ### Percentage values should be sent without decimals (/100) and temperature values should add 1k (+1000), dont know why
    <<id::size(32)>> = <<1::size(1), 0x4210::integer-size(31)>>
    frames = [{id, <<trunc(state.soh_pptt/100)::unsigned-integer-size(8),
                    trunc(state.reported_soc/100)::unsigned-integer-size(8),
                    state.temperature_max_dC+1000::integer-size(16)-little,
                    state.current_dA::integer-size(16),
                    state.voltage_dV::unsigned-integer-size(16)-little>>}]

    <<id::size(32)>> = <<1::size(1), 0x4220::integer-size(31)>>
    frames = [{id, <<state.max_discharge_current_dA::integer-size(16),
                    state.max_charge_current_dA::integer-size(16),
                    state.min_design_voltage_dV::unsigned-integer-size(16)-little,
                    state.max_design_voltage_dV::unsigned-integer-size(16)-little >>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4230::integer-size(31)>>
    frames = [{id, <<0::size(32),
                    state.min_cell_voltage_mV::unsigned-integer-size(16)-little,
                    state.max_cell_voltage_mV::unsigned-integer-size(16)-little >>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4240::integer-size(31)>>
    frames = [{id, <<0::size(32),
                    state.temperature_min_dC+1000::integer-size(16)-little,
                    state.temperature_max_dC+1000::integer-size(16)-little>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4250::integer-size(31)>>
    frames = [{id, <<0::size(56),
                    state.bms_status::unsigned-integer-size(8)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4260::integer-size(31)>>
    frames = [{id, <<state.msg_4260::binary>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4270::integer-size(31)>>
    frames = [{id, <<0::size(32),
                    state.min_cell_voltage_lim_mV::unsigned-integer-size(16)-little,
                    state.max_cell_voltage_lim_mV::unsigned-integer-size(16)-little>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4280::integer-size(31)>>
    frames = [{id, <<0::size(32),
                    state.disable_chg_dischg::binary>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4290::integer-size(31)>>
    frames = [{id, <<state.msg_4290::binary>>} | frames]

    Ng.Can.write(state.can_port, frames)
  end

  defp response02(state) do
    <<id::size(32)>> = <<1::size(1), 0x7310::integer-size(31)>>
    frames = [{id, <<state.msg_7310::binary>>}]

    <<id::size(32)>> = <<1::size(1), 0x7320::integer-size(31)>>
    frames = [{id, <<state.ah_capacity::unsigned-integer-size(16),
                    state.voltage_level::unsigned-integer-size(16),
                    state.cells_per_module::unsigned-integer-size(8),
                    state.modules_in_series::unsigned-integer-size(8),
                    state.total_cell_amount::unsigned-integer-size(16)>>} | frames]


    Ng.Can.write(state.can_port, frames)
  end

  def parse1xx(state, data) do
    <<_can2can_status::unsigned-integer-size(4),
    _operational_status::unsigned-integer-size(2),
    hvbusconnection_status::unsigned-integer-size(4),
    _cellbalaceing_active::unsigned-integer-size(4),
    _hvil_status::unsigned-integer-size(2),
    _hvbusactiveisotest_status::unsigned-integer-size(4),
    hvbusdisconnect_forewarning::unsigned-integer-size(4),
    _electronics_temp::unsigned-integer-size(8),
    maxcharge_curr::unsigned-integer-size(16),
    maxdischarge_curr::unsigned-integer-size(16)>> = data

    %{state | max_discharge_current_dA: trunc(((0.05*maxdischarge_curr)-1600)*100),
              max_charge_current_dA: trunc(((0.05*maxcharge_curr)-1600)*100),
              disable_chg_dischg: (if (hvbusdisconnect_forewarning != 0 || hvbusconnection_status == 0), do: <<0xAA, 0xAA, 0xAA, 0xAA>>, else: <<0x00, 0x00,0x00, 0x00>>)
    }
  end

  defp parse2xx(state, data) do
    <<ucell_min::unsigned-integer-size(16),
    ucell_max::unsigned-integer-size(16),
    ibat::unsigned-integer-size(16),
    ubat::unsigned-integer-size(16)>> = data

    %{state | min_cell_voltage_mV: trunc(0.001*ucell_min),
              max_cell_voltage_mV: trunc(0.001*ucell_max),
              current_dA: trunc(((0.05*ibat)-1600)*100),
              voltage_dV: trunc((0.05*ubat)*100),
    }
  end

  defp parse3xx(state, data) do
    <<_soccell_max::unsigned-integer-size(16),
      _soccell_min::unsigned-integer-size(16),
      tcellmin::unsigned-integer-size(16),
      tcellmax::unsigned-integer-size(16)>> = data

    %{state | temperature_min_dC: trunc(((0.03125*tcellmin)-173)*100),
              temperature_max_dC: trunc(((0.03125*tcellmax)-273)*100),
    }
  end

  defp parse4xx(state, data) do
    <<_ucell_avg::unsigned-integer-size(16),
      _ignition_volt::unsigned-integer-size(16),
      _bus_volt::unsigned-integer-size(16),
      soc::unsigned-integer-size(16)>> = data

    %{state | reported_soc: trunc(0.0015625*soc)}
  end

  defp parse5xx(state, data) do
    <<_pad1::unsigned-integer-size(16),
    _pad2::unsigned-integer-size(16),
    _errorcode::unsigned-integer-size(16),
    _watchdogcounter::unsigned-integer-size(16)>> = data

    state
  end

  defp build100frames(state) do
    on = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    off = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>

    com_ok = if state.bms_status != 0, do: on, else: off

    <<id::size(32)>> = <<0::size(1), 0xF0::integer-size(31)>> ## HV Enable
    frames = [{id, com_ok}]

    <<id::size(32)>> = <<0::size(1), 0xF3::integer-size(31)>>  ## 24 VPC ON
    frames = [{id, on} | frames]

    <<id::size(32)>> = <<0::size(1), 0xF4::integer-size(31)>> ## INV Enable
    frames = [{id, com_ok} | frames]

    Ng.Can.write(state.can_port, frames)
  end

  defp build1000frames(state) do
    #on = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    off = <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>

    <<id::size(32)>> = <<0::size(1), 0xF1::integer-size(31)>> ## ActiveIsolationCommand
    frames = [{id, off}]

    <<id::size(32)>> = <<0::size(1), 0xF2::integer-size(31)>>  ## Cell Balancing Command
    frames = [{id, off} | frames]

    <<id::size(32)>> = <<0::size(1), 0xF5::integer-size(31)>> ## Can_Can_Error_Clear
    frames = [{id, off} | frames]

    <<id::size(32)>> = <<0::size(1), 0xF6::integer-size(31)>> ## Watchdog
    frames = [{id, <<0::integer-size(32),
                    0::unsigned-integer-size(16),
                    state.watchdog_counter::unsigned-integer-size(16)>>} | frames]

    Ng.Can.write(state.can_port, frames)
  end

end

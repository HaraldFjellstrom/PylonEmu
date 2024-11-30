defmodule PylonEmu do
  require Logger

  defmodule BatState do
    defstruct  [:can_port,                          # pid to CAN process
                temperature_max_dC: 0,              # INT16   in deci °C
                temperature_min_dC: 0,              # INT16   in deci °C
                voltage_dV: 0,                      # UINT16  in deci volt
                current_dA: 0,                      # INT16   in deci ampere
                reported_soc: 0,                    # UINT16  integer-percent x 100. 9550 = 95.50%
                soh_pptt: 0,                        # UINT16  integer-percent x 100. 9550 = 95.50%
                max_charge_current_dA: 0,           # UINT16  in deci ampere
                max_discharge_current_dA: 0,        # UINT16  in deci ampere
                max_cell_voltage_mV: 0,             # UINT16  in milli volt
                min_cell_voltage_mV: 0,             # UINT16  in milli volt
                bms_status: 0,                      # UINT8   0x00 = SLEEP/FAULT 0x01 = Charge 0x02 = Discharge 0x03 = Idle
                disable_chg_dischg: <<0x00, 0x00,0x00, 0x00>>,      # Set to <<0xAA, 0xAA, 0xAA, 0xAA>> to disable battery, else <<0x00, 0x00, 0x00, 0x00>>
                msg_4260: <<0xAC, 0xC7, 0x74, 0x27, 0x03, 0x00, 0x02, 0x00>>, # ??
                msg_4290: <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>, # ??
                msg_7310: <<0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x00, 0x00>>, # ??
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

  @impl true
  def init(can_if) do
    {:ok, can_port} = Ng.Can.start_link
    Ng.Can.open(can_port, can_if, sndbuf: 1024, rcvbuf: 106496)
    Ng.Can.await_read(can_port)

    {:ok, %BatState{can_port: can_port}}
  end

  @impl true
  def handle_info({:can_frames, _interface_name, recvd_frames}, state) do
    Enum.map(recvd_frames, fn {id, data} ->
      <<_ide::size(1), _rtr::size(1), id::size(30)>> = <<id::integer-size(32)>>
      if id == 0x4200 do
        <<val::size(8), _::binary>> = data
        case val do
          0x00 ->
            Logger.info("Sending response after reciving #{inspect val}")
            response00(state)
          0x02 ->
            Logger.info("Sending response after reciving #{inspect val}")
            response02(state)
          _ ->
            Logger.info("No Resonse sent, recived #{inspect val}")
        end
      end
    end)
    Ng.Can.await_read(state.can_port)
    {:noreply, state}
  end

  defp response00(state) do
    ### All voltages and temperatures should be sent as little endian ??!
    ### Percentage values should be sent without decimals (/100) and temperature values should add 1k (+1000), dont know why
    <<id::size(32)>> = <<1::size(1), 0x4210::integer-size(31)>>
    frames = [{id, <<state.voltage_dV::unsigned-integer-size(16)-little,
                    state.current_dA::integer-size(16),
                    state.temperature_max_dC+1000::integer-size(16)-little,
                    trunc(state.reported_soc/100)::unsigned-integer-size(8),
                    trunc(state.soh_pptt/100)::unsigned-integer-size(8)>>}]

    <<id::size(32)>> = <<1::size(1), 0x4220::integer-size(31)>>
    frames = [{id, <<state.max_design_voltage_dV::unsigned-integer-size(16)-little,
            state.min_design_voltage_dV::unsigned-integer-size(16)-little,
            state.max_charge_current_dA::integer-size(16),
            state.max_discharge_current_dA::integer-size(16)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4230::integer-size(31)>>
    frames = [{id, <<state.max_cell_voltage_mV::unsigned-integer-size(16)-little,
            state.min_cell_voltage_mV::unsigned-integer-size(16)-little,
            0::size(32)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4240::integer-size(31)>>
    frames = [{id, <<state.temperature_max_dC+1000::integer-size(16)-little,
            state.temperature_min_dC+1000::integer-size(16)-little,
            0::size(32)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4250::integer-size(31)>>
    frames = [{id, <<state.bms_status::unsigned-integer-size(8),
            0::size(56)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4260::integer-size(31)>>
    frames = [{id, <<state.msg_4260::binary>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4270::integer-size(31)>>
    frames = [{id, <<state.max_cell_voltage_lim_mV::unsigned-integer-size(16)-little,
            state.min_cell_voltage_lim_mV::unsigned-integer-size(16)-little,
            0::size(32)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4280::integer-size(31)>>
    frames = [{id, <<state.disable_chg_dischg::binary,
            0::size(32)>>} | frames]

    <<id::size(32)>> = <<1::size(1), 0x4290::integer-size(31)>>
    frames = [{id, <<state.msg_4290::binary>>} | frames]

    Ng.Can.write(state.can_port, frames)
  end

  defp response02(state) do
    <<id::size(32)>> = <<1::size(1), 0x7310::integer-size(31)>>
    frames = [{id, <<state.msg_7310::binary>>}]

    <<id::size(32)>> = <<1::size(1), 0x7320::integer-size(31)>>
    frames = [{id, <<state.total_cell_amount::unsigned-integer-size(16),
                    state.modules_in_series::unsigned-integer-size(8),
                    state.cells_per_module::unsigned-integer-size(8),
                    state.voltage_level::unsigned-integer-size(16),
                    state.ah_capacity::unsigned-integer-size(16)>>} | frames]


    Ng.Can.write(state.can_port, frames)
  end

end

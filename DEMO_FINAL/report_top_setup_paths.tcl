project_open tcp_packet_receiver_redo -revision tcp_packet_receiver_redo
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -from_clock {clock_50_0} -to_clock {clock_50_0} -npaths 20 -detail full_path -file top_setup_paths.rpt
delete_timing_netlist
project_close
